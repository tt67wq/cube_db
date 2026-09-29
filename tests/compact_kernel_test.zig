//! tests/compact_kernel_test.zig — U5-5: compactFull copy-kernel TDD (design
//! `bb4d489` §7 step 3). The kernel rewrites the OLD root's visible set into
//! a brand-new tree and returns {new_root, stats, retired list} WITHOUT any
//! publish/commit/meta work (that is step 4's job).
//!
//! RED phase: `cube.compact` (src/compact.zig) does not exist yet — every
//! reference below fails compilation, which is the recorded red.
//!
//! Assertions (task contract):
//!   (i)   new tree select ≡ old db select ≡ oracle (three-way, per key AND
//!         per value bytes, via tests/compact_common.zig);
//!   (ii)  new tree contains ZERO tombstone entries (raw leaf walk);
//!   (iii) retired == collectTreePages(old_root) ∪ old tomb-chain pages,
//!         deduped, with NO new-tree pages mixed in;
//!   (iv)  abort path: pages returned to the pool, allocator intact
//!         (std.testing.allocator leak check), old db untouched.

const std = @import("std");
const cube = @import("cube_db");
const btree = cube.btree;
const cc = @import("compact_common.zig");
const compact = cube.compact; // RED: module does not exist yet
const Db = cube.Db;
const Entry = cube.Entry;
const MemPageStore = cube.page_store.MemPageStore;

const PAGE_SIZE = cube.format.PAGE_SIZE;
const PAGE_HEADER_SIZE = cube.format.PAGE_HEADER_SIZE;

// ===== fixture: 300 puts → point-delete every 3rd → deleteRange [100,200) =====

fn oracleSpec() cc.ChurnSpec {
    var ops: [300 + 100 + 1]cc.ChurnOp = undefined;
    var n: usize = 0;
    for (0..300) |i| {
        ops[n] = .{ .put = .{ .idx = i, .value_len = 100 } };
        n += 1;
    }
    for (0..300) |i| {
        if (i % 3 == 0) {
            ops[n] = .{ .del = .{ .idx = i } };
            n += 1;
        }
    }
    ops[n] = .{ .del_range = .{ .min_idx = 100, .max_idx = 200 } };
    n += 1;
    const frozen = ops;
    return .{ .ops = frozen[0..n] };
}

const oracle_spec = oracleSpec();

// NOTE: MemPageStore must be heap-pinned before Db.open borrows its address —
// returning the struct by value would leave db.store pointing at a dead frame
// local (mutex/pointer identity broken → futex hang on the first page read).
const Env = struct {
    ms: *MemPageStore,
    db: *Db,
    fn deinit(e: *Env, allocator: std.mem.Allocator) void {
        e.db.close();
        e.ms.deinit();
        allocator.destroy(e.ms);
    }
};

fn openChurnDb(allocator: std.mem.Allocator, mapsize: u32) !Env {
    const ms = try allocator.create(MemPageStore);
    ms.* = MemPageStore.init(allocator, mapsize);
    errdefer allocator.destroy(ms);
    const db = try Db.open(allocator, ms.store(), .{});
    errdefer db.close();
    try cc.buildChurnDb(allocator, db, oracle_spec);
    return .{ .ms = ms, .db = db };
}

// ===== test-local walkers (independent of the kernel) =====

/// Raw tree walk over `root`: counts tombstone-flagged leaf entries and
/// collects every visible (non-tombstone) entry. Asserts zero tombstones by
/// returning the count.
const RawWalk = struct {
    tomb_entries: usize,
    visible: usize,
};

fn walkRaw(allocator: std.mem.Allocator, store: cube.page_store.PageStore, root: u32) !RawWalk {
    var st: RawWalk = .{ .tomb_entries = 0, .visible = 0 };
    if (root == 0) return st;
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, root);
    while (stack.items.len > 0) {
        const pn = stack.pop().?;
        const page = try store.readPage(pn);
        const hdr = cube.format.decodePageHeader(page[0..PAGE_HEADER_SIZE]);
        const payload = page[PAGE_HEADER_SIZE .. PAGE_SIZE - 4];
        switch (hdr.page_type) {
            cube.format.PAGE_TYPE_BRANCH => {
                const count: usize = std.mem.readInt(u16, payload[1..3], .little);
                var pos: usize = 3;
                var i: usize = 0;
                while (i + 1 < count) : (i += 1) {
                    const klen = std.mem.readInt(u32, payload[pos..][0..4], .little);
                    pos += 4 + klen;
                }
                for (0..count) |j| {
                    const child = std.mem.readInt(u32, payload[pos + 4 * j ..][0..4], .little);
                    if (child != 0) try stack.append(allocator, child);
                }
            },
            cube.format.PAGE_TYPE_LEAF => {
                const count: usize = std.mem.readInt(u16, payload[1..3], .little);
                var pos: usize = 3;
                for (0..count) |_| {
                    const tomb = payload[pos] == 1;
                    pos += 1;
                    const klen = std.mem.readInt(u32, payload[pos..][0..4], .little);
                    pos += 4 + klen;
                    const vlen = std.mem.readInt(u32, payload[pos..][0..4], .little);
                    pos += 4;
                    const flags = payload[pos];
                    pos += 1;
                    if (tomb) st.tomb_entries += 1 else st.visible += 1;
                    if (flags & 1 != 0) pos += 4 else pos += vlen;
                }
            },
            else => return error.UnexpectedPageType,
        }
    }
    return st;
}

/// Old tomb-chain pages: walk `free_next` from `head` (header-driven, with a
/// revisit guard), independent of any kernel code.
fn chainPages(store: cube.page_store.PageStore, head: u32, out: *std.AutoHashMap(u32, void)) !void {
    var cur = head;
    while (cur != 0) {
        const gop = try out.getOrPut(cur);
        if (gop.found_existing) return error.ChainLoop;
        const page = try store.readPage(cur);
        const hdr = cube.format.decodePageHeader(page[0..PAGE_HEADER_SIZE]);
        cur = hdr.free_next;
    }
}

fn pageSet(allocator: std.mem.Allocator, pages: []const u32) !std.AutoHashMap(u32, void) {
    var set = std.AutoHashMap(u32, void).init(allocator);
    errdefer set.deinit();
    for (pages) |p| try set.put(p, {});
    return set;
}

// ===== (i)+(ii)+(iii): three-way reconciliation on a churned db =====

test "compactKernel: churn copy — new tree == oracle == old select, zero tombstones, retirement exact" {
    const allocator = std.testing.allocator;
    var env = try openChurnDb(allocator, 10_000);
    defer env.deinit(allocator);
    const old_root = env.db.getRoot();
    const old_tomb_head = env.db.state.getTombHead();

    const result = try compact.run(env.db, allocator, .{});
    defer allocator.free(result.retired_pages);
    defer allocator.free(result.new_pages);

    // --- (i) new tree select ≡ old db select ≡ oracle ---
    var want = try cc.expectedVisible(allocator, oracle_spec);
    defer want.deinit();

    // old db visible set (key idx)
    var old_set = std.AutoHashMap(u64, void).init(allocator);
    defer old_set.deinit();
    var it_old = try env.db.select(null, null);
    defer it_old.deinit();
    while (try it_old.next()) |e| {
        try std.testing.expectEqual(@as(usize, 10), e.key.len);
        try old_set.put(try std.fmt.parseInt(u64, e.key, 10), {});
    }

    // new tree visible set (key idx + value bytes)
    var new_set = std.AutoHashMap(u64, void).init(allocator);
    defer new_set.deinit();
    var it_new = try btree.selectChecked(allocator, env.db.store, result.new_root, null, null, .off);
    defer it_new.deinit();
    var new_count: usize = 0;
    while (try it_new.next()) |e| {
        try std.testing.expectEqual(@as(usize, 10), e.key.len);
        const idx = try std.fmt.parseInt(u64, e.key, 10);
        try new_set.put(idx, {});
        // value bytes must equal the fixture's fill ('x' * 100)
        try std.testing.expectEqual(@as(usize, 100), e.value.len);
        for (e.value) |b| try std.testing.expectEqual(@as(u8, 'x'), b);
        new_count += 1;
    }

    try std.testing.expectEqual(old_set.count(), new_set.count());
    try std.testing.expectEqual(want.count(), new_set.count());
    var wit = want.keyIterator();
    while (wit.next()) |k| {
        try std.testing.expect(old_set.contains(k.*));
        try std.testing.expect(new_set.contains(k.*));
    }
    try std.testing.expectEqual(@as(u64, new_count), result.entries_copied);

    // B-formula: kernel stats == oracle
    try std.testing.expectEqual(try cc.expectedLiveBytes(allocator, oracle_spec), result.live_bytes);

    // --- (ii) zero tombstone entries in the new tree ---
    const raw_new = try walkRaw(allocator, env.db.store, result.new_root);
    try std.testing.expectEqual(@as(usize, 0), raw_new.tomb_entries);
    try std.testing.expectEqual(new_count, raw_new.visible);

    // --- (iii) retirement == collectTreePages(old_root) ∪ chain pages ---
    var expected_retired = std.AutoHashMap(u32, void).init(allocator);
    defer expected_retired.deinit();
    var collected: std.ArrayList(u32) = .empty;
    defer collected.deinit(allocator);
    try btree.collectTreePages(allocator, env.db.store, old_root, &collected);
    for (collected.items) |p| try expected_retired.put(p, {});
    try chainPages(env.db.store, old_tomb_head, &expected_retired);

    var retired_set = try pageSet(allocator, result.retired_pages);
    defer retired_set.deinit();
    try std.testing.expectEqual(expected_retired.count(), retired_set.count());
    var erit = expected_retired.keyIterator();
    while (erit.next()) |p| try std.testing.expect(retired_set.contains(p.*));
    // F1 (U5-5-F review): the contract says retired_pages is DEDUPED — the
    // list length itself must equal the unique-page count (no page listed
    // twice; step 4 consumes it directly and MemPageStore.freePage does not
    // dedup pool inserts).
    try std.testing.expectEqual(expected_retired.count(), result.retired_pages.len);

    // no new-tree pages mixed into retirement
    var new_set_pages = try pageSet(allocator, result.new_pages);
    defer new_set_pages.deinit();
    var rit = retired_set.keyIterator();
    while (rit.next()) |p| try std.testing.expect(!new_set_pages.contains(p.*));

    // new_pages must itself equal a fresh collect of the new root
    var fresh_new: std.ArrayList(u32) = .empty;
    defer fresh_new.deinit(allocator);
    try btree.collectTreePages(allocator, env.db.store, result.new_root, &fresh_new);
    try std.testing.expectEqual(fresh_new.items.len, result.new_pages.len);

    // old db untouched by the kernel run (no publish, no frees): re-select
    var it_old2 = try env.db.select(null, null);
    defer it_old2.deinit();
    var old_again: usize = 0;
    while (try it_old2.next()) |_| old_again += 1;
    try std.testing.expectEqual(old_set.count(), old_again);
    try std.testing.expectEqual(old_root, env.db.getRoot());
}

// ===== empty db: zero side effects =====

test "compactKernel: empty db (root 0, tomb 0) — empty result, no work" {
    const allocator = std.testing.allocator;
    var ms = MemPageStore.init(allocator, 1_000);
    defer ms.deinit();
    const db = try Db.open(allocator, ms.store(), .{});
    defer db.close();

    const result = try compact.run(db, allocator, .{});
    defer allocator.free(result.retired_pages);
    defer allocator.free(result.new_pages);

    try std.testing.expectEqual(@as(u32, 0), result.new_root);
    try std.testing.expectEqual(@as(u64, 0), result.entries_copied);
    try std.testing.expectEqual(@as(u64, 0), result.live_bytes);
    try std.testing.expectEqual(@as(usize, 0), result.retired_pages.len);
    try std.testing.expectEqual(@as(usize, 0), result.new_pages.len);
}

// ===== all-dead db: V=0, new_root=0, retirement covers tree + chain =====

test "compactKernel: all-dead db — V=0, new root 0, old tree + chain fully retired" {
    const allocator = std.testing.allocator;
    var ms = MemPageStore.init(allocator, 10_000);
    defer ms.deinit();
    const db = try Db.open(allocator, ms.store(), .{});
    defer db.close();

    var kbuf: [10]u8 = undefined;
    const entries = try allocator.alloc(Entry, 100);
    defer allocator.free(entries);
    for (entries, 0..) |*e, i| {
        e.* = .{ .key = try allocator.dupe(u8, cc.fmtKey(&kbuf, i)), .value = "v" };
    }
    defer for (entries) |e| allocator.free(e.key);
    try db.putBatch(entries);
    try db.deleteRange(null, null); // full-range tombstone: everything shadowed

    const old_root = db.getRoot();
    try std.testing.expect(old_root != 0);
    const old_tomb_head = db.state.getTombHead();
    try std.testing.expect(old_tomb_head != 0);

    const result = try compact.run(db, allocator, .{});
    defer allocator.free(result.retired_pages);
    defer allocator.free(result.new_pages);

    try std.testing.expectEqual(@as(u64, 0), result.entries_copied);
    try std.testing.expectEqual(@as(u64, 0), result.live_bytes);
    try std.testing.expectEqual(@as(u32, 0), result.new_root);

    // retirement == full old tree ∪ chain
    var expected = std.AutoHashMap(u32, void).init(allocator);
    defer expected.deinit();
    var collected: std.ArrayList(u32) = .empty;
    defer collected.deinit(allocator);
    try btree.collectTreePages(allocator, db.store, old_root, &collected);
    for (collected.items) |p| try expected.put(p, {});
    try chainPages(db.store, old_tomb_head, &expected);
    var retired_set = try pageSet(allocator, result.retired_pages);
    defer retired_set.deinit();
    try std.testing.expectEqual(expected.count(), retired_set.count());
    try std.testing.expect(retired_set.count() > 1); // tree + chain both present
}

// ===== (iv) abort: pages returned, allocator intact, old db intact =====

test "compactKernel: progress abort — CompactAborted, pool restored, allocator clean, old db intact" {
    const allocator = std.testing.allocator;
    var env = try openChurnDb(allocator, 10_000);
    defer env.deinit(allocator);
    const pool_before = env.ms.freelist.items.len;
    const nf_before = env.ms.next_free;
    const old_root = env.db.getRoot();

    const AbortCtx = struct { calls: usize = 0 };
    var ctx = AbortCtx{};
    const S = struct {
        fn progress(copied: u64, batches: u64, user: ?*anyopaque) bool {
            _ = copied;
            const c: *AbortCtx = @ptrCast(@alignCast(user.?));
            c.calls += 1;
            return batches < 2; // abort on the 2nd callback (batches==2)
        }
    };
    const result = compact.run(env.db, allocator, .{ .progress = S.progress, .progress_user = &ctx, .batch_max_entries = 50 });
    try std.testing.expectError(error.CompactAborted, result);
    try std.testing.expect(ctx.calls >= 2);

    // every page the kernel allocated was returned to the pool
    // Exact "everything returned" invariant: each allocation either popped a
    // pooled page (net zero on the freelist) or bumped the high-water mark
    // (its return adds +1 freelist AND bump had added +1 next_free). So
    // freelist growth MUST equal high-water growth — a leaked page breaks it
    // (freelist too small), a double-returned page breaks it (too large).
    const nf_after = env.ms.next_free;
    try std.testing.expectEqual(nf_after - nf_before, @as(u32, @intCast(env.ms.freelist.items.len - pool_before)));

    // old db fully intact and still consistent with the oracle
    var want = try cc.expectedVisible(allocator, oracle_spec);
    defer want.deinit();
    var it = try env.db.select(null, null);
    defer it.deinit();
    var seen: usize = 0;
    while (try it.next()) |e| {
        _ = want.remove(try std.fmt.parseInt(u64, e.key, 10));
        seen += 1;
    }
    try std.testing.expectEqual(want.count(), 0);
    try std.testing.expectEqual(@as(usize, 133), seen);
    try std.testing.expectEqual(old_root, env.db.getRoot());
}

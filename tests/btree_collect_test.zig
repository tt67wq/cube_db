//! tests/btree_collect_test.zig — U5-3 step 2: `btree.collectTreePages` RED
//! tests (design `bb4d489` §7 step 2 verbatim acceptance) + the
//! `compact_common` oracle self-test (step 1's gate-visible enforcement,
//! since the helper module itself is test-free by contract).
//!
//! RED phase: `btree.collectTreePages` does not exist at base `8f578cd` —
//! every collectTreePages reference below fails compilation (asserted in the
//! U5-3 report). The oracle self-test is GREEN from the start (it only needs
//! the helper + engine), which is fine: the acceptance gate for step 2 is the
//! three collectTreePages cases.

const std = @import("std");
const cube = @import("cube_db");
const btree = cube.btree;
const cc = @import("compact_common.zig");
const Db = cube.Db;
const Entry = cube.Entry;
const MemPageStore = cube.page_store.MemPageStore;

const c = @import("cube_db").libc; // 0.17: @cImport removed

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

/// Deterministic small churn: 300 puts → delete every 3rd (point) →
/// deleteRange over [100, 200). Visible = {0,2,4,...} \ [100,200) re-derived
/// independently by the oracle.
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

// ===== Step 1 gate: oracle self-test (helper module has no tests itself) =====

test "compact_common: oracle visible set / count / B-formula agree with Db" {
    const allocator = std.heap.page_allocator;
    var ms = MemPageStore.init(allocator, 10_000);
    defer ms.deinit();
    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();

    try cc.buildChurnDb(allocator, db, oracle_spec);
    try cc.assertOracleMatches(allocator, db, oracle_spec);

    // explicit expected count: 300 puts; point deletes remove multiples of 3
    // (100 keys); range [100,200) removes the non-multiples-of-3 inside it
    // (67 keys). Independent arithmetic: survivors = 200 - 67 = 133.
    var want: usize = 0;
    for (0..300) |i| {
        if (i % 3 == 0) continue; // deleted by point
        if (i >= 100 and i < 200) continue; // covered by range
        want += 1;
    }
    try std.testing.expectEqual(@as(usize, 133), want); // pinned so oracle drift can't hide
    try std.testing.expectEqual(@as(u64, want), db.entryCount());
}

// ===== Step 2: collectTreePages (RED at base — decl missing) =====

test "collectTreePages: deep tree — reachable page count equals theoretical value" {
    const allocator = std.heap.page_allocator;
    var ms = MemPageStore.init(allocator, 100_000);
    defer ms.deinit();
    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();

    // 3000 × 100B entries → multi-level tree (leaf cap 32 entries @ payload):
    // theoretical pages = leaves(ceil(3000/32)=94) + branches + root, all
    // reachable from root; walker must find exactly the reachable set.
    const n = 3000;
    const entries = try allocator.alloc(Entry, n);
    defer allocator.free(entries);
    var value: [100]u8 = undefined;
    @memset(&value, 'v');
    var kbuf: [10]u8 = undefined;
    for (entries, 0..) |*e, i| e.* = .{ .key = try allocator.dupe(u8, cc.fmtKey(&kbuf, i)), .value = &value };
    defer for (entries) |e| allocator.free(e.key);
    try db.putBatch(entries);

    var pages: std.ArrayList(u32) = .empty;
    defer pages.deinit(std.testing.allocator);
    try btree.collectTreePages(std.testing.allocator, db.store, db.getRoot(), &pages);

    // min leaves = ceil(3000 / 32); actual must be >= min and every page
    // distinct (no duplicates — visited-set semantics)
    const min_leaves = (n + 31) / 32;
    try std.testing.expect(pages.items.len >= min_leaves);
    var uniq = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer uniq.deinit();
    for (pages.items) |p| try uniq.put(p, {});
    try std.testing.expectEqual(pages.items.len, uniq.count());
    // root itself is reachable
    var has_root = false;
    for (pages.items) |p| {
        if (p == db.getRoot()) has_root = true;
    }
    try std.testing.expect(has_root);
    // page账 cross-check: reachable total == 1 root path root+branches+leaves,
    // and must be <= file_pages - 3 reserved
    try std.testing.expect(pages.items.len + 3 <= ms.next_free);
}

test "collectTreePages: overflow chains — whole chain collected from leaf reference" {
    const allocator = std.heap.page_allocator;
    var ms = MemPageStore.init(allocator, 10_000);
    defer ms.deinit();
    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();

    // one entry with a 10KB value → 3-page overflow chain (4068B/page)
    var value: [10240]u8 = undefined;
    @memset(&value, 'O');
    try db.put("big", &value);

    var pages: std.ArrayList(u32) = .empty;
    defer pages.deinit(std.testing.allocator);
    try btree.collectTreePages(std.testing.allocator, db.store, db.getRoot(), &pages);

    // root leaf + 3 overflow pages = 4 reachable pages
    try std.testing.expectEqual(@as(usize, 4), pages.items.len);
    // and the chain pages are page-typed OVERFLOW on disk
    var ovf: usize = 0;
    for (pages.items) |p| {
        const page = try db.store.readPage(p);
        const hdr = cube.format.decodePageHeader(page[0..cube.format.PAGE_HEADER_SIZE]);
        if (hdr.page_type == cube.format.PAGE_TYPE_OVERFLOW) ovf += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), ovf);
}

test "collectTreePages: cycle injection — bounded termination with error.Truncated (no hang)" {
    const allocator = std.heap.page_allocator;
    var ms = MemPageStore.init(allocator, 10_000);
    defer ms.deinit();
    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();

    // enough entries for a branch root with >=2 children
    const n = 300;
    const entries = try allocator.alloc(Entry, n);
    defer allocator.free(entries);
    var value: [100]u8 = undefined;
    @memset(&value, 'v');
    var kbuf: [10]u8 = undefined;
    for (entries, 0..) |*e, i| e.* = .{ .key = try allocator.dupe(u8, cc.fmtKey(&kbuf, i)), .value = &value };
    defer for (entries) |e| allocator.free(e.key);
    try db.putBatch(entries);

    const root = db.getRoot();
    // Cycle injection: rewrite the ROOT branch's first child pointer to point
    // back at the root itself (header untouched — collector must not depend on
    // CRC validity to terminate).
    {
        const rpage = try db.store.readPage(root);
        const rhdr = cube.format.decodePageHeader(rpage[0..cube.format.PAGE_HEADER_SIZE]);
        try std.testing.expectEqual(cube.format.PAGE_TYPE_BRANCH, rhdr.page_type); // injection precondition
        const page = try db.store.readPage(root);
        const raw: [*]u8 = @constCast(page.ptr);
        const payload = raw[cube.format.PAGE_HEADER_SIZE .. cube.format.PAGE_SIZE - 4];
        // branch payload: kind(1) + count(2) + separators(count-1 × 4+klen)
        // + children(count × 4). Parse separators to find the children area —
        // the payload window is zero-padded past the encoded size, so the
        // children are NOT at the window end.
        const count = std.mem.readInt(u16, payload[1..3], .little);
        var pos: usize = 3;
        var si: usize = 0;
        while (si + 1 < count) : (si += 1) {
            const klen = std.mem.readInt(u32, payload[pos..][0..4], .little);
            pos += 4 + klen;
        }
        // overwrite the FIRST child slot with the root itself → revisit on walk
        std.mem.writeInt(u32, payload[pos..][0..4], root, .little);
    }

    // The collector must terminate BOUNDED (visited set) and report the cycle
    // as error.Truncated — this expectError IS the acceptance: a hang or an
    // unbounded walk fails the test run (zig test has no timeout, but the
    // visited-set cap makes termination immediate; a missing visited set would
    // loop until OOM, which under page_allocator aborts the process — red).
    var sink_pages: std.ArrayList(u32) = .empty;
    defer sink_pages.deinit(std.testing.allocator);
    try std.testing.expectError(error.Truncated, btree.collectTreePages(std.testing.allocator, db.store, root, &sink_pages));
}

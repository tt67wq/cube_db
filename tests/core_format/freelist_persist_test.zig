//! freelist_persist_test.zig - T-33 RED: freelist persistence (T2 chain layout, T3 roundtrip,
//! T4 bounded churn, T6 damaged-chain variants) built on the T7 partition helper.
//!
//! Contract under test (task.md, wf-red design.md @ 4f2d9cd):
//!   - a FREE page = PageHeader{page_type=FREE, gen=meta.sequence, free_next=next chain page}
//!     + count(u32, actually written) + <=1016 u32 entries + CRC
//!   - meta.free_head = chain head (0 = empty), meta.free_count = total entries across the chain
//!   - open walks the chain and validates it; ANY anomaly => discard the whole chain
//!     (INV-F2: leak, never mis-reclaim) and report it via freeListDiscarded()
//!   - the exception is P0-A: a chain listing a tree-reachable page is *accepted* (open stays O(1),
//!     no tree walk) and the overlap is T7's job to surface afterwards
//!
//! RED status against main (93ec9fc): main writes `.free_head = 0, .free_count = 0` unconditionally
//! (src/writer.zig) and never restores a freelist, so T3's `free_count > 0`, T4's bounded growth and
//! every `freeListDiscarded()` expectation fail. The GREEN-only APIs (freePageCount /
//! freeListDiscarded / freePagesSnapshot) are reached through @hasDecl guards so this file still
//! *compiles* on main and fails on assertions, not on the build.
//!
//! One fixture = one file = one reopen. checkReopen() ends by writing a key (to prove the DB is still
//! usable), which bumps the on-disk sequence — so no test may craft a second fixture into the same
//! file afterwards. Variants that need two shapes get two files.
//!
//! Hookup: comptime @import at the end of tests/core_format/format_test.zig.

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const ps = cube.page_store;
const Db = cube.Db;
const FilePageStore = cube.file_page_store.FilePageStore;
const part = @import("page_partition.zig");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

const alloc = std.testing.allocator;

/// Single-page freelist capacity. GREEN exposes it as f2.MAX_FREE_ENTRIES_PER_PAGE; the fallback is
/// the same arithmetic so this file compiles (and the layout tests stay meaningful) on main.
fn freeCap() u32 {
    if (@hasDecl(f2, "MAX_FREE_ENTRIES_PER_PAGE")) return @intCast(f2.MAX_FREE_ENTRIES_PER_PAGE);
    return @intCast((f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4 - 4) / 4);
}

// ===== GREEN API bridge (task.md: getter 出口, 命名固定) =====

/// The three getters are a fixed-name contract; asserting their existence is one of this file's RED
/// signals (main has none of them).
fn expectStoreGetters() !void {
    try std.testing.expect(@hasDecl(FilePageStore, "freePageCount"));
    try std.testing.expect(@hasDecl(FilePageStore, "freeListDiscarded"));
    try std.testing.expect(@hasDecl(FilePageStore, "freePagesSnapshot"));
}

fn discardedOf(fps: *const FilePageStore) bool {
    if (@hasDecl(FilePageStore, "freeListDiscarded")) return fps.freeListDiscarded();
    return false; // main never restores, so it never discards either
}

fn poolLenOf(fps: *const FilePageStore) usize {
    if (@hasDecl(FilePageStore, "freePageCount")) return fps.freePageCount();
    if (@hasField(FilePageStore, "freelist")) return fps.freelist.items.len;
    return 0;
}

/// Locked snapshot of the pool; null on main (no getter). Caller frees.
fn snapshotOf(fps: *FilePageStore) ?[]u32 {
    if (@hasDecl(FilePageStore, "freePagesSnapshot")) {
        return fps.freePagesSnapshot(alloc) catch null;
    }
    return null;
}

// ===== small utilities =====

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

fn fmtKey(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "k{d:0>6}", .{i}) catch unreachable;
}

fn fmtVal(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "v{d:0>6}", .{i}) catch unreachable;
}

/// Values are small on purpose: insertBatch's bulk-load path chunks by LEAF_MAX_ENTRIES (32) without
/// a byte-budget check, so 32 entries must stay under the 4068B payload cap (32 * (10+7+24) = 1315).
const val_len: usize = 24;

fn putKeys(db: *Db, from: usize, to: usize) !void {
    var entries = std.ArrayList(cube.Entry).empty;
    defer {
        for (entries.items) |e| {
            alloc.free(e.key);
            alloc.free(e.value);
        }
        entries.deinit(alloc);
    }
    for (from..to) |i| {
        const k = try std.fmt.allocPrint(alloc, "k{d:0>6}", .{i});
        errdefer alloc.free(k);
        const v = try alloc.alloc(u8, val_len);
        errdefer alloc.free(v);
        @memset(v, '.');
        _ = try std.fmt.bufPrint(v, "v{d:0>6}", .{i}); // value prefix; padded with '.' to val_len
        try entries.append(alloc, .{ .key = k, .value = v, .tombstone = false });
    }
    try db.putBatch(entries.items);
}

fn deleteKeys(db: *Db, from: usize, to: usize) !void {
    var entries = std.ArrayList(cube.Entry).empty;
    defer {
        for (entries.items) |e| alloc.free(e.key);
        entries.deinit(alloc);
    }
    for (from..to) |i| {
        const k = try std.fmt.allocPrint(alloc, "k{d:0>6}", .{i});
        errdefer alloc.free(k);
        try entries.append(alloc, .{ .key = k, .value = "", .tombstone = true });
    }
    try db.putBatch(entries.items);
}

fn expectKeysPresent(db: *Db, from: usize, to: usize) !void {
    var kbuf: [16]u8 = undefined;
    var vbuf: [16]u8 = undefined;
    for (from..to) |i| {
        const k = fmtKey(&kbuf, i);
        const got = try db.get(k) orelse {
            std.debug.print("key {s} missing\n", .{k});
            return error.KeyMissing;
        };
        defer alloc.free(got);
        const want = fmtVal(&vbuf, i);
        if (got.len < want.len or !std.mem.eql(u8, got[0..want.len], want)) {
            std.debug.print("key {s}: value mismatch (got {d} bytes)\n", .{ k, got.len });
            return error.ValueMismatch;
        }
    }
}

fn expectKeysAbsent(db: *Db, from: usize, to: usize) !void {
    var kbuf: [16]u8 = undefined;
    for (from..to) |i| {
        const k = fmtKey(&kbuf, i);
        if (try db.get(k)) |v| {
            alloc.free(v);
            std.debug.print("key {s} should be gone\n", .{k});
            return error.KeyPresent;
        }
    }
}

// ===== raw file surgery (fixtures must not depend on the code under test) =====

const PageWrite = struct { page_no: u32, bytes: []const u8 };

fn writePages(path_z: [:0]const u8, writes: []const PageWrite) !void {
    const fd = c.open(path_z, c.O_RDWR);
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    for (writes) |w| {
        const off: c.off_t = @as(c.off_t, @intCast(w.page_no)) * @as(c.off_t, @intCast(f2.PAGE_SIZE));
        const want: isize = @intCast(w.bytes.len);
        if (c.pwrite(fd, w.bytes.ptr, w.bytes.len, off) != want) return error.PwriteFailed;
    }
}

/// A FREE chain page: header (with the H1 gen stamp) + entries + CRC.
fn buildFreePage(page_no: u32, gen: u64, free_next: u32, entries: []const u32, out: *[f2.PAGE_SIZE]u8) void {
    @memset(out, 0);
    var h = f2.PageHeader{
        .page_no = page_no,
        .page_type = f2.PAGE_TYPE_FREE,
        .gen = gen,
        .nkeys = 0,
        .free_next = free_next,
    };
    f2.encodePageHeader(out, &h);
    f2.writeFreelistEntries(out, entries); // payload + whole-page CRC
}

/// A CRC-valid LEAF page that is *not* a FREE page (T6 v9 type confusion).
fn buildLeafPage(page_no: u32, out: *[f2.PAGE_SIZE]u8) void {
    @memset(out, 0);
    var h = f2.PageHeader{ .page_no = page_no, .page_type = f2.PAGE_TYPE_LEAF, .gen = 0, .nkeys = 0, .free_next = 0 };
    f2.encodePageHeader(out, &h);
    out[f2.PAGE_HEADER_SIZE] = 2; // btree.zig LEAF_KIND (private there)
    std.mem.writeInt(u16, out[f2.PAGE_HEADER_SIZE + 1 ..][0..2], 0, .little);
    f2.setPageChecksum(out, f2.computePageChecksum(out));
}

/// A CRC-valid OVERFLOW page (T6 v9b).
fn buildOverflowPage(page_no: u32, out: *[f2.PAGE_SIZE]u8) void {
    @memset(out, 0);
    var h = f2.PageHeader{ .page_no = page_no, .page_type = f2.PAGE_TYPE_OVERFLOW, .gen = 0, .nkeys = 0, .free_next = 0 };
    f2.encodePageHeader(out, &h);
    @memset(out[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4], 0xAB);
    f2.setPageChecksum(out, f2.computePageChecksum(out));
}

fn storedCount(page: *const [f2.PAGE_SIZE]u8) u32 {
    return std.mem.readInt(u32, page[f2.PAGE_HEADER_SIZE..][0..4], .little);
}

/// Patch BOTH meta slots with the same content (equal sequences make readMetaPage take slot 0).
/// Writing both keeps fixtures independent of the alternation state.
fn writeMetaBothSlots(path_z: [:0]const u8, base: f2.MetaPage, seq: u64, last_page: u32, free_head: u32, free_count: u64) !void {
    var m = base;
    m.sequence = seq;
    m.last_page = last_page;
    m.free_head = free_head;
    m.free_count = free_count;
    var p0: [f2.PAGE_SIZE]u8 = undefined;
    var p1: [f2.PAGE_SIZE]u8 = undefined;
    f2.writeMetaPage(&p0, &m, 0);
    f2.writeMetaPage(&p1, &m, 1);
    try writePages(path_z, &.{
        .{ .page_no = f2.META_PAGE_0, .bytes = &p0 },
        .{ .page_no = f2.META_PAGE_1, .bytes = &p1 },
    });
}

const Base = struct {
    path_z: [:0]const u8,
    meta: f2.MetaPage,
    n_keys: usize,

    fn deinit(self: *Base) void {
        alloc.free(self.path_z);
    }
    /// First page after everything the base DB used — fixtures lay chain pages + orphan entry pages
    /// above it, so they can never collide with the tree.
    fn tail(self: *const Base) u32 {
        return self.meta.last_page + 1;
    }
};

/// Build a real DB, close it, then re-open to capture the *durable* meta. Capturing after the close
/// matters: GREEN may add the P2 close-time checkpoint (one more meta write), and a fixture meta
/// must outrank whatever is on disk.
fn buildBase(path: []const u8, n_keys: usize) !Base {
    const path_z = try alloc.dupeZ(u8, path);
    errdefer alloc.free(path_z);
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try putKeys(db, 0, n_keys);
        try db.compact();
    }
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    const meta = (try fps.store().readMeta()) orelse return error.NoMeta;
    return .{ .path_z = path_z, .meta = meta, .n_keys = n_keys };
}

/// Fill buf with start, start+1, ... and return it.
fn ramp(buf: []u32, start: u32) []u32 {
    for (buf, 0..) |*b, i| b.* = start + @as(u32, @intCast(i));
    return buf;
}

// ===== T2: chain layout roundtrip (format level) =====

test "T2: freelist chain split roundtrip — 1016/1016/5, total 2037" {
    // GREEN step 1 must publish the capacity constant (chain split + restore bound share it).
    try std.testing.expect(@hasDecl(f2, "MAX_FREE_ENTRIES_PER_PAGE"));
    const cap: usize = freeCap();
    const total = 2 * cap + 5; // 2037 with cap == 1016

    var entries = std.ArrayList(u32).empty;
    defer entries.deinit(alloc);
    for (0..total) |i| try entries.append(alloc, @intCast(1000 + i));

    const seq: u64 = 4242; // H1: chain pages carry the sequence of the meta that points at them
    const pn0: u32 = 11;
    const pn1: u32 = 12;
    const pn2: u32 = 13;
    var page0: [f2.PAGE_SIZE]u8 = undefined;
    var page1: [f2.PAGE_SIZE]u8 = undefined;
    var page2: [f2.PAGE_SIZE]u8 = undefined;
    buildFreePage(pn0, seq, pn1, entries.items[0..cap], &page0);
    buildFreePage(pn1, seq, pn2, entries.items[cap .. 2 * cap], &page1);
    buildFreePage(pn2, seq, 0, entries.items[2 * cap ..], &page2);

    // walk the chain exactly the way restoreFreeList must
    const pages = [_]*const [f2.PAGE_SIZE]u8{ &page0, &page1, &page2 };
    const want_next = [_]u32{ pn1, pn2, 0 };
    const want_count = [_]u32{ @intCast(cap), @intCast(cap), 5 };
    var walked = std.ArrayList(u32).empty;
    defer walked.deinit(alloc);

    var cur: u32 = pn0;
    var i: usize = 0;
    while (cur != 0 and i < pages.len) : (i += 1) {
        const arr = pages[i];
        try std.testing.expect(f2.verifyPageChecksum(arr));
        const hdr = f2.decodePageHeader(arr[0..f2.PAGE_HEADER_SIZE]);
        try std.testing.expectEqual(cur, hdr.page_no);
        try std.testing.expectEqual(f2.PAGE_TYPE_FREE, hdr.page_type);
        try std.testing.expectEqual(seq, hdr.gen);
        try std.testing.expectEqual(want_next[i], hdr.free_next);
        try std.testing.expectEqual(want_count[i], storedCount(arr)); // count == actually written
        for (f2.readFreelistEntries(arr)) |e| try walked.append(alloc, e);
        cur = hdr.free_next;
    }
    try std.testing.expectEqual(@as(usize, 3), i); // terminated by free_next == 0, not by the bound

    // concatenation == the original sequence, and this total is what meta.free_count must carry
    try std.testing.expectEqual(@as(usize, 2037), walked.items.len);
    try std.testing.expectEqualSlices(u32, entries.items, walked.items);
}

// ===== T3: roundtrip — free pages survive close/reopen and get reused =====

test "T3: put/delete/compact/close/reopen — freelist persists and is reused" {
    const path = ".test_fl_persist_t3.db";
    defer unlinkPath(path);

    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try putKeys(db, 0, 400);
        try deleteKeys(db, 0, 200);
        // compact is load-bearing (task.md T3 clarification): the delete commit's COW victims only
        // reach the store pool in applyBatch step 9 — *after* meta S was written — so meta S's chain
        // cannot contain them. compact (= commit S+1) is what actually persists them.
        try db.compact();
    }
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        const meta = (try fps.store().readMeta()) orelse return error.NoMeta;
        const last_page_r1 = meta.last_page;

        // --- fixture sanity first: these hold on main too, so they validate the reopen + T7 helper
        // --- against a real DB state before the feature contract is asked about anything.
        {
            var db = try Db.open(alloc, fps.store(), .{});
            defer db.close();
            try expectKeysPresent(db, 200, 400);
            try expectKeysAbsent(db, 0, 200);
        }
        var rep = try part.classify(alloc, fps.store(), meta);
        defer rep.deinit();
        try part.expectDisjoint(&rep); // INV-F1 on the durable state

        // --- the feature contract ---
        // RED #1 on main: writer.zig hardcodes .free_count = 0 / .free_head = 0
        try std.testing.expect(meta.free_count > 0);
        try std.testing.expect(meta.free_head != 0);
        try std.testing.expectEqual(@as(usize, @intCast(meta.free_count)), rep.free_pages.items.len);
        // (the getter-symbol contract itself is asserted once, in "T6 contract: ...")
        try std.testing.expectEqual(false, discardedOf(&fps));
        try std.testing.expectEqual(@as(usize, @intCast(meta.free_count)), poolLenOf(&fps));

        // the restored pool must be sane: unique, in range (no double-free, no out-of-range page)
        if (snapshotOf(&fps)) |snap| {
            defer alloc.free(snap);
            try std.testing.expectEqual(@as(usize, @intCast(meta.free_count)), snap.len);
            const sorted = try alloc.dupe(u32, snap);
            defer alloc.free(sorted);
            std.mem.sort(u32, sorted, {}, std.sort.asc(u32));
            for (sorted, 0..) |p, i| {
                try std.testing.expect(p >= ps.FIRST_DATA_PAGE and p <= meta.last_page);
                if (i > 0) try std.testing.expect(sorted[i - 1] != p);
            }
        }

        // write again: pages must come from the restored pool, not from the bump allocator
        {
            var db = try Db.open(alloc, fps.store(), .{});
            defer db.close();
            try putKeys(db, 400, 460);
        }
        const meta2 = (try fps.store().readMeta()) orelse return error.NoMeta;
        // RED #3 on main: nothing is reused, so the high-water mark grows
        try std.testing.expect(meta2.last_page <= last_page_r1);
    }
}

// ===== T4: headline criterion — churn does not grow the file across restarts =====

/// Per-round high-water growth once the pool has converged. In steady state a round allocates ~33
/// pages for the 1000-key putBatch and ~17 for the 500-key delete batch and frees the same pages
/// back, so the bump allocator is only reached for the chain pages held out of the pool (two
/// generations) — a couple of pages per round. On main the pool is empty after every reopen, so a
/// round bumps its whole working set (~50). The bound discriminates the two regimes by ~10x.
const max_round_growth: u32 = 4;

test "T4: churn x6 close/reopen — last_page growth bounded (headline criterion)" {
    const path = ".test_fl_persist_t4.db";
    defer unlinkPath(path);
    const n_keys: usize = 1000;
    const n_del: usize = 500;
    const rounds: usize = 6;

    var last_pages: [rounds]u32 = undefined;
    for (0..rounds) |r| {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        // Same key space every round (overwrite + re-insert), same 500 deleted: the live set
        // oscillates 500 <-> 1000 and the page demand is identical round to round.
        try putKeys(db, 0, n_keys);
        try deleteKeys(db, 0, n_del);
        try db.compact(); // load-bearing: see T3
        const meta = (try fps.store().readMeta()) orelse return error.NoMeta;
        last_pages[r] = meta.last_page;
    }

    std.debug.print("T4 last_page per round: ", .{});
    for (last_pages) |lp| std.debug.print("{d} ", .{lp});
    std.debug.print("\n", .{});

    // Rounds 1-2 are warm-up: round 1 ends with only the delete batch's victims in the pool, which
    // is less than one round's peak demand, so round 2 must still bump. From round 3 on the regime
    // is steady and each round may add at most max_round_growth pages.
    for (3..rounds) |r| {
        const delta = last_pages[r] -| last_pages[r - 1];
        if (delta > max_round_growth) {
            std.debug.print(
                "T4 FAIL: round {d} grew last_page by {d} (> {d}) — free pages are not surviving reopen\n",
                .{ r + 1, delta, max_round_growth },
            );
            return error.UnboundedGrowth;
        }
    }
    // and the measured window as a whole must stay flat, not creep
    try std.testing.expect(last_pages[rounds - 1] <= last_pages[2] + max_round_growth * 3);
}

// ===== T6: damaged chains degrade to leak-only (INV-F2) =====

/// What T7 may assert about a fixture. Damaged chains are garbage *by construction*: T7 walks the
/// bytes on disk (it never asks the store what it decided), so for a discarded chain the partition is
/// expected to look wrong — v5b lists a meta page as free, which is exactly why the chain must be
/// dropped. For those variants the contract is the discard itself (INV-F2); T7 only runs as a
/// hang/crash canary plus a tree-intact check.
const T7Mode = enum {
    /// accepted chain: the five classes must be pairwise disjoint
    disjoint,
    /// P0-A: a chain listing a tree page is accepted; T7 must surface the overlap
    tree_free_overlap,
    /// discarded chain: no disjointness claim, but the tree must still walk clean
    skip_damaged_chain,
};

const Reopen = struct {
    base: Base,
    want_discarded: bool,
    /// expected pool size after reopen (null = do not check)
    want_pool: ?usize = null,
    t7: T7Mode = .skip_damaged_chain,
};

/// Shared post-fixture assertions: open must succeed, the discard flag and pool size must match,
/// data must be intact, the partition must match the variant's T7Mode, and the DB must stay writable.
///
/// The GREEN-only getters are reached through the guarded accessors (discardedOf / poolLenOf), so on
/// main each variant fails on *behavior* (nothing restored, damage not detected) rather than on a
/// missing symbol; the symbol contract is asserted once, in the dedicated test below.
fn checkReopen(path: []const u8, r: Reopen) !void {
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    // --- fixture sanity first: these hold on main too, so a broken fixture (or a T7 helper that
    // --- cannot walk a real tree) gets reported as such instead of masquerading as a persistence
    // --- failure. Everything here is read-only: the pool assertions below must precede any write.
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();
    try expectKeysPresent(db, 0, r.base.n_keys); // fixture damage must never touch the tree

    const meta = (try fps.store().readMeta()) orelse return error.NoMeta;
    var rep = try part.classify(alloc, fps.store(), meta);
    defer rep.deinit();
    switch (r.t7) {
        .disjoint => try part.expectDisjoint(&rep),
        .tree_free_overlap => try part.expectOverlap(&rep, .tree, .free_entry),
        .skip_damaged_chain => {
            // canary only: the walk must terminate and the tree must still classify in full
            try std.testing.expect(rep.tree_pages.items.len > 0);
        },
    }

    // --- the feature contract (before the write below mutates the pool) ---
    try std.testing.expectEqual(r.want_discarded, discardedOf(&fps));
    if (r.want_pool) |w| try std.testing.expectEqual(w, poolLenOf(&fps));

    // still writable after a damaged/odd chain
    try db.putDirect("post_fixture", "ok");
    const got = try db.get("post_fixture") orelse return error.KeyMissing;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("ok", got);
}

test "T6 contract: FilePageStore exposes the freelist diagnostics and the pool lock" {
    // Fixed names from task.md ("getter 出口，命名固定") plus the P0 freelist_mu. On main none of
    // these exist: FilePageStore has no lock at all and no way to report what it restored.
    try expectStoreGetters();
    try std.testing.expect(@hasField(FilePageStore, "freelist_mu"));
}

test "T6 v0: well-formed chain is accepted and restored" {
    const path = ".test_fl_t6_v0.db";
    defer unlinkPath(path);
    var base = try buildBase(path, 60);
    defer base.deinit();

    const chain_pg = base.tail(); // L+1
    const orphans = chain_pg + 1; // L+2 .. L+9: never written, so guaranteed non-tree
    var ents: [8]u32 = undefined;
    _ = ramp(&ents, orphans);
    var page: [f2.PAGE_SIZE]u8 = undefined;
    const seq = base.meta.sequence + 1;
    buildFreePage(chain_pg, seq, 0, &ents, &page);
    try writePages(base.path_z, &.{.{ .page_no = chain_pg, .bytes = &page }});
    try writeMetaBothSlots(base.path_z, base.meta, seq, orphans + 7, chain_pg, ents.len);

    try checkReopen(path, .{ .base = base, .want_discarded = false, .want_pool = ents.len, .t7 = .disjoint });
}

test "T6 v1: torn chain page (stale CRC) => discard" {
    const path = ".test_fl_t6_v1.db";
    defer unlinkPath(path);
    var base = try buildBase(path, 60);
    defer base.deinit();

    const chain_pg = base.tail();
    var ents: [4]u32 = undefined;
    _ = ramp(&ents, chain_pg + 1);
    var page: [f2.PAGE_SIZE]u8 = undefined;
    const seq = base.meta.sequence + 1;
    buildFreePage(chain_pg, seq, 0, &ents, &page);
    page[f2.PAGE_HEADER_SIZE + 8] ^= 0xFF; // flip a payload byte, leave the CRC stale
    try std.testing.expect(!f2.verifyPageChecksum(&page));
    try writePages(base.path_z, &.{.{ .page_no = chain_pg, .bytes = &page }});
    try writeMetaBothSlots(base.path_z, base.meta, seq, chain_pg + 4, chain_pg, ents.len);

    try checkReopen(path, .{ .base = base, .want_discarded = true, .want_pool = 0 });
}

test "T6 v2 (P0-A): entry pointing at a tree page is ACCEPTED, T7 surfaces the overlap" {
    const path = ".test_fl_t6_v2.db";
    defer unlinkPath(path);
    var base = try buildBase(path, 60);
    defer base.deinit();

    // Structural validation at open time cannot see tree reachability without an O(tree) walk, which
    // would break the "O(1) recovery" guarantee — so open accepts this chain and the overlap is
    // T7's (a future cube_check's) job. The live root page is listed FIRST so that, with the pool
    // sorted ascending and popped from the end, the follow-up write is served from the higher orphan
    // pages and never actually hands out the root. If an implementation pops the other way round,
    // the data-intact assertion in checkReopen catches the corruption — which is the point.
    const chain_pg = base.tail();
    const orphans = chain_pg + 1;
    var ents: [9]u32 = undefined;
    ents[0] = base.meta.root_page; // tree-reachable => INV-F1 violation, invisible to open
    _ = ramp(ents[1..], orphans);
    var page: [f2.PAGE_SIZE]u8 = undefined;
    const seq = base.meta.sequence + 1;
    buildFreePage(chain_pg, seq, 0, &ents, &page);
    try writePages(base.path_z, &.{.{ .page_no = chain_pg, .bytes = &page }});
    try writeMetaBothSlots(base.path_z, base.meta, seq, orphans + 7, chain_pg, ents.len);

    try checkReopen(path, .{
        .base = base,
        .want_discarded = false,
        .want_pool = ents.len,
        .t7 = .tree_free_overlap,
    });
}

test "T6 v3: duplicate entries => discard" {
    const path = ".test_fl_t6_v3.db";
    defer unlinkPath(path);
    var base = try buildBase(path, 60);
    defer base.deinit();

    const chain_pg = base.tail();
    var ents: [4]u32 = undefined;
    _ = ramp(&ents, chain_pg + 1);
    ents[2] = ents[0]; // the same page listed twice => double allocation if accepted
    var page: [f2.PAGE_SIZE]u8 = undefined;
    const seq = base.meta.sequence + 1;
    buildFreePage(chain_pg, seq, 0, &ents, &page);
    try writePages(base.path_z, &.{.{ .page_no = chain_pg, .bytes = &page }});
    try writeMetaBothSlots(base.path_z, base.meta, seq, chain_pg + 4, chain_pg, ents.len);

    try checkReopen(path, .{ .base = base, .want_discarded = true, .want_pool = 0 });
}

test "T6 v4: free_next cycle => discard" {
    const path = ".test_fl_t6_v4.db";
    defer unlinkPath(path);
    var base = try buildBase(path, 60);
    defer base.deinit();

    const pg0 = base.tail();
    const pg1 = pg0 + 1;
    var e0: [3]u32 = undefined;
    var e1: [3]u32 = undefined;
    _ = ramp(&e0, pg1 + 1);
    _ = ramp(&e1, pg1 + 4);
    var page0: [f2.PAGE_SIZE]u8 = undefined;
    var page1: [f2.PAGE_SIZE]u8 = undefined;
    const seq = base.meta.sequence + 1;
    buildFreePage(pg0, seq, pg1, &e0, &page0);
    buildFreePage(pg1, seq, pg0, &e1, &page1); // back to the head: cycle
    // free_count matches the entries, so only the walk bound / revisit guard can catch this one
    try writePages(base.path_z, &.{
        .{ .page_no = pg0, .bytes = &page0 },
        .{ .page_no = pg1, .bytes = &page1 },
    });
    try writeMetaBothSlots(base.path_z, base.meta, seq, pg1 + 6, pg0, e0.len + e1.len);

    try checkReopen(path, .{ .base = base, .want_discarded = true, .want_pool = 0 });
}

test "T6 v5a: entry beyond last_page => discard" {
    const path = ".test_fl_t6_v5a.db";
    defer unlinkPath(path);
    var base = try buildBase(path, 60);
    defer base.deinit();

    const chain_pg = base.tail();
    const last = chain_pg + 4;
    var ents: [4]u32 = undefined;
    _ = ramp(&ents, chain_pg + 1);
    ents[3] = last + 100; // beyond the high-water mark
    var page: [f2.PAGE_SIZE]u8 = undefined;
    const seq = base.meta.sequence + 1;
    buildFreePage(chain_pg, seq, 0, &ents, &page);
    try writePages(base.path_z, &.{.{ .page_no = chain_pg, .bytes = &page }});
    try writeMetaBothSlots(base.path_z, base.meta, seq, last, chain_pg, ents.len);

    try checkReopen(path, .{ .base = base, .want_discarded = true, .want_pool = 0 });
}

test "T6 v5b: entry claiming a meta page => discard" {
    const path = ".test_fl_t6_v5b.db";
    defer unlinkPath(path);
    var base = try buildBase(path, 60);
    defer base.deinit();

    const chain_pg = base.tail();
    var ents: [4]u32 = undefined;
    _ = ramp(&ents, chain_pg + 1);
    ents[1] = f2.META_PAGE_1;
    var page: [f2.PAGE_SIZE]u8 = undefined;
    const seq = base.meta.sequence + 1;
    buildFreePage(chain_pg, seq, 0, &ents, &page);
    try writePages(base.path_z, &.{.{ .page_no = chain_pg, .bytes = &page }});
    try writeMetaBothSlots(base.path_z, base.meta, seq, chain_pg + 4, chain_pg, ents.len);

    try checkReopen(path, .{ .base = base, .want_discarded = true, .want_pool = 0 });
}

test "T6 v6 (H1): previous-generation chain content revived under a newer meta => discard" {
    const path = ".test_fl_t6_v6.db";
    defer unlinkPath(path);
    var base = try buildBase(path, 60);
    defer base.deinit();

    // The scenario H1 exists for: chain pages are recycled from the pool, power is lost after the
    // new meta landed but before the recycled page's new content did, and the disk is left holding
    // the PREVIOUS generation's bytes — a structurally perfect FREE page (CRC, type, page_no, count
    // all valid; in churn steady state free_count matches too). Only the gen stamp tells it apart.
    // Generation A below deliberately lists the live root page: accepting it would hand a tree page
    // to the next allocation, i.e. exactly the corruption INV-F1/F2 are supposed to make impossible.
    const chain_pg = base.tail();
    const seq_a = base.meta.sequence; // old generation
    const seq_b = base.meta.sequence + 1; // the meta actually on disk

    var ents_b: [6]u32 = undefined;
    _ = ramp(&ents_b, chain_pg + 1); // benign orphans
    var page_b: [f2.PAGE_SIZE]u8 = undefined;
    buildFreePage(chain_pg, seq_b, 0, &ents_b, &page_b);
    try writePages(base.path_z, &.{.{ .page_no = chain_pg, .bytes = &page_b }});
    try writeMetaBothSlots(base.path_z, base.meta, seq_b, chain_pg + 6, chain_pg, ents_b.len);

    // roll the chain page back to generation A bytes (same page number, same entry count)
    var ents_a: [6]u32 = undefined;
    _ = ramp(&ents_a, chain_pg + 1);
    ents_a[0] = base.meta.root_page; // would violate INV-F1 if accepted
    var page_a: [f2.PAGE_SIZE]u8 = undefined;
    buildFreePage(chain_pg, seq_a, 0, &ents_a, &page_a);
    try std.testing.expect(f2.verifyPageChecksum(&page_a)); // structurally valid, only gen differs
    try writePages(base.path_z, &.{.{ .page_no = chain_pg, .bytes = &page_a }});

    try checkReopen(path, .{ .base = base, .want_discarded = true, .want_pool = 0 });
}

test "T6 v7a: free_count larger than the walked chain => discard" {
    const path = ".test_fl_t6_v7a.db";
    defer unlinkPath(path);
    var base = try buildBase(path, 60);
    defer base.deinit();

    const chain_pg = base.tail();
    const seq = base.meta.sequence + 1;
    var ents: [5]u32 = undefined;
    _ = ramp(&ents, chain_pg + 2);
    var page: [f2.PAGE_SIZE]u8 = undefined;
    buildFreePage(chain_pg, seq, 0, &ents, &page);
    try writePages(base.path_z, &.{.{ .page_no = chain_pg, .bytes = &page }});
    try writeMetaBothSlots(base.path_z, base.meta, seq, chain_pg + 6, chain_pg, ents.len + 5);

    try checkReopen(path, .{ .base = base, .want_discarded = true, .want_pool = 0 });
}

test "T6 v7b: chain terminates early (free_next dropped) => discard" {
    const path = ".test_fl_t6_v7b.db";
    defer unlinkPath(path);
    var base = try buildBase(path, 60);
    defer base.deinit();

    const pg0 = base.tail();
    const pg1 = pg0 + 1;
    const seq = base.meta.sequence + 1;
    var e0: [3]u32 = undefined;
    var e1: [2]u32 = undefined;
    _ = ramp(&e0, pg1 + 1);
    _ = ramp(&e1, pg1 + 4);
    var p0: [f2.PAGE_SIZE]u8 = undefined;
    var p1: [f2.PAGE_SIZE]u8 = undefined;
    buildFreePage(pg0, seq, 0, &e0, &p0); // link to pg1 dropped
    buildFreePage(pg1, seq, 0, &e1, &p1);
    try writePages(base.path_z, &.{
        .{ .page_no = pg0, .bytes = &p0 },
        .{ .page_no = pg1, .bytes = &p1 },
    });
    // meta counts both pages' entries, the walk only sees pg0's
    try writeMetaBothSlots(base.path_z, base.meta, seq, pg1 + 5, pg0, e0.len + e1.len);

    try checkReopen(path, .{ .base = base, .want_discarded = true, .want_pool = 0 });
}

test "T6 v8a: free_count > 0 with free_head == 0 => discard" {
    const path = ".test_fl_t6_v8a.db";
    defer unlinkPath(path);
    var base = try buildBase(path, 60);
    defer base.deinit();

    const chain_pg = base.tail();
    const seq = base.meta.sequence + 1;
    var ents: [4]u32 = undefined;
    _ = ramp(&ents, chain_pg + 1);
    var page: [f2.PAGE_SIZE]u8 = undefined;
    buildFreePage(chain_pg, seq, 0, &ents, &page);
    try writePages(base.path_z, &.{.{ .page_no = chain_pg, .bytes = &page }});
    // XOR-inconsistent meta: silently ignoring it would hide damage
    try writeMetaBothSlots(base.path_z, base.meta, seq, chain_pg + 4, 0, ents.len);

    try checkReopen(path, .{ .base = base, .want_discarded = true, .want_pool = 0 });
}

test "T6 v8b: free_head != 0 with free_count == 0 => discard" {
    const path = ".test_fl_t6_v8b.db";
    defer unlinkPath(path);
    var base = try buildBase(path, 60);
    defer base.deinit();

    const chain_pg = base.tail();
    const seq = base.meta.sequence + 1;
    var ents: [4]u32 = undefined;
    _ = ramp(&ents, chain_pg + 1);
    var page: [f2.PAGE_SIZE]u8 = undefined;
    buildFreePage(chain_pg, seq, 0, &ents, &page);
    try writePages(base.path_z, &.{.{ .page_no = chain_pg, .bytes = &page }});
    try writeMetaBothSlots(base.path_z, base.meta, seq, chain_pg + 4, chain_pg, 0);

    try checkReopen(path, .{ .base = base, .want_discarded = true, .want_pool = 0 });
}

test "T6 v9a: free_head points at a CRC-valid LEAF page => discard" {
    const path = ".test_fl_t6_v9a.db";
    defer unlinkPath(path);
    var base = try buildBase(path, 60);
    defer base.deinit();

    const chain_pg = base.tail();
    const seq = base.meta.sequence + 1;
    var leaf: [f2.PAGE_SIZE]u8 = undefined;
    buildLeafPage(chain_pg, &leaf);
    try std.testing.expect(f2.verifyPageChecksum(&leaf)); // the CRC is fine; only the type is wrong
    try writePages(base.path_z, &.{.{ .page_no = chain_pg, .bytes = &leaf }});
    try writeMetaBothSlots(base.path_z, base.meta, seq, chain_pg + 4, chain_pg, 4);

    try checkReopen(path, .{ .base = base, .want_discarded = true, .want_pool = 0 });
}

test "T6 v9b: free_head points at a CRC-valid OVERFLOW page => discard" {
    const path = ".test_fl_t6_v9b.db";
    defer unlinkPath(path);
    var base = try buildBase(path, 60);
    defer base.deinit();

    const chain_pg = base.tail();
    const seq = base.meta.sequence + 1;
    var ov: [f2.PAGE_SIZE]u8 = undefined;
    buildOverflowPage(chain_pg, &ov);
    try std.testing.expect(f2.verifyPageChecksum(&ov));
    try writePages(base.path_z, &.{.{ .page_no = chain_pg, .bytes = &ov }});
    try writeMetaBothSlots(base.path_z, base.meta, seq, chain_pg + 4, chain_pg, 4);

    try checkReopen(path, .{ .base = base, .want_discarded = true, .want_pool = 0 });
}

test "T6 v10 (T5 matrix row 4): meta landed, chain page never did => discard" {
    const path = ".test_fl_t6_v10.db";
    defer unlinkPath(path);
    var base = try buildBase(path, 60);
    defer base.deinit();

    // The single-sync power-loss window: meta is durable and points at a chain page whose bytes never
    // made it out of the page cache. fork()+_exit cannot produce this (the process-crash model keeps
    // the page cache intact), which is why T5 matrix row 4 lives here as a fixture: an all-zero page
    // carries a CRC that does not match zeroed content.
    const chain_pg = base.tail();
    const seq = base.meta.sequence + 1;
    var zero: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&zero, 0);
    try std.testing.expect(!f2.verifyPageChecksum(&zero));
    try writePages(base.path_z, &.{.{ .page_no = chain_pg, .bytes = &zero }});
    try writeMetaBothSlots(base.path_z, base.meta, seq, chain_pg + 4, chain_pg, 4);

    try checkReopen(path, .{ .base = base, .want_discarded = true, .want_pool = 0 });
}

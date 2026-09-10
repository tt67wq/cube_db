//! freelist_amp_red_test.zig — T-39-A RED tests: freelist write amplification,
//! dedup linear scan, and the silent OOM-drop observability gap.
//!
//! Contract under test (T-39-A task.md / issue T-39), three observability gaps
//! in src/file_page_store.zig at HEAD:
//!
//! 1. Whole-chain rewrite write amplification: `persistChainLocked`
//!    (src/file_page_store.zig:320) re-serializes the ENTIRE pool into a fresh
//!    FREE-page chain on every commit — O(free_pages/1016) page memcpy+CRC for
//!    even the smallest batch. RED: a small commit against a large pool must
//!    write far fewer chain pages than the full chain.
//! 2. Dedup linear scan: `pushPoolLocked` (:267-268) dedupes every free with a
//!    `std.mem.indexOfScalar` linear scan — N frees = O(N·pool). RED: the dedup
//!    membership work per free must be O(1)-ish, not O(pool).
//! 3. Silent error swallowing: `pushPoolLocked`'s `append(...) catch {}`
//!    silently drops a page on OOM with zero observability. RED: an
//!    observable `dropped_pages_oom` counter must exist (and read 0 on a
//!    healthy run).
//!
//! Observation API expected (fixed names, per the T-39-A contract; implemented
//! by T-39-B/C — this file is the naming contract):
//!   - `pub fn resetFreelistStats(self: *FilePageStore) void`
//!   - `pub const FreelistStats = struct {
//!         chain_pages_written: u64,      // FREE-chain pages written since reset
//!         dedup_scans: u64,              // pushPoolLocked dedup checks since reset
//!         dedup_membership_probe: u64,   // element probes spent deduping since reset
//!         dropped_pages_oom: u64,        // pages silently dropped on append OOM
//!     }`
//!   - `pub fn freelistStats(self: *const FilePageStore) FreelistStats`
//!
//! RED discipline (same as T-33 freelist_persist_test): every missing symbol is
//! reached through @hasDecl/@hasField guards so this file COMPILES on HEAD and
//! fails on the assertion/guard, not on the build. The guards sit BEFORE the
//! expensive fixtures, so the RED run on HEAD fails fast; the fixtures only
//! run once the API exists (GREEN-side cost is bounded by the fixes).
//!
//! Fixture notes:
//! - Pools are built through the REAL paths: `store().allocPage()` to grow the
//!   high-water mark, then `store().freePage()` to stock the pool (exercises
//!   pushPoolLocked itself). On HEAD this is O(P²) — acceptable only because
//!   the guards fail first; with T-39-B it is O(P).
//! - One fixture = one file = one reopen (T-33 discipline).
//!
//! Hookup: raw `zig test` per the T-39-A acceptance command (top-level
//! tests/*.zig auto-discovery does not recurse into tests/core_format/ —
//! same caveat as T-37; do NOT edit build.zig from the test role).

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const FilePageStore = cube.file_page_store.FilePageStore;

const c = @cImport({
    @cInclude("unistd.h");
});

const alloc = std.testing.allocator;

// ===== observation-API bridge (fixed names; missing on HEAD = the RED) =====

/// Comptime-known so the `if (!has_stats_api) return ...` guards prune the
/// missing-symbol code paths from semantic analysis on HEAD (a runtime fn
/// call would NOT prune — the whole body would be analyzed and fail to
/// compile, defeating the "compiles on HEAD, red in semantics" discipline).
const has_stats_api = @hasDecl(FilePageStore, "freelistStats") and
    @hasDecl(FilePageStore, "resetFreelistStats") and
    @hasDecl(FilePageStore, "FreelistStats");

/// Single-page freelist capacity (chain math). GREEN exposes it in f2; the
/// fallback keeps this file compiling either way (T-33 pattern).
fn freeCap() usize {
    if (@hasDecl(f2, "MAX_FREE_ENTRIES_PER_PAGE")) return f2.MAX_FREE_ENTRIES_PER_PAGE;
    return (f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4 - 4) / 4;
}

// ===== small utilities (T-33 freelist_persist_test style) =====

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

/// Grow the file by `n` fresh pages (real allocPage bumps; pool stays empty)
/// and return their page numbers. Caller frees.
fn bumpPages(store: cube.page_store.PageStore, n: usize) ![]u32 {
    const pns = try alloc.alloc(u32, n);
    errdefer alloc.free(pns);
    for (pns) |*p| p.* = try store.allocPage();
    return pns;
}

// ===== RED #1: whole-chain rewrite write amplification (main gate) =====

test "T-39 RED #1: small commit against a large pool must not rewrite the whole FREE chain" {
    // Guard FIRST (fail fast on HEAD — the fixture is only worth building once
    // the counters exist). Missing symbol IS the RED: HEAD has no per-commit
    // chain-write observability at all (FpsCounters counts vtWritePage calls;
    // persistChainLocked writes via pagePtr underneath it).
    if (!has_stats_api) return error.MissingFreelistStatsApi;

    const path = ".test_fl_amp_red1.db";
    defer unlinkPath(path);
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();

    // Build a large pool through the real paths: 20_000 pages bumped then
    // freed (with T-39-B: O(P); pushPoolLocked dedup handles the churn).
    const pool_pages: usize = 20_000;
    const pns = try bumpPages(fps.store(), pool_pages);
    defer alloc.free(pns);
    for (pns) |p| fps.store().freePage(p);
    try std.testing.expect(fps.freePageCount() == pool_pages);

    // Full-chain cost of THIS pool at the next commit: k = ceil(n/(cap+1))
    // (each chain page consumes one pool slot itself — P0-B arithmetic).
    const full_chain_pages = (pool_pages + freeCap()) / (freeCap() + 1);
    try std.testing.expect(full_chain_pages >= 10); // fixture sanity: pool is big enough to matter

    var db = try cube.Db.open(alloc, fps.store(), .{ .fsync = false });
    defer db.close();

    // Measure ONE small commit.
    fps.resetFreelistStats();
    try db.putBatch(&.{.{ .key = "tiny", .value = "v" }});
    const stats = fps.freelistStats();

    // The T-39-C contract: a small commit writes O(1) chain pages (append-only
    // tail / skip-unchanged), not the whole chain. Bound: at most an eighth of
    // the full chain, and never more than 4 pages for this fixture. HEAD's
    // whole-chain rewrite would write ~full_chain_pages (20 here) — RED.
    const bound = @max(@as(u64, 4), full_chain_pages / 8);
    if (stats.chain_pages_written > bound) {
        std.debug.print(
            "write amplification: small commit wrote {d} chain pages, full chain = {d} pages (pool {d})\n",
            .{ stats.chain_pages_written, full_chain_pages, pool_pages },
        );
        return error.FreelistWriteAmplification;
    }
}

// ===== RED #2: pushPoolLocked dedup linear scan =====

test "T-39 RED #2: re-freeing a pooled page must not scan the whole pool" {
    if (!has_stats_api) return error.MissingFreelistStatsApi;

    const path = ".test_fl_amp_red2.db";
    defer unlinkPath(path);
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();

    // Pool of 4096 entries via the real path.
    const pool_pages: usize = 4096;
    const pns = try bumpPages(fps.store(), pool_pages);
    defer alloc.free(pns);
    for (pns) |p| fps.store().freePage(p);
    try std.testing.expect(fps.freePageCount() == pool_pages);

    // Re-free the TAIL page K times: already pooled (idempotent free, the
    // P0-A load-bearing path), and on HEAD it is the WORST case —
    // indexOfScalar scans the entire pool before finding it at the end.
    const K: usize = 64;
    const tail = pns[pns.len - 1];

    fps.resetFreelistStats();
    for (0..K) |_| fps.store().freePage(tail);
    const stats = fps.freelistStats();

    // Pool must not have grown (idempotence is T-33-correct on HEAD too).
    try std.testing.expectEqual(pool_pages, fps.freePageCount());

    // The T-39-B contract: membership work per free is O(1)-ish (structured
    // pool / hash set), so K re-frees cost a small constant per free. HEAD's
    // linear scan costs ~pool_pages probes per free (~262k here total) — RED.
    const probe_bound: u64 = 4 * K + 16;
    if (stats.dedup_membership_probe > probe_bound) {
        std.debug.print(
            "dedup scan: {d} re-frees of a pooled page cost {d} membership probes (pool {d}); bound {d}\n",
            .{ K, stats.dedup_membership_probe, pool_pages, probe_bound },
        );
        return error.FreelistDedupLinearScan;
    }
}

// ===== RED #3: silent OOM drop has no observability =====

test "T-39 RED #3: dropped-pages-on-OOM must be observable, not silently swallowed" {
    // Guard first: on HEAD pushPoolLocked's `append(...) catch {}` drops the
    // page with zero counters, zero logs — nothing to assert on. The missing
    // symbol is the RED.
    if (!has_stats_api) return error.MissingFreelistStatsApi;
    if (!@hasField(FilePageStore.FreelistStats, "dropped_pages_oom")) {
        return error.MissingDroppedPagesOomCounter;
    }

    const path = ".test_fl_amp_red3.db";
    defer unlinkPath(path);
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();

    // A healthy run must report ZERO dropped pages: the counter exists, is
    // readable without any error-path gymnastics, and stays at 0 when nothing
    // goes wrong. (Triggering a real append-OOM deterministically would need
    // an allocator-failure injection surface; the observability contract here
    // is the counter's existence + a live read. T-39-B wires the increment
    // into the catch arm.)
    fps.resetFreelistStats();
    const pns = try bumpPages(fps.store(), 8);
    defer alloc.free(pns);
    for (pns) |p| fps.store().freePage(p);
    const stats = fps.freelistStats();
    try std.testing.expectEqual(@as(u64, 0), stats.dropped_pages_oom);
}

// ===== GREEN on HEAD: fixture sanity + canaries =====

test "T-39 sanity: T-33 freelist persistence smoke (must stay green on HEAD)" {
    // Compact T3-lite: put / delete / compact / close / reopen — the pool
    // persists and is restored, data intact. Proves this file's fixtures did
    // not break the already-green T-33 paths.
    const path = ".test_fl_amp_smoke.db";
    defer unlinkPath(path);

    const pool_before: usize = blk: {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try cube.Db.open(alloc, fps.store(), .{ .fsync = false });
        defer db.close();

        // Per-entry key buffers: putBatch references the caller's slices
        // during the call, so a single reused stack buffer would collapse all
        // keys into one (dedup) — keys must be DISTINCT slices (T-37 pattern).
        var kbufs: [400][16]u8 = undefined;
        var entries: [400]cube.Entry = undefined;
        for (0..400) |i| {
            entries[i] = .{
                .key = try std.fmt.bufPrint(&kbufs[i], "k{d:0>6}", .{i}),
                .value = "v",
            };
        }
        try db.putBatch(&entries);
        for (0..200) |i| {
            entries[i] = .{
                .key = try std.fmt.bufPrint(&kbufs[i], "k{d:0>6}", .{i}),
                .value = "",
                .tombstone = true,
            };
        }
        try db.putBatch(entries[0..200]);
        // compact is load-bearing (T-33 T3): the delete commit's COW victims
        // only reach the pool after their meta landed — compact persists them.
        try db.compact();
        break :blk fps.freePageCount();
    };
    try std.testing.expect(pool_before > 0); // the delete really freed pages

    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        try std.testing.expectEqual(pool_before, fps.freePageCount());
        try std.testing.expectEqual(false, fps.freeListDiscarded());
        var db = try cube.Db.open(alloc, fps.store(), .{ .fsync = false });
        defer db.close();

        var kbuf: [16]u8 = undefined;
        for (200..400) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{i});
            const got = try db.get(k) orelse return error.KeyMissing;
            defer alloc.free(got);
        }
        for (0..200) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{i});
            try std.testing.expectEqual(@as(?[]u8, null), try db.get(k));
        }
    }
}

test "T-39 sanity: crash-injection canary symbols still exist (T-33/T-27)" {
    // The T-39 fixes must not disturb the crash matrix surface; T-39-D owns
    // the append-only matrix extension. Canary: the symbols are still there.
    try std.testing.expect(@hasDecl(FilePageStore, "CrashTag"));
    try std.testing.expect(@hasDecl(FilePageStore, "test_crash_hook"));
    try std.testing.expectEqual(false, FilePageStore.test_crash_hook != null); // unarmed in this file
}

test "T-39 sanity: expected stat field names (contract echo, RED on HEAD)" {
    // Contract echo: the observation API's field set, asserted symbolically so
    // a rename during T-39-B/C review shows up here rather than as silent
    // test-skips in RED #1/#2/#3. On HEAD this is RED (no FreelistStats).
    if (!has_stats_api) return error.MissingFreelistStatsApi;
    try std.testing.expect(@hasField(FilePageStore.FreelistStats, "chain_pages_written"));
    try std.testing.expect(@hasField(FilePageStore.FreelistStats, "dedup_scans"));
    try std.testing.expect(@hasField(FilePageStore.FreelistStats, "dedup_membership_probe"));
    try std.testing.expect(@hasField(FilePageStore.FreelistStats, "dropped_pages_oom"));
}

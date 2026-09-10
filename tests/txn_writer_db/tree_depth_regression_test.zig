//! tree_depth_regression_test.zig — T-37 RED regression + depth-invariant tests.
//!
//! Issue T-37: bulk put + deleteRange churn makes the tree gain layers without ever
//! shrinking them (`insertBatchIntoLeaf` overflow path / `insertBatchSplitLeaves`
//! rebuild leaves into full subtrees; root-split only stacks new layers). Once depth
//! passes `Iterator.MAX_DEPTH = 64` (src/btree.zig), `select` / `deleteRange` return
//! `error.Truncated` while point `get` still works.
//!
//! Repro shape (deterministic, no RNG — matches the independently confirmed shapes
//! in issues/T-37-tree-depth-unbounded-growth-error-Truncated.md):
//!   round i (single-threaded, MemPageStore):
//!     1. putBatch 4000 NEW monotonic keys: [i*4000, (i+1)*4000)
//!     2. deleteRange the first half of that round: [i*4000, i*4000+2000)
//!     3. full-range select(null,null) scan + live-count check
//!   Growth + churn is the trigger (steady-state rewrite of the same keys does NOT
//!   trigger — confirmed empirically, and noted in the issue).
//!
//! Observed on HEAD 5b50abb: `error.Truncated` from `deleteRange` (internal select)
//! at round 32 (0-based; cumulative 132k staged keys, 64k live). Deterministic across
//! runs. Post-fix (T-37-B) the same loop must run to completion with no
//! `error.Truncated` and the exact expected live key set.
//!
//! Run (single file; the manifest's raw command needs --dep/-Mroot form because a
//! positional file plus -Mcube_db both claim the main module in zig 0.16):
//!   zig test --dep cube_db --dep zio \
//!     -Mroot=tests/txn_writer_db/tree_depth_regression_test.zig \
//!     --dep zio -Mcube_db=src/root.zig \
//!     --dep zio_options -Mzio=<zio-pkg>/src/zio.zig -Mzio_options=<zio_options shim> \
//!     -lc --test-filter tree_depth
//! (`zig build test-db` also works once the file is registered in build.zig.)
//!
//! zio_options shim (zio's build.zig generates this module; raw `zig test` needs it
//! as a file — save as tmp/zio_options_shim.zig):
//!   pub const backend: ?[]const u8 = null;
//!   pub const resolve_beneath_mode: enum { strict, best_effort } = .strict;
//!   pub const no_hacks: bool = false;
//!   pub const task_migration: bool = true;

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const dbi = cube.db;
const btree = cube.btree;

fn newStore() ps.MemPageStore {
    // Page cap only — MemPageStore allocates pages on demand.
    return ps.MemPageStore.init(std.testing.allocator, 4_000_000);
}

/// 10-digit zero-padded ASCII: lexicographic == numeric ordering (cmpKey is bytewise).
fn fmtKey(buf: *[10]u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>10}", .{i}) catch unreachable;
}

const batch: usize = 4000;
const rounds: usize = 40;

test "tree_depth regression: bulk put + deleteRange churn must not hit error.Truncated" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var kbufs: [batch][10]u8 = undefined;
    var entries: [batch]dbi.Entry = undefined;

    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        const base = round * batch;
        // 1. stage `batch` new keys (fixed, monotonic — growth is part of the trigger)
        for (0..batch) |i| {
            entries[i] = .{ .key = fmtKey(&kbufs[i], base + i), .value = "v" };
        }
        try db.putBatch(&entries);
        // 2. churn: drop the first half of this round's range (tombstone batch
        //    goes through the same bulk-insert overflow path that deepens the tree)
        var b1: [10]u8 = undefined;
        var b2: [10]u8 = undefined;
        try db.deleteRange(fmtKey(&b1, base), fmtKey(&b2, base + batch / 2));
        // 3. full-range scan — the user-visible failure mode (backup/export path)
        var it = try db.select(null, null);
        defer it.deinit();
        var n: usize = 0;
        while (try it.next()) |_| n += 1;
        // live set = second half of every round so far
        try std.testing.expectEqual((round + 1) * (batch / 2), n);
    }

    // Post-fix pass condition: exact live key set. Kept keys: [i*4000+2000, (i+1)*4000)
    // for every round; deleted keys: [i*4000, i*4000+2000).
    var it = try db.select(null, null);
    defer it.deinit();
    var n: usize = 0;
    var last: [10]u8 = .{'0'} ** 10;
    while (try it.next()) |e| {
        try std.testing.expect(e.key.len == 10);
        // strictly ascending — no duplicates, no resurrected tombstones
        try std.testing.expect(std.mem.order(u8, &last, e.key) == .lt);
        @memcpy(&last, e.key);
        n += 1;
    }
    try std.testing.expectEqual(rounds * (batch / 2), n);

    // Spot-check: a kept key from the first and last round survives; a deleted
    // key from the first and last round is gone.
    var kb: [10]u8 = undefined;
    for ([_]usize{ 0 * batch + batch / 2 + 7, (rounds - 1) * batch + batch / 2 + 7 }) |k| {
        const v = try db.get(fmtKey(&kb, k));
        try std.testing.expect(v != null);
        std.testing.allocator.free(v.?);
    }
    for ([_]usize{ 0 * batch + 7, (rounds - 1) * batch + 7 }) |k| {
        try std.testing.expectEqual(@as(?[]u8, null), try db.get(fmtKey(&kb, k)));
    }
}

// DEPENDS ON T-37-B: `pub fn treeDepth(self: *Db) usize` in src/db.zig
// (root→leaf height, 0 for empty tree). Guarded by @hasDecl so this file still
// compiles — and the regression test above still runs RED — on pre-fix HEAD;
// the invariant activates as soon as the real method lands. If T-37-B ships a
// different signature, that is a contract mismatch to flag to the conductor.
test "tree_depth invariant: depth stays ~balanced under churn" {
    if (!@hasDecl(dbi.Db, "treeDepth")) return error.SkipZigTest;

    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    // Fixed churn shape (same family as the regression test, smaller): bulk puts
    // of new keys with deleteRange churn in between.
    var kbufs: [batch][10]u8 = undefined;
    var entries: [batch]dbi.Entry = undefined;
    const inv_rounds: usize = 12;
    var round: usize = 0;
    while (round < inv_rounds) : (round += 1) {
        const base = round * batch;
        for (0..batch) |i| {
            entries[i] = .{ .key = fmtKey(&kbufs[i], base + i), .value = "v" };
        }
        try db.putBatch(&entries);
        var b1: [10]u8 = undefined;
        var b2: [10]u8 = undefined;
        try db.deleteRange(fmtKey(&b1, base), fmtKey(&b2, base + batch / 2));
    }

    // Live leaf count lower bound: leaves hold at most LEAF_MAX_ENTRIES entries.
    var it = try db.select(null, null);
    defer it.deinit();
    var live: usize = 0;
    while (try it.next()) |_| live += 1;
    try std.testing.expectEqual(inv_rounds * (batch / 2), live);
    const leaves = (live + btree.LEAF_MAX_ENTRIES - 1) / btree.LEAF_MAX_ENTRIES;

    // ceil(log_64(leaves)): smallest h with 64^h >= leaves.
    var balanced_height: usize = 0;
    while (std.math.pow(u64, btree.BRANCH_MAX_CHILDREN, balanced_height) < leaves) balanced_height += 1;

    // A balanced tree over `leaves` leaves is `balanced_height` branch levels tall;
    // allow a small constant slack for transient under-fill, but nothing like the
    // 60+ depths the unbounded-growth bug produces (old code violates this by ~55).
    const depth = db.treeDepth();
    const bound = 2 + balanced_height + 2;
    try std.testing.expect(depth <= bound);
}

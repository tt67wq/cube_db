//! insertbatch_owned_test.zig — T-42: non-arena ownership of the batch
//! merge path (merged-entry dupes) + producer error-path UAF.
//!
//! Issue T-42, two sub-problems in src/btree.zig's insertBatchIntoLeaf /
//! insertBatchIntoBranch (batch leaf/branch producers):
//!
//! A. Leak (success AND error paths): the merge loop dupes batch entries
//!    into `merged` (owned) while keeping old entries borrowed from `leaf`
//!    — mixed ownership means nobody frees the owned dupes after encoding.
//!    3 new entries into an existing leaf leak 6 allocations (2 per entry)
//!    on the SUCCESS path alone.
//!
//! B. UAF crash (error path): the splice producers declare BOTH
//!    `errdefer { for+deinit }` AND `defer deinit` on the same ArrayList —
//!    on error the plain defer runs first (fields become undefined), then
//!    the errdefer iterates `items` -> segfault (0xaaaa...). Proven in the
//!    T-41 review probe at fail_index=262.
//!
//! Both are invisible to arena callers (writer.applyBatch) but make the
//! public `btree.insertBatch` unusable (leaks) and crash-prone (UAF) for
//! non-arena allocators.
//!
//! Fault-injection design: FailingAllocator wraps std.testing.allocator,
//! so a run that leaks still fails the end-of-test leak check AND a run
//! that hits the bad errdefer crashes. The sweep range is calibrated per
//! scenario (one clean run counts total allocations; the sweep covers the
//! whole range for the small leaf scenario, the producer-loop tail for the
//! branch scenario).
//!
//! Wiring: comptime-imported from btree_test.zig into the test-btree step.
//!
//! T-54-C: the branch-producer calibrated fault sweep (formerly test #4
//! here, ~170s standalone) moved to 4 parallel shard binaries —
//! tests/insertbatch_sweep_{a,b,c,d}_test.zig — sharing the sweep plumbing
//! from insertbatch_sweep_helpers.zig. Same 82 fault points, same
//! assertions, just parallelized. This file keeps the two T-42 success-path
//! tests and the leaf-producer sweep (a few seconds).

const std = @import("std");
const cube = @import("cube_db");
const btree = cube.btree;
const h = @import("insertbatch_sweep_helpers.zig");

const alloc = h.alloc;
const newStore = h.newStore;
const fmtKey = h.fmtKey;
const ScenarioFn = h.ScenarioFn;
const sweepFailIndexes = h.sweepFailIndexes;
const countAllocs = h.countAllocs;

// ===== 1. Success path: zero leaks, single-leaf merge (non-splice) =====
// std.testing.allocator's end-of-test leak check IS the assertion: any
// leaked merged dupe fails the test.

test "T-42: insertBatch into existing leaf (merge path) leaks nothing on success" {
    var ms = newStore();
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(alloc);

    // Seed a fresh leaf root with 10 small entries (single-leaf path).
    var seed_bufs: [10][8]u8 = undefined;
    var seed: [10]btree.LeafEntry = undefined;
    for (0..10) |i| {
        seed_bufs[i] = fmtKey(8, i);
        seed[i] = .{ .tombstone = false, .key = &seed_bufs[i], .value = "vv" };
    }
    const wr = try btree.insertBatch(alloc, ms.store(), btree.NULL_ROOT, &seed, &dirty);
    try std.testing.expect(wr.new_root != btree.NULL_ROOT);

    // Batch: 1 overwrite (k0000005 is in the seed) + 3 new keys beyond the
    // seed range. Exercises the merge branches: .eq (overwrite), .lt
    // (untouched old), and the remaining-batch tail loop.
    // merged = 13 <= LEAF_MAX_ENTRIES -> single-leaf merge, non-splice.
    // Pre-fix: the 3 new + 1 overwrite dupes leak (8 allocations).
    var new_bufs: [4][8]u8 = undefined;
    var batch: [4]btree.LeafEntry = undefined;
    const idx = [_]usize{ 5, 15, 25, 35 }; // k0000005 overwrites the seed
    for (idx, 0..) |v, i| {
        new_bufs[i] = fmtKey(8, v);
        batch[i] = .{ .tombstone = false, .key = &new_bufs[i], .value = "ww" };
    }
    const wr2 = try btree.insertBatch(alloc, ms.store(), wr.new_root, &batch, &dirty);
    try std.testing.expect(wr2.new_root != btree.NULL_ROOT);

    // Content check: count via full scan.
    var it = try btree.select(alloc, ms.store(), wr2.new_root, null, null);
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 13), count);
}

// ===== 2. Success path: zero leaks, splice path (leaf overflow) =====

test "T-42: insertBatch leaf-overflow splice path leaks nothing on success" {
    var ms = newStore();
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(alloc);

    // Seed a full-ish leaf (20 entries), then overflow it with 100 new
    // entries -> merge (120) > 32 -> leaf chunk loop + splice to root.
    // Pre-fix: all 100 new-entry dupes leak (200 allocations).
    var seed_bufs: [20][8]u8 = undefined;
    var seed: [20]btree.LeafEntry = undefined;
    for (0..20) |i| {
        seed_bufs[i] = fmtKey(8, i);
        seed[i] = .{ .tombstone = false, .key = &seed_bufs[i], .value = "vv" };
    }
    const wr = try btree.insertBatch(alloc, ms.store(), btree.NULL_ROOT, &seed, &dirty);

    var new_bufs: [100][8]u8 = undefined;
    var batch: [100]btree.LeafEntry = undefined;
    for (0..100) |i| {
        new_bufs[i] = fmtKey(8, 100 + i);
        batch[i] = .{ .tombstone = false, .key = &new_bufs[i], .value = "ww" };
    }
    const wr2 = try btree.insertBatch(alloc, ms.store(), wr.new_root, &batch, &dirty);
    try std.testing.expect(wr2.new_root != btree.NULL_ROOT);

    var it = try btree.select(alloc, ms.store(), wr2.new_root, null, null);
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 120), count);
}

// ===== 3. Error path: leaf-producer fault-injection sweep ==============
// Each fail_index is a fresh end-to-end run; a correct implementation
// either succeeds or returns a clean error.OutOfMemory — never crashes
// (UAF), never leaks (backing testing.allocator checks at test end).

/// leaf-producer error path: leaf root + overflow batch -> the splice
/// chunk loop inside insertBatchIntoLeaf (where the bad errdefer lives).
fn leafOverflowScenario(store: cube.page_store.PageStore, fa: std.mem.Allocator, dirty: *std.ArrayList(u32)) anyerror!void {
    var seed_bufs: [20][8]u8 = undefined;
    var seed: [20]btree.LeafEntry = undefined;
    for (0..20) |i| {
        seed_bufs[i] = fmtKey(8, i);
        seed[i] = .{ .tombstone = false, .key = &seed_bufs[i], .value = "vv" };
    }
    const wr = try btree.insertBatch(fa, store, btree.NULL_ROOT, &seed, dirty);

    var new_bufs: [100][8]u8 = undefined;
    var batch: [100]btree.LeafEntry = undefined;
    for (0..100) |i| {
        new_bufs[i] = fmtKey(8, 100 + i);
        batch[i] = .{ .tombstone = false, .key = &new_bufs[i], .value = "ww" };
    }
    _ = try btree.insertBatch(fa, store, wr.new_root, &batch, dirty);
}

test "T-42: leaf-producer error path — no UAF, no leaks (full fault sweep)" {
    const total = try countAllocs(leafOverflowScenario);
    try sweepFailIndexes("leaf", leafOverflowScenario, 1, total + 2);
}

// T-54-C: the branch-producer calibrated fault sweep moved to the 4
// parallel shard binaries tests/insertbatch_sweep_{a,b,c,d}_test.zig
// (scenario + plumbing in insertbatch_sweep_helpers.zig). Its window
// [total-|80, total+2) is split by h.shardRange into 4 gap-free shards;
// the partition invariants are guarded by
// tests/insertbatch_sweep_partition_test.zig.

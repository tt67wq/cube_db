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

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;

const alloc = std.testing.allocator;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 100000);
}

fn fmtKey(comptime buf_len: usize, i: usize) [buf_len]u8 {
    var buf: [buf_len]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "k{d:0>6}", .{i}) catch unreachable;
    return buf;
}

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

// ===== 3./4. Error paths: fault-injection sweeps ========================
// Each fail_index is a fresh end-to-end run; a correct implementation
// either succeeds or returns a clean error.OutOfMemory — never crashes
// (UAF), never leaks (backing testing.allocator checks at test end).

const ScenarioFn = fn (store: ps.PageStore, fa: std.mem.Allocator, dirty: *std.ArrayList(u32)) anyerror!void;

fn sweepFailIndexes(comptime label: []const u8, comptime build: ScenarioFn, first: usize, last_exclusive: usize) !void {
    var fail_index: usize = first;
    while (fail_index < last_exclusive) : (fail_index += 1) {
        var ms = newStore();
        defer ms.deinit();
        var dirty = std.ArrayList(u32).empty;
        defer dirty.deinit(alloc);

        var failing = std.testing.FailingAllocator.init(alloc, .{
            .fail_index = fail_index,
        });
        build(ms.store(), failing.allocator(), &dirty) catch |e| {
            if (e != error.OutOfMemory) {
                std.debug.print("{s}: fail_index={d}: unexpected error {s}\n", .{ label, fail_index, @errorName(e) });
                return error.UnexpectedError;
            }
        };
    }
}

/// One clean run to count the scenario's total allocations (calibrates
/// the sweep range; the producers' chunk loops live in the tail).
fn countAllocs(comptime build: ScenarioFn) !usize {
    var ms = newStore();
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(alloc);

    var failing = std.testing.FailingAllocator.init(alloc, .{});
    try build(ms.store(), failing.allocator(), &dirty);
    return failing.allocations;
}

/// leaf-producer error path: leaf root + overflow batch -> the splice
/// chunk loop inside insertBatchIntoLeaf (where the bad errdefer lives).
fn leafOverflowScenario(store: ps.PageStore, fa: std.mem.Allocator, dirty: *std.ArrayList(u32)) anyerror!void {
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

/// branch-producer error path: 2-level tree + overflow batch big enough to
/// overflow the root branch -> the splice chunk loop inside
/// insertBatchIntoBranch (second copy of the bad errdefer pattern).
fn branchOverflowScenario(store: ps.PageStore, fa: std.mem.Allocator, dirty: *std.ArrayList(u32)) anyerror!void {
    // 2-level tree: batches of 500 -> ~16 leaves each, root branch grows.
    var wr = btree.WriteResult{ .new_root = btree.NULL_ROOT, .live_delta = 0, .count_delta = 0 };
    var i: usize = 0;
    while (i < 2000) : (i += 500) {
        var bufs: [500][8]u8 = undefined;
        var batch: [500]btree.LeafEntry = undefined;
        for (0..500) |j| {
            bufs[j] = fmtKey(8, i + j);
            batch[j] = .{ .tombstone = false, .key = &bufs[j], .value = "vv" };
        }
        wr = try btree.insertBatch(fa, store, wr.new_root, &batch, dirty);
    }

    // Overflow batch beyond all existing keys -> merges into the rightmost
    // leaf, splices ~64 children into the root branch -> branch overflow ->
    // insertBatchIntoBranch chunk loop.
    var bufs: [2000][8]u8 = undefined;
    var batch: [2000]btree.LeafEntry = undefined;
    for (0..2000) |j| {
        bufs[j] = fmtKey(8, 10000 + j);
        batch[j] = .{ .tombstone = false, .key = &bufs[j], .value = "ww" };
    }
    _ = try btree.insertBatch(fa, store, wr.new_root, &batch, dirty);
}

test "T-42: branch-producer error path — no UAF, no leaks (calibrated fault sweep)" {
    const total = try countAllocs(branchOverflowScenario);
    // The final ~80 allocations span the leaf chunk loop, the branch chunk
    // loop (the two producers under test), and the splice handoff.
    const first = total -| 80;
    try sweepFailIndexes("branch", branchOverflowScenario, first, total + 2);
}

//! insertbatch_sweep_helpers.zig — T-54-C: shared plumbing for the T-42
//! fault-injection sweeps (extracted from insertbatch_owned_test.zig) plus
//! the shard-range arithmetic that splits the branch-producer sweep into 4
//! parallel binaries.
//!
//! ⚠️ This file MUST NOT contain any `test` block: it is imported by 4
//! top-level shard binaries (tests/insertbatch_sweep_{a,b,c,d}_test.zig)
//! AND by insertbatch_owned_test.zig — any test here would execute once per
//! importing binary (duplicating work and eating the shard speedup).
//!
//! Semantics are byte-identical to the original T-42 sweep code (moved, not
//! modified); the only new logic is `shardRange` below.

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;

pub const alloc = std.testing.allocator;

pub fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 100000);
}

pub fn fmtKey(comptime buf_len: usize, i: usize) [buf_len]u8 {
    var buf: [buf_len]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "k{d:0>6}", .{i}) catch unreachable;
    return buf;
}

pub const ScenarioFn = fn (store: ps.PageStore, fa: std.mem.Allocator, dirty: *std.ArrayList(u32)) anyerror!void;

/// Fault sweep over [first, last_exclusive): each fail_index is a fresh
/// end-to-end run; a correct implementation either succeeds or returns a
/// clean error.OutOfMemory — never crashes (UAF), never leaks.
pub fn sweepFailIndexes(comptime label: []const u8, comptime build: ScenarioFn, first: usize, last_exclusive: usize) !void {
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

/// One clean run to count the scenario's total allocations (calibrates the
/// sweep range; the producers' chunk loops live in the tail).
pub fn countAllocs(comptime build: ScenarioFn) !usize {
    var ms = newStore();
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(alloc);

    var failing = std.testing.FailingAllocator.init(alloc, .{});
    try build(ms.store(), failing.allocator(), &dirty);
    return failing.allocations;
}

/// branch-producer error path: 2-level tree + overflow batch big enough to
/// overflow the root branch -> the splice chunk loop inside
/// insertBatchIntoBranch (the producer under test).
pub fn branchOverflowScenario(store: ps.PageStore, fa: std.mem.Allocator, dirty: *std.ArrayList(u32)) anyerror!void {
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

// ===== T-54-C: shard-range arithmetic (the only new logic) =============

pub const Range = struct { first: usize, last_exclusive: usize };

pub const SHARD_COUNT: usize = 4;
pub const SWEEP_TAIL_WIDTH: usize = 80;
pub const SWEEP_OVERSHOOT: usize = 2;

/// The full sweep window for a scenario with `total` allocations:
/// [total -| 80, total + 2) — identical to the original single test
/// (`first = total -| 80`, `last = total + 2`). Width = 82 for total=21852.
pub fn sweepWindow(total: usize) Range {
    return .{ .first = total -| SWEEP_TAIL_WIDTH, .last_exclusive = total + SWEEP_OVERSHOOT };
}

/// Sub-range of the sweep window for shard `shard` (0..3, i.e. a..d):
/// the window is split into SHARD_COUNT consecutive, non-overlapping,
/// gap-free ranges; when the width is not divisible the first `width % 4`
/// shards take one extra point. Shards are ordered a,b,c,d = 0,1,2,3.
/// shard >= SHARD_COUNT yields an empty range (defensive; unused by the
/// 4 shard binaries).
pub fn shardRange(total: usize, shard: usize) Range {
    const w = sweepWindow(total);
    const width = w.last_exclusive - w.first;
    const base = width / SHARD_COUNT;
    const rem = width % SHARD_COUNT;
    var first = w.first;
    var n = base;
    var i: usize = 0;
    while (i < shard and i < SHARD_COUNT) : (i += 1) {
        first += base + @intFromBool(i < rem);
    }
    if (shard < SHARD_COUNT) {
        n = base + @intFromBool(shard < rem);
    } else {
        first = w.last_exclusive;
        n = 0;
    }
    return .{ .first = first, .last_exclusive = first + n };
}

comptime {
    // Fail fast at compile time if the shard math ever regresses on the
    // NOTE on the two totals: the scenario's real calibrated total under the
    // test's own counting semantics (std.testing.FailingAllocator counts
    // .alloc calls only) is 21842 -> sweep window [21762, 21844).
    // The 21852 figure frozen in T-54-A/T-54-D came from an investigation
    // probe that also counted 10 growth-resize/remap events; it does NOT
    // match countAllocs(). Both are valid inputs to shardRange — assert
    // tessellation arithmetic for both.
    std.debug.assert(sweepWindow(21842).first == 21762);
    std.debug.assert(sweepWindow(21842).last_exclusive == 21844);
    std.debug.assert(shardRange(21852, 0).first == 21772);
    std.debug.assert(shardRange(21852, 3).last_exclusive == 21854);
}

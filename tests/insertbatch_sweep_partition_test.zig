//! insertbatch_sweep_partition_test.zig — T-54-C: pure-arithmetic guard
//! for the shard partition of the T-42 branch-producer fault sweep.
//!
//! `shardRange` (tests/btree_storage/insertbatch_sweep_helpers.zig) is the
//! ONLY new logic in the T-54-C split. An off-by-one there silently drops
//! fault points — sweep strength loss is invisible in test output — so this
//! test pins the invariants for the real production total (21842, plus the
//! probe-style 21852) and for a dense band of small totals:
//!
//!   1. the 4 shards are pairwise non-overlapping;
//!   2. they are consecutive (no gaps: next.first == prev.last_exclusive);
//!   3. their union is exactly [total-|80, total+2);
//!   4. point count per shard == its range width, and the 4 sum to the
//!      window width;
//!   5. shard sizes differ by at most 1 (balanced split).

const std = @import("std");
const testing = std.testing;
const h = @import("btree_storage/insertbatch_sweep_helpers.zig");

fn checkTotal(total: usize) !void {
    const w = h.sweepWindow(total);
    const width = w.last_exclusive - w.first;

    // 4. per-shard width == last-first, and collect them.
    var lasts: [h.SHARD_COUNT]usize = undefined;
    var firsts: [h.SHARD_COUNT]usize = undefined;
    var sum: usize = 0;
    for (0..h.SHARD_COUNT) |i| {
        const r = h.shardRange(total, i);
        try testing.expect(r.first <= r.last_exclusive);
        try testing.expect(r.last_exclusive - r.first <= width); // no shard wider than the window
        firsts[i] = r.first;
        lasts[i] = r.last_exclusive;
        sum += r.last_exclusive - r.first;
    }

    // 3. + 2. + 1.: tessellation — shards sorted by construction (a..d),
    // first shard starts at window start, each next continues the previous,
    // last ends at window end. Together this proves no overlap and no gap.
    try testing.expectEqual(w.first, firsts[0]);
    for (1..h.SHARD_COUNT) |i| {
        try testing.expectEqual(lasts[i - 1], firsts[i]);
    }
    try testing.expectEqual(w.last_exclusive, lasts[h.SHARD_COUNT - 1]);

    // 4. total points == window width.
    try testing.expectEqual(width, sum);

    // 5. balanced: sizes differ by at most 1.
    for (0..h.SHARD_COUNT) |i| {
        for (0..h.SHARD_COUNT) |j| {
            const di = lasts[i] - firsts[i];
            const dj = lasts[j] - firsts[j];
            try testing.expect(di <= dj + 1);
            try testing.expect(dj <= di + 1);
        }
    }
}

test "T-54-C: shardRange tiles [total-|80, total+2) for the real total (21842)" {
    // Real production value: the scenario calibrates to 21842 under the
    // test's own counting semantics (FailingAllocator counts .alloc calls
    // only) -> window [21762, 21844), 82 points.
    // (The 21852 figure frozen in T-54-A/T-54-D counted 10 extra
    // growth-resize/remap events; it matches an investigation probe, not
    // countAllocs().)
    try checkTotal(21842);
    const w = h.sweepWindow(21842);
    try testing.expectEqual(@as(usize, 21762), w.first);
    try testing.expectEqual(@as(usize, 21844), w.last_exclusive);
    try testing.expectEqual(@as(usize, 82), w.last_exclusive - w.first);
    // Arithmetic also stays correct for the probe-style total (21852).
    try checkTotal(21852);
}

test "T-54-C: shardRange tiles the window for small totals 1..300" {
    for (1..301) |total| try checkTotal(total);
}

test "T-54-C: shardRange degenerate cases (0, 80, 81, 82)" {
    // total = 0 -> first saturates to 0, window [0, 2), width 2.
    try checkTotal(0);
    // total = 80 -> window [0, 82) exactly the tail width + overshoot.
    try checkTotal(80);
    // total = 81 -> window [1, 83): first no longer saturated.
    try checkTotal(81);
    // total = 82 -> window [2, 84).
    try checkTotal(82);
}

test "T-54-C: shard >= SHARD_COUNT yields an empty range (defensive)" {
    const r = h.shardRange(21852, 4);
    try testing.expectEqual(@as(usize, 21854), r.first);
    try testing.expectEqual(@as(usize, 21854), r.last_exclusive);
}

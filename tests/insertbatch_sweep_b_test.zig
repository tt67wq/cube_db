//! insertbatch_sweep_a_test.zig — T-54-C shard b (of a..d) of the T-42
//! branch-producer calibrated fault sweep, split out of
//! tests/btree_storage/insertbatch_owned_test.zig for parallel execution.
//!
//! Each shard is its own top-level test binary (picked up by build.zig's
//! tests/*.zig auto-discovery), sweeps its own sub-range of the original
//! window [total-|80, total+2), and prints a machine-readable summary line
//! (includes the shard's calibrated total; verbose-gated via
//! tests/core_format/test_diag.zig — unconditional
//! prints would regress T-54-B's "failed command: = 0" gate; format is
//! check.sh v2 contract: SWEEP shard=<a-d> total=<T> first=<F> last=<L> points=<K>).
//!
//! Shards a..d are gap-free and non-overlapping; their union is exactly the
//! original sweep window (guarded by tests/insertbatch_sweep_partition_test.zig).

const std = @import("std");
const h = @import("btree_storage/insertbatch_sweep_helpers.zig");
const diag = @import("core_format/test_diag.zig");

test "T-42: branch-producer error path — no UAF, no leaks (calibrated fault sweep, shard b)" {
    const total = try h.countAllocs(h.branchOverflowScenario);
    const r = h.shardRange(total, 1);
    try h.sweepFailIndexes("branch-b", h.branchOverflowScenario, r.first, r.last_exclusive);
    diag.print("SWEEP shard=b total={d} first={d} last={d} points={d}\n", .{ total, r.first, r.last_exclusive, r.last_exclusive - r.first });
}

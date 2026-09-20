//! test_one_aggregator.zig — T-54-F: root closure for `zig build test-one -Dfilter=<子串>`.
//!
//! Lives at tests/ top level BUT is explicitly excluded from build.zig's
//! auto-discovery loop (one-name skip): without the skip it would become
//! its own step and double-execute every test it aggregates. It only ever
//! runs as the root of `zig build test-one -Dfilter=<substr>`.
//!
//! Imports everything the default `zig build test` covers on the tests/
//! side — the 13 domain aggregators + the partition guard + the 13 orphan
//! files wired by T-54-F — EXCEPT the 4 insertbatch_sweep_{a,b,c,d} shard
//! files: each shard is a ~46s fault-injection sweep; pulling them into a
//! single filtered binary would serialize them (~3min) and defeat the
//! <5s iteration goal. The shards stay covered by the default gate and
//! can be run via `zig build test-one`-free `zig build test` / named steps.
//! (src/ unit tests are a separate mechanism — mod_tests/exe_tests in
//! build.zig — and are NOT part of this aggregator.)
//!
//! Compile-time filtering (`Compile.filters` via -Dfilter) then prunes the
//! test set to names containing the substring: one binary, one cache hit,
//! only matching tests run.

comptime {
    // 13 domain aggregators (each = one auto-discovered top-level file)
    _ = @import("btree_read_test.zig");
    _ = @import("btree_storage_test.zig");
    _ = @import("core_format_test.zig");
    _ = @import("crash_insertbatch_pb_test.zig");
    _ = @import("crc_integrity_test.zig");
    _ = @import("cube_check_test.zig");
    _ = @import("get_mvcc_pin_test.zig");
    _ = @import("n1_composite_overflow_test.zig");
    _ = @import("oversized_key_test.zig");
    _ = @import("reader_handle_test.zig");
    _ = @import("staging_concurrent_regression_test.zig");
    _ = @import("staging_concurrent_test.zig");
    _ = @import("txn_writer_db_test.zig");
    // shard-partition arithmetic guard (fast, pure arithmetic)
    _ = @import("insertbatch_sweep_partition_test.zig");

    // T-54-F: orphan files wired into the default gate as standalone steps —
    // mirrored here so test-one can filter into them too. freelist_amp_red
    // is deliberately included (NOT in the default gate: its RED #1 is red
    // by design, see issues/T-39-C-followup) — filtering into it from here
    // is the intended iteration workflow while T-39-C is parked.
    _ = @import("txn_writer_db/range_tombstone_read_test.zig");
    _ = @import("core_format/range_tombstone_format_test.zig");
    _ = @import("core_format/freelist_amp_red_test.zig");
    _ = @import("txn_writer_db/applybatch_single_vs_multi_test.zig");
    _ = @import("fuzz/probe_test.zig");
    _ = @import("txn_writer_db/delete_range_concurrent_test.zig");
    _ = @import("txn_writer_db/deleterange_mem_budget_test.zig");
    _ = @import("fuzz/api_fuzz_test.zig");
    _ = @import("fuzz/api_batch_fuzz_test.zig");
    _ = @import("fuzz/format_fuzz_test.zig");
    _ = @import("fuzz/range_delete_fuzz_test.zig");
    _ = @import("txn_writer_db/mvcc_concurrent_flush_test.zig");
    _ = @import("fuzz/meta_corrupt_fuzz_test.zig");
}

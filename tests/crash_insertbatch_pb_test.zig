//! crash_insertbatch_pb_test.zig - domain aggregate: crash recovery / stress / insertbatch / putbatch / range_delete / fps benchmark
//! comptime @import aggregates sub-files, reducing compilation units from 38 to 6.
//! Moved from original tests/*.zig, logic unchanged.

comptime {
    _ = @import("crash_insertbatch_pb/crash_harness_test.zig");
    _ = @import("crash_insertbatch_pb/crash_putbatch_test.zig");
    _ = @import("crash_insertbatch_pb/crash_recovery_test.zig");
    _ = @import("crash_insertbatch_pb/crash_recovery_framework.zig");
    _ = @import("crash_insertbatch_pb/stress_test.zig");
    _ = @import("crash_insertbatch_pb/insertbatch_capaware_test.zig");
    _ = @import("crash_insertbatch_pb/insertbatch_overflow_test.zig");
    _ = @import("crash_insertbatch_pb/putbatch_correctness_test.zig");
    _ = @import("crash_insertbatch_pb/range_delete_test.zig");
    _ = @import("crash_insertbatch_pb/pb_fps_ordered_test.zig");
    _ = @import("crash_insertbatch_pb/pb_fps_scale_test.zig");
    _ = @import("crash_insertbatch_pb/crash_meta_midwrite_test.zig");
    _ = @import("crash_insertbatch_pb/durability_order_test.zig");
    // T-33 RED: freelist persistence crash injection (T5 + T5-b + T5-r)
    _ = @import("crash_insertbatch_pb/freelist_persist_crash_test.zig");
}

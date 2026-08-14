//! crash_insertbatch_pb_test.zig — 领域汇总：crash 恢复 / stress / insertbatch / putbatch / range_delete / fps 基准
//! comptime @import 聚合子文件，编译单元从 38 降到 6。
//! 搬运自原 tests/*.zig，逻辑未动。

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
}

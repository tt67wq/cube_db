//! txn_writer_db_test.zig — 领域汇总：writer / MVCC / overflow / compact / db / txn / group_commit / tutorial
//! comptime @import 聚合子文件，编译单元从 38 降到 6。
//! 搬运自原 tests/*.zig，逻辑未动。

comptime {
    _ = @import("txn_writer_db/writer_test.zig");
    _ = @import("txn_writer_db/mvcc_test.zig");
    _ = @import("txn_writer_db/overflow_test.zig");
    _ = @import("txn_writer_db/compact_test.zig");
    _ = @import("txn_writer_db/db_test.zig");
    _ = @import("txn_writer_db/txn_test.zig");
    _ = @import("txn_writer_db/txn_arena_test.zig");
    _ = @import("txn_writer_db/txn_abort_arena_test.zig");
    _ = @import("txn_writer_db/group_commit_test.zig");
    _ = @import("txn_writer_db/group_commit_ext_test.zig");
    _ = @import("txn_writer_db/tutorial_smoke_test.zig");
}

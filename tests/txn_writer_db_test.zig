//! txn_writer_db_test.zig - domain aggregate: writer / MVCC / overflow / compact / db / txn / group_commit / tutorial
//! comptime @import aggregates sub-files, reducing compilation units from 38 to 6.
//! Moved from original tests/*.zig, logic unchanged.

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
    _ = @import("txn_writer_db/closed_state_test.zig");
    _ = @import("txn_writer_db/lock_failure_test.zig");
    _ = @import("txn_writer_db/close_flush_failure_test.zig");
    _ = @import("txn_writer_db/compact_strong_assert_test.zig");
}

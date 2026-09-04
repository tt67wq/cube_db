//! btree_storage_test.zig - domain aggregate: B-tree / read-txn fuzz / shared COW
//! comptime @import aggregates sub-files, reducing compilation units from 38 to 6.
//! Moved from original tests/*.zig, logic unchanged.

comptime {
    _ = @import("btree_storage/btree_test.zig");
    _ = @import("btree_storage/shared_cow_test.zig");
}

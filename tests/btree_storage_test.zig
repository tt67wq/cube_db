//! btree_storage_test.zig — 领域汇总：B-tree / 读事务 fuzz / 共享 COW
//! comptime @import 聚合子文件，编译单元从 38 降到 6。
//! 搬运自原 tests/*.zig，逻辑未动。

comptime {
    _ = @import("btree_storage/btree_test.zig");
    _ = @import("btree_storage/readtxn_fuzz.zig");
    _ = @import("btree_storage/shared_cow_test.zig");
}

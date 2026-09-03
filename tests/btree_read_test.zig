//! btree_read_test.zig — 读路径领域汇总：getInto / 借用读（T-29）
//! comptime @import 聚合子文件，配合 build.zig 的 tests/*.zig 自动发现。

comptime {
    _ = @import("btree_read/getinto_borrow_test.zig");
    _ = @import("btree_read/iterator_borrow_test.zig");
}

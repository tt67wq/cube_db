//! btree_read_test.zig - read-path domain aggregate: getInto / borrowed reads (T-29)
//! comptime @import aggregates sub-files, paired with build.zig auto-discovery of tests/*.zig.

comptime {
    _ = @import("btree_read/getinto_borrow_test.zig");
    _ = @import("btree_read/iterator_borrow_test.zig");
}

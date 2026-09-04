//! core_format_test.zig - domain aggregate: page format / page_store / slab / CRC32 / mmap / binary search / cow
//! comptime @import aggregates sub-files, reducing compilation units from 38 to 6.
//! Moved from original tests/*.zig, logic unchanged.

comptime {
    _ = @import("core_format/format_test.zig");
    _ = @import("core_format/page_store_test.zig");
    _ = @import("core_format/slab_page_store_test.zig");
    _ = @import("core_format/slab_memory_test.zig");
    _ = @import("core_format/crc32_hw_test.zig");
    _ = @import("core_format/crc_regression_test.zig");
    _ = @import("core_format/mmap_region_test.zig");
    _ = @import("core_format/binary_search_test.zig");
    _ = @import("core_format/cow_fast_test.zig");
}

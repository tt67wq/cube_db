//! core_format_test.zig — 领域汇总：页格式 / page_store / slab / CRC32 / mmap / 二分 / cow
//! comptime @import 聚合子文件，编译单元从 38 降到 6。
//! 搬运自原 tests/*.zig，逻辑未动。

comptime {
    _ = @import("core_format/format_test.zig");
    _ = @import("core_format/page_store_test.zig");
    _ = @import("core_format/slab_page_store_test.zig");
    _ = @import("core_format/slab_memory_test.zig");
    _ = @import("core_format/crc32_hw_test.zig");
    _ = @import("core_format/crc_regression_test.zig");
    _ = @import("core_format/mmap_region_test.zig");
    _ = @import("core_format/binary_search_test.zig");
    _ = @import("core_format/zero_copy_test.zig");
    _ = @import("core_format/cow_fast_test.zig");
}

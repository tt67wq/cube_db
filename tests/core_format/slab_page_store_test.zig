//! slab_page_store_test.zig — TDD: MemPageStore slab 页池改造
//! 验证 ArrayList+freelist 替代 HashMap 后的正确性。
const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const ps = cube.page_store;

const MemPageStore = ps.MemPageStore;

test "slab: allocPage sequential page numbers" {
    var ms = MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const s = ms.store();

    const p1 = try s.allocPage();
    try std.testing.expectEqual(@as(u32, 3), p1); // FIRST_DATA_PAGE
    const p2 = try s.allocPage();
    try std.testing.expectEqual(@as(u32, 4), p2);
    _ = try s.allocPage();
}

test "slab: write then read returns same data" {
    var ms = MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const s = ms.store();

    const pn = try s.allocPage();
    const w = try s.writePage(pn);
    w[0] = 0xAA;
    w[1] = 0xBB;
    w[4095] = 0xCC;

    const r = try s.readPage(pn);
    try std.testing.expectEqual(@as(u8, 0xAA), r[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), r[1]);
    try std.testing.expectEqual(@as(u8, 0xCC), r[4095]);
}

test "slab: freePage returns page to freelist" {
    var ms = MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const s = ms.store();

    const p1 = try s.allocPage();
    const p2 = try s.allocPage();
    _ = try s.allocPage();
    s.freePage(p2);
    const p4 = try s.allocPage(); // Should reuse p2
    try std.testing.expectEqual(p2, p4);
    _ = p1;
}

test "slab: writePage creates page if not exists" {
    var ms = MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const s = ms.store();

    // Write to a page that hasn't been allocated yet
    const w = try s.writePage(42);
    w[0] = 0x42;
    const r = try s.readPage(42);
    try std.testing.expectEqual(@as(u8, 0x42), r[0]);
}

test "slab: many sequential allocations" {
    var ms = MemPageStore.init(std.testing.allocator, 50000);
    defer ms.deinit();
    const s = ms.store();

    const n: usize = 10000;
    for (0..n) |i| {
        const pn = try s.allocPage();
        const w = try s.writePage(pn);
        w[0] = @truncate(i);
    }
    // Verify all pages
    for (0..n) |i| {
        const pn = @as(u32, @intCast(ps.FIRST_DATA_PAGE + i));
        const r = try s.readPage(pn);
        try std.testing.expectEqual(@as(u8, @truncate(i)), r[0]);
    }
}

test "slab: allocPage returns error.MapFull when full" {
    var ms = MemPageStore.init(std.testing.allocator, 5); // Only 5 pages
    defer ms.deinit();
    const s = ms.store();

    // FIRST_DATA_PAGE=3, max_pages=5, so pages 3,4 are available
    _ = try s.allocPage();
    _ = try s.allocPage();
    try std.testing.expectError(error.MapFull, s.allocPage());
}

test "slab: meta pages work correctly" {
    var ms = MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const s = ms.store();

    const meta = f2.MetaPage{
        .magic = f2.MAGIC_V2,
        .version = 2,
        .mapsize = 1000,
        .sequence = 1,
        .root_page = 42,
        .entry_count = 100,
        .byte_size = 5000,
        .free_head = 0,
        .free_count = 0,
        .last_page = 0,
    };
    try s.writeMeta(&meta);
    const read_back = try s.readMeta();
    try std.testing.expect(read_back != null);
    try std.testing.expectEqual(@as(u64, 100), read_back.?.entry_count);
}

test "slab: writePage handles large page number" {
    var ms = MemPageStore.init(std.testing.allocator, 500000);
    defer ms.deinit();
    const s = ms.store();

    // Write to a large page number (tests ArrayList growth)
    const w = try s.writePage(30000);
    w[0] = 0xFF;
    const r = try s.readPage(30000);
    try std.testing.expectEqual(@as(u8, 0xFF), r[0]);
}
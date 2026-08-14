//! format_test.zig — 页格式 v2 编解码测试（TDD RED）
//! 覆盖：PageHeader roundtrip、MetaPage roundtrip + 交替恢复、CRC 校验 + 损坏回退、freelist 页编码。
//! 先 fail（format2.zig 尚不存在），实现后全绿。
const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;

test "format: PAGE_SIZE and PAGE_HEADER_SIZE constants" {
    try std.testing.expectEqual(@as(usize, 4096), f2.PAGE_SIZE);
    try std.testing.expectEqual(@as(usize, 24), f2.PAGE_HEADER_SIZE);
}

test "format: page type constants" {
    try std.testing.expectEqual(@as(u8, 0), f2.PAGE_TYPE_FREE);
    try std.testing.expectEqual(@as(u8, 1), f2.PAGE_TYPE_META);
    try std.testing.expectEqual(@as(u8, 2), f2.PAGE_TYPE_BRANCH);
    try std.testing.expectEqual(@as(u8, 3), f2.PAGE_TYPE_LEAF);
    try std.testing.expectEqual(@as(u8, 4), f2.PAGE_TYPE_OVERFLOW);
}

test "format: null page constants" {
    try std.testing.expectEqual(@as(u32, 0), f2.NULL_PAGE);
    try std.testing.expectEqual(@as(u32, 1), f2.META_PAGE_0);
    try std.testing.expectEqual(@as(u32, 2), f2.META_PAGE_1);
}

test "format: page header encode/decode roundtrip" {
    const h = f2.PageHeader{
        .page_no = 42,
        .page_type = f2.PAGE_TYPE_LEAF,
        .gen = 1000,
        .nkeys = 16,
        .free_next = 0,
    };
    var buf: [f2.PAGE_HEADER_SIZE]u8 = undefined;
    f2.encodePageHeader(&buf, &h);
    const got = f2.decodePageHeader(&buf);
    try std.testing.expectEqual(h.page_no, got.page_no);
    try std.testing.expectEqual(h.page_type, got.page_type);
    try std.testing.expectEqual(h.gen, got.gen);
    try std.testing.expectEqual(h.nkeys, got.nkeys);
    try std.testing.expectEqual(h.free_next, got.free_next);
}

test "format: page header free page free_next preserved" {
    const h = f2.PageHeader{
        .page_no = 99,
        .page_type = f2.PAGE_TYPE_FREE,
        .gen = 0,
        .nkeys = 0,
        .free_next = 777,
    };
    var buf: [f2.PAGE_HEADER_SIZE]u8 = undefined;
    f2.encodePageHeader(&buf, &h);
    const got = f2.decodePageHeader(&buf);
    try std.testing.expectEqual(@as(u32, 777), got.free_next);
    try std.testing.expectEqual(f2.PAGE_TYPE_FREE, got.page_type);
}

test "format: page header zero values" {
    const h = f2.PageHeader{
        .page_no = 0,
        .page_type = 0,
        .gen = 0,
        .nkeys = 0,
        .free_next = 0,
    };
    var buf: [f2.PAGE_HEADER_SIZE]u8 = undefined;
    f2.encodePageHeader(&buf, &h);
    const got = f2.decodePageHeader(&buf);
    try std.testing.expectEqual(@as(u32, 0), got.page_no);
    try std.testing.expectEqual(@as(u8, 0), got.page_type);
    try std.testing.expectEqual(@as(u64, 0), got.gen);
}

test "format: page checksum covers header + payload" {
    // 构造一个完整页（header + payload + checksum），验证 checksum 覆盖 header+payload
    var page: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page, 0xaa);
    const h = f2.PageHeader{
        .page_no = 1,
        .page_type = f2.PAGE_TYPE_META,
        .gen = 5,
        .nkeys = 0,
        .free_next = 0,
    };
    f2.encodePageHeader(&page, &h);
    // 写 payload 区
    @memset(page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4], 0xbb);
    // 计算并写入 checksum
    const cs = f2.computePageChecksum(&page);
    f2.setPageChecksum(&page, cs);
    // 验证
    const verified = f2.verifyPageChecksum(&page);
    try std.testing.expect(verified);
    // 篡改 payload 一字节 → 验证失败
    page[f2.PAGE_HEADER_SIZE + 10] ^= 0xff;
    try std.testing.expect(!f2.verifyPageChecksum(&page));
}

test "format: page checksum tampered header fails" {
    var page: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page, 0);
    const h = f2.PageHeader{ .page_no = 7, .page_type = f2.PAGE_TYPE_LEAF, .gen = 3, .nkeys = 8, .free_next = 0 };
    f2.encodePageHeader(&page, &h);
    f2.setPageChecksum(&page, f2.computePageChecksum(&page));
    // 篡改 header 域
    page[0] ^= 0xff; // flip page_no 第一字节
    try std.testing.expect(!f2.verifyPageChecksum(&page));
}

test "format: meta page encode/decode roundtrip" {
    const meta = f2.MetaPage{
        .magic = f2.MAGIC_V2,
        .version = 2,
        .mapsize = 1 << 30,
        .sequence = 42,
        .root_page = 100,
        .entry_count = 5000,
        .byte_size = 1_000_000,
        .free_head = 50,
        .free_count = 200,
        .last_page = 300,
    };
    var buf: [f2.META_PAGE_PAYLOAD_SIZE]u8 = undefined;
    f2.encodeMetaPayload(&buf, &meta);
    const got = f2.decodeMetaPayload(&buf);
    try std.testing.expectEqual(meta.magic, got.magic);
    try std.testing.expectEqual(meta.version, got.version);
    try std.testing.expectEqual(meta.mapsize, got.mapsize);
    try std.testing.expectEqual(meta.sequence, got.sequence);
    try std.testing.expectEqual(meta.root_page, got.root_page);
    try std.testing.expectEqual(meta.entry_count, got.entry_count);
    try std.testing.expectEqual(meta.byte_size, got.byte_size);
    try std.testing.expectEqual(meta.free_head, got.free_head);
    try std.testing.expectEqual(meta.free_count, got.free_count);
    try std.testing.expectEqual(meta.last_page, got.last_page);
}

test "format: meta page magic and version validation" {
    try std.testing.expect(f2.isValidMeta(.{
        .magic = f2.MAGIC_V2,
        .version = 2,
        .mapsize = 0,
        .sequence = 0,
        .root_page = 0,
        .entry_count = 0,
        .byte_size = 0,
        .free_head = 0,
        .free_count = 0,
        .last_page = 0,
    }));
    try std.testing.expect(!f2.isValidMeta(.{
        .magic = 0x12345678,
        .version = 2,
        .mapsize = 0,
        .sequence = 0,
        .root_page = 0,
        .entry_count = 0,
        .byte_size = 0,
        .free_head = 0,
        .free_count = 0,
        .last_page = 0,
    }));
    try std.testing.expect(!f2.isValidMeta(.{
        .magic = f2.MAGIC_V2,
        .version = 99,
        .mapsize = 0,
        .sequence = 0,
        .root_page = 0,
        .entry_count = 0,
        .byte_size = 0,
        .free_head = 0,
        .free_count = 0,
        .last_page = 0,
    }));
}

test "format: meta alternation — take larger sequence" {
    const meta0 = f2.MetaPage{
        .magic = f2.MAGIC_V2,
        .version = 2,
        .mapsize = 1 << 30,
        .sequence = 100,
        .root_page = 50,
        .entry_count = 1000,
        .byte_size = 50000,
        .free_head = 10,
        .free_count = 5,
        .last_page = 200,
    };
    const meta1 = f2.MetaPage{
        .magic = f2.MAGIC_V2,
        .version = 2,
        .mapsize = 1 << 30,
        .sequence = 200,
        .root_page = 60,
        .entry_count = 2000,
        .byte_size = 100000,
        .free_head = 20,
        .free_count = 10,
        .last_page = 300,
    };
    // 编码 meta0 到 page 1，meta1 到 page 2
    var page0: [f2.PAGE_SIZE]u8 = undefined;
    var page1: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page0, 0);
    @memset(&page1, 0);
    f2.writeMetaPage(&page0, &meta0, 0);
    f2.writeMetaPage(&page1, &meta1, 1);
    // 恢复：取 sequence 大的
    const got = f2.readMetaPage(&page0, &page1);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u64, 200), got.?.sequence);
    try std.testing.expectEqual(@as(u32, 60), got.?.root_page);
    try std.testing.expectEqual(@as(u64, 2000), got.?.entry_count);
}

test "format: meta alternation — meta0 newer" {
    const meta0 = f2.MetaPage{
        .magic = f2.MAGIC_V2, .version = 2, .mapsize = 1 << 30,
        .sequence = 300, .root_page = 70, .entry_count = 3000, .byte_size = 150000,
        .free_head = 30, .free_count = 15, .last_page = 400,
    };
    const meta1 = f2.MetaPage{
        .magic = f2.MAGIC_V2, .version = 2, .mapsize = 1 << 30,
        .sequence = 100, .root_page = 10, .entry_count = 500, .byte_size = 25000,
        .free_head = 5, .free_count = 2, .last_page = 50,
    };
    var page0: [f2.PAGE_SIZE]u8 = undefined;
    var page1: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page0, 0);
    @memset(&page1, 0);
    f2.writeMetaPage(&page0, &meta0, 0);
    f2.writeMetaPage(&page1, &meta1, 1);
    const got = f2.readMetaPage(&page0, &page1);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u64, 300), got.?.sequence);
    try std.testing.expectEqual(@as(u32, 70), got.?.root_page);
}

test "format: meta alternation — one corrupt, take other" {
    const meta0 = f2.MetaPage{
        .magic = f2.MAGIC_V2, .version = 2, .mapsize = 1 << 30,
        .sequence = 500, .root_page = 100, .entry_count = 5000, .byte_size = 250000,
        .free_head = 50, .free_count = 25, .last_page = 600,
    };
    var page0: [f2.PAGE_SIZE]u8 = undefined;
    var page1: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page0, 0);
    @memset(&page1, 0);
    f2.writeMetaPage(&page0, &meta0, 0);
    // page1 是垃圾（未写过 meta 或写一半崩溃）
    @memset(page1[0..f2.PAGE_HEADER_SIZE], 0xff);
    f2.setPageChecksum(&page1, f2.computePageChecksum(&page1));
    const got = f2.readMetaPage(&page0, &page1);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u64, 500), got.?.sequence);
    try std.testing.expectEqual(@as(u32, 100), got.?.root_page);
}

test "format: meta alternation — both corrupt returns null" {
    var page0: [f2.PAGE_SIZE]u8 = undefined;
    var page1: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page0, 0xff);
    @memset(&page1, 0xff);
    f2.setPageChecksum(&page0, f2.computePageChecksum(&page0));
    f2.setPageChecksum(&page1, f2.computePageChecksum(&page1));
    const got = f2.readMetaPage(&page0, &page1);
    try std.testing.expect(got == null);
}

test "format: meta alternation — both empty returns null" {
    var page0: [f2.PAGE_SIZE]u8 = undefined;
    var page1: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page0, 0);
    @memset(&page1, 0);
    f2.setPageChecksum(&page0, f2.computePageChecksum(&page0));
    f2.setPageChecksum(&page1, f2.computePageChecksum(&page1));
    const got = f2.readMetaPage(&page0, &page1);
    try std.testing.expect(got == null);
}

test "format: encode/decode MetaPage from page buffer" {
    const meta = f2.MetaPage{
        .magic = f2.MAGIC_V2, .version = 2, .mapsize = 1 << 30,
        .sequence = 777, .root_page = 123, .entry_count = 9999, .byte_size = 500000,
        .free_head = 45, .free_count = 100, .last_page = 456,
    };
    var page: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page, 0);
    f2.writeMetaPage(&page, &meta, 0);
    // 验证页头 page_no=1(page index 0 → page_no=1 for meta0)
    const hdr = f2.decodePageHeader(page[0..f2.PAGE_HEADER_SIZE]);
    try std.testing.expectEqual(@as(u32, 1), hdr.page_no);
    try std.testing.expectEqual(f2.PAGE_TYPE_META, hdr.page_type);
    // 验证 checksum
    try std.testing.expect(f2.verifyPageChecksum(&page));
    // 解回 meta
    const got = f2.readMetaPageSingle(&page);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u64, 777), got.?.sequence);
    try std.testing.expectEqual(@as(u32, 123), got.?.root_page);
    try std.testing.expectEqual(@as(u64, 9999), got.?.entry_count);
}

test "format: freelist page chain" {
    // 模拟 freelist 页链：page 100 → page 200 → page 300 (tail)
    var page100: [f2.PAGE_SIZE]u8 = undefined;
    var page200: [f2.PAGE_SIZE]u8 = undefined;
    var page300: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page100, 0);
    @memset(&page200, 0);
    @memset(&page300, 0);

    // page 100: free_next=200, contains [10, 20, 30]
    var h100 = f2.PageHeader{ .page_no = 100, .page_type = f2.PAGE_TYPE_FREE, .gen = 0, .nkeys = 0, .free_next = 200 };
    f2.encodePageHeader(&page100, &h100);
    f2.writeFreelistEntries(&page100, &.{ 10, 20, 30 });

    // page 200: free_next=300, contains [40, 50]
    var h200 = f2.PageHeader{ .page_no = 200, .page_type = f2.PAGE_TYPE_FREE, .gen = 0, .nkeys = 0, .free_next = 300 };
    f2.encodePageHeader(&page200, &h200);
    f2.writeFreelistEntries(&page200, &.{ 40, 50 });

    // page 300: free_next=0 (tail), contains [60]
    var h300 = f2.PageHeader{ .page_no = 300, .page_type = f2.PAGE_TYPE_FREE, .gen = 0, .nkeys = 0, .free_next = 0 };
    f2.encodePageHeader(&page300, &h300);
    f2.writeFreelistEntries(&page300, &.{60});

    // 读回验证
    const entries1 = f2.readFreelistEntries(&page100);
    try std.testing.expectEqual(@as(usize, 3), entries1.len);
    try std.testing.expectEqual(@as(u32, 10), entries1[0]);
    try std.testing.expectEqual(@as(u32, 20), entries1[1]);
    try std.testing.expectEqual(@as(u32, 30), entries1[2]);

    const entries2 = f2.readFreelistEntries(&page200);
    try std.testing.expectEqual(@as(usize, 2), entries2.len);
    try std.testing.expectEqual(@as(u32, 40), entries2[0]);
    try std.testing.expectEqual(@as(u32, 50), entries2[1]);

    const entries3 = f2.readFreelistEntries(&page300);
    try std.testing.expectEqual(@as(usize, 1), entries3.len);
    try std.testing.expectEqual(@as(u32, 60), entries3[0]);
}

test "format: freelist page with no entries" {
    var page: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page, 0);
    var h = f2.PageHeader{ .page_no = 50, .page_type = f2.PAGE_TYPE_FREE, .gen = 0, .nkeys = 0, .free_next = 0 };
    f2.encodePageHeader(&page, &h);
    const entries = f2.readFreelistEntries(&page);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "format: freelist page max entries fits in one page" {
    // 计算一页能装多少 u32 条目（4 字节 count + 剩余放条目）
    const max_entries = (f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4 - 4) / 4;
    try std.testing.expectEqual(@as(usize, 1016), max_entries);
    // 写满一页
    var page: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page, 0);
    var h = f2.PageHeader{ .page_no = 10, .page_type = f2.PAGE_TYPE_FREE, .gen = 0, .nkeys = 0, .free_next = 0 };
    f2.encodePageHeader(&page, &h);
    var entries = std.ArrayList(u32).empty;
    defer entries.deinit(std.testing.allocator);
    var i: u32 = 0;
    while (i < max_entries) : (i += 1) {
        entries.append(std.testing.allocator, 1000 + i) catch unreachable;
    }
    f2.writeFreelistEntries(&page, entries.items);
    const got = f2.readFreelistEntries(&page);
    try std.testing.expectEqual(max_entries, got.len);
    try std.testing.expectEqual(@as(u32, 1000), got[0]);
    try std.testing.expectEqual(@as(u32, 1000 + max_entries - 1), got[got.len - 1]);
}

test "format: readMetaPageSingle on junk page returns null" {
    var page: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page, 0xff);
    f2.setPageChecksum(&page, f2.computePageChecksum(&page));
    const got = f2.readMetaPageSingle(&page);
    try std.testing.expect(got == null);
}

test "format: computePageChecksum is deterministic" {
    var page: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page, 0x42);
    const cs1 = f2.computePageChecksum(&page);
    const cs2 = f2.computePageChecksum(&page);
    try std.testing.expectEqual(cs1, cs2);
}
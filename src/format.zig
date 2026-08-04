//! format.zig — v2 页格式常量与编解码（页头、meta、freelist、CRC）
//! 纯函数模块，无 IO。PAGE_SIZE=4096，固定页头 24B，页尾 4B CRC。
const std = @import("std");

pub const PAGE_SIZE: usize = 4096;
pub const PAGE_HEADER_SIZE: usize = 24;

/// 页类型
pub const PAGE_TYPE_FREE: u8 = 0;
pub const PAGE_TYPE_META: u8 = 1;
pub const PAGE_TYPE_BRANCH: u8 = 2;
pub const PAGE_TYPE_LEAF: u8 = 3;
pub const PAGE_TYPE_OVERFLOW: u8 = 4;

/// 特殊页号
pub const NULL_PAGE: u32 = 0;
pub const META_PAGE_0: u32 = 1;
pub const META_PAGE_1: u32 = 2;

pub const MAGIC_V2: u32 = 0x4355_4232; // "CUB2"
pub const META_PAGE_PAYLOAD_SIZE: usize = 58;

/// 页头（每个页前 24 字节）
pub const PageHeader = struct {
    page_no: u32,
    page_type: u8,
    gen: u64,
    nkeys: u16,
    free_next: u32, // freelist 链下一页；非 free 页为 0
};

/// meta page 内容（编码在 payload 区）
pub const MetaPage = struct {
    magic: u32,
    version: u16,
    mapsize: u64,
    sequence: u64,
    root_page: u32,
    entry_count: u64,
    byte_size: u64,
    free_head: u32,
    free_count: u64,
    last_page: u32,
};

const Crc32 = std.hash.crc.Crc32;

// ===== 页头编解码 =====

comptime {
    std.debug.assert(PAGE_HEADER_SIZE == 24);
}

pub fn encodePageHeader(buf: []u8, h: *const PageHeader) void {
    std.debug.assert(buf.len >= PAGE_HEADER_SIZE);
    var pos: usize = 0;
    std.mem.writeInt(u32, buf[pos..][0..4], h.page_no, .little);
    pos += 4;
    buf[pos] = h.page_type;
    pos += 1;
    std.mem.writeInt(u64, buf[pos..][0..8], h.gen, .little);
    pos += 8;
    std.mem.writeInt(u16, buf[pos..][0..2], h.nkeys, .little);
    pos += 2;
    std.mem.writeInt(u32, buf[pos..][0..4], h.free_next, .little);
    pos += 4;
    // padding 5 bytes (leave as is)
}

pub fn decodePageHeader(buf: []const u8) PageHeader {
    std.debug.assert(buf.len >= PAGE_HEADER_SIZE);
    var pos: usize = 0;
    const page_no = std.mem.readInt(u32, buf[pos..][0..4], .little);
    pos += 4;
    const page_type = buf[pos];
    pos += 1;
    const gen = std.mem.readInt(u64, buf[pos..][0..8], .little);
    pos += 8;
    const nkeys = std.mem.readInt(u16, buf[pos..][0..2], .little);
    pos += 2;
    const free_next = std.mem.readInt(u32, buf[pos..][0..4], .little);
    return .{
        .page_no = page_no,
        .page_type = page_type,
        .gen = gen,
        .nkeys = nkeys,
        .free_next = free_next,
    };
}

// ===== 页校验和 =====

const builtin = @import("builtin");
const crc32_hw = @import("crc32_hw.zig");

/// 计算整页 CRC32（覆盖 bytes [0..PAGE_SIZE-4)）
/// ARM64 使用硬件 CRC32 指令，其他平台走软件表驱动
pub fn computePageChecksum(page: *const [PAGE_SIZE]u8) u32 {
    return switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => crc32_hw.computePageChecksumHw(page),
        else => computePageChecksumSw(page),
    };
}

/// 软件路径（表驱动 CRC32）
pub fn computePageChecksumSw(page: *const [PAGE_SIZE]u8) u32 {
    var crc = Crc32.init();
    crc.update(page[0 .. PAGE_SIZE - 4]);
    return crc.final();
}

/// 写入校验和到页尾
pub fn setPageChecksum(page: *[PAGE_SIZE]u8, cs: u32) void {
    std.mem.writeInt(u32, page[PAGE_SIZE - 4 ..][0..4], cs, .little);
}

/// 验证整页校验和
pub fn verifyPageChecksum(page: *const [PAGE_SIZE]u8) bool {
    const stored = std.mem.readInt(u32, page[PAGE_SIZE - 4 ..][0..4], .little);
    const computed = computePageChecksum(page);
    return stored == computed;
}

// ===== Meta page 编解码 =====

pub fn encodeMetaPayload(buf: []u8, meta: *const MetaPage) void {
    std.debug.assert(buf.len >= META_PAGE_PAYLOAD_SIZE);
    var pos: usize = 0;
    std.mem.writeInt(u32, buf[pos..][0..4], meta.magic, .little);
    pos += 4;
    std.mem.writeInt(u16, buf[pos..][0..2], meta.version, .little);
    pos += 2;
    std.mem.writeInt(u64, buf[pos..][0..8], meta.mapsize, .little);
    pos += 8;
    std.mem.writeInt(u64, buf[pos..][0..8], meta.sequence, .little);
    pos += 8;
    std.mem.writeInt(u32, buf[pos..][0..4], meta.root_page, .little);
    pos += 4;
    std.mem.writeInt(u64, buf[pos..][0..8], meta.entry_count, .little);
    pos += 8;
    std.mem.writeInt(u64, buf[pos..][0..8], meta.byte_size, .little);
    pos += 8;
    std.mem.writeInt(u32, buf[pos..][0..4], meta.free_head, .little);
    pos += 4;
    std.mem.writeInt(u64, buf[pos..][0..8], meta.free_count, .little);
    pos += 8;
    std.mem.writeInt(u32, buf[pos..][0..4], meta.last_page, .little);
}

pub fn decodeMetaPayload(buf: []const u8) MetaPage {
    std.debug.assert(buf.len >= META_PAGE_PAYLOAD_SIZE);
    var pos: usize = 0;
    const magic = std.mem.readInt(u32, buf[pos..][0..4], .little);
    pos += 4;
    const version = std.mem.readInt(u16, buf[pos..][0..2], .little);
    pos += 2;
    const mapsize = std.mem.readInt(u64, buf[pos..][0..8], .little);
    pos += 8;
    const sequence = std.mem.readInt(u64, buf[pos..][0..8], .little);
    pos += 8;
    const root_page = std.mem.readInt(u32, buf[pos..][0..4], .little);
    pos += 4;
    const entry_count = std.mem.readInt(u64, buf[pos..][0..8], .little);
    pos += 8;
    const byte_size = std.mem.readInt(u64, buf[pos..][0..8], .little);
    pos += 8;
    const free_head = std.mem.readInt(u32, buf[pos..][0..4], .little);
    pos += 4;
    const free_count = std.mem.readInt(u64, buf[pos..][0..8], .little);
    pos += 8;
    const last_page = std.mem.readInt(u32, buf[pos..][0..4], .little);
    return .{
        .magic = magic,
        .version = version,
        .mapsize = mapsize,
        .sequence = sequence,
        .root_page = root_page,
        .entry_count = entry_count,
        .byte_size = byte_size,
        .free_head = free_head,
        .free_count = free_count,
        .last_page = last_page,
    };
}

pub fn isValidMeta(meta: MetaPage) bool {
    return meta.magic == MAGIC_V2 and meta.version == 2;
}

/// 将 meta 写入 page 缓冲区（page 索引 0 或 1 → 页号 1 或 2）
pub fn writeMetaPage(page: *[PAGE_SIZE]u8, meta: *const MetaPage, index: u32) void {
    std.debug.assert(index == 0 or index == 1);
    const page_no = if (index == 0) META_PAGE_0 else META_PAGE_1;
    // 写页头
    const hdr = PageHeader{
        .page_no = page_no,
        .page_type = PAGE_TYPE_META,
        .gen = meta.sequence,
        .nkeys = 0,
        .free_next = 0,
    };
    encodePageHeader(page[0..PAGE_HEADER_SIZE], &hdr);
    // 写 meta payload
    @memset(page[PAGE_HEADER_SIZE .. PAGE_SIZE - 4], 0);
    encodeMetaPayload(page[PAGE_HEADER_SIZE .. PAGE_SIZE - 4], meta);
    // 写校验和
    setPageChecksum(page, computePageChecksum(page));
}

/// 从单页缓冲区读 meta（不校验 meta 页类型，返回 null 如果 checksum 不匹配或 magic/version 不对）
pub fn readMetaPageSingle(page: *const [PAGE_SIZE]u8) ?MetaPage {
    if (!verifyPageChecksum(page)) return null;
    const hdr = decodePageHeader(page[0..PAGE_HEADER_SIZE]);
    if (hdr.page_type != PAGE_TYPE_META) return null;
    const meta = decodeMetaPayload(page[PAGE_HEADER_SIZE .. PAGE_SIZE - 4]);
    if (!isValidMeta(meta)) return null;
    return meta;
}

/// 从两个 meta page 读取，取 sequence 大者（crash 安全）
pub fn readMetaPage(page0: *const [PAGE_SIZE]u8, page1: *const [PAGE_SIZE]u8) ?MetaPage {
    const m0 = readMetaPageSingle(page0);
    const m1 = readMetaPageSingle(page1);
    if (m0 == null and m1 == null) return null;
    if (m0 == null) return m1;
    if (m1 == null) return m0;
    return if (m0.?.sequence >= m1.?.sequence) m0 else m1;
}

// ===== Freelist 页编解码 =====

/// 空闲页的 payload 区存储 u32 页号数组，后续扩展
/// 写入 freelist 条目到页（覆盖 payload 区）
pub fn writeFreelistEntries(page: *[PAGE_SIZE]u8, entries: []const u32) void {
    const payload = page[PAGE_HEADER_SIZE .. PAGE_SIZE - 4];
    // 前 4 字节存条目数
    std.mem.writeInt(u32, payload[0..4], @intCast(entries.len), .little);
    var pos: usize = 4;
    for (entries) |e| {
        if (pos + 4 > payload.len) break;
        std.mem.writeInt(u32, payload[pos..][0..4], e, .little);
        pos += 4;
    }
    // 剩余 payload 区清零
    if (pos < payload.len) {
        @memset(payload[pos..], 0);
    }
    // 更新页校验和
    setPageChecksum(page, computePageChecksum(page));
}

/// 从页读 freelist 条目（返回借用 payload 的切片）
pub fn readFreelistEntries(page: *const [PAGE_SIZE]u8) []const u32 {
    const payload = page[PAGE_HEADER_SIZE .. PAGE_SIZE - 4];
    const count = std.mem.readInt(u32, payload[0..4], .little);
    const max = @min(count, @as(u32, @intCast((payload.len - 4) / 4)));
    // ponytail: payload 起始偏移 24，天然 4 对齐；跳过前 4 字节 count
    const ptr: [*]const u32 = @ptrCast(@alignCast(payload.ptr));
    return ptr[1..][0..max];
}

// ===== 测试 =====

test "format: page header roundtrip" {
    const h = PageHeader{
        .page_no = 42,
        .page_type = PAGE_TYPE_LEAF,
        .gen = 1000,
        .nkeys = 16,
        .free_next = 0,
    };
    var buf: [PAGE_HEADER_SIZE]u8 = undefined;
    encodePageHeader(&buf, &h);
    const got = decodePageHeader(&buf);
    try std.testing.expectEqual(h.page_no, got.page_no);
    try std.testing.expectEqual(h.page_type, got.page_type);
    try std.testing.expectEqual(h.gen, got.gen);
    try std.testing.expectEqual(h.nkeys, got.nkeys);
    try std.testing.expectEqual(h.free_next, got.free_next);
}

test "format: meta page roundtrip" {
    const meta = MetaPage{
        .magic = MAGIC_V2,
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
    var buf: [META_PAGE_PAYLOAD_SIZE]u8 = undefined;
    encodeMetaPayload(&buf, &meta);
    const got = decodeMetaPayload(&buf);
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

test "format: page checksum verification" {
    var page: [PAGE_SIZE]u8 = undefined;
    @memset(&page, 0xaa);
    const h = PageHeader{ .page_no = 1, .page_type = PAGE_TYPE_META, .gen = 5, .nkeys = 0, .free_next = 0 };
    encodePageHeader(&page, &h);
    @memset(page[PAGE_HEADER_SIZE .. PAGE_SIZE - 4], 0xbb);
    const cs = computePageChecksum(&page);
    setPageChecksum(&page, cs);
    try std.testing.expect(verifyPageChecksum(&page));
    page[PAGE_HEADER_SIZE + 10] ^= 0xff;
    try std.testing.expect(!verifyPageChecksum(&page));
}

test "format: meta alternation — take larger sequence" {
    const meta0 = MetaPage{
        .magic = MAGIC_V2, .version = 2, .mapsize = 1 << 30,
        .sequence = 100, .root_page = 50, .entry_count = 1000, .byte_size = 50000,
        .free_head = 10, .free_count = 5, .last_page = 200,
    };
    const meta1 = MetaPage{
        .magic = MAGIC_V2, .version = 2, .mapsize = 1 << 30,
        .sequence = 200, .root_page = 60, .entry_count = 2000, .byte_size = 100000,
        .free_head = 20, .free_count = 10, .last_page = 300,
    };
    var page0: [PAGE_SIZE]u8 = undefined;
    var page1: [PAGE_SIZE]u8 = undefined;
    @memset(&page0, 0);
    @memset(&page1, 0);
    writeMetaPage(&page0, &meta0, 0);
    writeMetaPage(&page1, &meta1, 1);
    const got = readMetaPage(&page0, &page1);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u64, 200), got.?.sequence);
}

test "format: meta alternation — one corrupt, take other" {
    const meta0 = MetaPage{
        .magic = MAGIC_V2, .version = 2, .mapsize = 1 << 30,
        .sequence = 500, .root_page = 100, .entry_count = 5000, .byte_size = 250000,
        .free_head = 50, .free_count = 25, .last_page = 600,
    };
    var page0: [PAGE_SIZE]u8 = undefined;
    var page1: [PAGE_SIZE]u8 = undefined;
    @memset(&page0, 0);
    @memset(&page1, 0);
    writeMetaPage(&page0, &meta0, 0);
    @memset(page1[0..PAGE_HEADER_SIZE], 0xff);
    setPageChecksum(&page1, computePageChecksum(&page1));
    const got = readMetaPage(&page0, &page1);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u64, 500), got.?.sequence);
}

test "format: freelist page chain" {
    var page100: [PAGE_SIZE]u8 = undefined;
    var page200: [PAGE_SIZE]u8 = undefined;
    var page300: [PAGE_SIZE]u8 = undefined;
    @memset(&page100, 0);
    @memset(&page200, 0);
    @memset(&page300, 0);
    var h100 = PageHeader{ .page_no = 100, .page_type = PAGE_TYPE_FREE, .gen = 0, .nkeys = 0, .free_next = 200 };
    encodePageHeader(&page100, &h100);
    writeFreelistEntries(&page100, &.{ 10, 20, 30 });
    var h200 = PageHeader{ .page_no = 200, .page_type = PAGE_TYPE_FREE, .gen = 0, .nkeys = 0, .free_next = 300 };
    encodePageHeader(&page200, &h200);
    writeFreelistEntries(&page200, &.{ 40, 50 });
    var h300 = PageHeader{ .page_no = 300, .page_type = PAGE_TYPE_FREE, .gen = 0, .nkeys = 0, .free_next = 0 };
    encodePageHeader(&page300, &h300);
    writeFreelistEntries(&page300, &.{60});
    const e1 = readFreelistEntries(&page100);
    try std.testing.expectEqual(@as(u32, 10), e1[0]);
    try std.testing.expectEqual(@as(u32, 20), e1[1]);
    try std.testing.expectEqual(@as(u32, 30), e1[2]);
    const e2 = readFreelistEntries(&page200);
    try std.testing.expectEqual(@as(u32, 40), e2[0]);
    try std.testing.expectEqual(@as(u32, 50), e2[1]);
    const e3 = readFreelistEntries(&page300);
    try std.testing.expectEqual(@as(u32, 60), e3[0]);
}
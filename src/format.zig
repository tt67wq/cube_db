//! format.zig — v2 page format constants and encode/decode (page header, meta, freelist, CRC)
//! Pure-function module, no IO. PAGE_SIZE=4096, fixed 24B page header, 4B trailing CRC.
const std = @import("std");

pub const PAGE_SIZE: usize = 4096;
pub const PAGE_HEADER_SIZE: usize = 24;

/// Page types
pub const PAGE_TYPE_FREE: u8 = 0;
pub const PAGE_TYPE_META: u8 = 1;
pub const PAGE_TYPE_BRANCH: u8 = 2;
pub const PAGE_TYPE_LEAF: u8 = 3;
pub const PAGE_TYPE_OVERFLOW: u8 = 4;

/// Special page numbers
pub const NULL_PAGE: u32 = 0;
pub const META_PAGE_0: u32 = 1;
pub const META_PAGE_1: u32 = 2;

pub const MAGIC_V2: u32 = 0x4355_4232; // "CUB2"
pub const META_PAGE_PAYLOAD_SIZE: usize = 58;

/// Max free-page entries per FREE page: payload = PAGE_SIZE - PAGE_HEADER_SIZE(24) - CRC(4);
/// first 4 bytes hold the count, the rest holds u32 entries. T-33: single source of truth
/// for the chain split (persistChain) and the restore walk bound (restoreFreeList).
pub const MAX_FREE_ENTRIES_PER_PAGE: usize = (PAGE_SIZE - PAGE_HEADER_SIZE - 4 - 4) / 4;
comptime {
    std.debug.assert(MAX_FREE_ENTRIES_PER_PAGE == 1016);
}

/// Page header (first 24 bytes of every page)
pub const PageHeader = struct {
    page_no: u32,
    page_type: u8,
    gen: u64,
    nkeys: u16,
    free_next: u32, // next page in the freelist chain; 0 for non-free pages
};

/// Meta page contents (encoded in the payload area)
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

// ===== Page header encode/decode =====

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

// ===== Page checksum =====

const builtin = @import("builtin");
const crc32_hw = @import("crc32_hw.zig");

/// Compute the whole-page CRC32 (covers bytes [0..PAGE_SIZE-4))
/// ARM64 uses the hardware CRC32 instruction; other platforms use the software table
pub fn computePageChecksum(page: *const [PAGE_SIZE]u8) u32 {
    return switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => crc32_hw.computePageChecksumHw(page),
        else => computePageChecksumSw(page),
    };
}

/// Software path (table-driven CRC32)
pub fn computePageChecksumSw(page: *const [PAGE_SIZE]u8) u32 {
    var crc = Crc32.init();
    crc.update(page[0 .. PAGE_SIZE - 4]);
    return crc.final();
}

/// Write the checksum to the page tail
pub fn setPageChecksum(page: *[PAGE_SIZE]u8, cs: u32) void {
    std.mem.writeInt(u32, page[PAGE_SIZE - 4 ..][0..4], cs, .little);
}

/// Verify the whole-page checksum
pub fn verifyPageChecksum(page: *const [PAGE_SIZE]u8) bool {
    const stored = std.mem.readInt(u32, page[PAGE_SIZE - 4 ..][0..4], .little);
    const computed = computePageChecksum(page);
    return stored == computed;
}

// ===== Meta page encode/decode =====

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

/// Write meta into a page buffer (page index 0 or 1 -> page number 1 or 2)
pub fn writeMetaPage(page: *[PAGE_SIZE]u8, meta: *const MetaPage, index: u32) void {
    std.debug.assert(index == 0 or index == 1);
    const page_no = if (index == 0) META_PAGE_0 else META_PAGE_1;
    // Write the page header
    const hdr = PageHeader{
        .page_no = page_no,
        .page_type = PAGE_TYPE_META,
        .gen = meta.sequence,
        .nkeys = 0,
        .free_next = 0,
    };
    encodePageHeader(page[0..PAGE_HEADER_SIZE], &hdr);
    // Write the meta payload
    @memset(page[PAGE_HEADER_SIZE .. PAGE_SIZE - 4], 0);
    encodeMetaPayload(page[PAGE_HEADER_SIZE .. PAGE_SIZE - 4], meta);
    // Write the checksum
    setPageChecksum(page, computePageChecksum(page));
}

/// Read meta from a single page buffer (validates checksum / page_type /
/// magic+version; returns null if any check fails)
pub fn readMetaPageSingle(page: *const [PAGE_SIZE]u8) ?MetaPage {
    if (!verifyPageChecksum(page)) return null;
    const hdr = decodePageHeader(page[0..PAGE_HEADER_SIZE]);
    if (hdr.page_type != PAGE_TYPE_META) return null;
    const meta = decodeMetaPayload(page[PAGE_HEADER_SIZE .. PAGE_SIZE - 4]);
    if (!isValidMeta(meta)) return null;
    return meta;
}

/// Read from the two meta pages and take the higher sequence (crash safe)
pub fn readMetaPage(page0: *const [PAGE_SIZE]u8, page1: *const [PAGE_SIZE]u8) ?MetaPage {
    const m0 = readMetaPageSingle(page0);
    const m1 = readMetaPageSingle(page1);
    if (m0 == null and m1 == null) return null;
    if (m0 == null) return m1;
    if (m1 == null) return m0;
    return if (m0.?.sequence >= m1.?.sequence) m0 else m1;
}

// ===== Freelist page encode/decode =====

/// A free page's payload area stores an array of u32 page numbers, extensible later
/// Write freelist entries into the page (overwrites the payload area)
pub fn writeFreelistEntries(page: *[PAGE_SIZE]u8, entries: []const u32) void {
    const payload = page[PAGE_HEADER_SIZE .. PAGE_SIZE - 4];
    // T-33(T1): count = actually written (was entries.len — the overflow count-mismatch bug
    // pinned by freelist_overflow_test.zig). Callers chunk by MAX_FREE_ENTRIES_PER_PAGE, so
    // the truncation path is defense-only; readFreelistEntries keeps its @min clamp.
    const n = @min(entries.len, MAX_FREE_ENTRIES_PER_PAGE);
    // First 4 bytes hold the entry count
    std.mem.writeInt(u32, payload[0..4], @intCast(n), .little);
    var pos: usize = 4;
    for (entries[0..n]) |e| {
        std.mem.writeInt(u32, payload[pos..][0..4], e, .little);
        pos += 4;
    }
    // Zero the remaining payload area
    if (pos < payload.len) {
        @memset(payload[pos..], 0);
    }
    // Update the page checksum
    setPageChecksum(page, computePageChecksum(page));
}

/// Read freelist entries from the page (returns a slice borrowing the payload)
/// Returns []align(1) const u32: page is a u8 array (1-aligned) and the
/// payload offset of 24 gives no 4-alignment guarantee, so the borrowed slice
/// honestly declares align(1) — @alignCast would panic on Linux.
pub fn readFreelistEntries(page: *const [PAGE_SIZE]u8) []align(1) const u32 {
    const payload = page[PAGE_HEADER_SIZE .. PAGE_SIZE - 4];
    const count = std.mem.readInt(u32, payload[0..4], .little);
    const max = @min(count, @as(u32, @intCast((payload.len - 4) / 4)));
    // ponytail: skip the first 4 bytes (count); [*]align(1) const u32 honestly
    // declares the alignment, allowing unaligned u32 reads (natively supported
    // on x86/ARM) with no @alignCast runtime check
    const ptr: [*]align(1) const u32 = @ptrCast(payload.ptr);
    return ptr[1..][0..max];
}

// ===== Tests =====


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
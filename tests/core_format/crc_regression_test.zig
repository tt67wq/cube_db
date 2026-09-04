//! crc_regression_test.zig - Phase 2 correctness regression tests (@ZigFollower2)
//!
//! Covers: CRC verification regression for all page formats (meta/freelist/leaf/branch/overflow).
//! Verification points:
//!   1. format.computePageChecksum (ARM64 hardware path) matches crc32_hw.crc32Sw (pure software)
//!   2. setPageChecksum + verifyPageChecksum round-trip passes
//!   3. tampering with any payload / header byte -> verifyPageChecksum fails
//!   4. determinism: repeated checksums of the same page agree
//!
//! Depends on Phase 1 interfaces (commit 42f1a05):
//!   - cube.crc32_hw.crc32Sw(init, data) - software CRC32 reference
//!   - cube.format.computePageChecksum - automatic ARM64 hardware path
//!   - cube.format.setPageChecksum / verifyPageChecksum

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const crc32_hw = cube.crc32_hw;

// ===== page construction helpers =====

const PageTypeInfo = struct {
    name: []const u8,
    page_type: u8,
    nkeys: u16,
};

/// Basic info for the 5 page types
const ALL_PAGE_TYPES = [_]PageTypeInfo{
    .{ .name = "meta", .page_type = f2.PAGE_TYPE_META, .nkeys = 0 },
    .{ .name = "freelist", .page_type = f2.PAGE_TYPE_FREE, .nkeys = 0 },
    .{ .name = "leaf", .page_type = f2.PAGE_TYPE_LEAF, .nkeys = 4 },
    .{ .name = "branch", .page_type = f2.PAGE_TYPE_BRANCH, .nkeys = 3 },
    .{ .name = "overflow", .page_type = f2.PAGE_TYPE_OVERFLOW, .nkeys = 0 },
};

/// Build a "realistic" page for a given page type (header + payload, CRC not yet written)
/// meta/freelist use format.zig's canonical encoders;
/// leaf/branch/overflow are hand-built following btree.zig's encoding format (inline values, no store dependency).
fn buildPage(page_type: u8, page: *[f2.PAGE_SIZE]u8) void {
    @memset(page, 0);
    switch (page_type) {
        f2.PAGE_TYPE_META => {
            const meta = f2.MetaPage{
                .magic = f2.MAGIC_V2,
                .version = 2,
                .sequence = 7,
                .mapsize = 1 << 30,
                .root_page = 42,
                .entry_count = 3,
                .byte_size = 12345,
                .free_head = 0,
                .free_count = 0,
                .last_page = 200,
            };
            // reuse the canonical encoding (includes CRC); recompute the checksum uniformly later
            f2.writeMetaPage(page, &meta, 0);
        },
        f2.PAGE_TYPE_FREE => {
            const entries = [_]u32{ 300, 301, 302, 303, 304 };
            f2.writeFreelistEntries(page, &entries);
        },
        f2.PAGE_TYPE_LEAF => {
            // leaf payload: kind(1) + count(2) + per-entry [tomb(1)+klen(4)+key+vlen(4)+flags(1)+value]
            var buf: [f2.PAGE_SIZE]u8 = undefined;
            var pos: usize = 0;
            buf[pos] = 2; // LEAF_KIND
            pos += 1;
            std.mem.writeInt(u16, buf[pos..][0..2], 4, .big);
            pos += 2;
            const keys = [_][]const u8{ "apple", "banana", "cherry", "date" };
            const values = [_][]const u8{ "v1", "v2", "v3", "v4" };
            for (keys, values) |k, v| {
                buf[pos] = 0; // tombstone = false
                pos += 1;
                std.mem.writeInt(u32, buf[pos..][0..4], @intCast(k.len), .big);
                pos += 4;
                @memcpy(buf[pos..][0..k.len], k);
                pos += k.len;
                std.mem.writeInt(u32, buf[pos..][0..4], @intCast(v.len), .big);
                pos += 4;
                buf[pos] = 0; // flags = 0 (inline)
                pos += 1;
                @memcpy(buf[pos..][0..v.len], v);
                pos += v.len;
            }
            const hdr = f2.PageHeader{
                .page_no = 500,
                .page_type = f2.PAGE_TYPE_LEAF,
                .gen = 1,
                .nkeys = 4,
                .free_next = 0,
            };
            f2.encodePageHeader(page[0..f2.PAGE_HEADER_SIZE], &hdr);
            @memcpy(page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4][0..pos], buf[0..pos]);
        },
        f2.PAGE_TYPE_BRANCH => {
            // branch payload: kind(1) + count(2) + per-key [klen(4)+key] + children(4 each, big-endian)
            var buf: [f2.PAGE_SIZE]u8 = undefined;
            var pos: usize = 0;
            buf[pos] = 1; // BRANCH_KIND
            pos += 1;
            std.mem.writeInt(u16, buf[pos..][0..2], 3, .big); // 3 children => 2 keys
            pos += 2;
            const keys = [_][]const u8{ "bb", "dd" };
            const children = [_]u32{ 100, 200, 300 };
            for (keys) |k| {
                std.mem.writeInt(u32, buf[pos..][0..4], @intCast(k.len), .big);
                pos += 4;
                @memcpy(buf[pos..][0..k.len], k);
                pos += k.len;
            }
            for (children) |c| {
                std.mem.writeInt(u32, buf[pos..][0..4], c, .big);
                pos += 4;
            }
            const hdr = f2.PageHeader{
                .page_no = 600,
                .page_type = f2.PAGE_TYPE_BRANCH,
                .gen = 2,
                .nkeys = 3,
                .free_next = 0,
            };
            f2.encodePageHeader(page[0..f2.PAGE_HEADER_SIZE], &hdr);
            @memcpy(page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4][0..pos], buf[0..pos]);
        },
        f2.PAGE_TYPE_OVERFLOW => {
            const hdr = f2.PageHeader{
                .page_no = 700,
                .page_type = f2.PAGE_TYPE_OVERFLOW,
                .gen = 0,
                .nkeys = 0,
                .free_next = 0,
            };
            f2.encodePageHeader(page[0..f2.PAGE_HEADER_SIZE], &hdr);
            const chunk = 1000;
            for (page[f2.PAGE_HEADER_SIZE .. f2.PAGE_HEADER_SIZE + chunk], 0..) |*b, i| {
                b.* = @intCast((i * 3 + 7) & 0xFF);
            }
        },
        else => unreachable,
    }
}

/// Deterministic pseudo-random fill (no RNG dependency, same as crc32_hw_test.zig)
fn fillRandom(page: *[f2.PAGE_SIZE]u8, seed0: u64) void {
    var seed = seed0;
    for (page) |*b| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        b.* = @intCast((seed >> 32) & 0xFF);
    }
}

// ===== Test 1: per-page-type HW-SW consistency + roundtrip + tamper detection =====

test "crc_regression: 5 page types hw/sw consistency + roundtrip + tamper" {
    inline for (ALL_PAGE_TYPES) |t| {
        var page: [f2.PAGE_SIZE]u8 = undefined;
        buildPage(t.page_type, &page);

        // 1. HW (computePageChecksum uses hardware on ARM64) vs SW (crc32Sw) consistency
        const hw_cs = f2.computePageChecksum(&page);
        const sw_cs = crc32_hw.crc32Sw(0, page[0 .. f2.PAGE_SIZE - 4]);
        try std.testing.expectEqual(sw_cs, hw_cs);

        // 2. set + verify roundtrip
        f2.setPageChecksum(&page, hw_cs);
        try std.testing.expect(f2.verifyPageChecksum(&page));

        // 3. tamper one payload byte -> fails
        var page_payload = page;
        const tamper_pos = f2.PAGE_HEADER_SIZE + 16;
        page_payload[tamper_pos] ^= 0xFF;
        try std.testing.expect(!f2.verifyPageChecksum(&page_payload));

        // 4. tamper one header byte -> fails
        var page_header = page;
        page_header[3] ^= 0xFF;
        try std.testing.expect(!f2.verifyPageChecksum(&page_header));

        // 5. tamper the stored CRC region -> fails
        var page_crc = page;
        page_crc[f2.PAGE_SIZE - 1] ^= 0xFF;
        try std.testing.expect(!f2.verifyPageChecksum(&page_crc));
    }
}

// ===== Test 2: determinism =====

test "crc_regression: checksum deterministic for all page types" {
    inline for (ALL_PAGE_TYPES) |t| {
        var page: [f2.PAGE_SIZE]u8 = undefined;
        buildPage(t.page_type, &page);
        const cs1 = f2.computePageChecksum(&page);
        const cs2 = f2.computePageChecksum(&page);
        try std.testing.expectEqual(cs1, cs2);
    }
}

// ===== Test 3: canonical helpers produce verifiable pages =====

test "crc_regression: writeMetaPage produces verifiable page" {
    const meta = f2.MetaPage{
        .magic = f2.MAGIC_V2,
        .version = 2,
        .sequence = 99,
        .mapsize = 1 << 30,
        .root_page = 8,
        .entry_count = 2,
        .byte_size = 4096,
        .free_head = 0,
        .free_count = 0,
        .last_page = 10,
    };
    var page: [f2.PAGE_SIZE]u8 = undefined;
    f2.writeMetaPage(&page, &meta, 0);
    try std.testing.expect(f2.verifyPageChecksum(&page));

    // read-back verification
    const got = f2.readMetaPageSingle(&page);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(meta.sequence, got.?.sequence);
    try std.testing.expectEqual(meta.root_page, got.?.root_page);
}

test "crc_regression: writeFreelistEntries produces verifiable page" {
    const entries = [_]u32{ 10, 20, 30, 40, 50 };
    var page: [f2.PAGE_SIZE]u8 = undefined;
    f2.writeFreelistEntries(&page, &entries);
    try std.testing.expect(f2.verifyPageChecksum(&page));

    const got = f2.readFreelistEntries(&page);
    try std.testing.expectEqual(@as(usize, 5), got.len);
    try std.testing.expectEqual(@as(u32, 10), got[0]);
    try std.testing.expectEqual(@as(u32, 50), got[4]);
}

// ===== Test 4: random-data pages HW-SW consistency (multiple seeds) =====

test "crc_regression: random pages hw/sw consistency" {
    inline for ([_]u64{ 0x1111, 0x2222, 0x3333, 0x4444, 0x5555 }) |seed0| {
        var page: [f2.PAGE_SIZE]u8 = undefined;
        fillRandom(&page, seed0);
        const hw_cs = f2.computePageChecksum(&page);
        const sw_cs = crc32_hw.crc32Sw(0, page[0 .. f2.PAGE_SIZE - 4]);
        try std.testing.expectEqual(sw_cs, hw_cs);
    }
}

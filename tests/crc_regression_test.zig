//! crc_regression_test.zig — Phase 2 正确性回归测试（@ZigFollower2）
//!
//! 覆盖：全量页格式（meta/freelist/leaf/branch/overflow）的 CRC 校验回归。
//! 验证点：
//!   1. format.computePageChecksum（ARM64 硬件路径）与 crc32_hw.crc32Sw（纯软件）结果一致
//!   2. setPageChecksum + verifyPageChecksum 往返通过
//!   3. 篡改 payload / header 任一处 → verifyPageChecksum 失败
//!   4. 确定性：同一页多次计算 checksum 一致
//!
//! 依赖 Phase 1 接口（commit 42f1a05）：
//!   - cube.crc32_hw.crc32Sw(init, data) — 软件 CRC32 对照
//!   - cube.format.computePageChecksum — ARM64 自动走硬件路径
//!   - cube.format.setPageChecksum / verifyPageChecksum

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const crc32_hw = cube.crc32_hw;

// ===== 页构造辅助 =====

const PageTypeInfo = struct {
    name: []const u8,
    page_type: u8,
    nkeys: u16,
};

/// 5 种页类型的基本信息
const ALL_PAGE_TYPES = [_]PageTypeInfo{
    .{ .name = "meta", .page_type = f2.PAGE_TYPE_META, .nkeys = 0 },
    .{ .name = "freelist", .page_type = f2.PAGE_TYPE_FREE, .nkeys = 0 },
    .{ .name = "leaf", .page_type = f2.PAGE_TYPE_LEAF, .nkeys = 4 },
    .{ .name = "branch", .page_type = f2.PAGE_TYPE_BRANCH, .nkeys = 3 },
    .{ .name = "overflow", .page_type = f2.PAGE_TYPE_OVERFLOW, .nkeys = 0 },
};

/// 按页类型构造一个"真实"页（页头 + payload，尚未写 CRC）
/// meta/freelist 用 format.zig 的 canonical 编码器；
/// leaf/branch/overflow 按 btree.zig 的编码格式手工构造（inline 值，无 store 依赖）。
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
            // 复用 canonical 编码（含 CRC），稍后统一重算校验
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

/// 确定性伪随机填充（无 RNG 依赖，与 crc32_hw_test.zig 同款）
fn fillRandom(page: *[f2.PAGE_SIZE]u8, seed0: u64) void {
    var seed = seed0;
    for (page) |*b| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        b.* = @intCast((seed >> 32) & 0xFF);
    }
}

// ===== 测试 1: 每种页类型 HW-SW 一致性 + 往返 + 篡改检测 =====

test "crc_regression: 5 page types hw/sw consistency + roundtrip + tamper" {
    inline for (ALL_PAGE_TYPES) |t| {
        var page: [f2.PAGE_SIZE]u8 = undefined;
        buildPage(t.page_type, &page);

        // 1. HW（computePageChecksum 在 ARM64 走硬件）vs SW（crc32Sw）一致性
        const hw_cs = f2.computePageChecksum(&page);
        const sw_cs = crc32_hw.crc32Sw(0, page[0 .. f2.PAGE_SIZE - 4]);
        try std.testing.expectEqual(sw_cs, hw_cs);

        // 2. set + verify 往返
        f2.setPageChecksum(&page, hw_cs);
        try std.testing.expect(f2.verifyPageChecksum(&page));

        // 3. 篡改 payload 区一字节 → 失败
        var page_payload = page;
        const tamper_pos = f2.PAGE_HEADER_SIZE + 16;
        page_payload[tamper_pos] ^= 0xFF;
        try std.testing.expect(!f2.verifyPageChecksum(&page_payload));

        // 4. 篡改 header 区一字节 → 失败
        var page_header = page;
        page_header[3] ^= 0xFF;
        try std.testing.expect(!f2.verifyPageChecksum(&page_header));

        // 5. 篡改 CRC 存储区 → 失败
        var page_crc = page;
        page_crc[f2.PAGE_SIZE - 1] ^= 0xFF;
        try std.testing.expect(!f2.verifyPageChecksum(&page_crc));
    }
}

// ===== 测试 2: 确定性 =====

test "crc_regression: checksum deterministic for all page types" {
    inline for (ALL_PAGE_TYPES) |t| {
        var page: [f2.PAGE_SIZE]u8 = undefined;
        buildPage(t.page_type, &page);
        const cs1 = f2.computePageChecksum(&page);
        const cs2 = f2.computePageChecksum(&page);
        try std.testing.expectEqual(cs1, cs2);
    }
}

// ===== 测试 3: canonical helpers 产出可验证页 =====

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

    // 读回验证
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

// ===== 测试 4: 随机数据页 HW-SW 一致性（多 seed） =====

test "crc_regression: random pages hw/sw consistency" {
    inline for ([_]u64{ 0x1111, 0x2222, 0x3333, 0x4444, 0x5555 }) |seed0| {
        var page: [f2.PAGE_SIZE]u8 = undefined;
        fillRandom(&page, seed0);
        const hw_cs = f2.computePageChecksum(&page);
        const sw_cs = crc32_hw.crc32Sw(0, page[0 .. f2.PAGE_SIZE - 4]);
        try std.testing.expectEqual(sw_cs, hw_cs);
    }
}

//! crc32_hw_test.zig — TDD: hardware CRC32 vs software CRC32 consistency
//!
//! Red phase: tests fail because crc32_hw module doesn't exist yet.
//! Green phase: implement computePageChecksumHw in src/crc32_hw.zig
const std = @import("std");
const cube = @import("cube_db");
const fmt = cube.format;
const crc32_hw = cube.crc32_hw;

// ---- Consistency: hardware CRC32 == software CRC32 ----

test "crc32_hw: all-zero page checksum matches software" {
    var page: [fmt.PAGE_SIZE]u8 = [_]u8{0} ** fmt.PAGE_SIZE;
    const sw = fmt.computePageChecksum(&page);
    const hw = crc32_hw.computePageChecksumHw(&page);
    try std.testing.expectEqual(sw, hw);
}

test "crc32_hw: all-0xFF page checksum matches software" {
    var page: [fmt.PAGE_SIZE]u8 = [_]u8{0xFF} ** fmt.PAGE_SIZE;
    const sw = fmt.computePageChecksum(&page);
    const hw = crc32_hw.computePageChecksumHw(&page);
    try std.testing.expectEqual(sw, hw);
}

test "crc32_hw: sequential bytes page checksum matches software" {
    var page: [fmt.PAGE_SIZE]u8 = undefined;
    for (&page, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    const sw = fmt.computePageChecksum(&page);
    const hw = crc32_hw.computePageChecksumHw(&page);
    try std.testing.expectEqual(sw, hw);
}

test "crc32_hw: random-ish page checksum matches software" {
    var page: [fmt.PAGE_SIZE]u8 = undefined;
    // deterministic pseudo-random fill (no RNG dependency)
    var seed: u64 = 0x1234_5678_9ABC_DEF0;
    for (&page) |*b| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        b.* = @intCast((seed >> 32) & 0xFF);
    }
    const sw = fmt.computePageChecksum(&page);
    const hw = crc32_hw.computePageChecksumHw(&page);
    try std.testing.expectEqual(sw, hw);
}

test "crc32_hw: page with real header + payload matches software" {
    var page: [fmt.PAGE_SIZE]u8 = [_]u8{0} ** fmt.PAGE_SIZE;
    // Write a header
    std.mem.writeInt(u32, page[0..4], 42, .little); // page_no
    page[4] = 3; // LEAF
    std.mem.writeInt(u64, page[5..13], 99, .little); // gen
    std.mem.writeInt(u16, page[13..15], 10, .little); // nkeys
    std.mem.writeInt(u32, page[15..19], 0, .little); // free_next
    // Some payload bytes
    for (page[19..100]) |*b| b.* = 0xAA;
    for (page[100..200]) |*b| b.* = 0x55;

    const sw = fmt.computePageChecksum(&page);
    const hw = crc32_hw.computePageChecksumHw(&page);
    try std.testing.expectEqual(sw, hw);
}

// ---- Edge cases: arbitrary-length data (not just full pages) ----

test "crc32_hw: empty data matches software" {
    const sw = crc32_hw.crc32Sw(0, &[_]u8{});
    const hw = crc32_hw.crc32Hw(0, &[_]u8{});
    try std.testing.expectEqual(sw, hw);
}

test "crc32_hw: 1 byte matches software" {
    const data = [_]u8{0x42};
    const sw = crc32_hw.crc32Sw(0, &data);
    const hw = crc32_hw.crc32Hw(0, &data);
    try std.testing.expectEqual(sw, hw);
}

test "crc32_hw: 7 bytes (just under 8) matches software" {
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 };
    const sw = crc32_hw.crc32Sw(0, &data);
    const hw = crc32_hw.crc32Hw(0, &data);
    try std.testing.expectEqual(sw, hw);
}

test "crc32_hw: 8 bytes (exactly one chunk) matches software" {
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    const sw = crc32_hw.crc32Sw(0, &data);
    const hw = crc32_hw.crc32Hw(0, &data);
    try std.testing.expectEqual(sw, hw);
}

test "crc32_hw: 9 bytes (one chunk + 1 remainder) matches software" {
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09 };
    const sw = crc32_hw.crc32Sw(0, &data);
    const hw = crc32_hw.crc32Hw(0, &data);
    try std.testing.expectEqual(sw, hw);
}

test "crc32_hw: 4092 bytes (exact PAGE_SIZE - 4) matches software" {
    var data: [4092]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast((i * 7 + 3) & 0xFF);
    const sw = crc32_hw.crc32Sw(0, &data);
    const hw = crc32_hw.crc32Hw(0, &data);
    try std.testing.expectEqual(sw, hw);
}

test "crc32_hw: 4093 bytes (one over page payload) matches software" {
    var data: [4093]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast((i * 3 + 1) & 0xFF);
    const sw = crc32_hw.crc32Sw(0, &data);
    const hw = crc32_hw.crc32Hw(0, &data);
    try std.testing.expectEqual(sw, hw);
}

// ---- Non-zero initial CRC (chained computation) ----

test "crc32_hw: non-zero initial CRC matches software" {
    var data: [256]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    const sw = crc32_hw.crc32Sw(0xDEAD_BEEF, &data);
    const hw = crc32_hw.crc32Hw(0xDEAD_BEEF, &data);
    try std.testing.expectEqual(sw, hw);
}

// ---- Integration: setPageChecksum + verifyPageChecksum with hardware ----

test "crc32_hw: set + verify with hardware checksum roundtrip" {
    var page: [fmt.PAGE_SIZE]u8 = undefined;
    for (&page, 0..) |*b, i| b.* = @intCast((i * 5 + 1) & 0xFF);

    // Use hardware path
    const cs = crc32_hw.computePageChecksumHw(&page);
    fmt.setPageChecksum(&page, cs);
    try std.testing.expect(fmt.verifyPageChecksum(&page));

    // Corrupt one byte
    page[100] ^= 0xFF;
    try std.testing.expect(!fmt.verifyPageChecksum(&page));
}

test "crc32_hw: hardware and software set/verify interoperable" {
    var page: [fmt.PAGE_SIZE]u8 = undefined;
    for (&page, 0..) |*b, i| b.* = @intCast((i * 11 + 7) & 0xFF);

    // Software set, hardware verify
    const sw_cs = fmt.computePageChecksum(&page);
    fmt.setPageChecksum(&page, sw_cs);
    const hw_cs = crc32_hw.computePageChecksumHw(&page);
    try std.testing.expectEqual(sw_cs, hw_cs);
    try std.testing.expect(fmt.verifyPageChecksum(&page));

    // Hardware set, software verify
    var page2: [fmt.PAGE_SIZE]u8 = undefined;
    for (&page2, 0..) |*b, i| b.* = @intCast((i * 13 + 5) & 0xFF);
    const hw_cs2 = crc32_hw.computePageChecksumHw(&page2);
    fmt.setPageChecksum(&page2, hw_cs2);
    try std.testing.expectEqual(fmt.computePageChecksum(&page2), hw_cs2);
    try std.testing.expect(fmt.verifyPageChecksum(&page2));
}

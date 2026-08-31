//! freelist_overflow_test.zig — T-3: 钉死 writeFreelistEntries 超容量行为
//!
//! src/format.zig:234 writeFreelistEntries 写入超过单页容量的 entries 时
//! `if (pos + 4 > payload.len) break` 静默丢弃溢出条目，但 count 字段写成原始
//! entries.len（不是实际写入数）。readFreelistEntries（src/format.zig:255）用
//! `@min(count, max)` 钳制，掩盖了 count != 实际写入数 的不一致。
//!
//! 本文件断言当前实际行为（读回条数），并在发现 count 与实际写入数不一致处
//! 标注 `// FIXME: known bug - write count mismatch`，让测试绿但不掩盖问题。
//!
//! 接入方式：tests/core_format/format_test.zig 末尾 comptime @import 本文件。

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;

/// freelist 单页最大条目数：payload = PAGE_SIZE - PAGE_HEADER_SIZE(24) - CRC(4)
/// 前 4 字节存 count，剩余放 u32 条目 → max = (payload - 4) / 4 = (4096-24-4-4)/4 = 1016
const MAX_ENTRIES: u32 = @as(u32, @intCast((f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4 - 4) / 4));

/// 构造一个全零页 + FREE 页头，便于只测 freelist payload 行为
fn newFreePage() [f2.PAGE_SIZE]u8 {
    var page: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page, 0);
    var h = f2.PageHeader{ .page_no = 1, .page_type = f2.PAGE_TYPE_FREE, .gen = 0, .nkeys = 0, .free_next = 0 };
    f2.encodePageHeader(&page, &h);
    return page;
}

test "freelist_overflow: max+1 entries — read-back clamped to max, count mismatch" {
    // max+1 条：写入端 break 丢弃最后 1 条，但 count 字段写成 max+1
    var page = newFreePage();
    const allocator = std.testing.allocator;
    var entries = std.ArrayList(u32).empty;
    defer entries.deinit(allocator);
    var i: u32 = 0;
    while (i < MAX_ENTRIES + 1) : (i += 1) {
        try entries.append(allocator, 1000 + i);
    }

    f2.writeFreelistEntries(&page, entries.items);
    const got = f2.readFreelistEntries(&page);

    // 读回条数：readFreelistEntries @min(count=max+1, max) = max
    try std.testing.expectEqual(MAX_ENTRIES, @as(u32, @intCast(got.len)));

    // FIXME: known bug - write count mismatch
    // writeFreelistEntries 把 count 写成 entries.len (max+1)，但实际只写入 max 条。
    // 读回因 @min 钳制返回 max，count 字段 (1017) 与实际写入数 (1016) 不一致。
    // 验证 count 字段确实写成了 max+1（即 bug 存在）：
    const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    const stored_count = std.mem.readInt(u32, payload[0..4], .little);
    try std.testing.expectEqual(MAX_ENTRIES + 1, stored_count);

    // 读回内容：前 max 条应完整，第 max+1 条（被 break 丢弃）不可达
    try std.testing.expectEqual(@as(u32, 1000), got[0]);
    try std.testing.expectEqual(@as(u32, 1000 + MAX_ENTRIES - 1), got[got.len - 1]);
}

test "freelist_overflow: max+10 entries — read-back still clamped to max" {
    var page = newFreePage();
    const allocator = std.testing.allocator;
    var entries = std.ArrayList(u32).empty;
    defer entries.deinit(allocator);
    var i: u32 = 0;
    while (i < MAX_ENTRIES + 10) : (i += 1) {
        try entries.append(allocator, 2000 + i);
    }

    f2.writeFreelistEntries(&page, entries.items);
    const got = f2.readFreelistEntries(&page);

    // 即使多丢 10 条，读回仍 = max（@min 钳制）
    try std.testing.expectEqual(MAX_ENTRIES, @as(u32, @intCast(got.len)));

    // FIXME: known bug - write count mismatch
    const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    const stored_count = std.mem.readInt(u32, payload[0..4], .little);
    try std.testing.expectEqual(MAX_ENTRIES + 10, stored_count);
}

test "freelist_overflow: corrupt count 0xFFFFFFFF — no crash, clamped to max" {
    // 直接构造一个页：count 字段 = 0xFFFFFFFF（远超容量），payload 区填满有效条目
    var page = newFreePage();
    const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    std.mem.writeInt(u32, payload[0..4], 0xFFFFFFFF, .little);
    var pos: usize = 4;
    var i: u32 = 0;
    while (pos + 4 <= payload.len) : (i += 1) {
        std.mem.writeInt(u32, payload[pos..][0..4], 3000 + i, .little);
        pos += 4;
    }
    // 不调用 writeFreelistEntries（它会重写 count），直接测 readFreelistEntries 的钳制
    f2.setPageChecksum(&page, f2.computePageChecksum(&page));

    const got = f2.readFreelistEntries(&page);
    // @min(0xFFFFFFFF, max) = max，不越界、不 crash
    try std.testing.expectEqual(MAX_ENTRIES, @as(u32, @intCast(got.len)));
    try std.testing.expectEqual(@as(u32, 3000), got[0]);
    try std.testing.expectEqual(@as(u32, 3000 + MAX_ENTRIES - 1), got[got.len - 1]);
}

test "freelist_overflow: exactly max entries — count and read-back consistent" {
    // 恰好 max 条：count == 实际写入数，无丢弃，无 bug
    var page = newFreePage();
    const allocator = std.testing.allocator;
    var entries = std.ArrayList(u32).empty;
    defer entries.deinit(allocator);
    var i: u32 = 0;
    while (i < MAX_ENTRIES) : (i += 1) {
        try entries.append(allocator, 4000 + i);
    }

    f2.writeFreelistEntries(&page, entries.items);
    const got = f2.readFreelistEntries(&page);

    try std.testing.expectEqual(MAX_ENTRIES, @as(u32, @intCast(got.len)));
    const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    const stored_count = std.mem.readInt(u32, payload[0..4], .little);
    // 恰好 max 时 count 与实际一致（无 bug 路径）
    try std.testing.expectEqual(MAX_ENTRIES, stored_count);
    try std.testing.expectEqual(@as(u32, 4000), got[0]);
    try std.testing.expectEqual(@as(u32, 4000 + MAX_ENTRIES - 1), got[got.len - 1]);
}

test "freelist_overflow: zero entries — empty read-back, count 0" {
    var page = newFreePage();
    f2.writeFreelistEntries(&page, &.{});
    const got = f2.readFreelistEntries(&page);
    try std.testing.expectEqual(@as(usize, 0), got.len);
    const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    const stored_count = std.mem.readInt(u32, payload[0..4], .little);
    try std.testing.expectEqual(@as(u32, 0), stored_count);
}

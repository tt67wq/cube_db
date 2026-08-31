//! btree_decode_corrupt_test.zig — T-5: btree 页解码损坏/截断路径测试
//!
//! src/btree.zig 反序列化信任边界（readNodePayload / decodeLeafPayload /
//! decodeBranchPayload）的 error.CorruptCrc / error.Truncated 路径原本零直接
//! 测试，全靠 put/get 黑盒间接覆盖。本文件直接构造损坏/截断 payload 钉死 error。
//!
//! 策略：用 pub 编码函数（encodeLeafPayload / encodeBranchPayload）构造合法
//! payload，再翻转/截断/错型，断言解码返回确切 error。
//! LEAF_KIND/BRANCH_KIND 是 private，但 encode* 已埋好正确 kind 字节，损坏测试
//! 不需直接引用这些常量；错型测试靠"把 branch payload 喂给 decodeLeafPayload"
//! 自然触发 kind != LEAF_KIND。
//!
//! 接入方式：tests/btree_storage/btree_test.zig 末尾 comptime @import 本文件。

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const ps = cube.page_store;
const btree = cube.btree;

const allocator = std.testing.allocator;

/// 构造一个合法 leaf payload（1 个内联 entry，不触发溢出页 IO）到 buf，返回实际占用长度
fn buildValidLeafPayload(buf: []u8) !usize {
    var ms = ps.MemPageStore.init(allocator, 64);
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);
    const entries = [_]btree.LeafEntry{
        .{ .tombstone = false, .key = "key1", .value = "val1" },
    };
    return try btree.encodeLeafPayload(buf, &entries, ms.store(), &dirty);
}

/// 构造一个合法 branch payload（3 children, 2 keys）到 buf，返回实际占用长度
fn buildValidBranchPayload(buf: []u8) usize {
    const keys = [_][]const u8{ "m", "q" };
    const children = [_]u32{ 10, 20, 30 };
    return btree.encodeBranchPayload(buf, &keys, &children);
}

// ===== readNodePayload CRC 损坏 =====

test "btree_decode_corrupt: readNodePayload on CRC-damaged leaf returns CorruptCrc" {
    var ms = ps.MemPageStore.init(allocator, 64);
    defer ms.deinit();
    const s = ms.store();

    // 构造合法 leaf payload
    var payload_buf: [f2.PAGE_SIZE]u8 = undefined;
    const pl_len = try buildValidLeafPayload(&payload_buf);

    // 写成完整页（页头 + payload + padding + CRC）
    const page_no = try s.allocPage();
    try btree.writeNodePage(s, page_no, f2.PAGE_TYPE_LEAF, 1, payload_buf[0..pl_len]);

    // 合法页：readNodePayload 应成功
    const valid = try btree.readNodePayload(s, page_no);
    try std.testing.expect(valid.len > 0);

    // 翻转 payload 区 1 字节 → CRC 不匹配
    const page = try s.writePage(page_no);
    page[f2.PAGE_HEADER_SIZE + 1] ^= 0xFF;

    // 期望 error.CorruptCrc
    try std.testing.expectError(error.CorruptCrc, btree.readNodePayload(s, page_no));
}

// ===== decodeLeafPayload 截断 =====

test "btree_decode_corrupt: decodeLeafPayload < 3 bytes returns Truncated" {
    // 2 字节 payload → len < 3 → error.Truncated
    const short = [_]u8{ 0x02, 0x00 };
    var entries_out: [4]btree.DecodedLeafEntry = undefined;
    try std.testing.expectError(error.Truncated, btree.decodeLeafPayload(&short, &entries_out));
}

test "btree_decode_corrupt: decodeLeafPayload on truncated valid leaf returns Truncated" {
    // 合法 leaf payload 截断为 3 字节（kind + count=1），entries_out 容量够，
    // 但 entry body 数据缺失 → 循环内 pos+1+4 > payload.len → error.Truncated
    var full: [f2.PAGE_SIZE]u8 = undefined;
    const pl_len = try buildValidLeafPayload(&full);
    try std.testing.expect(pl_len >= 3);

    var truncated: [3]u8 = undefined;
    @memcpy(&truncated, full[0..3]);
    var entries_out: [4]btree.DecodedLeafEntry = undefined;
    try std.testing.expectError(error.Truncated, btree.decodeLeafPayload(&truncated, &entries_out));
}

test "btree_decode_corrupt: decodeLeafPayload wrong kind (branch payload) returns CorruptCrc" {
    // 把 branch payload 喂给 decodeLeafPayload：BRANCH_KIND != LEAF_KIND → error.CorruptCrc
    var branch_buf: [f2.PAGE_SIZE]u8 = undefined;
    _ = buildValidBranchPayload(&branch_buf);

    var entries_out: [4]btree.DecodedLeafEntry = undefined;
    try std.testing.expectError(error.CorruptCrc, btree.decodeLeafPayload(&branch_buf, &entries_out));
}

test "btree_decode_corrupt: decodeLeafPayload entries_out too small returns Truncated" {
    // 合法 leaf payload 含 1 entry，但 entries_out 长度 0 → entries_out.len < count → Truncated
    var full: [f2.PAGE_SIZE]u8 = undefined;
    _ = try buildValidLeafPayload(&full);
    var entries_out: [0]btree.DecodedLeafEntry = undefined;
    try std.testing.expectError(error.Truncated, btree.decodeLeafPayload(&full, &entries_out));
}

// ===== decodeBranchPayload 截断 =====

test "btree_decode_corrupt: decodeBranchPayload < 3 bytes returns Truncated" {
    const short = [_]u8{ 0x01, 0x00 };
    var keys_out: [4][]const u8 = undefined;
    var children_out: [4]u32 = undefined;
    try std.testing.expectError(error.Truncated, btree.decodeBranchPayload(&short, &keys_out, &children_out));
}

test "btree_decode_corrupt: decodeBranchPayload on truncated valid branch returns Truncated" {
    // 合法 branch payload 截断为 3 字节（kind + count=3），keys_out/children_out 容量够，
    // 但 key 数据缺失 → pos+4 > payload.len → error.Truncated
    var full: [f2.PAGE_SIZE]u8 = undefined;
    const pl_len = buildValidBranchPayload(&full);
    try std.testing.expect(pl_len >= 3);

    var truncated: [3]u8 = undefined;
    @memcpy(&truncated, full[0..3]);
    var keys_out: [4][]const u8 = undefined;
    var children_out: [4]u32 = undefined;
    try std.testing.expectError(error.Truncated, btree.decodeBranchPayload(&truncated, &keys_out, &children_out));
}

test "btree_decode_corrupt: decodeBranchPayload wrong kind (leaf payload) returns CorruptCrc" {
    // 把 leaf payload 喂给 decodeBranchPayload：LEAF_KIND != BRANCH_KIND → error.CorruptCrc
    var leaf_buf: [f2.PAGE_SIZE]u8 = undefined;
    _ = try buildValidLeafPayload(&leaf_buf);

    var keys_out: [4][]const u8 = undefined;
    var children_out: [4]u32 = undefined;
    try std.testing.expectError(error.CorruptCrc, btree.decodeBranchPayload(&leaf_buf, &keys_out, &children_out));
}

test "btree_decode_corrupt: decodeBranchPayload children_out too small returns Truncated" {
    // 合法 branch payload 含 3 children，children_out 长度 2 → children_out.len < count → Truncated
    var full: [f2.PAGE_SIZE]u8 = undefined;
    _ = buildValidBranchPayload(&full);
    var keys_out: [4][]const u8 = undefined;
    var children_out: [2]u32 = undefined; // count=3, 需要 >=3
    try std.testing.expectError(error.Truncated, btree.decodeBranchPayload(&full, &keys_out, &children_out));
}

// ===== 合法路径回归（确保 encode→decode round-trip 正常，否则损坏测试无意义）=====

test "btree_decode_corrupt: valid leaf payload round-trips (sanity)" {
    var full: [f2.PAGE_SIZE]u8 = undefined;
    const pl_len = try buildValidLeafPayload(&full);
    var entries_out: [4]btree.DecodedLeafEntry = undefined;
    try btree.decodeLeafPayload(full[0..pl_len], &entries_out);
    try std.testing.expectEqualStrings("key1", entries_out[0].key);
    try std.testing.expectEqualStrings("val1", entries_out[0].value);
}

test "btree_decode_corrupt: valid branch payload round-trips (sanity)" {
    var full: [f2.PAGE_SIZE]u8 = undefined;
    const pl_len = buildValidBranchPayload(&full);
    var keys_out: [4][]const u8 = undefined;
    var children_out: [4]u32 = undefined;
    try btree.decodeBranchPayload(full[0..pl_len], &keys_out, &children_out);
    try std.testing.expectEqualStrings("m", keys_out[0]);
    try std.testing.expectEqualStrings("q", keys_out[1]);
    try std.testing.expectEqual(@as(u32, 10), children_out[0]);
    try std.testing.expectEqual(@as(u32, 30), children_out[2]);
}

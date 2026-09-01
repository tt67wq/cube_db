//! endian_consistency_test.zig — T-8: btree payload 端序一致性（TDD 红阶段）
//!
//! src/btree.zig 当前 leaf/branch payload 的 count/klen/vlen/children 字段
//! 用 `.big`（37 处），溢出页号用 `.little`（6 处）。目标是统一全 `.little`。
//!
//! 这是 TDD 红阶段：测试断言这些字段用 `.little` 读出正确值。源码还没改，
//! 所以前 3 类（leaf count / leaf klen vlen / branch children）会 FAIL，
//! 第 4 类（溢出页号，已是 .little）会 PASS 作为对照。
//!
//! T-9（绿阶段）会把 37 处 .big 改成 .little，届时全绿。
//! 接入：tests/btree_storage/btree_test.zig 末尾 comptime @import 本文件。

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const ps = cube.page_store;
const btree = cube.btree;

const allocator = std.testing.allocator;

/// 构造 1 个内联 leaf entry 的 payload，返回 (buf, 实际长度)
fn buildLeafPayload(buf: []u8) !usize {
    var ms = ps.MemPageStore.init(allocator, 64);
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);
    const entries = [_]btree.LeafEntry{
        .{ .tombstone = false, .key = "key1", .value = "val1" },
    };
    return try btree.encodeLeafPayload(buf, &entries, ms.store(), &dirty);
}

/// 构造 1 个溢出 leaf entry 的 payload，返回 (buf, 实际长度)
fn buildOverflowLeafPayload(buf: []u8) !usize {
    var ms = ps.MemPageStore.init(allocator, 64);
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);
    // > MAX_INLINE_VALUE(3800) 触发溢出页
    var big: [4000]u8 = undefined;
    @memset(&big, 0xAB);
    const entries = [_]btree.LeafEntry{
        .{ .tombstone = false, .key = "k", .value = &big },
    };
    return try btree.encodeLeafPayload(buf, &entries, ms.store(), &dirty);
}

/// 构造 branch payload（3 children, 2 keys），返回实际长度
fn buildBranchPayload(buf: []u8) usize {
    const keys = [_][]const u8{ "m", "q" };
    const children = [_]u32{ 10, 20, 30 };
    return btree.encodeBranchPayload(buf, &keys, &children);
}

test "endian: leaf count field is little-endian" {
    // 红阶段：当前 encodeLeafPayload 用 .big 写 count(=1)。
    // .big → bytes [0x00, 0x01]；.little 读 → 0x0100 = 256 ≠ 1 → FAIL（预期红）
    var buf: [f2.PAGE_SIZE]u8 = undefined;
    _ = try buildLeafPayload(&buf);
    // count 在 offset 1（byte[0]=LEAF_KIND）
    const got_little = std.mem.readInt(u16, buf[1..3], .little);
    try std.testing.expectEqual(@as(u16, 1), got_little);
}

test "endian: leaf klen field is little-endian" {
    // 红阶段：klen(=4, "key1") 用 .big 写 → bytes [0x00,0x00,0x00,0x04]
    // .little 读 → 0x04000000 ≠ 4 → FAIL（预期红）
    var buf: [f2.PAGE_SIZE]u8 = undefined;
    _ = try buildLeafPayload(&buf);
    // 布局：kind(1) + count(2) + tombstone(1) + klen(4) → klen 在 offset 4
    const got_little = std.mem.readInt(u32, buf[4..8], .little);
    try std.testing.expectEqual(@as(u32, 4), got_little); // "key1".len
}

test "endian: leaf vlen field is little-endian" {
    // 红阶段：vlen(=4, "val1") 用 .big 写 → .little 读得 0x04000000 ≠ 4 → FAIL
    var buf: [f2.PAGE_SIZE]u8 = undefined;
    _ = try buildLeafPayload(&buf);
    // 布局：kind(1)+count(2)+tombstone(1)+klen(4)+key(4)+vlen(4) → vlen 在 offset 12
    const got_little = std.mem.readInt(u32, buf[12..16], .little);
    try std.testing.expectEqual(@as(u32, 4), got_little); // "val1".len
}

test "endian: branch children field is little-endian" {
    // 红阶段：children 用 .big 写。children=[10,20,30]，30=0x1E → .big bytes
    // [0x00,0x00,0x00,0x1E]；.little 读 → 0x1E000000 ≠ 30 → FAIL（预期红）
    var buf: [f2.PAGE_SIZE]u8 = undefined;
    const pl_len = buildBranchPayload(&buf);
    // 布局：kind(1)+count(2)+ [klen(4)+key(1)]×2 + children(3×4)
    // = 1+2 + (4+1)+(4+1) + 12 = 3+10+12 = 25；children 区从 offset 13
    const children_off: usize = pl_len - 3 * 4;
    // 第 3 个 child（=30）在 children_off + 8
    const got_little = std.mem.readInt(u32, buf[children_off + 8 ..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 30), got_little);
}

test "endian: overflow page_no field is little-endian (control, passes)" {
    // 对照：溢出页号当前已是 .little（6 处之一），此测试应 PASS。
    // 构造溢出 entry，读回 overflow page_no 字段，断言 .little 读得非 0（页号有效）。
    var buf: [f2.PAGE_SIZE]u8 = undefined;
    const pl_len = try buildOverflowLeafPayload(&buf);
    try std.testing.expect(pl_len > 0);
    // 布局：kind(1)+count(2)+tombstone(1)+klen(4)+key(1)+vlen(4)+flags(1)+page_no(4)
    // flags=LEAF_FLAG_OVERFLOW，page_no 在 offset 1+2+1+4+1+4+1 = 14
    const page_no_little = std.mem.readInt(u32, buf[14..18], .little);
    // 溢出页号应 >= FIRST_DATA_PAGE(3)，.little 读得正确值（对照绿）
    try std.testing.expect(page_no_little >= 3);
    // 确认非对称：.big 读应得不同值（证明确实是 .little）
    const page_no_big = std.mem.readInt(u32, buf[14..18], .big);
    try std.testing.expect(page_no_little != page_no_big);
}

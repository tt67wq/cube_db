//! T5 RED: getLatestHeader 正向扫全文件记最后有效 header（去 marker 后）。
//! 旧实现按块倒扫 MARKER_HEADER；去 marker 后失效。GREEN 改正扫记录。
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const f = cube.format;
const store_mod = cube.store;

test "T5: empty store -> null" {
    var ms = store_mod.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const r = try store_mod.getLatestHeader(std.testing.allocator, ms.store());
    try std.testing.expectEqual(@as(?store_mod.HeaderScanResult, null), r);
}

test "T5: single header found" {
    var ms = store_mod.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    _ = try ms.appendHeaderRecord(.{ .btree_root = 42, .entry_count = 1, .byte_size = 1, .dirt = 0 });
    const r = try store_mod.getLatestHeader(std.testing.allocator, ms.store());
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 42), r.?.header.btree_root);
}

test "T5: multiple headers -> latest found (forward scan order)" {
    var ms = store_mod.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    // 正扫要求连续有效记录（[len][payload][crc]）。穿插的 node 用 encodeRecord 编码。
    var node_buf: [128]u8 = undefined;
    const node_rec = blk: {
        const payload = "node-payload";
        const n = f.encodeRecord(&node_buf, payload);
        break :blk node_buf[0..n];
    };
    _ = try ms.store().append(node_rec);
    _ = try ms.appendHeaderRecord(.{ .btree_root = 1, .entry_count = 1, .byte_size = 1, .dirt = 0 });
    _ = try ms.store().append(node_rec);
    _ = try ms.appendHeaderRecord(.{ .btree_root = 2, .entry_count = 2, .byte_size = 2, .dirt = 0 });
    _ = try ms.store().append(node_rec);
    const r = try store_mod.getLatestHeader(std.testing.allocator, ms.store());
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 2), r.?.header.btree_root);
}

test "T5: trailing garbage after last header -> still finds last good header" {
    var ms = store_mod.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    _ = try ms.appendHeaderRecord(.{ .btree_root = 7, .entry_count = 1, .byte_size = 1, .dirt = 0 });
    // 追加垃圾字节（不是合法记录结构）——正扫遇到解析失败应停在最后一个有效 header
    _ = try ms.store().append("garbage trailing bytes that are not a valid record");
    const r = try store_mod.getLatestHeader(std.testing.allocator, ms.store());
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 7), r.?.header.btree_root);
}

test "T5: corrupt trailing header (crc) -> falls back to previous" {
    var ms = store_mod.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    _ = try ms.appendHeaderRecord(.{ .btree_root = 1, .entry_count = 1, .byte_size = 1, .dirt = 0 });
    _ = try ms.appendHeaderRecord(.{ .btree_root = 2, .entry_count = 2, .byte_size = 2, .dirt = 0 });
    // 破坏最后 header 记录的 payload 区一字节（翻第 6 字节，len 在前 4、payload 从第 5 起）
    // 正扫时最后 header crc 不对 → 跳过 → 返上一个（root=1）
    const total = ms.data.items.len;
    ms.data.items[total - 6] ^= 0xff;
    const r = try store_mod.getLatestHeader(std.testing.allocator, ms.store());
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 1), r.?.header.btree_root);
}

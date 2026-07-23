//! T5 测试：get skip-decode — findInLeaf 直接从 payload seek 目标 key。
const std = @import("std");
const cube = @import("cube_db");
const btree = cube.btree;
const f = cube.format;

fn buildLeafPayload(allocator: std.mem.Allocator, entries: []const f.LeafEntry) ![]u8 {
    // 直接用 encodeLeafPayload 组 payload，不经 Leaf（避免 deinit free 字面量问题）
    const payload_size = f.leafPayloadSize(.{ .entries = entries });
    const total = f.REC_LEN_SIZE + payload_size + f.REC_CRC_SIZE;
    const rec = try allocator.alloc(u8, total);
    defer allocator.free(rec);
    std.mem.writeInt(u32, rec[0..4], @intCast(payload_size), .big);
    _ = f.encodeLeafPayload(rec[f.REC_LEN_SIZE..][0..payload_size], .{ .entries = entries });
    var crc = f.Crc32.init();
    crc.update(rec[0 .. f.REC_LEN_SIZE + payload_size]);
    std.mem.writeInt(u32, rec[f.REC_LEN_SIZE + payload_size ..][0..4], crc.final(), .big);
    const payload = try btree.decodeNodePayload(rec);
    return try allocator.dupe(u8, payload);
}

test "T5: findInLeaf hit returns correct value" {
    const a = std.testing.allocator;
    const entries = [_]f.LeafEntry{
        .{ .tombstone = false, .key = "a", .value = "va" },
        .{ .tombstone = false, .key = "b", .value = "vb" },
        .{ .tombstone = false, .key = "c", .value = "vc" },
    };
    const payload = try buildLeafPayload(a, &entries);
    defer a.free(payload);
    const v = try btree.findInLeaf(a, payload, "b");
    try std.testing.expect(v != null);
    defer if (v) |vv| a.free(vv);
    try std.testing.expectEqualStrings("vb", v.?);
}

test "T5: findInLeaf miss returns null" {
    const a = std.testing.allocator;
    const entries = [_]f.LeafEntry{
        .{ .tombstone = false, .key = "a", .value = "va" },
        .{ .tombstone = false, .key = "c", .value = "vc" },
    };
    const payload = try buildLeafPayload(a, &entries);
    defer a.free(payload);
    const v = try btree.findInLeaf(a, payload, "b");
    try std.testing.expect(v == null);
}

test "T5: findInLeaf tombstone returns null" {
    const a = std.testing.allocator;
    const entries = [_]f.LeafEntry{
        .{ .tombstone = false, .key = "a", .value = "va" },
        .{ .tombstone = true, .key = "b", .value = "" },
        .{ .tombstone = false, .key = "c", .value = "vc" },
    };
    const payload = try buildLeafPayload(a, &entries);
    defer a.free(payload);
    const v = try btree.findInLeaf(a, payload, "b");
    try std.testing.expect(v == null);
}

test "T5: findInLeaf first/last/mid on large sorted leaf" {
    const a = std.testing.allocator;
    // 组排序 key（4 位数字补零）
    var keys: [500][]const u8 = undefined;
    var keybuf: [500][4]u8 = undefined;
    for (0..500) |i| {
        const s = try std.fmt.bufPrint(&keybuf[i], "{d:0>4}", .{i});
        keys[i] = s;
    }
    var entries: [500]f.LeafEntry = undefined;
    for (0..500) |i| entries[i] = .{ .tombstone = false, .key = keys[i], .value = "v" };
    const payload = try buildLeafPayload(a, &entries);
    defer a.free(payload);
    const v0 = try btree.findInLeaf(a, payload, "0000");
    try std.testing.expect(v0 != null);
    defer if (v0) |vv| a.free(vv);
    const v499 = try btree.findInLeaf(a, payload, "0499");
    try std.testing.expect(v499 != null);
    defer if (v499) |vv| a.free(vv);
    const v250 = try btree.findInLeaf(a, payload, "0250");
    try std.testing.expect(v250 != null);
    defer if (v250) |vv| a.free(vv);
    const miss = try btree.findInLeaf(a, payload, "9999");
    try std.testing.expect(miss == null);
}

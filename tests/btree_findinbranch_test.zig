//! T6 续：get 跳过 branch 全解码——findInBranchPayload 直接 seek 目标 child offset。
//! 旧 get 走 Branch.fromPayload 全解码+逐 key dup；新 findInBranchPayload 线性扫 keys 找
//! 第一个 > key 的 index → 读该 child offset（8 字节），不 dup 全 entry。
const std = @import("std");
const cube = @import("cube_db");
const btree = cube.btree;
const f = cube.format;

fn buildBranchPayload(allocator: std.mem.Allocator, keys: []const []const u8, children: []const u64) ![]u8 {
    const node: f.BranchNode = .{ .keys = keys, .children = children };
    const psz = f.branchPayloadSize(node);
    const total = f.REC_LEN_SIZE + psz + f.REC_CRC_SIZE;
    const rec = try allocator.alloc(u8, total);
    defer allocator.free(rec);
    std.mem.writeInt(u32, rec[0..4], @intCast(psz), .big);
    _ = f.encodeBranchPayload(rec[f.REC_LEN_SIZE..][0..psz], node);
    var crc = f.Crc32.init();
    crc.update(rec[0 .. f.REC_LEN_SIZE + psz]);
    std.mem.writeInt(u32, rec[f.REC_LEN_SIZE + psz ..][0..4], crc.final(), .big);
    const payload = try btree.decodeNodePayload(rec);
    return try allocator.dupe(u8, payload);
}

test "T6: findInBranchPayload hit returns correct child offset" {
    const a = std.testing.allocator;
    const keys = [_][]const u8{ "b", "d", "f" };
    const children = [_]u64{ 100, 200, 300, 400 }; // n keys + 1
    const payload = try buildBranchPayload(a, &keys, &children);
    defer a.free(payload);
    // key "a" < "b" → child[0]=100
    try std.testing.expectEqual(@as(u64, 100), try btree.findInBranchPayload(payload, "a"));
    // key "b" == "b" → 右子 child[1]=200
    try std.testing.expectEqual(@as(u64, 200), try btree.findInBranchPayload(payload, "b"));
    // key "c" → child[1]=200
    try std.testing.expectEqual(@as(u64, 200), try btree.findInBranchPayload(payload, "c"));
    // key "e" → child[2]=300
    try std.testing.expectEqual(@as(u64, 300), try btree.findInBranchPayload(payload, "e"));
    // key "z" > all → child[3]=400
    try std.testing.expectEqual(@as(u64, 400), try btree.findInBranchPayload(payload, "z"));
}

test "T6: findInBranchPayload minimal branch (1 key, 2 children)" {
    const a = std.testing.allocator;
    const keys = [_][]const u8{"m"};
    const children = [_]u64{ 10, 20 };
    const payload = try buildBranchPayload(a, &keys, &children);
    defer a.free(payload);
    try std.testing.expectEqual(@as(u64, 10), try btree.findInBranchPayload(payload, "a"));
    try std.testing.expectEqual(@as(u64, 20), try btree.findInBranchPayload(payload, "m"));
    try std.testing.expectEqual(@as(u64, 20), try btree.findInBranchPayload(payload, "z"));
}

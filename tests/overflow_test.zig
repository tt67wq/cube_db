//! overflow_test.zig — 溢出页测试（TDD RED）
//! 覆盖：大 value > 4KB 的 put/get、超大 value 链、覆写、delete、select。
//! 先 fail（overflow 尚未实现）。
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree2 = cube.btree2;
const db2 = cube.db2;

test "overflow: put and get value larger than one page" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    var db = try db2.Db2.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const big = try std.testing.allocator.alloc(u8, 5000);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');

    try db.put("big", big);
    const v = try db.get("big");
    try std.testing.expect(v != null);
    try std.testing.expectEqual(@as(usize, 5000), v.?.len);
    try std.testing.expectEqualSlices(u8, big, v.?);
    std.testing.allocator.free(v.?);
}

test "overflow: 10KB value roundtrip" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    var db = try db2.Db2.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const big = try std.testing.allocator.alloc(u8, 10000);
    defer std.testing.allocator.free(big);
    @memset(big, 'y');

    try db.put("big", big);
    const v = try db.get("big");
    try std.testing.expect(v != null);
    try std.testing.expectEqual(@as(usize, 10000), v.?.len);
    try std.testing.expectEqualSlices(u8, big, v.?);
    std.testing.allocator.free(v.?);
}

test "overflow: overwrite with big value" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    var db = try db2.Db2.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    try db.put("k", "small");
    const big = try std.testing.allocator.alloc(u8, 8000);
    defer std.testing.allocator.free(big);
    @memset(big, 'z');

    try db.put("k", big);
    const v = try db.get("k");
    try std.testing.expect(v != null);
    try std.testing.expectEqual(@as(usize, 8000), v.?.len);
    try std.testing.expectEqualSlices(u8, big, v.?);
    std.testing.allocator.free(v.?);
}

test "overflow: delete big value then get null" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    var db = try db2.Db2.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const big = try std.testing.allocator.alloc(u8, 6000);
    defer std.testing.allocator.free(big);
    @memset(big, 'w');

    try db.put("k", big);
    try db.delete("k");
    try std.testing.expectEqual(@as(?[]u8, null), try db.get("k"));
}

test "overflow: multiple big values coexist" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    var db = try db2.Db2.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const big1 = try std.testing.allocator.alloc(u8, 5000);
    defer std.testing.allocator.free(big1);
    @memset(big1, 'a');

    const big2 = try std.testing.allocator.alloc(u8, 7000);
    defer std.testing.allocator.free(big2);
    @memset(big2, 'b');

    try db.put("k1", big1);
    try db.put("k2", big2);

    const v1 = try db.get("k1");
    try std.testing.expectEqualSlices(u8, big1, v1.?);
    std.testing.allocator.free(v1.?);

    const v2 = try db.get("k2");
    try std.testing.expectEqualSlices(u8, big2, v2.?);
    std.testing.allocator.free(v2.?);
}

test "overflow: big value in select range" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    var db = try db2.Db2.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const big = try std.testing.allocator.alloc(u8, 5000);
    defer std.testing.allocator.free(big);
    @memset(big, 'c');

    try db.put("a", "small");
    try db.put("b", big);
    try db.put("c", "small");

    var it = try db.select("b", "c");
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}
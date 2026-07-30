const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const MemPageStore = cube.page_store.MemPageStore;
const testing = std.testing;

test "repro: delete with 10KB overflow values" {
    const allocator = testing.allocator;
    const n: usize = 100;
    const value_size: usize = 10000; // overflow

    const v = try allocator.alloc(u8, value_size);
    defer allocator.free(v);
    @memset(v, 'x');

    var ms = MemPageStore.init(allocator, 3 + n * 4 + 1000);
    defer ms.deinit();
    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();

    var kbuf: [12]u8 = undefined;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i});
        try db.put(k, v);
    }

    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i});
        try db.delete(k);
    }

    var failed: usize = 0;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i});
        if (try db.get(k)) |got| {
            allocator.free(got);
            std.debug.print("UNEXPECTED: key {s} still exists after delete\n", .{k});
            failed += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failed);
}

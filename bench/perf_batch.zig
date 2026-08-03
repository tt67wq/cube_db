const std = @import("std");
const cube = @import("cube_db");

fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const n: usize = 100000;

    var ms = cube.page_store.MemPageStore.init(alloc, 5000000);
    defer ms.deinit();
    var db = try cube.Db.open(alloc, ms.store(), .{});
    defer db.close();

    const entries = try alloc.alloc(cube.Entry, n);
    defer alloc.free(entries);
    for (entries, 0..) |*e, i| {
        e.* = .{ .key = try std.fmt.allocPrint(alloc, "{d:0>10}", .{i}), .value = "v" };
    }
    defer for (entries) |e| alloc.free(e.key);

    const t0 = monoNs();
    try db.putBatch(entries);
    const t1 = monoNs();
    const per_entry = @divFloor(t1 - t0, @as(i64, @intCast(n)));

    std.debug.print("100K putBatch: {d} ms, {d} ns/entry ({d:.2} us/entry), count={d}\n", 
        .{ @divFloor(t1 - t0, 1_000_000), per_entry, @as(f64, @floatFromInt(per_entry)) / 1000.0, db.entryCount() });
}

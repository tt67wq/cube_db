const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const FilePageStore = cube.file_page_store.FilePageStore;

fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

const c = @cImport({
    @cInclude("unistd.h");
});

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

test "FPS ordered scaling" {
    const allocator = std.heap.page_allocator;
    const v100: [100]u8 = [_]u8{'x'} ** 100;

    for ([_]usize{ 10000, 100000, 500000, 1000000 }) |n| {
        const path = ".test_fps_scale.db";
        defer unlinkPath(path);
        var fps = try FilePageStore.init(allocator, path);
        defer fps.deinit();
        var db = try Db.open(allocator, fps.store(), .{});
        defer db.close();
        var entries = try allocator.alloc(cube.Entry, n);
        defer allocator.free(entries);
        for (0..n) |i| entries[i] = .{ .key = try std.fmt.allocPrint(allocator, "{d:0>10}", .{i}), .value = &v100 };
        defer for (entries) |e| allocator.free(e.key);
        const start = monoNs();
        try db.putBatch(entries);
        const el = monoNs() - start;
        std.debug.print("FPS ordered N={d:>7}: {d:.2} ns/entry\n", .{ n, @as(f64, @floatFromInt(el)) / @as(f64, @floatFromInt(n)) });
    }
}

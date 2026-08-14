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

test "FilePageStore ordered 1M putBatch" {
    const allocator = std.heap.page_allocator;
    const path = ".test_fps_ordered.db";
    defer unlinkPath(path);

    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    var db = try Db.open(allocator, fps.store(), .{});
    defer db.close();

    const n: usize = 1000000;
    var v100: [100]u8 = undefined;
    @memset(&v100, 'x');
    var entries = try allocator.alloc(cube.Entry, n);
    defer allocator.free(entries);
    // 有序 key（顺序递增）
    for (0..n) |i| entries[i] = .{ .key = try std.fmt.allocPrint(allocator, "{d:0>10}", .{i}), .value = &v100 };
    defer for (entries) |e| allocator.free(e.key);

    const start = monoNs();
    try db.putBatch(entries);
    const el = monoNs() - start;
    std.debug.print("FPS ordered 1M: {d:.2} ns/entry, count={d}\n", .{ @as(f64, @floatFromInt(el)) / @as(f64, @floatFromInt(n)), db.entryCount() });
}

test "FilePageStore unordered 100K putBatch" {
    const allocator = std.heap.page_allocator;
    const path = ".test_fps_unordered.db";
    defer unlinkPath(path);

    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    var db = try Db.open(allocator, fps.store(), .{});
    defer db.close();

    const n: usize = 100000;
    var v100: [100]u8 = undefined;
    @memset(&v100, 'x');
    var prng = std.Random.DefaultPrng.init(0xDEAD);
    const rnd = prng.random();
    var entries = try allocator.alloc(cube.Entry, n);
    defer allocator.free(entries);
    for (0..n) |i| entries[i] = .{ .key = try std.fmt.allocPrint(allocator, "k{d:0>10}", .{rnd.uintLessThan(usize, 1000000)}), .value = &v100 };
    defer for (entries) |e| allocator.free(e.key);

    const start = monoNs();
    try db.putBatch(entries);
    const el = monoNs() - start;
    std.debug.print("FPS unordered 100K: {d:.2} ns/entry, count={d}\n", .{ @as(f64, @floatFromInt(el)) / @as(f64, @floatFromInt(n)), db.entryCount() });
}

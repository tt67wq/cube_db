const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const FilePageStore = cube.file_page_store.FilePageStore;
const tdiag = @import("test_diag.zig");

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
    // T-54-B: was std.heap.page_allocator — 每次微分配独立 mmap+4KB 取整，
    // 1M-entry putBatch 的 ~30 万次微分配被放大成 17GB RSS（vmmap: 10 万个
    // 112K SM=PRV 区域）。smp_allocator 同样线程安全，实测峰值 16.5GB → ~430MB。
    const allocator = std.heap.smp_allocator;
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
    // ordered keys (monotonically increasing)
    for (0..n) |i| entries[i] = .{ .key = try std.fmt.allocPrint(allocator, "{d:0>10}", .{i}), .value = &v100 };
    defer for (entries) |e| allocator.free(e.key);

    const start = monoNs();
    try db.putBatch(entries);
    const el = monoNs() - start;
    tdiag.print("FPS ordered 1M: {d:.2} ns/entry, count={d}\n", .{ @as(f64, @floatFromInt(el)) / @as(f64, @floatFromInt(n)), db.entryCount() });
}

test "FilePageStore unordered 100K putBatch" {
    // T-54-B: 同上（见 ordered 测试注释），smp_allocator 替换 page_allocator。
    // 112K SM=PRV 区域）。smp_allocator 同样线程安全，实测峰值 16.5GB → ~430MB。
    const allocator = std.heap.smp_allocator;
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
    tdiag.print("FPS unordered 100K: {d:.2} ns/entry, count={d}\n", .{ @as(f64, @floatFromInt(el)) / @as(f64, @floatFromInt(n)), db.entryCount() });
}

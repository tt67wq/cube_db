//! bench_compare.zig — 快速 v1 vs v2 性能对比
//! zig build-exe bench/bench_compare.zig -lc --dep cube_db -Mcube_db=src/root.zig --dep zio -Mzio=../zio/src/zio.zig 2>/dev/null && ./bench_compare
const std = @import("std");
const cube = @import("cube_db");
const zio = @import("zio");

fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

fn fmtKey(buf: *[12]u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>10}", .{i}) catch unreachable;
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // V1 benchmark with files
    {
        const path = "bench_v1.db";
        const cwd = zio.Dir.cwd();
        cwd.deleteFile(path) catch {};
        defer cwd.deleteFile(path) catch {};
        cwd.deleteFile(path ++ ".compact") catch {};
        defer cwd.deleteFile(path ++ ".compact") catch {};

        const db = try cube.Db.open(allocator, path, .{ .fsync = false });
        defer db.close() catch {};

        const N = 10000;
        var kbuf: [12]u8 = undefined;

        // put benchmark
        var start = monoNs();
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const k = fmtKey(&kbuf, i);
            try db.put(k, "value_100B___");
        }
        var ns = monoNs() - start;
        std.debug.print("v1 put {d} ops: {d} ms, {d} ops/s\n", .{ N, @as(i64, @intCast(@divTrunc(ns, 1_000_000))), N * 1_000_000_000 / @as(u64, @intCast(ns)) });

        // get benchmark
        start = monoNs();
        i = 0;
        while (i < N) : (i += 1) {
            const k = fmtKey(&kbuf, i);
            const v = try db.get(k);
            if (v) |val| allocator.free(val);
        }
        ns = monoNs() - start;
        std.debug.print("v1 get {d} ops: {d} ms, {d} ops/s\n", .{ N, @as(i64, @intCast(@divTrunc(ns, 1_000_000))), N * 1_000_000_000 / @as(u64, @intCast(ns)) });
    }

    // V2 benchmark with FilePageStore
    {
        const path = "bench_v2.db";
        const cwd = zio.Dir.cwd();
        cwd.deleteFile(path) catch {};
        defer cwd.deleteFile(path) catch {};

        var fps = try cube.V2.file_page_store.create(allocator, path, 1 << 30); // 1GB mapsize
        defer fps.deinit();
        const store = fps.store();
        var db = try cube.V2.db2.Db2.open(allocator, store, .{});
        defer db.close();

        const N = 10000;
        var kbuf: [12]u8 = undefined;

        // put benchmark
        var start = monoNs();
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const k = fmtKey(&kbuf, i);
            try db.put(k, "value_100B___");
        }
        var ns = monoNs() - start;
        std.debug.print("v2 put {d} ops: {d} ms, {d} ops/s\n", .{ N, @as(i64, @intCast(@divTrunc(ns, 1_000_000))), N * 1_000_000_000 / @as(u64, @intCast(ns)) });

        // get benchmark
        start = monoNs();
        i = 0;
        while (i < N) : (i += 1) {
            const k = fmtKey(&kbuf, i);
            const v = try db.get(k);
            if (v) |val| allocator.free(val);
        }
        ns = monoNs() - start;
        std.debug.print("v2 get {d} ops: {d} ms, {d} ops/s\n", .{ N, @as(i64, @intCast(@divTrunc(ns, 1_000_000))), N * 1_000_000_000 / @as(u64, @intCast(ns)) });
    }
}

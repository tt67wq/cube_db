//! put 压测：单线程 vs 多线程同步写吞吐
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const Db = cube.Db;

const WARMUP = 20;
const OPS_PER_THREAD = 100;

fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

fn deleteIfExists(path: []const u8) void {
    zio.Dir.cwd().deleteFile(path) catch {};
}

fn benchSingle(allocator: std.mem.Allocator, path: []const u8) !void {
    deleteIfExists(path);
    const db = try Db.open(allocator, path, .{});
    defer db.close() catch {};

    for (0..WARMUP) |_| try db.put("warmup", "v");

    const start = monoNs();
    for (0..OPS_PER_THREAD) |i| {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "{d}", .{i});
        try db.put(k, "v");
    }
    const elapsed_ns = monoNs() - start;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const ops_sec = @as(f64, @floatFromInt(OPS_PER_THREAD)) / (elapsed_ms / 1000.0);
    std.debug.print("single-thread: {d} ops in {d:.1} ms -> {d:.0} ops/s, avg {d:.2} ms/op\n", .{
        OPS_PER_THREAD, elapsed_ms, ops_sec, elapsed_ms / @as(f64, @floatFromInt(OPS_PER_THREAD)),
    });
}

fn benchMulti(allocator: std.mem.Allocator, path: []const u8, n_threads: u32) !void {
    deleteIfExists(path);
    deleteIfExists(try std.fmt.allocPrint(allocator, "{s}.compact", .{path}));
    const db = try Db.open(allocator, path, .{});
    defer db.close() catch {};

    for (0..WARMUP) |_| try db.put("warmup", "v");

    const putter = struct {
        fn run(pdb: *Db, base: u32) !void {
            for (0..OPS_PER_THREAD) |i| {
                var kbuf: [16]u8 = undefined;
                const k = try std.fmt.bufPrint(&kbuf, "{d}", .{base * OPS_PER_THREAD + i});
                try pdb.put(k, "v");
            }
        }
    }.run;

    var threads: [64]std.Thread = undefined;
    const start = monoNs();
    for (0..n_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, putter, .{ db, @as(u32, @intCast(i)) });
    }
    for (0..n_threads) |i| threads[i].join();
    const elapsed_ns = monoNs() - start;

    const total_ops = n_threads * OPS_PER_THREAD;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const ops_sec = @as(f64, @floatFromInt(total_ops)) / (elapsed_ms / 1000.0);
    std.debug.print("{d}-thread:    {d} ops in {d:.1} ms -> {d:.0} ops/s, avg {d:.2} ms/op\n", .{
        n_threads, total_ops, elapsed_ms, ops_sec, elapsed_ms / @as(f64, @floatFromInt(total_ops)),
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const path = "bench_put.db";

    std.debug.print("=== cube_db put benchmark (fsync on) ===\n", .{});
    try benchSingle(allocator, path);
    try benchMulti(allocator, path, 2);
    try benchMulti(allocator, path, 4);
    try benchMulti(allocator, path, 10);
    deleteIfExists(path);
}

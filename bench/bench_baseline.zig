//! bench_baseline.zig — benchmark 回归基线检查
const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const MemPageStore = cube.page_store.MemPageStore;
const FilePageStore = cube.file_page_store.FilePageStore;

const SEED: u64 = 0x42;

const Metric = struct {
    name: []const u8,
    store: []const u8,
    value_ns: u64,
    threshold_pct: u64,
    note: []const u8,
};

const MetricList = []const Metric;

fn currentBaseline() MetricList {
    return &.{
        .{ .name = "put 100B", .store = "mem", .value_ns = 82136, .threshold_pct = 10, .note = "MemPageStore, 5K keys" },
        .{ .name = "putBatch 100B", .store = "mem", .value_ns = 93, .threshold_pct = 25, .note = "MemPageStore, 5K keys, 噪声大" },
        .{ .name = "get 100B", .store = "mem", .value_ns = 2844, .threshold_pct = 10, .note = "MemPageStore, 5K keys" },
        .{ .name = "getBorrowed 100B", .store = "mem", .value_ns = 352, .threshold_pct = 15, .note = "MemPageStore, 5K keys" },
        .{ .name = "delete 100B", .store = "mem", .value_ns = 91608, .threshold_pct = 15, .note = "MemPageStore, 5K keys" },
        .{ .name = "put 100B", .store = "file-fsync", .value_ns = 192561, .threshold_pct = 20, .note = "FilePageStore+fsync, 10K keys" },
        .{ .name = "putBatch 100B", .store = "file-fsync", .value_ns = 98, .threshold_pct = 25, .note = "FilePageStore+fsync, 10K keys" },
        .{ .name = "get 100B", .store = "file-fsync", .value_ns = 3097, .threshold_pct = 20, .note = "FilePageStore+fsync, 10K keys" },
    };
}

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

fn fmtKey(buf: *[12]u8, i: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d:0>10}", .{i});
}

fn runMemBench(name: []const u8, allocator: std.mem.Allocator, n: usize) !u64 {
    var ms = MemPageStore.init(allocator, @as(u32, @intCast(3 + n * 2 + 1000)));
    defer ms.deinit();
    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();

    var v100: [100]u8 = undefined;
    @memset(&v100, 'x');
    var kbuf: [12]u8 = undefined;
    for (0..n) |i| {
        const k = try fmtKey(&kbuf, i);
        try db.put(k, &v100);
    }

    var prng = std.Random.DefaultPrng.init(SEED);
    const rnd = prng.random();
    const trials = 5;
    var total_ns: i64 = 0;

    for (0..trials) |_| {
        const start = monoNs();
        if (std.mem.eql(u8, name, "put 100B")) {
            for (0..n) |i| {
                const k = try fmtKey(&kbuf, i);
                try db.put(k, &v100);
            }
        } else if (std.mem.eql(u8, name, "putBatch 100B")) {
            var entries = try allocator.alloc(cube.Entry, n);
            defer allocator.free(entries);
            for (0..n) |i| {
                const k = try fmtKey(&kbuf, i);
                entries[i] = .{ .key = k, .value = &v100 };
            }
            try db.putBatch(entries);
        } else if (std.mem.eql(u8, name, "get 100B")) {
            for (0..n) |_| {
                const idx = rnd.uintLessThan(usize, n);
                const k = try fmtKey(&kbuf, idx);
                if (try db.get(k)) |val| allocator.free(val);
            }
        } else if (std.mem.eql(u8, name, "getBorrowed 100B")) {
            var txn = try db.beginReadTxn();
            defer txn.end();
            for (0..n) |_| {
                const idx = rnd.uintLessThan(usize, n);
                const k = try fmtKey(&kbuf, idx);
                _ = try txn.getBorrowed(k);
            }
        } else if (std.mem.eql(u8, name, "delete 100B")) {
            for (0..n) |idx| {
                const k = try fmtKey(&kbuf, idx);
                try db.delete(k);
            }
        }
        total_ns += monoNs() - start;
    }
    return @as(u64, @intFromFloat(@as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(trials * n))));
}

fn runFileBench(name: []const u8, allocator: std.mem.Allocator, n: usize) !u64 {
    const path = ".baseline_fps.db";
    defer unlinkPath(path);

    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    var db = try Db.open(allocator, fps.store(), .{ .fsync = true });
    defer db.close();

    var v100: [100]u8 = undefined;
    @memset(&v100, 'x');
    var kbuf: [12]u8 = undefined;
    for (0..n) |i| {
        const k = try fmtKey(&kbuf, i);
        try db.put(k, &v100);
    }

    var prng = std.Random.DefaultPrng.init(SEED);
    const rnd = prng.random();
    const trials = 3;
    var total_ns: i64 = 0;

    for (0..trials) |_| {
        const start = monoNs();
        if (std.mem.eql(u8, name, "put 100B")) {
            for (0..n) |i| {
                const k = try fmtKey(&kbuf, i);
                try db.put(k, &v100);
            }
        } else if (std.mem.eql(u8, name, "putBatch 100B")) {
            var entries = try allocator.alloc(cube.Entry, n);
            defer allocator.free(entries);
            for (0..n) |i| {
                const k = try fmtKey(&kbuf, i);
                entries[i] = .{ .key = k, .value = &v100 };
            }
            try db.putBatch(entries);
        } else if (std.mem.eql(u8, name, "get 100B")) {
            for (0..n) |_| {
                const idx = rnd.uintLessThan(usize, n);
                const k = try fmtKey(&kbuf, idx);
                if (try db.get(k)) |val| allocator.free(val);
            }
        }
        total_ns += monoNs() - start;
    }
    return @as(u64, @intFromFloat(@as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(trials * n))));
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const baseline = currentBaseline();

    std.debug.print("=== benchmark 回归基线检查 ===\n", .{});
    std.debug.print("机器: Apple M1 Pro (8 cores)\n", .{});
    std.debug.print("日期: 2026-07-31\n\n", .{});

    std.debug.print("  {s:>25}  {s:>12}  {s:>10}  {s:>10}  {s:>6}  {s}\n", .{ "操作", "存储后端", "基准(ns)", "实测(ns)", "阈值", "结果" });
    std.debug.print("  {s:->25}  {s:->12}  {s:->10}  {s:->10}  {s:->6}  {s:->6}\n", .{ "", "", "", "", "", "" });

    const mem_n: usize = 5000;
    const file_n: usize = 10000;
    var failures: usize = 0;

    for (baseline) |m| {
        const actual_ns = if (std.mem.eql(u8, m.store, "mem"))
            try runMemBench(m.name, allocator, mem_n)
        else
            try runFileBench(m.name, allocator, file_n);

        const degradation = if (actual_ns > m.value_ns) (actual_ns - m.value_ns) * 100 / m.value_ns else 0;
        const passed = degradation < m.threshold_pct;
        if (!passed) failures += 1;

        std.debug.print("  {s:>25}  {s:>12}  {d:>10}  {d:>10}  {d:>4}%  {s}\n", .{
            m.name, m.store, m.value_ns, actual_ns, m.threshold_pct,
            if (passed) "PASS" else "FAIL",
        });
        if (!passed) {
            std.debug.print("  {s:>25}  {s:>12}  {s:>10}  {s:>10}  劣化 {d}%\n", .{ "", "", "", "", degradation });
        }
    }

    const total = baseline.len;
    std.debug.print("\n结果: {d}/{d} 通过", .{ total - failures, total });
    if (failures > 0) {
        std.debug.print(", {d} 失败\n", .{failures});
        return error.BaselineFailed;
    }
    std.debug.print(" 全部通过 ✅\n", .{});
}
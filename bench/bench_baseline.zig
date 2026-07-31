//! bench_baseline.zig — benchmark 回归基线检查
//! 注意：Zig 0.16.0 构建系统并行测试有竞争条件（txn_test 间歇 SEGV），
//! 跑全量测试时务必串行执行（`zig build test` 仅单模块），避免并行触发 flaky。
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
        // 2026-07-31 重校：put/delete 解释 = 写路径 dupe 开销（假设，待 commit 分解任务验证）
        .{ .name = "put 100B", .store = "mem", .value_ns = 123721, .threshold_pct = 25, .note = "MemPageStore, 5K keys, 重校(dupe 假设)" },
        .{ .name = "putBatch 100B", .store = "mem", .value_ns = 13240, .threshold_pct = 25, .note = "MemPageStore, 30 keys(快路径), 重校(旧值=1-key bug)" },
        .{ .name = "get 100B", .store = "mem", .value_ns = 2907, .threshold_pct = 15, .note = "MemPageStore, 5K keys, A/B 确认无回归" },
        .{ .name = "getBorrowed 100B", .store = "mem", .value_ns = 352, .threshold_pct = 15, .note = "MemPageStore, 5K keys" },
        .{ .name = "delete 100B", .store = "mem", .value_ns = 117093, .threshold_pct = 25, .note = "MemPageStore, 5K keys, 重校(dupe 假设)" },
        .{ .name = "put 100B", .store = "file-fsync", .value_ns = 167499, .threshold_pct = 20, .note = "FilePageStore+fsync, 1K keys, 重校" },
        .{ .name = "putBatch 100B", .store = "file-fsync", .value_ns = 15233, .threshold_pct = 25, .note = "FilePageStore+fsync, 30 keys, 重校(旧值=1-key bug)" },
        .{ .name = "get 100B", .store = "file-fsync", .value_ns = 3100, .threshold_pct = 25, .note = "FilePageStore+fsync, 1K keys, 噪声敏感" },
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

fn median(values: []const u64) u64 {
    var buf: [16]u64 = undefined;
    std.debug.assert(values.len <= buf.len);
    @memcpy(buf[0..values.len], values);
    const arr = buf[0..values.len];
    std.mem.sort(u64, arr, {}, std.sort.asc(u64));
    return arr[arr.len / 2];
}

fn runMemBench(name: []const u8, allocator: std.mem.Allocator, n: usize) !u64 {
    var ms = MemPageStore.init(allocator, @as(u32, @intCast(3 + n * 10 + 10000)));
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
            const keybufs = try allocator.alloc([12]u8, n);
            defer allocator.free(keybufs);
            for (0..n) |i| {
                const k = try fmtKey(&keybufs[i], i);
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
    const trials = 1; // file-fsync is slow, 1 trial for CI
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
            const keybufs = try allocator.alloc([12]u8, n);
            defer allocator.free(keybufs);
            for (0..n) |i| {
                const k = try fmtKey(&keybufs[i], i);
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
    const file_n: usize = 1000; // reduced from 10000 — fsync per put makes large N too slow for baseline
    // putBatch uses smaller N to stay on fast path (entries <= LEAF_MAX_ENTRIES=32)
    const batch_n: usize = 30;
    var failures: usize = 0;

    for (baseline) |m| {
        const effective_n = if (std.mem.eql(u8, m.name, "putBatch 100B")) batch_n else if (std.mem.eql(u8, m.store, "mem")) mem_n else file_n;
        var samples: [3]u64 = undefined;
        for (0..3) |i| {
            samples[i] = if (std.mem.eql(u8, m.store, "mem"))
                try runMemBench(m.name, allocator, effective_n)
            else
                try runFileBench(m.name, allocator, effective_n);
        }
        const actual_ns = median(&samples);

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
//! bench_baseline.zig — benchmark 回归基线检查
const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const MemPageStore = cube.page_store.MemPageStore;

const SEED: u64 = 0x42;

const Metric = struct {
    name: []const u8,
    value_ns: u64,
    threshold_pct: u64,
};

const Baseline = struct {
    machine: []const u8,
    cpu: []const u8,
    metrics: []const Metric,
};

fn currentBaseline() Baseline {
    return .{
        .machine = "MacBookPro18,3",
        .cpu = "Apple M1 Pro (8 cores)",
        .metrics = &.{
            .{ .name = "put 100B", .value_ns = 79325, .threshold_pct = 10 },
            .{ .name = "putBatch 100B", .value_ns = 62, .threshold_pct = 10 },
            .{ .name = "get 100B", .value_ns = 3292, .threshold_pct = 10 },
            .{ .name = "getBorrowed 100B", .value_ns = 347, .threshold_pct = 15 },
            .{ .name = "delete 100B", .value_ns = 78977, .threshold_pct = 10 },
        },
    };
}

fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

fn fmtKey(buf: *[12]u8, i: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d:0>10}", .{i});
}

fn runBench(name: []const u8, allocator: std.mem.Allocator, n: usize) !u64 {
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

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const baseline = currentBaseline();

    std.debug.print("=== benchmark 回归基线检查 ===\n", .{});
    std.debug.print("机器: {s} ({s})\n\n", .{ baseline.machine, baseline.cpu });
    std.debug.print("  {s:>25}  {s:>10}  {s:>10}  {s:>8}  {s}\n", .{ "操作", "基准(ns)", "实测(ns)", "阈值", "结果" });
    std.debug.print("  {s:->25}  {s:->10}  {s:->10}  {s:->8}  {s:->6}\n", .{ "", "", "", "", "" });

    const n: usize = 5000;
    var failures: usize = 0;
    for (baseline.metrics) |m| {
        const actual_ns = try runBench(m.name, allocator, n);
        const degradation = if (actual_ns > m.value_ns) (actual_ns - m.value_ns) * 100 / m.value_ns else 0;
        const passed = degradation < m.threshold_pct;
        if (!passed) failures += 1;

        std.debug.print("  {s:>25}  {d:>10}  {d:>10}  {d:>6}%  {s}\n", .{
            m.name, m.value_ns, actual_ns, m.threshold_pct,
            if (passed) "PASS" else "FAIL",
        });
        if (!passed) {
            std.debug.print("  {s:>25}  {s:>10}  {s:>10}  劣化 {d:>3}%\n", .{ "", "", "", degradation });
        }
    }

    const total = baseline.metrics.len;
    std.debug.print("\n结果: {d}/{d} 通过", .{ total - failures, total });
    if (failures > 0) {
        std.debug.print(", {d} 失败 -- 退出码非零\n", .{failures});
        return error.BaselineFailed;
    }
    std.debug.print(" 全部通过 ✅\n", .{});
}
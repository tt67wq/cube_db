//! get_profile.zig — get 分阶段耗时分解
const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const btree = cube.btree;
const MemPageStore = cube.page_store.MemPageStore;

const SEED: u64 = 0x42;

fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

fn fmtKey(buf: *[12]u8, i: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d:0>10}", .{i});
}

fn pct(part: f64, total: f64) u64 {
    if (total == 0) return 0;
    return @as(u64, @intFromFloat(part / total * 100.0));
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== get 分阶段耗时分解 ===\n\n", .{});

    const configs = [_]struct { n: usize, label: []const u8 }{
        .{ .n = 100, .label = "100 keys (depth ~2)" },
        .{ .n = 10000, .label = "10K keys (depth ~3)" },
        .{ .n = 100000, .label = "100K keys (depth ~4)" },
    };

    var v100: [100]u8 = undefined;
    @memset(&v100, 'x');

    const trials = 5;
    const ops_per_trial = 2000;

    for (configs) |cfg| {
        std.debug.print("\n--- {s} ---\n", .{cfg.label});

        var ms = MemPageStore.init(allocator, @as(u32, @intCast(3 + cfg.n * 2 + 1000)));
        defer ms.deinit();
        var db = try Db.open(allocator, ms.store(), .{});
        defer db.close();

        var kbuf: [12]u8 = undefined;
        for (0..cfg.n) |i| {
            const k = try fmtKey(&kbuf, i);
            try db.put(k, &v100);
        }

        var prng = std.Random.DefaultPrng.init(SEED);
        const rnd = prng.random();
        var keys = try allocator.alloc([]const u8, ops_per_trial);
        defer allocator.free(keys);
        for (0..ops_per_trial) |i| {
            const idx = rnd.uintLessThan(usize, cfg.n);
            keys[i] = try fmtKey(&kbuf, idx);
        }

        var total_get_ns: i64 = 0;
        for (0..trials) |_| {
            const start = monoNs();
            for (0..ops_per_trial) |i| {
                if (try db.get(keys[i])) |val| allocator.free(val);
            }
            total_get_ns += monoNs() - start;
        }
        const avg_get = @as(f64, @floatFromInt(total_get_ns)) / @as(f64, @floatFromInt(trials * ops_per_trial));

        var total_borrow_ns: i64 = 0;
        for (0..trials) |_| {
            var txn = try db.beginReadTxn();
            defer txn.end();
            const start = monoNs();
            for (0..ops_per_trial) |i| {
                _ = try txn.getBorrowed(keys[i]);
            }
            total_borrow_ns += monoNs() - start;
        }
        const avg_borrow = @as(f64, @floatFromInt(total_borrow_ns)) / @as(f64, @floatFromInt(trials * ops_per_trial));

        var txn_create_ns: i64 = 0;
        for (0..trials) |_| {
            const start = monoNs();
            for (0..ops_per_trial) |_| {
                var txn = try db.beginReadTxn();
                txn.end();
            }
            txn_create_ns += monoNs() - start;
        }
        const avg_txn = @as(f64, @floatFromInt(txn_create_ns)) / @as(f64, @floatFromInt(trials * ops_per_trial));

        var page_read_ns: i64 = 0;
        const root = db.getRoot();
        const s = ms.store();
        for (0..trials) |_| {
            const start = monoNs();
            for (0..ops_per_trial) |_| {
                const payload = try btree.readNodePayload(s, root);
                _ = payload;
            }
            page_read_ns += monoNs() - start;
        }
        const avg_page = @as(f64, @floatFromInt(page_read_ns)) / @as(f64, @floatFromInt(trials * ops_per_trial));

        const ag = @as(u64, @intFromFloat(avg_get));
        const ab = @as(u64, @intFromFloat(avg_borrow));
        const at = @as(u64, @intFromFloat(avg_txn));
        const ap = @as(u64, @intFromFloat(avg_page));

        std.debug.print("  get (with dupe):       {d:>8} ns/op  ({d:>5} us)\n", .{ ag, ag / 1000 });
        std.debug.print("  getBorrowed (no dupe): {d:>8} ns/op  ({d:>5} us)\n", .{ ab, ab / 1000 });
        std.debug.print("  ReadTxn create:        {d:>8} ns/op\n", .{at});
        std.debug.print("  readNodePayload:       {d:>8} ns/op\n", .{ap});

        const dupe_overhead = avg_get - avg_borrow;
        const traversal_overhead = avg_borrow - avg_txn;
        const est_depth = btreeDepth(cfg.n);
        const page_read_total = avg_page * est_depth;
        const cmp_overhead = traversal_overhead - page_read_total;

        const do_ns = @as(u64, @intFromFloat(dupe_overhead));
        const pr_ns = @as(u64, @intFromFloat(page_read_total));
        const co_ns = @as(u64, @intFromFloat(@max(0, cmp_overhead)));

        std.debug.print("\n  估计分解（getBorrowed {d}ns 基准）：\n", .{ab});
        std.debug.print("    读事务创建:     {d:>7} ns ({d:>3}%)\n", .{ at, pct(avg_txn, avg_borrow) });
        std.debug.print("    页面读取({d:.0}层): {d:>7} ns ({d:>3}%)\n", .{ est_depth, pr_ns, pct(page_read_total, avg_borrow) });
        std.debug.print("    key 比较/遍历:   {d:>7} ns ({d:>3}%)\n", .{ co_ns, pct(@max(0, cmp_overhead), avg_borrow) });
        std.debug.print("    dupe 分配:       {d:>7} ns ({d:>3}%)\n", .{ do_ns, pct(dupe_overhead, avg_get) });
        std.debug.print("  二分查找预期: 线性扫描 O(n) 占 key 比较的主要部分，改为二分后预计可减半\n", .{});
    }
}

fn btreeDepth(n: usize) f64 {
    if (n <= 32) return 1.0;
    var leaves: f64 = @as(f64, @floatFromInt(n)) / 32.0;
    var depth: f64 = 1.0;
    while (leaves > 64) {
        leaves /= 64.0;
        depth += 1.0;
    }
    return depth + 1.0;
}
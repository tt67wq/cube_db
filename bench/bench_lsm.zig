//! bench_lsm.zig — Profiling benchmark: per-stage time decomposition of LSM put/get.
//! TDD: each stage timing printed + reconciliation (sum ≈ total)
const std = @import("std");
const cube_db = @import("cube_db");
const zio = @import("zio");

const Db = cube_db.Db;
const PageStore = cube_db.page_store;
const MemPageStore = PageStore.MemPageStore;
const Memtable = cube_db.memtable.Memtable;
const Wal = cube_db.wal.Wal;
const Io = std.Io;

fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

const N = 1000;
const WARMUP = 100;

fn printRow(w: *Io.Writer, stage: []const u8, us: f64, pct: f64) !void {
    try w.print("  {s:<20} {d:>8.1} us  {d:>5.1}%\n", .{ stage, us, pct });
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const w = &stdout_writer.interface;

    // ===== PUT PATH DECOMPOSITION =====
    try w.writeAll("=== PUT path decomposition ===\n");
    {
        var ms = MemPageStore.init(allocator, 1 << 16);
        defer ms.deinit();
        var db = try Db.open(allocator, ms.store(), .{});
        defer db.close();

        var mt = Memtable.init(allocator, 1024 * 1024);
        defer mt.deinit();
        var wal = try Wal.init(allocator, ".bench_lsm_put_profile");
        defer {
            wal.deinit();
            zio.Dir.cwd().deleteFile(".bench_lsm_put_profile") catch {};
        }
        db.mt = &mt;
        db.wal = &wal;

        var kbuf: [12]u8 = undefined;

        // Warmup
        for (0..WARMUP) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i});
            try db.put(k, "x");
        }

        // Timed run
        var t_fmt: i64 = 0;
        var t_wal: i64 = 0;
        var t_mt: i64 = 0;
        var t_flush: i64 = 0;
        var t_total: i64 = 0;

        for (0..N) |i| {
            // T0: fmtKey
            const s0 = monoNs();
            const key = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i});
            const e0 = monoNs();
            t_fmt += e0 - s0;

            // T1: WAL append
            const s1 = monoNs();
            _ = try wal.append(.put, key, "x");
            const e1 = monoNs();
            t_wal += e1 - s1;

            // T2: Memtable put
            const s2 = monoNs();
            _ = try mt.put(key, "x");
            const e2 = monoNs();
            t_mt += e2 - s2;

            // T3: shouldFlush
            const s3 = monoNs();
            _ = mt.shouldFlush();
            const e3 = monoNs();
            t_flush += e3 - s3;

            t_total += e3 - s0;
        }

        // Reconcile
        const sum_stages = t_fmt + t_wal + t_mt + t_flush;
        const total_us = @as(f64, @floatFromInt(t_total)) / 1000.0 / N;
        const sum_us = @as(f64, @floatFromInt(sum_stages)) / 1000.0 / N;
        const fmt_us = @as(f64, @floatFromInt(t_fmt)) / 1000.0 / N;
        const wal_us = @as(f64, @floatFromInt(t_wal)) / 1000.0 / N;
        const mt_us = @as(f64, @floatFromInt(t_mt)) / 1000.0 / N;
        const flush_us = @as(f64, @floatFromInt(t_flush)) / 1000.0 / N;

        try w.print("Total put: {d:>8.1} us/op\n", .{total_us});
        try w.print("Stage breakdown:\n", .{});
        try printRow(w, "fmtKey (bufPrint)", fmt_us, fmt_us / total_us * 100);
        try printRow(w, "WAL append (single pwrite)", wal_us, wal_us / total_us * 100);
        try printRow(w, "Memtable put (dupe+HashMap)", mt_us, mt_us / total_us * 100);
        try printRow(w, "shouldFlush", flush_us, flush_us / total_us * 100);
        try w.print("  {s:<20} {d:>8.1} us\n", .{"Sum of stages", sum_us});
        try w.print("  {s:<20} {d:>8.1} us\n", .{"Delta (sum - total)", sum_us - total_us});

        const delta = if (total_us > 0) @abs(sum_us - total_us) / total_us else 0.0;
        if (delta <= 0.15) {
            try w.print("  OK Reconciliation: {d:.1}% <= 15%\n", .{delta * 100});
        } else {
            try w.print("  FAIL Reconciliation: {d:.1}% > 15%\n", .{delta * 100});
        }

        const wal_ok = wal_us <= 8.0;
        const total_ok = total_us <= 12.0;
        try w.print("  Target: WAL append <= 8.0us | Total put <= 12.0us\n", .{});
        try w.print("  Result: WAL {d:.1}us [{s}] | Total {d:.1}us [{s}]\n", .{
            wal_us, if (wal_ok) @as([]const u8, "PASS") else "FAIL",
            total_us, if (total_ok) @as([]const u8, "PASS") else "FAIL",
        });
        if (!wal_ok or !total_ok) {
            try w.print("  >>> ACCEPTANCE FAIL: target not met <<<\n", .{});
        } else {
            try w.print("  >>> ACCEPTANCE PASS <<<\n", .{});
        }
    }

    // ===== GET PATH DECOMPOSITION =====
    try w.writeAll("\n=== GET path decomposition ===\n");
    {
        var ms = MemPageStore.init(allocator, 1 << 16);
        defer ms.deinit();
        var db = try Db.open(allocator, ms.store(), .{});
        defer db.close();

        var mt = Memtable.init(allocator, 1024 * 1024);
        defer mt.deinit();
        db.mt = &mt;

        // Preload memtable
        var kbuf: [12]u8 = undefined;
        for (0..N) |i| {
            const key = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i});
            _ = try mt.put(key, "x");
        }

        var prng = std.Random.DefaultPrng.init(0x42);
        const rnd = prng.random();

        // Warmup
        for (0..WARMUP) |_| {
            const idx = rnd.uintLessThan(usize, N);
            const key = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{idx});
            if (try db.get(key)) |v| allocator.free(v);
        }

        // Timed run — stage decomposition
        var t_g0_fmt: i64 = 0;
        var t_g1_lookup: i64 = 0;
        var t_g2_dupe: i64 = 0;

        for (0..N) |_| {
            const idx = rnd.uintLessThan(usize, N);

            const s0 = monoNs();
            const key = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{idx});
            const e0 = monoNs();
            t_g0_fmt += e0 - s0;

            const s1 = monoNs();
            const val = mt.get(key);
            const e1 = monoNs();
            t_g1_lookup += e1 - s1;

            const s2 = monoNs();
            _ = try allocator.dupe(u8, val.?);
            const e2 = monoNs();
            t_g2_dupe += e2 - s2;
        }

        // Measure total db.get() for comparison
        var prng2 = std.Random.DefaultPrng.init(0x42);
        const rnd2 = prng2.random();
        for (0..WARMUP) |_| {
            const idx = rnd2.uintLessThan(usize, N);
            const key = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{idx});
            if (try db.get(key)) |v| allocator.free(v);
        }
        const s_total = monoNs();
        for (0..N) |_| {
            const idx = rnd2.uintLessThan(usize, N);
            const key = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{idx});
            if (try db.get(key)) |v| allocator.free(v);
        }
        const total_get_ns = monoNs() - s_total;
        const total_get_us = @as(f64, @floatFromInt(total_get_ns)) / 1000.0 / N;

        const g_fmt_us = @as(f64, @floatFromInt(t_g0_fmt)) / 1000.0 / N;
        const g_lookup_us = @as(f64, @floatFromInt(t_g1_lookup)) / 1000.0 / N;
        const g_dupe_us = @as(f64, @floatFromInt(t_g2_dupe)) / 1000.0 / N;
        const g_sum_us = g_fmt_us + g_lookup_us + g_dupe_us;

        try w.print("Total get (db.get): {d:>8.1} us/op\n", .{total_get_us});
        try w.print("Stage breakdown:\n", .{});
        try printRow(w, "fmtKey (bufPrint)", g_fmt_us, g_fmt_us / total_get_us * 100);
        try printRow(w, "memtable get (HashMap look)", g_lookup_us, g_lookup_us / total_get_us * 100);
        try printRow(w, "dupe value return", g_dupe_us, g_dupe_us / total_get_us * 100);
        try w.print("  {s:<20} {d:>8.1} us\n", .{"Sum of stages", g_sum_us});
        try w.print("  {s:<20} {d:>8.1} us\n", .{"Delta (sum - total)", g_sum_us - total_get_us});

        const g_delta = if (total_get_us > 0) @abs(g_sum_us - total_get_us) / total_get_us else 0.0;
        if (g_delta <= 0.15) {
            try w.print("  OK Reconciliation: {d:.1}% <= 15%\n", .{g_delta * 100});
        } else {
            try w.print("  FAIL Reconciliation: {d:.1}% > 15%\n", .{g_delta * 100});
        }
    }

    try w.writeAll("\n");
    try w.flush();
}
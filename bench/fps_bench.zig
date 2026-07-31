//! fps_bench.zig — FilePageStore benchmark: 2x2 matrix (no-fsync / fsync)
//! Usage: zig build fps-bench -Doptimize=ReleaseFast
//!
//! Measures FilePageStore performance aligned with LMDB semantics:
//! - no-fsync: MDB_NOSYNC equivalent (mmap writes, no fsync)
//! - fsync: LMDB default equivalent (fsync on commit)
//!
//! Also records commit latency p50/p99 and batch size scan.
const std = @import("std");
const Io = std.Io;
const cube = @import("cube_db");
const Db = cube.Db;
const Entry = cube.Entry;
const FilePageStore = cube.file_page_store.FilePageStore;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

fn fmtKey(buf: *[12]u8, i: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d:0>10}", .{i});
}

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

fn percentile(sorted: []i64, p: f64) i64 {
    if (sorted.len == 0) return 0;
    const idx = @as(usize, @intFromFloat(@as(f64, @floatFromInt(sorted.len)) * p / 100.0));
    const i = @min(idx, sorted.len - 1);
    return sorted[i];
}

const Config = struct {
    fsync: bool,
    n: usize,
    value_size: usize,
    label: []const u8,
};

fn runPut(path: []const u8, cfg: Config, w: *Io.Writer) !void {
    var fps = try FilePageStore.init(std.heap.page_allocator, path);
    defer fps.deinit();
    var db = try Db.open(std.heap.page_allocator, fps.store(), .{ .fsync = cfg.fsync });
    defer db.close();

    var vbuf: [10000]u8 = undefined;
    @memset(vbuf[0..cfg.value_size], 'x');
    const value = vbuf[0..cfg.value_size];

    // Warmup
    const wu = @min(cfg.n / 100, 100);
    var kbuf: [12]u8 = undefined;
    for (0..wu) |i| {
        const k = try fmtKey(&kbuf, i);
        try db.put(k, value);
    }

    // Measure
    var commit_times = std.heap.page_allocator.alloc(i64, cfg.n) catch unreachable;
    defer std.heap.page_allocator.free(commit_times);

    const start = monoNs();
    for (0..cfg.n) |i| {
        const k = try fmtKey(&kbuf, i);
        const cs = monoNs();
        try db.put(k, value);
        commit_times[i] = monoNs() - cs;
    }
    const ns = monoNs() - start;

    std.mem.sort(i64, commit_times, {}, std.sort.asc(i64));
    const avg_ns = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(cfg.n));
    const p50 = percentile(commit_times, 50);
    const p99 = percentile(commit_times, 99);

    var buf2: [200]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf2, "  {s:<12} put  {s:<5}  avg={d:>8.2}us  p50={d:>8.2}us  p99={d:>8.2}us\n", .{
        cfg.label, if (cfg.value_size == 100) "100B" else "10KB", avg_ns / 1000.0, @as(f64, @floatFromInt(p50)) / 1000.0, @as(f64, @floatFromInt(p99)) / 1000.0,
    });
    try w.writeAll(line);
    try w.flush();
}

fn runPutBatch(path: []const u8, cfg: Config, w: *Io.Writer) !void {
    var fps = try FilePageStore.init(std.heap.page_allocator, path);
    defer fps.deinit();
    var db = try Db.open(std.heap.page_allocator, fps.store(), .{ .fsync = cfg.fsync });
    defer db.close();

    var vbuf: [10000]u8 = undefined;
    @memset(vbuf[0..cfg.value_size], 'x');
    const value = vbuf[0..cfg.value_size];

    // Prepare entries
    const entries = try std.heap.page_allocator.alloc(Entry, cfg.n);
    defer std.heap.page_allocator.free(entries);
    var kbuf: [12]u8 = undefined;
    for (entries, 0..) |*e, i| {
        const k = try fmtKey(&kbuf, i);
        e.* = .{ .key = k, .value = value };
    }

    // Measure single batch commit
    const start = monoNs();
    try db.putBatch(entries);
    const ns = monoNs() - start;
    const avg_ns = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(cfg.n));

    var buf2: [200]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf2, "  {s:<12} putBatch {s:<5}  avg={d:>8.2}us  total={d:>8.2}ms\n", .{
        cfg.label, if (cfg.value_size == 100) "100B" else "10KB", avg_ns / 1000.0, @as(f64, @floatFromInt(ns)) / 1_000_000.0,
    });
    try w.writeAll(line);
    try w.flush();
}

fn runPutBatchScan(path: []const u8, fsync: bool, label: []const u8, w: *Io.Writer) !void {
    const sizes = [_]usize{ 10, 100, 1000, 10000 };
    var vbuf: [100]u8 = undefined;
    @memset(&vbuf, 'x');

    try w.writeAll("  --- putBatch batch size scan (100B) ---\n");
    try w.flush();
    for (sizes) |batch_size| {
        const sub_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_scan_{d}", .{ path, batch_size });
        defer std.heap.page_allocator.free(sub_path);
        defer unlinkPath(sub_path);

        var fps = try FilePageStore.init(std.heap.page_allocator, sub_path);
        defer fps.deinit();
        var db = try Db.open(std.heap.page_allocator, fps.store(), .{ .fsync = fsync });
        defer db.close();

        const entries = try std.heap.page_allocator.alloc(Entry, batch_size);
        defer std.heap.page_allocator.free(entries);
        var kbuf: [12]u8 = undefined;
        for (entries, 0..) |*e, i| {
            const k = try fmtKey(&kbuf, i);
            e.* = .{ .key = k, .value = &vbuf };
        }

        const start = monoNs();
        try db.putBatch(entries);
        const ns = monoNs() - start;
        const avg_us = @as(f64, @floatFromInt(ns)) / 1000.0 / @as(f64, @floatFromInt(batch_size));

        var buf2: [200]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf2, "  {s:<12} batch={d:>6}  per-entry={d:>8.2}us  total={d:>8.2}ms\n", .{
            label, batch_size, avg_us, @as(f64, @floatFromInt(ns)) / 1_000_000.0,
        });
        try w.writeAll(line);
        try w.flush();
    }
}

fn runGet(path: []const u8, cfg: Config, w: *Io.Writer) !void {
    var fps = try FilePageStore.init(std.heap.page_allocator, path);
    defer fps.deinit();
    var db = try Db.open(std.heap.page_allocator, fps.store(), .{});
    defer db.close();

    var vbuf: [10000]u8 = undefined;
    @memset(vbuf[0..cfg.value_size], 'x');
    const value = vbuf[0..cfg.value_size];

    // Pre-populate
    var kbuf: [12]u8 = undefined;
    for (0..cfg.n) |i| {
        const k = try fmtKey(&kbuf, i);
        try db.putDirect(k, value);
    }

    // Measure get
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    const wu = @min(cfg.n / 100, 1000);
    for (0..wu) |_| {
        const idx = rnd.uintLessThan(usize, cfg.n);
        const k = try fmtKey(&kbuf, idx);
        if (try db.get(k)) |got| std.heap.page_allocator.free(got);
    }

    const start = monoNs();
    for (0..cfg.n) |_| {
        const idx = rnd.uintLessThan(usize, cfg.n);
        const k = try fmtKey(&kbuf, idx);
        if (try db.get(k)) |got| std.heap.page_allocator.free(got);
    }
    const ns = monoNs() - start;
    const avg_us = @as(f64, @floatFromInt(ns)) / 1000.0 / @as(f64, @floatFromInt(cfg.n));

    var buf2: [200]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf2, "  {s:<12} get  {s:<5}  avg={d:>8.2}us\n", .{
        cfg.label, if (cfg.value_size == 100) "100B" else "10KB", avg_us,
    });
    try w.writeAll(line);
    try w.flush();
}

fn fileSize(path: []const u8) u64 {
    const f2c = @cImport({
        @cInclude("sys/stat.h");
    });
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return 0;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var st: f2c.struct_stat = undefined;
    _ = f2c.stat(@ptrCast(&buf), &st);
    return @intCast(st.st_size);
}

fn runLargeScale(path: []const u8, n: usize, fsync: bool, label: []const u8, w: *Io.Writer) !void {
    const allocator = std.heap.page_allocator;
    var vbuf: [100]u8 = undefined;
    @memset(&vbuf, 'x');

    // --- putBatch + fsync ---
    {
        unlinkPath(path);
        var fps = try FilePageStore.init(allocator, path);
        defer fps.deinit();
        var db = try Db.open(allocator, fps.store(), .{ .fsync = fsync });
        defer db.close();

        const entries = try allocator.alloc(Entry, n);
        defer allocator.free(entries);
        const keybufs = try allocator.alloc([12]u8, n);
        defer allocator.free(keybufs);
        for (entries, 0..) |*e, i| {
            const k = try fmtKey(&keybufs[i], i);
            e.* = .{ .key = k, .value = &vbuf };
        }

        const start = monoNs();
        try db.putBatch(entries);
        const ns = monoNs() - start;
        const avg_us = @as(f64, @floatFromInt(ns)) / 1000.0 / @as(f64, @floatFromInt(n));

        std.debug.print("  (entryCount={d}, next_free={d})\n", .{db.entryCount(), fps.next_free});
        var buf2: [300]u8 = undefined;
        const fsize = @as(u64, fps.next_free) * 4096;
        const line = try std.fmt.bufPrint(&buf2, "  {s:<12} putBatch {d:>7} keys  per-entry={d:>8.2}us  total={d:>8.2}ms  filesize={d:>8} bytes ({d:.1}MB)\n", .{
            label, n, avg_us, @as(f64, @floatFromInt(ns)) / 1e6, fsize, @as(f64, @floatFromInt(fsize)) / 1e6,
        });
        try w.writeAll(line);
        try w.flush();
    }

    // --- get (cold: reopen first, then warm) ---
    {
        var fps = try FilePageStore.init(allocator, path);
        defer fps.deinit();
        var db = try Db.open(allocator, fps.store(), .{});
        defer db.close();

        var prng = std.Random.DefaultPrng.init(42);
        const rnd = prng.random();
        var kbuf: [12]u8 = undefined;

        // Cold start: first 100 gets after reopen
        const cold_start = monoNs();
        for (0..@min(n, 100)) |_| {
            const idx = rnd.uintLessThan(usize, n);
            const k = try fmtKey(&kbuf, idx);
            if (try db.get(k)) |got| allocator.free(got);
        }
        const cold_ns = monoNs() - cold_start;

        // Warm get
        const warm_n = @min(n, 10000);
        const warm_start = monoNs();
        for (0..warm_n) |_| {
            const idx = rnd.uintLessThan(usize, n);
            const k = try fmtKey(&kbuf, idx);
            if (try db.get(k)) |got| allocator.free(got);
        }
        const warm_ns = monoNs() - warm_start;

        var buf2: [300]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf2, "  {s:<12} get     {d:>7} keys  cold-100={d:>8.2}us  warm-{d}={d:>8.2}us/op\n", .{
            label, n, @as(f64, @floatFromInt(cold_ns)) / 1000.0, warm_n, @as(f64, @floatFromInt(warm_ns)) / 1000.0 / @as(f64, @floatFromInt(warm_n)),
        });
        try w.writeAll(line);
        try w.flush();
    }

    unlinkPath(path);
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const w = &stdout_file_writer.interface;

    const n: usize = 10000;

    try w.writeAll("cube_db FilePageStore Benchmark\n");
    try w.writeAll("================================\n\n");

    // --- no-fsync (MDB_NOSYNC equivalent) ---
    {
        try w.writeAll("== FilePageStore + no-fsync (MDB_NOSYNC equivalent) ==\n");
        try w.flush();

        const path = ".bench_fps_nosync.db";
        defer unlinkPath(path);

        try runPut(path, .{ .fsync = false, .n = n, .value_size = 100, .label = "no-fsync" }, w);
        try runPutBatch(path, .{ .fsync = false, .n = n, .value_size = 100, .label = "no-fsync" }, w);

        // Reuse same path for get (data already written by put)
        try runGet(path, .{ .fsync = false, .n = n, .value_size = 100, .label = "no-fsync" }, w);

        try runPutBatchScan(path, false, "no-fsync", w);
    }

    try w.writeAll("\n");

    // --- fsync (LMDB default equivalent) ---
    {
        try w.writeAll("== FilePageStore + fsync (LMDB default equivalent) ==\n");
        try w.flush();

        const path = ".bench_fps_fsync.db";
        defer unlinkPath(path);

        try runPut(path, .{ .fsync = true, .n = n, .value_size = 100, .label = "fsync" }, w);
        try runPutBatch(path, .{ .fsync = true, .n = n, .value_size = 100, .label = "fsync" }, w);

        try runGet(path, .{ .fsync = true, .n = n, .value_size = 100, .label = "fsync" }, w);

        try runPutBatchScan(path, true, "fsync", w);
    }

    // --- large scale: 10k / 100k / 1M ---
    try w.writeAll("\n== Large Scale (FilePageStore + fsync) ==\n");
    try w.flush();

    for ([_]usize{ 10_000, 100_000, 1_000_000 }) |keys_n| {
        const path = ".bench_fps_large.db";
        try runLargeScale(path, keys_n, true, "fsync", w);
    }

    try w.writeAll("\nDone.\n");
    try w.flush();
}

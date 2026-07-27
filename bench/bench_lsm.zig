//! bench_lsm.zig — Quick benchmark: COW put vs LSM put latency.
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

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const w = &stdout_writer.interface;

    try w.writeAll("--- cube_db LSM vs COW latency benchmark ---\n");
    try w.writeAll("op         path     ops    avg_us/op\n");
    try w.writeAll("---------- -------- -----  ----------\n");

    // === COW path ===
    {
        var ms = MemPageStore.init(allocator, 1 << 16);
        defer ms.deinit();
        var db = try Db.open(allocator, ms.store(), .{});
        defer db.close();

        var kbuf: [12]u8 = undefined;
        for (0..100) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i});
            try db.put(k, "x");
        }
        const start = monoNs();
        for (0..N) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i});
            try db.put(k, "x");
        }
        const ns = monoNs() - start;
        const avg_us = @as(f64, @floatFromInt(ns)) / 1000.0 / N;
        try w.print("put        COW      {d:>5}  {d:>8.1}\n", .{ N, avg_us });
    }

    // === LSM path (memtable + WAL, no compactor) ===
    {
        var ms = MemPageStore.init(allocator, 1 << 16);
        defer ms.deinit();
        var db = try Db.open(allocator, ms.store(), .{});
        defer db.close();

        var mt = Memtable.init(allocator, 1024 * 1024);
        defer mt.deinit();

        const wal_path = ".bench_lsm_wal";
        defer zio.Dir.cwd().deleteFile(wal_path) catch {};
        var wal = try Wal.init(allocator, wal_path);
        defer wal.deinit();

        db.mt = &mt;
        db.wal = &wal;

        var kbuf: [12]u8 = undefined;
        for (0..100) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i});
            try db.put(k, "x");
        }
        const start = monoNs();
        for (0..N) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i});
            try db.put(k, "x");
        }
        const ns = monoNs() - start;
        const avg_us = @as(f64, @floatFromInt(ns)) / 1000.0 / N;
        try w.print("put        LSM      {d:>5}  {d:>8.1}\n", .{ N, avg_us });
    }

    // === LSM get (memtable hit) ===
    {
        var ms = MemPageStore.init(allocator, 1 << 16);
        defer ms.deinit();
        var db = try Db.open(allocator, ms.store(), .{});
        defer db.close();

        var mt = Memtable.init(allocator, 1024 * 1024);
        defer mt.deinit();
        db.mt = &mt;

        var kbuf: [12]u8 = undefined;
        for (0..N) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i});
            _ = try mt.put(k, "x");
        }

        var prng = std.Random.DefaultPrng.init(0x42);
        const rnd = prng.random();
        for (0..100) |_| {
            const idx = rnd.uintLessThan(usize, N);
            const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{idx});
            if (try db.get(k)) |v| allocator.free(v);
        }
        const start = monoNs();
        for (0..N) |_| {
            const idx = rnd.uintLessThan(usize, N);
            const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{idx});
            if (try db.get(k)) |v| allocator.free(v);
        }
        const ns = monoNs() - start;
        const avg_us = @as(f64, @floatFromInt(ns)) / 1000.0 / N;
        try w.print("get        LSM      {d:>5}  {d:>8.1}\n", .{ N, avg_us });
    }

    try w.writeAll("------------------------------------------\n");
    try w.flush();
}
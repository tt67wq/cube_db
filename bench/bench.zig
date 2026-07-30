//! bench.zig — cube_db v2 基准矩阵 runner
//! 运行：zig build bench -Doptimize=ReleaseFast
//! 20 格 = 5 op × 2 scale × 2 value。计时 monoNs。
//! 使用 MemPageStore（内存），测量算法吞吐。
const std = @import("std");
const Io = std.Io;
const zio = @import("zio");
const cube = @import("cube_db");
const Db = cube.Db;
const Entry = cube.Entry;
const MemPageStore = cube.page_store.MemPageStore;

const SEED: u64 = 0x42;
const bopts = @import("bench_opts");

fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

fn fmtKey(buf: *[12]u8, i: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d:0>10}", .{i});
}

fn warmupCount(n: usize) usize {
    return @min(n / 100, 1000);
}

const Scale = enum { small, large };
const Op = enum { put, putbatch, get, delete, select, compact };
const VSize = enum { b100, b10k };

const Cell = struct { op: Op, scale: Scale, v: VSize };

const Result = struct {
    op: Op,
    scale: Scale,
    v: VSize,
    ops: u64,
    elapsed_ns: i64,
};

fn keysFor(scale: Scale, v: VSize) usize {
    return switch (scale) {
        .small => 10_000,
        .large => if (v == .b100) 1_000_000 else 100_000,
    };
}

fn mapsizeFor(scale: Scale, v: VSize) u32 {
    // 足够容纳所有 key 的页数（含溢出页）
    const n = keysFor(scale, v);
    const overflow_pages: u32 = if (v == .b10k) 3 else 0; // 10KB ≈ 3 overflow pages
    return @as(u32, @intCast(cube.page_store.FIRST_DATA_PAGE + n * (1 + overflow_pages) + 10000));
}

fn runPut(allocator: std.mem.Allocator, cell: Cell, n: usize, value: []const u8) !Result {
    var ms = MemPageStore.init(allocator, mapsizeFor(cell.scale, cell.v));
    defer ms.deinit();
    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();
    var kbuf: [12]u8 = undefined;
    const wu = warmupCount(n);
    for (0..wu) |i| {
        const k = try fmtKey(&kbuf, i);
        try db.put(k, value);
    }
    const start = monoNs();
    for (0..n) |i| {
        const k = try fmtKey(&kbuf, i);
        try db.put(k, value);
    }
    const ns = monoNs() - start;
    return .{ .op = cell.op, .scale = cell.scale, .v = cell.v, .ops = n, .elapsed_ns = ns };
}

fn runPutBatch(allocator: std.mem.Allocator, cell: Cell, n: usize, value: []const u8) !Result {
    var ms = MemPageStore.init(allocator, mapsizeFor(cell.scale, cell.v));
    defer ms.deinit();
    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();
    const entries = try allocator.alloc(Entry, n);
    defer allocator.free(entries);
    var kbuf: [12]u8 = undefined;
    for (0..n) |i| {
        const k = try fmtKey(&kbuf, i);
        entries[i] = .{ .key = k, .value = value };
    }
    const wu = warmupCount(n);
    if (wu > 0) {
        const we = try allocator.alloc(Entry, wu);
        defer allocator.free(we);
        for (0..wu) |i| {
            const k = try fmtKey(&kbuf, i);
            we[i] = .{ .key = k, .value = value };
        }
        try db.putBatch(we);
    }
    const start = monoNs();
    try db.putBatch(entries);
    const ns = monoNs() - start;
    return .{ .op = cell.op, .scale = cell.scale, .v = cell.v, .ops = n, .elapsed_ns = ns };
}

fn runGet(allocator: std.mem.Allocator, cell: Cell, n: usize, value: []const u8) !Result {
    var ms = MemPageStore.init(allocator, mapsizeFor(cell.scale, cell.v));
    defer ms.deinit();
    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();
    // 预载
    var kbuf: [12]u8 = undefined;
    for (0..n) |i| {
        const k = try fmtKey(&kbuf, i);
        try db.put(k, value);
    }
    var prng = std.Random.DefaultPrng.init(SEED);
    const rnd = prng.random();
    const wu = warmupCount(n);
    for (0..wu) |_| {
        const idx = rnd.uintLessThan(usize, n);
        const k = try fmtKey(&kbuf, idx);
        if (try db.get(k)) |got| allocator.free(got);
    }
    const start = monoNs();
    for (0..n) |_| {
        const idx = rnd.uintLessThan(usize, n);
        const k = try fmtKey(&kbuf, idx);
        if (try db.get(k)) |got| allocator.free(got);
    }
    const ns = monoNs() - start;
    return .{ .op = cell.op, .scale = cell.scale, .v = cell.v, .ops = n, .elapsed_ns = ns };
}

fn runDelete(allocator: std.mem.Allocator, cell: Cell, n: usize, value: []const u8) !Result {
    var ms = MemPageStore.init(allocator, mapsizeFor(cell.scale, cell.v));
    defer ms.deinit();
    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();
    var kbuf: [12]u8 = undefined;
    for (0..n) |i| {
        const k = try fmtKey(&kbuf, i);
        try db.put(k, value);
    }
    const perm = try allocator.alloc(u32, n);
    defer allocator.free(perm);
    for (perm, 0..) |*p, i| p.* = @intCast(i);
    var prng = std.Random.DefaultPrng.init(SEED);
    const rnd = prng.random();
    var i: usize = n;
    while (i > 1) {
        i -= 1;
        const j = rnd.uintLessThan(usize, i + 1);
        const t = perm[i];
        perm[i] = perm[j];
        perm[j] = t;
    }
    const start = monoNs();
    for (perm) |idx| {
        const k = try fmtKey(&kbuf, idx);
        try db.delete(k);
    }
    const ns = monoNs() - start;
    const k0 = try fmtKey(&kbuf, perm[0]);
    if (try db.get(k0)) |got| {
        allocator.free(got);
        return error.UnexpectedKeyAfterDelete;
    }
    return .{ .op = cell.op, .scale = cell.scale, .v = cell.v, .ops = n, .elapsed_ns = ns };
}

fn runSelect(allocator: std.mem.Allocator, cell: Cell, n: usize, value: []const u8) !Result {
    var ms = MemPageStore.init(allocator, mapsizeFor(cell.scale, cell.v));
    defer ms.deinit();
    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();
    var kbuf: [12]u8 = undefined;
    for (0..n) |i| {
        const k = try fmtKey(&kbuf, i);
        try db.put(k, value);
    }
    const r = n / 100;
    var prng = std.Random.DefaultPrng.init(SEED);
    const rnd = prng.random();
    var kmin: [12]u8 = undefined;
    var kmax: [12]u8 = undefined;
    const wu = warmupCount(r);
    for (0..wu) |_| {
        const s = rnd.uintLessThan(usize, n - 100 + 1);
        const mn = try fmtKey(&kmin, s);
        const mx = try fmtKey(&kmax, s + 100);
        var it = try db.select(mn, mx);
        defer it.deinit();
        while (try it.next()) |_| {}
    }
    const start = monoNs();
    for (0..r) |_| {
        const s = rnd.uintLessThan(usize, n - 100 + 1);
        const mn = try fmtKey(&kmin, s);
        const mx = try fmtKey(&kmax, s + 100);
        var it = try db.select(mn, mx);
        defer it.deinit();
        while (try it.next()) |_| {}
    }
    const ns = monoNs() - start;
    return .{ .op = cell.op, .scale = cell.scale, .v = cell.v, .ops = r, .elapsed_ns = ns };
}

fn runCompact(allocator: std.mem.Allocator, cell: Cell, n: usize, value: []const u8) !Result {
    var ms = MemPageStore.init(allocator, mapsizeFor(cell.scale, cell.v));
    defer ms.deinit();
    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();
    var kbuf: [12]u8 = undefined;
    for (0..n) |i| {
        const k = try fmtKey(&kbuf, i);
        try db.put(k, value);
    }
    var j: usize = 0;
    while (j < 4 * n) : (j += 1) {
        const k = try fmtKey(&kbuf, j % n);
        try db.put(k, value);
    }
    const start = monoNs();
    try db.compact();
    const ns = monoNs() - start;
    return .{ .op = cell.op, .scale = cell.scale, .v = cell.v, .ops = 1, .elapsed_ns = ns };
}

fn opName(op: Op) []const u8 {
    return switch (op) { .put => "put", .putbatch => "putbatch", .get => "get", .delete => "delete", .select => "select", .compact => "compact" };
}
fn scaleName(s: Scale) []const u8 {
    return switch (s) { .small => "small", .large => "large" };
}
fn vName(v: VSize) []const u8 {
    return switch (v) { .b100 => "100B", .b10k => "10KB" };
}

fn printRow(w: *Io.Writer, r: Result) !void {
    const elapsed_ms = @as(f64, @floatFromInt(r.elapsed_ns)) / 1_000_000.0;
    const sec = @as(f64, @floatFromInt(r.elapsed_ns)) / 1_000_000_000.0;
    const ops_f = @as(f64, @floatFromInt(r.ops));
    var buf: [160]u8 = undefined;
    if (r.op == .compact) {
        const line = try std.fmt.bufPrint(&buf, "{s:<7} {s:<6} {s:<5} {d:>12} {d:>12.1} {s:>12} {d:>12.2}\n", .{
            opName(r.op), scaleName(r.scale), vName(r.v), r.ops, elapsed_ms, @as([]const u8, "-"), elapsed_ms * 1000.0,
        });
        try w.writeAll(line);
    } else {
        const ops_s = ops_f / sec;
        const avg_us = (@as(f64, @floatFromInt(r.elapsed_ns)) / 1000.0) / ops_f;
        const line = try std.fmt.bufPrint(&buf, "{s:<7} {s:<6} {s:<5} {d:>12} {d:>12.1} {d:>12.0} {d:>12.2}\n", .{
            opName(r.op), scaleName(r.scale), vName(r.v), r.ops, elapsed_ms, ops_s, avg_us,
        });
        try w.writeAll(line);
    }
    try w.flush();
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    var v100: [100]u8 = undefined;
    var v10k: [10000]u8 = undefined;
    @memset(&v100, 'x');
    @memset(&v10k, 'x');

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const w = &stdout_file_writer.interface;

    try w.writeAll("op      scale  value  ops          time_ms      ops/s        avg_us/op\n");
    try w.flush();

    const ops = [_]Op{ .put, .putbatch, .get, .delete, .select, .compact };
    const scales = [_]Scale{ .small, .large };
    const vsizes = [_]VSize{ .b100, .b10k };

    var last_err: ?anyerror = null;
    for (ops) |op| {
        for (scales) |scale| {
            for (vsizes) |v| {
                if (std.mem.eql(u8, bopts.scale_filter, "small") and scale == .large) continue;
                if (std.mem.eql(u8, bopts.scale_filter, "large") and scale == .small) continue;
                const cell = Cell{ .op = op, .scale = scale, .v = v };
                const n = keysFor(scale, v);
                const value: []const u8 = if (v == .b100) &v100 else &v10k;
                const result = switch (op) {
                    .put => runPut(allocator, cell, n, value) catch |e| { last_err = e; continue; },
                    .putbatch => runPutBatch(allocator, cell, n, value) catch |e| { last_err = e; continue; },
                    .get => runGet(allocator, cell, n, value) catch |e| { last_err = e; continue; },
                    .delete => runDelete(allocator, cell, n, value) catch |e| { last_err = e; continue; },
                    .select => runSelect(allocator, cell, n, value) catch |e| { last_err = e; continue; },
                    .compact => runCompact(allocator, cell, n, value) catch |e| { last_err = e; continue; },
                };
                try printRow(w, result);
            }
        }
    }
    if (last_err) |e| {
        var ebuf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&ebuf, "bench: at least one cell failed: {s}\n", .{@errorName(e)});
        try w.writeAll(msg);
        try w.flush();
        return e;
    }
}
//! bench/profile_fps.zig — #41: FPS write-path counter profiling
//! Usage: zig build profile-fps -Doptimize=ReleaseFast
//! Counts writePage/allocPage/freePage/readPage/fstat/ftruncate calls + timings
const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const Entry = cube.Entry;
const FilePageStore = cube.file_page_store.FilePageStore;
const FpsCounters = cube.file_page_store.FpsCounters;

fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

const c = @cImport({
    @cInclude("unistd.h");
});

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

/// Build entries: contiguous key buffer + shared value (matching the MemPageStore comparison)
fn buildEntries(allocator: std.mem.Allocator, n: usize) !struct { entries: []Entry, key_buf: []u8 } {
    const entries = try allocator.alloc(Entry, n);
    errdefer allocator.free(entries);
    const key_buf = try allocator.alloc(u8, n * 10);
    errdefer allocator.free(key_buf);
    var v100: [100]u8 = undefined;
    @memset(&v100, 'x');
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(key_buf[i * 10 ..][0..10], "{d:0>10}", .{i});
        entries[i] = .{ .key = k, .value = &v100 };
    }
    return .{ .entries = entries, .key_buf = key_buf };
}

/// Build entries: scattered keys (each allocPrint on its own page, mimicking rigor's pb_fps_ordered_test)
fn buildEntriesScattered(allocator: std.mem.Allocator, n: usize) ![]Entry {
    const entries = try allocator.alloc(Entry, n);
    errdefer allocator.free(entries);
    var v100: [100]u8 = undefined;
    @memset(&v100, 'x');
    for (0..n) |i| {
        entries[i] = .{ .key = try std.fmt.allocPrint(allocator, "{d:0>10}", .{i}), .value = &v100 };
    }
    return entries;
}

fn runScale(allocator: std.mem.Allocator, n: usize, label: []const u8, fsync: bool) !void {
    const path = ".profile_fps.db";
    unlinkPath(path);
    defer unlinkPath(path);

    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    var db = try Db.open(allocator, fps.store(), .{ .fsync = fsync });
    defer db.close();

    const built = try buildEntries(allocator, n);
    defer allocator.free(built.entries);
    defer allocator.free(built.key_buf);

    FpsCounters.reset();
    FpsCounters.enable = true;
    defer FpsCounters.enable = false;

    const t0 = monoNs();
    try db.putBatch(built.entries);
    const elapsed = monoNs() - t0;

    const per_entry = @divFloor(elapsed, @as(i64, @intCast(n)));
    std.debug.print("\n=== {s}: N={d} fsync={} total {d} ms, {d} ns/entry ===\n", .{ label, n, fsync, @divFloor(elapsed, 1_000_000), per_entry });
    std.debug.print("entryCount = {d}\n", .{db.entryCount()});

    std.debug.print("--- FPS counters ---\n", .{});
    std.debug.print("  writePage:  {d} calls ({d:.1} ms, {d} ns/call)\n", .{ FpsCounters.write_page_calls, @as(f64, @floatFromInt(FpsCounters.write_page_ns)) / 1e6, if (FpsCounters.write_page_calls > 0) @divFloor(FpsCounters.write_page_ns, FpsCounters.write_page_calls) else 0 });
    std.debug.print("  allocPage:  {d} calls ({d:.1} ms, {d} ns/call)\n", .{ FpsCounters.alloc_page_calls, @as(f64, @floatFromInt(FpsCounters.alloc_page_ns)) / 1e6, if (FpsCounters.alloc_page_calls > 0) @divFloor(FpsCounters.alloc_page_ns, FpsCounters.alloc_page_calls) else 0 });
    std.debug.print("  freePage:   {d} calls\n", .{FpsCounters.free_page_calls});
    std.debug.print("  readPage:   {d} calls\n", .{FpsCounters.read_page_calls});
    std.debug.print("  fstat:      {d} calls\n", .{FpsCounters.fstat_calls});
    std.debug.print("  ftruncate:  {d} calls\n", .{FpsCounters.ftruncate_calls});
    std.debug.print("  ensureGrowth total: {d:.1} ms\n", .{@as(f64, @floatFromInt(FpsCounters.ensure_growth_ns)) / 1e6});
    std.debug.print("  writePage+allocPage total: {d:.1} ms ({d:.1}% of total {d} ms)\n", .{
        (@as(f64, @floatFromInt(FpsCounters.write_page_ns)) + @as(f64, @floatFromInt(FpsCounters.alloc_page_ns))) / 1e6,
        (@as(f64, @floatFromInt(FpsCounters.write_page_ns)) + @as(f64, @floatFromInt(FpsCounters.alloc_page_ns))) / @as(f64, @floatFromInt(elapsed)) * 100.0,
        @as(f64, @floatFromInt(elapsed)) / 1e6,
    });

    // Estimated page count: LEAF_MAX_ENTRIES=32 -> n/32 leaves + branches
    const est_leaf = n / 32;
    std.debug.print("  Estimated leaf pages: {d} (n/32)\n", .{est_leaf});
    std.debug.print("  Store calls per entry: {d:.3} (writePage+allocPage)/entry\n", .{
        (@as(f64, @floatFromInt(FpsCounters.write_page_calls)) + @as(f64, @floatFromInt(FpsCounters.alloc_page_calls))) / @as(f64, @floatFromInt(n)),
    });
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    // 1M ordered, fsync=false (aligned with rigor's nosync 16.9us)
    try runScale(alloc, 1_000_000, "1M ordered nosync", false);

    // 100K ordered (superlinear comparison point)
    try runScale(alloc, 100_000, "100K ordered nosync", false);

    // 10K ordered (smallest-scale comparison)
    try runScale(alloc, 10_000, "10K ordered nosync", false);

    // Scattered-key variant (rigor's pb_fps_ordered_test layout) 1M

    try runScaleScattered(alloc, 1_000_000, "1M scattered nosync", false);
}

fn runScaleScattered(allocator: std.mem.Allocator, n: usize, label: []const u8, fsync: bool) !void {
    const path = ".profile_fps_scat.db";
    unlinkPath(path);
    defer unlinkPath(path);

    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    var db = try Db.open(allocator, fps.store(), .{ .fsync = fsync });
    defer db.close();

    const entries = try buildEntriesScattered(allocator, n);
    defer {
        for (entries) |e| allocator.free(e.key);
        allocator.free(entries);
    }

    FpsCounters.reset();
    FpsCounters.enable = true;
    defer FpsCounters.enable = false;

    const t0 = monoNs();
    try db.putBatch(entries);
    const elapsed = monoNs() - t0;

    const per_entry = @divFloor(elapsed, @as(i64, @intCast(n)));
    std.debug.print("\n=== {s}: N={d} fsync={} total {d} ms, {d} ns/entry ===\n", .{ label, n, fsync, @divFloor(elapsed, 1_000_000), per_entry });
    std.debug.print("entryCount = {d}\n", .{db.entryCount()});

    std.debug.print("--- FPS counters ---\n", .{});
    std.debug.print("  writePage:  {d} calls ({d:.1} ms, {d} ns/call)\n", .{ FpsCounters.write_page_calls, @as(f64, @floatFromInt(FpsCounters.write_page_ns)) / 1e6, if (FpsCounters.write_page_calls > 0) @divFloor(FpsCounters.write_page_ns, FpsCounters.write_page_calls) else 0 });
    std.debug.print("  allocPage:  {d} calls ({d:.1} ms, {d} ns/call)\n", .{ FpsCounters.alloc_page_calls, @as(f64, @floatFromInt(FpsCounters.alloc_page_ns)) / 1e6, if (FpsCounters.alloc_page_calls > 0) @divFloor(FpsCounters.alloc_page_ns, FpsCounters.alloc_page_calls) else 0 });
    std.debug.print("  fstat:      {d} calls\n", .{FpsCounters.fstat_calls});
    std.debug.print("  ftruncate:  {d} calls\n", .{FpsCounters.ftruncate_calls});
    std.debug.print("  writePage+allocPage total: {d:.1} ms ({d:.1}% of total {d} ms)\n", .{
        (@as(f64, @floatFromInt(FpsCounters.write_page_ns)) + @as(f64, @floatFromInt(FpsCounters.alloc_page_ns))) / 1e6,
        (@as(f64, @floatFromInt(FpsCounters.write_page_ns)) + @as(f64, @floatFromInt(FpsCounters.alloc_page_ns))) / @as(f64, @floatFromInt(elapsed)) * 100.0,
        @as(f64, @floatFromInt(elapsed)) / 1e6,
    });
}

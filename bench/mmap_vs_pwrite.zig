//! bench/mmap_vs_pwrite.zig — discriminating experiment: mmap MAP_SHARED vs pwrite, 100MB sequential writes
//! Goal: identify the bottleneck behind FPS 1M putBatch at 16.9us/entry
//!   - if mmap is 10x+ slower than pwrite -> mmap fault/writeback mechanism
//!   - if they are comparable -> the problem is cube_db's writePage call pattern (per-page fstat/ftruncate etc.)
//! Usage: zig build run-mmap-vs-pwrite -Doptimize=ReleaseFast
//!   or: zig build-exe bench/mmap_vs_pwrite.zig -O ReleaseFast && ./mmap_vs_pwrite
const std = @import("std");
const c = @cImport({
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const PAGE_SIZE: usize = 4096;
const TOTAL_MB: usize = 100;
const TOTAL_BYTES: usize = TOTAL_MB * 1024 * 1024;
const N_PAGES: usize = TOTAL_BYTES / PAGE_SIZE;

fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

fn openFile(path: []const u8) !c_int {
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    const fd = c.open(path_z, @as(c_int, c.O_RDWR | c.O_CREAT), @as(c.mode_t, 0o644));
    if (fd < 0) return error.OpenFailed;
    return fd;
}

/// Experiment 1: mmap MAP_SHARED + sequential memcpy writing 100MB (4KB pages, mimicking writePage)
fn runMmapShared(fd: c_int, label: []const u8) !i64 {
    const ptr = c.mmap(null, TOTAL_BYTES, @as(c_int, c.PROT_READ) | @as(c_int, c.PROT_WRITE), @as(c_int, c.MAP_SHARED), fd, 0);
    if (ptr == c.MAP_FAILED) return error.MapFailed;
    defer _ = c.munmap(@ptrCast(ptr), TOTAL_BYTES);

    const buf = @as([*]u8, @ptrCast(ptr));
    const start = monoNs();
    var x: u8 = 0;
    for (0..N_PAGES) |p| {
        const dst = buf[p * PAGE_SIZE ..][0..PAGE_SIZE];
        @memset(dst, x);
        x +%= 1;
    }
    const elapsed = monoNs() - start;
    std.debug.print("  {s}: {d} ms ({d:.2} MB/s)  [{d} pages]\n", .{
        label,
        @divFloor(elapsed, 1_000_000),
        @as(f64, @floatFromInt(TOTAL_BYTES)) / (@as(f64, @floatFromInt(elapsed)) / 1e9) / 1e6,
        N_PAGES,
    });
    return elapsed;
}

/// Experiment 2: pwrite sequential 100MB (4KB at a time, the syscall version of writePage)
fn runPwrite(fd: c_int, label: []const u8) !i64 {
    var buf: [PAGE_SIZE]u8 = undefined;
    var x: u8 = 0;
    const start = monoNs();
    for (0..N_PAGES) |p| {
        @memset(&buf, x);
        x +%= 1;
        const n = c.pwrite(fd, &buf, PAGE_SIZE, @as(c.off_t, @intCast(p * PAGE_SIZE)));
        if (n != PAGE_SIZE) return error.PwriteFailed;
    }
    const elapsed = monoNs() - start;
    std.debug.print("  {s}: {d} ms ({d:.2} MB/s)  [{d} syscalls]\n", .{
        label,
        @divFloor(elapsed, 1_000_000),
        @as(f64, @floatFromInt(TOTAL_BYTES)) / (@as(f64, @floatFromInt(elapsed)) / 1e9) / 1e6,
        N_PAGES,
    });
    return elapsed;
}

/// Experiment 3: pwrite large chunks (1MB at a time, to contrast with 4KB small writes)
fn runPwriteBig(fd: c_int, label: []const u8) !i64 {
    const buf = try std.heap.page_allocator.alloc(u8, 1024 * 1024);
    defer std.heap.page_allocator.free(buf);
    const big = 1024 * 1024;
    const n_big = TOTAL_BYTES / big;
    var x: u8 = 0;
    const start = monoNs();
    for (0..n_big) |i| {
        @memset(buf, x);
        x +%= 1;
        const n = c.pwrite(fd, buf.ptr, big, @as(c.off_t, @intCast(i * big)));
        if (n != big) return error.PwriteFailed;
    }
    const elapsed = monoNs() - start;
    std.debug.print("  {s}: {d} ms ({d:.2} MB/s)  [{d} syscalls]\n", .{
        label,
        @divFloor(elapsed, 1_000_000),
        @as(f64, @floatFromInt(TOTAL_BYTES)) / (@as(f64, @floatFromInt(elapsed)) / 1e9) / 1e6,
        n_big,
    });
    return elapsed;
}

/// Experiment 4: mmap MAP_SHARED + ftruncate growth first (mimicking ensureFileGrowth's sparse-growth pattern)
fn runMmapSparse(fd: c_int, label: []const u8) !i64 {
    // Mimic cube_db: ftruncate to cover each page before writing it (sparse growth)
    var x: u8 = 0;
    const start = monoNs();
    for (0..N_PAGES) |p| {
        const needed: u64 = (@as(u64, p) + 1) * PAGE_SIZE;
        if (c.ftruncate(fd, @as(c.off_t, @intCast(needed))) != 0) return error.TruncateFailed;
        const ptr = c.mmap(null, PAGE_SIZE, @as(c_int, c.PROT_READ) | @as(c_int, c.PROT_WRITE), @as(c_int, c.MAP_SHARED), fd, @as(c.off_t, @intCast(p * PAGE_SIZE)));
        if (ptr == c.MAP_FAILED) return error.MapFailed;
        const dst = @as([*]u8, @ptrCast(ptr))[0..PAGE_SIZE];
        @memset(dst, x);
        x +%= 1;
        _ = c.munmap(@ptrCast(ptr), PAGE_SIZE);
    }
    const elapsed = monoNs() - start;
    std.debug.print("  {s}: {d} ms ({d:.2} MB/s)  [{d} ftruncate+mmap+write+munmap]\n", .{
        label,
        @divFloor(elapsed, 1_000_000),
        @as(f64, @floatFromInt(TOTAL_BYTES)) / (@as(f64, @floatFromInt(elapsed)) / 1e9) / 1e6,
        N_PAGES,
    });
    return elapsed;
}

/// Experiment 5: exact cube_db pattern — one 1TB reserved mmap + per-page ftruncate growth + writes
/// (call pattern identical to FilePageStore: allocPage->ensureFileGrowth->writePage->ensureFileGrowth)
fn runCubeDbPattern(fd: c_int, label: []const u8) !i64 {
    const REGION: usize = 1 << 40; // 1TB virtual reservation
    const ptr = c.mmap(null, REGION, @as(c_int, c.PROT_READ) | @as(c_int, c.PROT_WRITE), @as(c_int, c.MAP_SHARED), fd, 0);
    if (ptr == c.MAP_FAILED) return error.MapFailed;
    defer _ = c.munmap(@ptrCast(ptr), REGION);
    const buf = @as([*]u8, @ptrCast(ptr));

    const N = N_PAGES; // 25600 pages
    var x: u8 = 0;
    const start = monoNs();
    var ftruncate_count: u64 = 0;
    var fstat_count: u64 = 0;
    for (0..N) |p| {
        // --- allocPage: ensureFileGrowth(p) [fstat + possible ftruncate] ---
        var st: c.struct_stat = undefined;
        if (c.fstat(fd, &st) != 0) return error.FstatFailed;
        fstat_count += 1;
        const needed: u64 = (@as(u64, p) + 1) * PAGE_SIZE;
        if (@as(u64, @intCast(st.st_size)) < needed) {
            if (c.ftruncate(fd, @as(c.off_t, @intCast(needed))) != 0) return error.TruncateFailed;
            ftruncate_count += 1;
        }
        // --- writePage: ensureFileGrowth(p) [fstat] ---
        if (c.fstat(fd, &st) != 0) return error.FstatFailed;
        fstat_count += 1;
        // --- write the page ---
        const dst = buf[p * PAGE_SIZE ..][0..PAGE_SIZE];
        @memset(dst, x);
        x +%= 1;
    }
    const elapsed = monoNs() - start;
    std.debug.print("  {s}: {d} ms ({d:.2} MB/s)  [{d} pages, {d} ftruncate, {d} fstat]\n", .{
        label,
        @divFloor(elapsed, 1_000_000),
        @as(f64, @floatFromInt(TOTAL_BYTES)) / (@as(f64, @floatFromInt(elapsed)) / 1e9) / 1e6,
        N,
        ftruncate_count,
        fstat_count,
    });
    return elapsed;
}

pub fn main() !void {
    std.debug.print("=== Discriminating experiment: sequential 100MB writes ({d} MB) ===\n", .{TOTAL_MB});
    std.debug.print("Machine: {s}\n", .{@tagName(@import("builtin").cpu.arch)});

    const path1 = ".exp_mmap.db";
    const path2 = ".exp_pwrite.db";
    const path3 = ".exp_pwrite_big.db";
    const path4 = ".exp_sparse.db";

    // Experiment 1: mmap MAP_SHARED (one-shot 100MB reservation)
    {
        unlinkPath(path1);
        const fd = try openFile(path1);
        defer _ = c.close(fd);
        defer unlinkPath(path1);
        // ftruncate to 100MB (one shot)
        if (c.ftruncate(fd, @as(c.off_t, @intCast(TOTAL_BYTES))) != 0) return error.TruncateFailed;
        const t1 = try runMmapShared(fd, "mmap MAP_SHARED whole-region + sequential 4KB writes");
        const t2 = try runMmapShared(fd, "mmap MAP_SHARED second pass (pages already faulted)");
        std.debug.print("  first vs second (cached) difference: {d:.1}x\n", .{@as(f64, @floatFromInt(t1)) / @as(f64, @floatFromInt(t2))});
    }

    // Experiment 2: pwrite 4KB
    {
        unlinkPath(path2);
        const fd = try openFile(path2);
        defer _ = c.close(fd);
        defer unlinkPath(path2);
        if (c.ftruncate(fd, @as(c.off_t, @intCast(TOTAL_BYTES))) != 0) return error.TruncateFailed;
        _ = try runPwrite(fd, "pwrite 4KB×25600");
    }

    // Experiment 3: pwrite 1MB chunks
    {
        unlinkPath(path3);
        const fd = try openFile(path3);
        defer _ = c.close(fd);
        defer unlinkPath(path3);
        if (c.ftruncate(fd, @as(c.off_t, @intCast(TOTAL_BYTES))) != 0) return error.TruncateFailed;
        _ = try runPwriteBig(fd, "pwrite 1MB×100");
    }

    // Experiment 4: cube_db's sparse-growth pattern (per-page ftruncate + mmap + write)
    // Note: per-page 4KB mmap may be limited on macOS; this experiment is
    // informational only — its failure does not affect the 1/2/3 discrimination
    {
        unlinkPath(path4);
        const fd = try openFile(path4);
        defer _ = c.close(fd);
        defer unlinkPath(path4);
        _ = runMmapSparse(fd, "sparse growth 4KB ftruncate+mmap+write+munmap x25600") catch |e| blk: {
            std.debug.print("  [sparse experiment failed: {s} — macOS 4KB mmap limit, skipped (core discrimination unaffected)]\n", .{@errorName(e)});
            break :blk 0;
        };
    }

    // Experiment 5: exact cube_db pattern (1TB reserved mmap + per-page ftruncate growth + writes)
    {
        const path5 = ".exp_cubedb.db";
        unlinkPath(path5);
        const fd = try openFile(path5);
        defer _ = c.close(fd);
        defer unlinkPath(path5);
        // Initial 3 pages (mimicking FIRST_DATA_PAGE)
        if (c.ftruncate(fd, @as(c.off_t, @intCast(3 * PAGE_SIZE))) != 0) return error.TruncateFailed;
        _ = try runCubeDbPattern(fd, "cube_db pattern: 1TB reservation + per-page ftruncate + writes x25600");

    }
}

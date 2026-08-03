//! bench/mmap_vs_pwrite.zig — Archon 判别式实验：mmap MAP_SHARED vs pwrite 顺序写 100MB
//! 目的：判别 FPS 1M putBatch 16.9µs/entry 的瓶颈机制
//!   - 如果 mmap 比 pwrite 慢 10x+ → mmap fault/回写机制问题
//!   - 如果两者相当 → 问题在 cube_db 的 writePage 调用模式（per-page fstat/ftruncate 等）
//! 用法：zig build run-mmap-vs-pwrite -Doptimize=ReleaseFast
//!   或：zig build-exe bench/mmap_vs_pwrite.zig -O ReleaseFast && ./mmap_vs_pwrite
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

/// 实验 1：mmap MAP_SHARED + 顺序 memcpy 写 100MB（每次 4KB 页，模拟 writePage）
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

/// 实验 2：pwrite 顺序写 100MB（每次 4KB，模拟 writePage 的 syscall 版本）
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

/// 实验 3：pwrite 大块写（每次 1MB，对比 4KB 小写的影响）
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

/// 实验 4：mmap MAP_SHARED + 先 ftruncate 扩展（模拟 ensureFileGrowth 的稀疏扩展模式）
fn runMmapSparse(fd: c_int, label: []const u8) !i64 {
    // 模拟 cube_db：每页写前 ftruncate 到覆盖该页（稀疏增长）
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

/// 实验 5：精确模拟 cube_db 模式 — mmap 一次 1TB 预留 + 逐页 ftruncate 增长 + 写
/// （与 FilePageStore 完全一致的调用模式：allocPage→ensureFileGrowth→writePage→ensureFileGrowth）
fn runCubeDbPattern(fd: c_int, label: []const u8) !i64 {
    const REGION: usize = 1 << 40; // 1TB 虚拟预留
    const ptr = c.mmap(null, REGION, @as(c_int, c.PROT_READ) | @as(c_int, c.PROT_WRITE), @as(c_int, c.MAP_SHARED), fd, 0);
    if (ptr == c.MAP_FAILED) return error.MapFailed;
    defer _ = c.munmap(@ptrCast(ptr), REGION);
    const buf = @as([*]u8, @ptrCast(ptr));

    const N = N_PAGES; // 25600 页
    var x: u8 = 0;
    const start = monoNs();
    var ftruncate_count: u64 = 0;
    var fstat_count: u64 = 0;
    for (0..N) |p| {
        // --- allocPage: ensureFileGrowth(p) [fstat + 可能 ftruncate] ---
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
        // --- 写页 ---
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
    std.debug.print("=== 判别式实验：顺序写 100MB（{d} MB）===\n", .{TOTAL_MB});
    std.debug.print("机器: {s}\n", .{@tagName(@import("builtin").cpu.arch)});

    const path1 = ".exp_mmap.db";
    const path2 = ".exp_pwrite.db";
    const path3 = ".exp_pwrite_big.db";
    const path4 = ".exp_sparse.db";

    // 实验 1: mmap MAP_SHARED（一次性 100MB 预留）
    {
        unlinkPath(path1);
        const fd = try openFile(path1);
        defer _ = c.close(fd);
        defer unlinkPath(path1);
        // ftruncate 到 100MB（一次性）
        if (c.ftruncate(fd, @as(c.off_t, @intCast(TOTAL_BYTES))) != 0) return error.TruncateFailed;
        const t1 = try runMmapShared(fd, "mmap MAP_SHARED 整区+顺序4KB写");
        const t2 = try runMmapShared(fd, "mmap MAP_SHARED 第二次(页已fault)");
        std.debug.print("  首次 vs 二次(缓存) 差异: {d:.1}x\n", .{@as(f64, @floatFromInt(t1)) / @as(f64, @floatFromInt(t2))});
    }

    // 实验 2: pwrite 4KB
    {
        unlinkPath(path2);
        const fd = try openFile(path2);
        defer _ = c.close(fd);
        defer unlinkPath(path2);
        if (c.ftruncate(fd, @as(c.off_t, @intCast(TOTAL_BYTES))) != 0) return error.TruncateFailed;
        _ = try runPwrite(fd, "pwrite 4KB×25600");
    }

    // 实验 3: pwrite 1MB 大块
    {
        unlinkPath(path3);
        const fd = try openFile(path3);
        defer _ = c.close(fd);
        defer unlinkPath(path3);
        if (c.ftruncate(fd, @as(c.off_t, @intCast(TOTAL_BYTES))) != 0) return error.TruncateFailed;
        _ = try runPwriteBig(fd, "pwrite 1MB×100");
    }

    // 实验 4: 模拟 cube_db 的稀疏扩展模式（per-page ftruncate + mmap + write）
    // 注: macOS 上逐页 4KB mmap 可能受限，此实验仅作参考，失败不影响 1/2/3 判别
    {
        unlinkPath(path4);
        const fd = try openFile(path4);
        defer _ = c.close(fd);
        defer unlinkPath(path4);
        _ = runMmapSparse(fd, "稀疏扩展 4KB ftruncate+mmap+write+munmap ×25600") catch |e| blk: {
            std.debug.print("  [稀疏实验失败: {s} — macOS 4KB mmap 限制，跳过（不影响核心判别）]\n", .{@errorName(e)});
            break :blk 0;
        };
    }

    // 实验 5: 精确模拟 cube_db 模式（mmap 1TB 预留 + 逐页 ftruncate 增长 + 写）
    {
        const path5 = ".exp_cubedb.db";
        unlinkPath(path5);
        const fd = try openFile(path5);
        defer _ = c.close(fd);
        defer unlinkPath(path5);
        // 初始 3 页（模拟 FIRST_DATA_PAGE）
        if (c.ftruncate(fd, @as(c.off_t, @intCast(3 * PAGE_SIZE))) != 0) return error.TruncateFailed;
        _ = try runCubeDbPattern(fd, "cube_db 模式 1TB预留+逐页ftruncate+写 ×25600");
    }
}

//! file_page_store.zig — 文件页 Store（LMDB 式 1TB 预留 mmap 区）
//!
//! open 时 mmap 1TB MAP_SHARED 预留虚拟区（方案 I，spike_mmap.zig 已验证 macOS 可行）。
//! 文件按需 ftruncate 增长，reader 经同一 mmap 指针读新数据，无 SIGBUS、无需重 mmap。
//! 写路径保留 PageStore 页接口（allocPage/freePage/writePage）；读路径零拷贝直接 mmap 指针。
const std = @import("std");
const f2 = @import("format.zig");
const ps = @import("page_store.zig");
const c = @cImport({
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const PAGE_SIZE = f2.PAGE_SIZE;

/// 1 TB 预留虚拟区（LMDB 式占位；64-bit 系统虚拟地址空间充裕）
pub const REGION_SIZE: u64 = 1 << 40;

/// #41 FPS 写路径计数器（profile 开关，不进生产热路径）
pub const FpsCounters = struct {
    pub var enable: bool = false;
    pub var write_page_calls: u64 = 0;
    pub var alloc_page_calls: u64 = 0;
    pub var free_page_calls: u64 = 0;
    pub var read_page_calls: u64 = 0;
    pub var fstat_calls: u64 = 0;
    pub var ftruncate_calls: u64 = 0;
    pub var write_page_ns: u64 = 0;
    pub var alloc_page_ns: u64 = 0;
    pub var ensure_growth_ns: u64 = 0;

    pub fn reset() void {
        write_page_calls = 0;
        alloc_page_calls = 0;
        free_page_calls = 0;
        read_page_calls = 0;
        fstat_calls = 0;
        ftruncate_calls = 0;
        write_page_ns = 0;
        alloc_page_ns = 0;
        ensure_growth_ns = 0;
    }

    pub fn now() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
    }
};

pub const FilePageStore = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    region_size: u64,
    mmap_ptr: [*]u8,
    freelist: std.ArrayList(u32),
    next_free: u32,
    meta_index: u32,
    meta0: [PAGE_SIZE]u8,
    meta1: [PAGE_SIZE]u8,

    /// open（或创建）path，mmap 1TB 预留区。文件按需增长。
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !FilePageStore {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const fd = c.open(path_z, @as(c_int, c.O_RDWR | c.O_CREAT), @as(c.mode_t, 0o644));
        if (fd < 0) return error.OpenFailed;

        // 初始文件至少覆盖 meta0 + meta1（3 页）
        var st: c.struct_stat = undefined;
        if (c.fstat(fd, &st) != 0) {
            _ = c.close(fd);
            return error.FstatFailed;
        }
        const min_size: u64 = @as(u64, ps.FIRST_DATA_PAGE) * PAGE_SIZE;
        if (@as(u64, @intCast(st.st_size)) < min_size) {
            if (c.ftruncate(fd, @as(c.off_t, @intCast(min_size))) != 0) {
                _ = c.close(fd);
                return error.TruncateFailed;
            }
        }

        // mmap 1TB MAP_SHARED 预留区
        const ptr = c.mmap(null, REGION_SIZE, @as(c_int, c.PROT_READ) | @as(c_int, c.PROT_WRITE), @as(c_int, c.MAP_SHARED), fd, 0);
        if (ptr == c.MAP_FAILED) {
            _ = c.close(fd);
            return error.MapFailed;
        }

        var fps: FilePageStore = .{
            .allocator = allocator,
            .fd = fd,
            .region_size = REGION_SIZE,
            .mmap_ptr = @ptrCast(ptr),
            .freelist = .empty,
            .next_free = ps.FIRST_DATA_PAGE,
            .meta_index = 0,
            .meta0 = [_]u8{0} ** PAGE_SIZE,
            .meta1 = [_]u8{0} ** PAGE_SIZE,
        };

        // 从 mmap 区加载 meta 缓冲区，再尝试恢复 next_free 和 meta_index
        @memcpy(fps.meta0[0..PAGE_SIZE], fps.pagePtr(f2.META_PAGE_0)[0..PAGE_SIZE]);
        @memcpy(fps.meta1[0..PAGE_SIZE], fps.pagePtr(f2.META_PAGE_1)[0..PAGE_SIZE]);
        // Determine which meta page is active (higher sequence) and set meta_index
        // to write the OTHER page next (alternating write for crash safety)
        const m0 = f2.readMetaPageSingle(&fps.meta0);
        const m1 = f2.readMetaPageSingle(&fps.meta1);
        if (m0 != null and m1 != null) {
            // Both valid: active page is the one with higher sequence;
            // meta_index should point to the inactive (older) page to overwrite next
            if (m0.?.sequence >= m1.?.sequence) {
                // meta0 is active (was last written with meta_index=0), so next write goes to meta1
                fps.meta_index = 1;
                fps.next_free = @max(fps.next_free, m0.?.last_page + 1);
            } else {
                // meta1 is active (was last written with meta_index=1), so next write goes to meta0
                fps.meta_index = 0;
                fps.next_free = @max(fps.next_free, m1.?.last_page + 1);
            }
        } else if (m0 != null) {
            fps.meta_index = 1; // only meta0 valid, next write to meta1
            fps.next_free = @max(fps.next_free, m0.?.last_page + 1);
        } else if (m1 != null) {
            fps.meta_index = 0; // only meta1 valid, next write to meta0
            fps.next_free = @max(fps.next_free, m1.?.last_page + 1);
        }
        // else: both null (fresh DB), meta_index stays 0, next_free stays FIRST_DATA_PAGE
        return fps;

    }

    pub fn deinit(self: *FilePageStore) void {
        _ = c.munmap(@ptrCast(self.mmap_ptr), REGION_SIZE);
        _ = c.close(self.fd);
        self.freelist.deinit(self.allocator);
    }

    /// 预留虚拟区大小（字节）
    pub fn regionSize(self: *const FilePageStore) u64 {
        return self.region_size;
    }

    pub fn store(self: *FilePageStore) ps.PageStore {
        return .{ .ptr = self, .vtable = &file_vtable };
    }

    fn pagePtr(self: *FilePageStore, page_no: u32) [*]u8 {
        return self.mmap_ptr + @as(usize, @intCast(page_no)) * PAGE_SIZE;
    }

    /// 将 meta 缓冲区刷到文件（mmap 区可见）
    fn flushMetaBuffer(self: *FilePageStore, page_no: u32) void {
        const buf = if (page_no == f2.META_PAGE_0) &self.meta0 else &self.meta1;
        const dst = self.pagePtr(page_no);
        @memcpy(dst[0..PAGE_SIZE], buf[0..PAGE_SIZE]);
    }

    /// 确保文件已增长到覆盖 page_no（含整页）
    fn ensureFileGrowth(self: *FilePageStore, page_no: u32) !void {
        const t0 = if (FpsCounters.enable) FpsCounters.now() else 0;
        const needed: u64 = (@as(u64, page_no) + 1) * PAGE_SIZE;
        var st: c.struct_stat = undefined;
        if (c.fstat(self.fd, &st) != 0) return error.FstatFailed;
        if (FpsCounters.enable) FpsCounters.fstat_calls += 1;
        if (@as(u64, @intCast(st.st_size)) < needed) {
            if (c.ftruncate(self.fd, @as(c.off_t, @intCast(needed))) != 0) return error.TruncateFailed;
            if (FpsCounters.enable) FpsCounters.ftruncate_calls += 1;
        }
        if (FpsCounters.enable) FpsCounters.ensure_growth_ns += @intCast(FpsCounters.now() - t0);
    }

    // ===== PageStore vtable =====

    fn vtAllocPage(ptr: *anyopaque) !u32 {
        const self: *FilePageStore = @ptrCast(@alignCast(ptr));
        const t0 = if (FpsCounters.enable) FpsCounters.now() else 0;
        if (FpsCounters.enable) FpsCounters.alloc_page_calls += 1;
        if (self.freelist.items.len > 0) return self.freelist.pop().?;
        const pn = self.next_free;
        if (@as(u64, pn) * PAGE_SIZE >= self.region_size) return error.MapFull;
        try self.ensureFileGrowth(pn);
        self.next_free = pn + 1;
        if (FpsCounters.enable) FpsCounters.alloc_page_ns += @intCast(FpsCounters.now() - t0);
        return pn;
    }

    fn vtFreePage(ptr: *anyopaque, page_no: u32) void {
        const self: *FilePageStore = @ptrCast(@alignCast(ptr));
        if (FpsCounters.enable) FpsCounters.free_page_calls += 1;
        self.freelist.append(self.allocator, page_no) catch {};
    }

    fn vtReadPage(ptr: *anyopaque, page_no: u32) ![]const u8 {
        const self: *FilePageStore = @ptrCast(@alignCast(ptr));
        if (FpsCounters.enable) FpsCounters.read_page_calls += 1;
        if (page_no == f2.META_PAGE_0) return &self.meta0;
        if (page_no == f2.META_PAGE_1) return &self.meta1;
        if (@as(u64, page_no) * PAGE_SIZE >= self.region_size) return error.PageNotFound;
        return self.pagePtr(page_no)[0..PAGE_SIZE];
    }

    fn vtWritePage(ptr: *anyopaque, page_no: u32) ![]u8 {
        const self: *FilePageStore = @ptrCast(@alignCast(ptr));
        const t0 = if (FpsCounters.enable) FpsCounters.now() else 0;
        if (FpsCounters.enable) FpsCounters.write_page_calls += 1;
        if (page_no == f2.META_PAGE_0) return &self.meta0;
        if (page_no == f2.META_PAGE_1) return &self.meta1;
        if (@as(u64, page_no) * PAGE_SIZE >= self.region_size) return error.MapFull;
        try self.ensureFileGrowth(page_no);
        if (FpsCounters.enable) FpsCounters.write_page_ns += @intCast(FpsCounters.now() - t0);
        return self.pagePtr(page_no)[0..PAGE_SIZE];
    }

    fn vtReadMeta(ptr: *anyopaque) !?f2.MetaPage {
        const self: *FilePageStore = @ptrCast(@alignCast(ptr));
        // 先从 mmap 区同步到缓冲区，再读（reader 可能跨进程写）
        @memcpy(self.meta0[0..PAGE_SIZE], self.pagePtr(f2.META_PAGE_0)[0..PAGE_SIZE]);
        @memcpy(self.meta1[0..PAGE_SIZE], self.pagePtr(f2.META_PAGE_1)[0..PAGE_SIZE]);
        return f2.readMetaPage(&self.meta0, &self.meta1);
    }

    fn vtWriteMeta(ptr: *anyopaque, meta: *const f2.MetaPage) !void {
        const self: *FilePageStore = @ptrCast(@alignCast(ptr));
        // Override last_page with actual highest allocated page for correct recovery on reopen
        var meta_copy = meta.*;
        if (self.next_free > ps.FIRST_DATA_PAGE) {
            meta_copy.last_page = self.next_free - 1;
        } else {
            meta_copy.last_page = 0;
        }
        // Determine which meta page to write (opposite of the active one)
        // meta_index tracks which page was last written; next write goes to the other
        const page = if (self.meta_index == 0) &self.meta0 else &self.meta1;
        const page_no = if (self.meta_index == 0) f2.META_PAGE_0 else f2.META_PAGE_1;
        f2.writeMetaPage(page, &meta_copy, self.meta_index);
        self.flushMetaBuffer(page_no);
        self.meta_index = 1 - self.meta_index;
    }

    fn vtSync(ptr: *anyopaque) !void {
        const self: *FilePageStore = @ptrCast(@alignCast(ptr));
        // fsync(fd) flush page cache for the inode（mmap MAP_SHARED 写经页缓存）
        if (c.fsync(self.fd) != 0) return error.SyncFailed;
    }

    fn vtMapSize(ptr: *anyopaque) u64 {
        const self: *FilePageStore = @ptrCast(@alignCast(ptr));
        return self.region_size / PAGE_SIZE;
    }
};

const file_vtable: ps.PageStore.VTable = .{
    .allocPage = FilePageStore.vtAllocPage,
    .freePage = FilePageStore.vtFreePage,
    .readPage = FilePageStore.vtReadPage,
    .writePage = FilePageStore.vtWritePage,
    .readMeta = FilePageStore.vtReadMeta,
    .writeMeta = FilePageStore.vtWriteMeta,
    .sync = FilePageStore.vtSync,
    .mapsize = FilePageStore.vtMapSize,
};

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}
test "file_page_store: 1TB region reserved on open" {
    const allocator = std.testing.allocator;
    const path = ".fps_region_test.db";
    defer unlinkPath(path);
    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    try std.testing.expect(fps.regionSize() >= (1 << 40));
}

test "file_page_store: alloc grows file, read-back visible" {
    const allocator = std.testing.allocator;
    const path = ".fps_grow_test.db";
    defer unlinkPath(path);
    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    const s = fps.store();
    const pn = try s.allocPage();
    const w = try s.writePage(pn);
    @memcpy(w[0..4], "ABCD");
    const r = try s.readPage(pn);
    try std.testing.expectEqualStrings("ABCD", r[0..4]);
}

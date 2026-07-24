//! file_page_store.zig — 文件页 Store（mmap 读写）
//! 创建/打开文件，mmap 固定大小 mapsize，管理 freelist + meta 交替。
const std = @import("std");
const zio = @import("zio");
const c = @cImport({
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
});
const f2 = @import("format2.zig");

const PAGE_SIZE = f2.PAGE_SIZE;

const FilePageStore = @This();

allocator: std.mem.Allocator,
file: zio.File,
fd: i32,
mapsize: u64,
mmap_ptr: [*]u8,
freelist: std.ArrayList(u32),
next_free: u32,
meta_index: u32,
meta0: [PAGE_SIZE]u8,
meta1: [PAGE_SIZE]u8,

pub fn create(allocator: std.mem.Allocator, path: []const u8, mapsize: u64) !FilePageStore {
    const cwd = zio.Dir.cwd();
    const file = try cwd.createFile(path, .{ .read = true, .truncate = false, .exclusive = false });
    // grow file to mapsize (write 1 byte at the end creates sparse file)
    if (mapsize > 0) _ = try file.write(&.{0}, mapsize - 1);
    const fd = file.fd;

    const ptr = try mmapRW(fd, mapsize);
    // 初始化 freelist（从已有 meta 恢复），先设默认值
    var fps = FilePageStore{
        .allocator = allocator,
        .file = file,
        .fd = fd,
        .mapsize = mapsize,
        .mmap_ptr = ptr,
        .freelist = .empty,
        .next_free = f2.META_PAGE_1 + 1, // first data page after meta0, meta1
        .meta_index = 0,
        .meta0 = [_]u8{0} ** PAGE_SIZE,
        .meta1 = [_]u8{0} ** PAGE_SIZE,
    };

    // 尝试从文件已有 meta 恢复
    const loaded_meta = fps.store().readMeta() catch null;
    if (loaded_meta) |m| {
        fps.next_free = @max(fps.next_free, m.last_page + 1);
    }

    return fps;
}

pub fn deinit(self: *FilePageStore) void {
    _ = c.munmap(@ptrCast(self.mmap_ptr), self.mapsize);
    _ = c.close(self.fd);
    self.freelist.deinit(self.allocator);
}

pub fn store(self: *FilePageStore) @import("page_store.zig").PageStore {
    return .{
        .ptr = self,
        .vtable = &file_vtable,
    };
}

fn mmapRW(fd: i32, size: u64) ![*]u8 {
    const aligned = std.mem.alignForward(u64, size, @as(u64, std.heap.page_size_min));
    const ptr = c.mmap(null, aligned, @as(c_int, c.PROT_READ) | @as(c_int, c.PROT_WRITE), @as(c_int, c.MAP_SHARED), fd, 0);
    if (ptr == c.MAP_FAILED) return error.MapFailed;
    return @as([*]u8, @ptrCast(ptr));
}

fn pagePtr(self: *FilePageStore, page_no: u32) [*]u8 {
    return self.mmap_ptr + @as(usize, @intCast(page_no)) * PAGE_SIZE;
}

fn vtAllocPage(ptr: *anyopaque) !u32 {
    const self: *FilePageStore = @ptrCast(@alignCast(ptr));
    if (self.freelist.items.len > 0) return self.freelist.pop().?;
    const pn = self.next_free;
    if (@as(u64, pn) * PAGE_SIZE >= self.mapsize) return error.MapFull;
    self.next_free = pn + 1;
    return pn;
}

fn vtFreePage(ptr: *anyopaque, page_no: u32) void {
    const self: *FilePageStore = @ptrCast(@alignCast(ptr));
    self.freelist.append(self.allocator, page_no) catch {};
}

fn vtReadPage(ptr: *anyopaque, page_no: u32) ![]const u8 {
    const self: *FilePageStore = @ptrCast(@alignCast(ptr));
    if (page_no == f2.META_PAGE_0) return &self.meta0;
    if (page_no == f2.META_PAGE_1) return &self.meta1;
    return self.pagePtr(page_no)[0..PAGE_SIZE];
}

fn vtWritePage(ptr: *anyopaque, page_no: u32) ![]u8 {
    const self: *FilePageStore = @ptrCast(@alignCast(ptr));
    if (page_no == f2.META_PAGE_0) return &self.meta0;
    if (page_no == f2.META_PAGE_1) return &self.meta1;
    return self.pagePtr(page_no)[0..PAGE_SIZE];
}

fn vtReadMeta(ptr: *anyopaque) !?f2.MetaPage {
    const self: *FilePageStore = @ptrCast(@alignCast(ptr));
    return f2.readMetaPage(&self.meta0, &self.meta1);
}

fn vtWriteMeta(ptr: *anyopaque, meta: *const f2.MetaPage) !void {
    const self: *FilePageStore = @ptrCast(@alignCast(ptr));
    const page = if (self.meta_index == 0) &self.meta0 else &self.meta1;
    f2.writeMetaPage(page, meta, self.meta_index);
    // 将 meta 页刷到文件
    const page_no = if (self.meta_index == 0) f2.META_PAGE_0 else f2.META_PAGE_1;
    @memcpy(self.pagePtr(page_no)[0..PAGE_SIZE], page[0..PAGE_SIZE]);
    self.meta_index = 1 - self.meta_index;
}

fn vtSync(ptr: *anyopaque) !void {
    const self: *FilePageStore = @ptrCast(@alignCast(ptr));
    _ = c.msync(self.mmap_ptr, self.mapsize, c.MS_SYNC);
}

fn vtMapSize(ptr: *anyopaque) u64 {
    const self: *FilePageStore = @ptrCast(@alignCast(ptr));
    return self.mapsize / PAGE_SIZE;
}

const file_vtable: @import("page_store.zig").PageStore.VTable = .{
    .allocPage = vtAllocPage,
    .freePage = vtFreePage,
    .readPage = vtReadPage,
    .writePage = vtWritePage,
    .readMeta = vtReadMeta,
    .writeMeta = vtWriteMeta,
    .sync = vtSync,
    .mapsize = vtMapSize,
};

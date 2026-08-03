//! page_store.zig — 页 Store 接口（vtable）及内存实现（MemPageStore）。
//! 生产级 FilePageStore（mmap）后续实现；MemPageStore 用于测试。
const std = @import("std");
const f2 = @import("format.zig");

/// 数据页起始页号（0=NULL，1=meta0，2=meta1）
pub const FIRST_DATA_PAGE: u32 = 3;

/// 错误
pub const Error = error{
    MapFull,
    PageNotFound,
};

/// 页 Store 运行时多态接口
pub const PageStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 分配一页：从 freelist 取或 bump。返页号。
        allocPage: *const fn (ptr: *anyopaque) anyerror!u32,
        /// 回收一页到 freelist（LIFO）。不释放页数据。
        freePage: *const fn (ptr: *anyopaque, page_no: u32) void,
        /// 读页（返借用切片，零拷贝）
        readPage: *const fn (ptr: *anyopaque, page_no: u32) anyerror![]const u8,
        /// 写页（返可变切片）
        writePage: *const fn (ptr: *anyopaque, page_no: u32) anyerror![]u8,
        /// 读 meta（双页交替恢复）
        readMeta: *const fn (ptr: *anyopaque) anyerror!?f2.MetaPage,
        /// 写 meta（交替写 meta0/meta1）
        writeMeta: *const fn (ptr: *anyopaque, meta: *const f2.MetaPage) anyerror!void,
        /// sync（fsync 到磁盘）
        sync: *const fn (ptr: *anyopaque) anyerror!void,
        /// mapsize（页数上限）
        mapsize: *const fn (ptr: *anyopaque) u64,
    };

    pub fn allocPage(self: PageStore) !u32 {
        return self.vtable.allocPage(self.ptr);
    }
    pub fn freePage(self: PageStore, page_no: u32) void {
        self.vtable.freePage(self.ptr, page_no);
    }
    pub fn readPage(self: PageStore, page_no: u32) ![]const u8 {
        return self.vtable.readPage(self.ptr, page_no);
    }
    pub fn writePage(self: PageStore, page_no: u32) ![]u8 {
        return self.vtable.writePage(self.ptr, page_no);
    }
    pub fn readMeta(self: PageStore) !?f2.MetaPage {
        return self.vtable.readMeta(self.ptr);
    }
    pub fn writeMeta(self: PageStore, meta: *const f2.MetaPage) !void {
        return self.vtable.writeMeta(self.ptr, meta);
    }
    pub fn sync(self: PageStore) !void {
        return self.vtable.sync(self.ptr);
    }
    pub fn mapsize(self: PageStore) u64 {
        return self.vtable.mapsize(self.ptr);
    }
};

// ===== 测试用内存实现 =====

/// 内存 PageStore（测试用）。页数据存在 HashMap 中，freelist 为 ArrayList。
/// 不持久化，不支持跨生命周期恢复。
pub const MemPageStore = struct {
    allocator: std.mem.Allocator,
    // slab 页池：按页号索引的 4KB 页数组（ArrayList 几何增长，替代 HashMap 每页 mmap）
    pages: std.ArrayList([f2.PAGE_SIZE]u8),
    freelist: std.ArrayList(u32),
    next_free: u32,
    max_pages: u32,
    meta0: [f2.PAGE_SIZE]u8,
    meta1: [f2.PAGE_SIZE]u8,
    meta_index: u32,

    pub fn init(allocator: std.mem.Allocator, mapsize_pages: u32) MemPageStore {
        return .{
            .allocator = allocator,
            .pages = .empty,
            .freelist = .empty,
            .next_free = FIRST_DATA_PAGE,
            .max_pages = mapsize_pages,
            .meta0 = [_]u8{0} ** f2.PAGE_SIZE,
            .meta1 = [_]u8{0} ** f2.PAGE_SIZE,
            .meta_index = 0,
        };
    }

    pub fn deinit(self: *MemPageStore) void {
        self.pages.deinit(self.allocator);
        self.freelist.deinit(self.allocator);
    }

    pub fn store(self: *MemPageStore) PageStore {
        return .{ .ptr = self, .vtable = &mem_vtable };
    }

    /// 确保页数组至少包含 index+1 个页（不足则几何增长，摊销 O(1)）
    fn ensurePage(self: *MemPageStore, index: u32) !void {
        if (index < self.pages.items.len) return;
        const need = @as(usize, index) + 1;
        try self.pages.appendNTimes(self.allocator, [_]u8{0} ** f2.PAGE_SIZE, need - self.pages.items.len);
    }

    fn vtAllocPage(ptr: *anyopaque) !u32 {
        const self: *MemPageStore = @ptrCast(@alignCast(ptr));
        if (self.freelist.items.len > 0) return self.freelist.pop().?;
        const pn = self.next_free;
        if (pn >= self.max_pages) return error.MapFull;
        self.next_free = pn + 1;
        try self.ensurePage(pn);
        return pn;
    }

    fn vtFreePage(ptr: *anyopaque, page_no: u32) void {
        const self: *MemPageStore = @ptrCast(@alignCast(ptr));
        self.freelist.append(self.allocator, page_no) catch {};
    }

    fn vtReadPage(ptr: *anyopaque, page_no: u32) ![]const u8 {
        const self: *MemPageStore = @ptrCast(@alignCast(ptr));
        if (page_no == f2.META_PAGE_0) return &self.meta0;
        if (page_no == f2.META_PAGE_1) return &self.meta1;
        if (page_no >= self.pages.items.len) return error.PageNotFound;
        return &self.pages.items[page_no];
    }

    fn vtWritePage(ptr: *anyopaque, page_no: u32) ![]u8 {
        const self: *MemPageStore = @ptrCast(@alignCast(ptr));
        if (page_no == f2.META_PAGE_0) return &self.meta0;
        if (page_no == f2.META_PAGE_1) return &self.meta1;
        try self.ensurePage(page_no);
        return &self.pages.items[page_no];
    }

    fn vtReadMeta(ptr: *anyopaque) !?f2.MetaPage {
        const self: *MemPageStore = @ptrCast(@alignCast(ptr));
        return f2.readMetaPage(&self.meta0, &self.meta1);
    }

    fn vtWriteMeta(ptr: *anyopaque, meta: *const f2.MetaPage) !void {
        const self: *MemPageStore = @ptrCast(@alignCast(ptr));
        const page = if (self.meta_index == 0) &self.meta0 else &self.meta1;
        f2.writeMetaPage(page, meta, self.meta_index);
        self.meta_index = 1 - self.meta_index;
    }

    fn vtSync(ptr: *anyopaque) !void {
        _ = ptr;
    }

    fn vtMapSize(ptr: *anyopaque) u64 {
        const self: *MemPageStore = @ptrCast(@alignCast(ptr));
        return self.max_pages;
    }
};

const mem_vtable: PageStore.VTable = .{
    .allocPage = MemPageStore.vtAllocPage,
    .freePage = MemPageStore.vtFreePage,
    .readPage = MemPageStore.vtReadPage,
    .writePage = MemPageStore.vtWritePage,
    .readMeta = MemPageStore.vtReadMeta,
    .writeMeta = MemPageStore.vtWriteMeta,
    .sync = MemPageStore.vtSync,
    .mapsize = MemPageStore.vtMapSize,
};

// ===== 内联测试 =====
// page_store_test.zig 使用 MemPageStore 做功能测试；此处仅留基本测试。

test "page_store: FIRST_DATA_PAGE constant" {
    try std.testing.expectEqual(@as(u32, 3), FIRST_DATA_PAGE);
}

test "page_store: MemPageStore alloc/free roundtrip" {
    var ms = MemPageStore.init(std.testing.allocator, 100);
    defer ms.deinit();
    const s = ms.store();
    const pn = try s.allocPage();
    try std.testing.expectEqual(FIRST_DATA_PAGE, pn);
    s.freePage(pn);
    try std.testing.expectEqual(pn, try s.allocPage());
}

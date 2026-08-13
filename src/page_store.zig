//! page_store.zig — 页 Store 接口（vtable）及内存实现（MemPageStore）。
//! 生产级 FilePageStore（mmap）后续实现；MemPageStore 用于测试。
const std = @import("std");
const f2 = @import("format.zig");
const zio = @import("zio");

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

/// 内存 PageStore（测试用）。页数据为每页独立堆分配（*[PAGE_SIZE]u8），
/// 页地址在生命期不变 → 读者 readPage 借用的切片不会因扩容悬垂。
/// 不持久化，不支持跨生命周期恢复。
pub const MemPageStore = struct {
    allocator: std.mem.Allocator,
    // slab 页池：按页号索引的页指针数组。ArrayList 本身会扩容（指针移动），
    // 但每页是独立堆分配，页数据地址稳定 → 读者借用切片不悬垂（修复并发
    // 写者 allocPage 扩容 ArrayList 导致借用切片悬垂的 SEGV）。
    pages: std.ArrayList(*[f2.PAGE_SIZE]u8),
    freelist: std.ArrayList(u32),
    /// pages/freelist 互斥锁：串行化写者 allocPage/writePage/ensurePage 与读者
    /// readPage（仅护指针数组查找；页数据地址稳定，unlock 后借用切片仍有效）。
    freelist_mu: zio.Mutex,
    next_free: u32,
    max_pages: u32,
    meta0: [f2.PAGE_SIZE]u8,
    meta1: [f2.PAGE_SIZE]u8,
    meta_index: u32,

    pub fn init(allocator: std.mem.Allocator, mapsize_pages: u32) MemPageStore {
        const self: MemPageStore = .{
            .allocator = allocator,
            .pages = .empty,
            .freelist = .empty,
            .freelist_mu = .{},
            .next_free = FIRST_DATA_PAGE,
            .max_pages = mapsize_pages,
            .meta0 = [_]u8{0} ** f2.PAGE_SIZE,
            .meta1 = [_]u8{0} ** f2.PAGE_SIZE,
            .meta_index = 0,
        };
        // 页按需在 ensurePage 中独立堆分配；页地址稳定 → 读者借用切片不悬垂。
        return self;
    }

    pub fn deinit(self: *MemPageStore) void {
        for (self.pages.items) |p| self.allocator.destroy(p);
        self.pages.deinit(self.allocator);
        self.freelist.deinit(self.allocator);
    }

    pub fn store(self: *MemPageStore) PageStore {
        return .{ .ptr = self, .vtable = &mem_vtable };
    }

    /// 为 index 分配独立页（堆分配，地址稳定）。扩容 pages 指针数组仅移动指针，
    /// 不移动页数据 → 读者已借用的页切片不悬垂。调用方须持有 mu。
    fn ensurePage(self: *MemPageStore, index: u32) !void {
        if (index < self.pages.items.len) return;
        if (index >= self.max_pages) return error.MapFull;
        const old_len = self.pages.items.len;
        try self.pages.appendNTimes(self.allocator, undefined, @as(usize, index) + 1 - old_len);
        var i: usize = old_len;
        while (i < self.pages.items.len) : (i += 1) {
            self.pages.items[i] = try self.allocator.create([f2.PAGE_SIZE]u8);
            self.pages.items[i].* = [_]u8{0} ** f2.PAGE_SIZE;
        }
    }

    fn vtAllocPage(ptr: *anyopaque) !u32 {
        const self: *MemPageStore = @ptrCast(@alignCast(ptr));
        self.freelist_mu.lockUncancelable();
        defer self.freelist_mu.unlock();
        if (self.freelist.items.len > 0) return self.freelist.pop().?;
        const pn = self.next_free;
        if (pn >= self.max_pages) return error.MapFull;
        try self.ensurePage(pn);
        self.next_free = pn + 1;
        return pn;
    }

    fn vtFreePage(ptr: *anyopaque, page_no: u32) void {
        const self: *MemPageStore = @ptrCast(@alignCast(ptr));
        self.freelist_mu.lockUncancelable();
        defer self.freelist_mu.unlock();
        self.freelist.append(self.allocator, page_no) catch {};
    }

    fn vtReadPage(ptr: *anyopaque, page_no: u32) ![]const u8 {
        const self: *MemPageStore = @ptrCast(@alignCast(ptr));
        if (page_no == f2.META_PAGE_0) return &self.meta0;
        if (page_no == f2.META_PAGE_1) return &self.meta1;
        self.freelist_mu.lockUncancelable();
        defer self.freelist_mu.unlock();
        if (page_no >= self.pages.items.len) return error.PageNotFound;
        // 页数据为独立堆分配，地址稳定；返回的切片在 unlock 后仍有效。
        return self.pages.items[page_no][0..];
    }

    fn vtWritePage(ptr: *anyopaque, page_no: u32) ![]u8 {
        const self: *MemPageStore = @ptrCast(@alignCast(ptr));
        if (page_no == f2.META_PAGE_0) return &self.meta0;
        if (page_no == f2.META_PAGE_1) return &self.meta1;
        self.freelist_mu.lockUncancelable();
        defer self.freelist_mu.unlock();
        try self.ensurePage(page_no);
        return self.pages.items[page_no][0..];
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

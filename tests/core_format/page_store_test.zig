//! page_store_test.zig - PageStore tests (TDD RED)
//! Covers: allocPage (bump when freelist empty), freePage reclaim/reuse, freelist LIFO semantics,
//! readPage/writePage roundtrip, meta alternating write/read recovery, mapsize limit, sync.
//!
//! MemPageStore is an in-memory implementation of the page_store.PageStore interface (for tests).
const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const ps = cube.page_store;

// ===== in-memory PageStore implementation =====

const MemPageStore = struct {
    allocator: std.mem.Allocator,
    /// Page frame map (page_no -> page data). Sparse (only allocated pages are in the map).
    pages: std.AutoHashMap(u32, [f2.PAGE_SIZE]u8),
    /// Free page number list (LIFO)
    freelist: std.ArrayList(u32),
    /// Next page number for bump allocation (initial = FIRST_DATA_PAGE)
    next_free: u32,
    /// User-specified mapsize (in pages)
    max_pages: u32,
    /// meta page 0 buffer
    meta0: [f2.PAGE_SIZE]u8,
    /// meta page 1 buffer
    meta1: [f2.PAGE_SIZE]u8,
    /// Alternating meta write index (0 or 1)
    meta_index: u32,

    pub fn init(allocator: std.mem.Allocator, mapsize_pages: u32) MemPageStore {
        const pages = std.AutoHashMap(u32, [f2.PAGE_SIZE]u8).init(allocator);
        return .{
            .allocator = allocator,
            .pages = pages,
            .freelist = .empty,
            .next_free = cube.page_store.FIRST_DATA_PAGE,
            .max_pages = mapsize_pages,
            .meta0 = [_]u8{0} ** f2.PAGE_SIZE,
            .meta1 = [_]u8{0} ** f2.PAGE_SIZE,
            .meta_index = 0,
        };
    }

    pub fn deinit(self: *MemPageStore) void {
        self.pages.deinit();
        self.freelist.deinit(self.allocator);
    }

    pub fn vtable(self: *MemPageStore) ps.PageStore {
        return .{
            .ptr = self,
            .vtable = &mem_vtable,
        };
    }

    fn vtAllocPage(ptr: *anyopaque) !u32 {
        const self: *MemPageStore = @ptrCast(@alignCast(ptr));
        // freelist first
        if (self.freelist.items.len > 0) {
            return self.freelist.pop().?;
        }
        // bump allocation
        const pn = self.next_free;
        if (pn >= self.max_pages) return error.MapFull;
        self.next_free = pn + 1;
        // initialize zeroed page
        try self.pages.put(pn, [_]u8{0} ** f2.PAGE_SIZE);
        return pn;
    }

    fn vtFreePage(ptr: *anyopaque, page_no: u32) void {
        const self: *MemPageStore = @ptrCast(@alignCast(ptr));
        // do not remove from the pages map (an MVCC reader may still be reading it); freelist takes allocation priority
        self.freelist.append(self.allocator, page_no) catch {};
    }

    fn vtReadPage(ptr: *anyopaque, page_no: u32) ![]const u8 {
        const self: *MemPageStore = @ptrCast(@alignCast(ptr));
        if (page_no == f2.META_PAGE_0) return &self.meta0;
        if (page_no == f2.META_PAGE_1) return &self.meta1;
        const entry = self.pages.getPtr(page_no) orelse return error.PageNotFound;
        return entry;
    }

    fn vtWritePage(ptr: *anyopaque, page_no: u32) ![]u8 {
        const self: *MemPageStore = @ptrCast(@alignCast(ptr));
        if (page_no == f2.META_PAGE_0) return &self.meta0;
        if (page_no == f2.META_PAGE_1) return &self.meta1;
        const gop = try self.pages.getOrPut(page_no);
        if (!gop.found_existing) {
            gop.value_ptr.* = [_]u8{0} ** f2.PAGE_SIZE;
        }
        return gop.value_ptr;
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
        // MemPageStore sync is a no-op
    }

    fn vtSyncDataPages(ptr: *anyopaque) !void {
        _ = ptr;
        // MemPageStore syncDataPages is a no-op (T-27: the in-memory implementation has no persistence semantics)
    }

    fn vtMapSize(ptr: *anyopaque) u64 {
        const self: *MemPageStore = @ptrCast(@alignCast(ptr));
        return self.max_pages;
    }
};

const mem_vtable: ps.PageStore.VTable = .{
    .allocPage = MemPageStore.vtAllocPage,
    .freePage = MemPageStore.vtFreePage,
    .readPage = MemPageStore.vtReadPage,
    .writePage = MemPageStore.vtWritePage,
    .readMeta = MemPageStore.vtReadMeta,
    .writeMeta = MemPageStore.vtWriteMeta,
    .syncDataPages = MemPageStore.vtSyncDataPages,
    .sync = MemPageStore.vtSync,
    .mapsize = MemPageStore.vtMapSize,
};

// ===== tests =====

test "page_store: alloc page from empty freelist bumps next_free" {
    var ms = MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const p0 = try ms.vtable().allocPage();
    try std.testing.expectEqual(ps.FIRST_DATA_PAGE, p0);
    const p1 = try ms.vtable().allocPage();
    try std.testing.expectEqual(ps.FIRST_DATA_PAGE + 1, p1);
}

test "page_store: free then alloc reuses freed page (LIFO)" {
    var ms = MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const pn = try ms.vtable().allocPage();
    try std.testing.expectEqual(ps.FIRST_DATA_PAGE, pn);
    ms.vtable().freePage(pn);
    const reused = try ms.vtable().allocPage();
    try std.testing.expectEqual(pn, reused);
}

test "page_store: free multiple, alloc returns last freed (LIFO)" {
    var ms = MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const a = try ms.vtable().allocPage();
    const b = try ms.vtable().allocPage();
    const c = try ms.vtable().allocPage();
    ms.vtable().freePage(a);
    ms.vtable().freePage(c);
    ms.vtable().freePage(b);
    // LIFO: b first, then c, then a
    try std.testing.expectEqual(b, try ms.vtable().allocPage());
    try std.testing.expectEqual(c, try ms.vtable().allocPage());
    try std.testing.expectEqual(a, try ms.vtable().allocPage());
}

test "page_store: write then read page roundtrip" {
    var ms = MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const pn = try ms.vtable().allocPage();
    const wbuf = try ms.vtable().writePage(pn);
    // write some content
    wbuf[0] = 0xAB;
    wbuf[100] = 0xCD;
    wbuf[4095] = 0xEF; // last byte (the CRC region gets written too)
    const rbuf = try ms.vtable().readPage(pn);
    try std.testing.expectEqual(@as(u8, 0xAB), rbuf[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), rbuf[100]);
    try std.testing.expectEqual(@as(u8, 0xEF), rbuf[4095]);
}

test "page_store: allocPage beyond mapsize returns MapFull" {
    var ms = MemPageStore.init(std.testing.allocator, ps.FIRST_DATA_PAGE + 2);
    defer ms.deinit();
    // allocate one page (FIRST_DATA_PAGE); it should allocate FIRST_DATA_PAGE
    // mapsize=FIRST_DATA_PAGE+2 means max_pages=FIRST_DATA_PAGE+2
    // next_free starts at FIRST_DATA_PAGE
    // allocatable pages = max_pages - next_free = 2
    try std.testing.expectEqual(ps.FIRST_DATA_PAGE, try ms.vtable().allocPage());
    try std.testing.expectEqual(ps.FIRST_DATA_PAGE + 1, try ms.vtable().allocPage());
    // the third allocation should be full
    try std.testing.expectError(error.MapFull, ms.vtable().allocPage());
}

test "page_store: free page then alloc beyond mapsize still works (reuse)" {
    var ms = MemPageStore.init(std.testing.allocator, ps.FIRST_DATA_PAGE + 1);
    defer ms.deinit();
    // only one allocatable page
    const pn = try ms.vtable().allocPage();
    try std.testing.expectEqual(ps.FIRST_DATA_PAGE, pn);
    try std.testing.expectError(error.MapFull, ms.vtable().allocPage());
    // after freeing, allocation works again
    ms.vtable().freePage(pn);
    try std.testing.expectEqual(pn, try ms.vtable().allocPage());
}

test "page_store: meta write then read alternates pages" {
    var ms = MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const meta1 = f2.MetaPage{
        .magic = f2.MAGIC_V2, .version = 2, .mapsize = 1 << 30,
        .sequence = 1, .root_page = 10, .entry_count = 100, .byte_size = 5000,
        .free_head = 0, .free_count = 0, .last_page = 5,
    };
    try ms.vtable().writeMeta(&meta1);
    const got1 = try ms.vtable().readMeta();
    try std.testing.expect(got1 != null);
    try std.testing.expectEqual(@as(u64, 1), got1.?.sequence);
    try std.testing.expectEqual(@as(u32, 10), got1.?.root_page);

    // the second write should go to the other meta page
    const meta2 = f2.MetaPage{
        .magic = f2.MAGIC_V2, .version = 2, .mapsize = 1 << 30,
        .sequence = 2, .root_page = 20, .entry_count = 200, .byte_size = 10000,
        .free_head = 0, .free_count = 0, .last_page = 10,
    };
    try ms.vtable().writeMeta(&meta2);
    const got2 = try ms.vtable().readMeta();
    try std.testing.expect(got2 != null);
    try std.testing.expectEqual(@as(u64, 2), got2.?.sequence);
    try std.testing.expectEqual(@as(u32, 20), got2.?.root_page);
}

test "page_store: meta alternation — one corrupt, recover from other" {
    var ms = MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const meta = f2.MetaPage{
        .magic = f2.MAGIC_V2, .version = 2, .mapsize = 1 << 30,
        .sequence = 42, .root_page = 100, .entry_count = 999, .byte_size = 50000,
        .free_head = 10, .free_count = 5, .last_page = 50,
    };
    try ms.vtable().writeMeta(&meta); // writes to meta0
    // corrupt meta1 (scramble the header but keep the checksum consistent - a real crash would not fix the checksum)
    @memset(&ms.meta1, 0xff);
    f2.setPageChecksum(&ms.meta1, f2.computePageChecksum(&ms.meta1)); // checksum matches garbage
    // readMeta should return meta0's contents (the one with the correct checksum)
    const got = try ms.vtable().readMeta();
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u64, 42), got.?.sequence);
    try std.testing.expectEqual(@as(u32, 100), got.?.root_page);
}

test "page_store: meta alternation — both empty returns null" {
    var ms = MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const got = try ms.vtable().readMeta();
    try std.testing.expect(got == null);
}

test "page_store: allocPage after many frees reuses in LIFO order" {
    var ms = MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const count: u32 = 100;
    var pages = std.ArrayList(u32).empty;
    defer pages.deinit(std.testing.allocator);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try pages.append(std.testing.allocator, try ms.vtable().allocPage());
    }
    // free all
    for (pages.items) |p| ms.vtable().freePage(p);
    // reallocation order should be LIFO (reverse)
    var j: u32 = count;
    while (j > 0) {
        j -= 1;
        const p = try ms.vtable().allocPage();
        try std.testing.expectEqual(pages.items[j], p);
    }
}

test "page_store: write many pages and verify independently" {
    var ms = MemPageStore.init(std.testing.allocator, 200);
    defer ms.deinit();
    const count: u32 = 50;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const pn = try ms.vtable().allocPage();
        const w = try ms.vtable().writePage(pn);
        @memset(w, @intCast(i & 0xff));
    }
    // verify each written page's pattern independently
    var j: u32 = 0;
    while (j < count) : (j += 1) {
        const pn = ps.FIRST_DATA_PAGE + j;
        const r = try ms.vtable().readPage(pn);
        try std.testing.expectEqual(@as(u8, @intCast(j & 0xff)), r[0]);
        try std.testing.expectEqual(@as(u8, @intCast(j & 0xff)), r[100]);
        try std.testing.expectEqual(@as(u8, @intCast(j & 0xff)), r[4095]);
    }
}

//! page_store.zig — PageStore interface (vtable) and in-memory impl (MemPageStore).
//! The production FilePageStore (mmap) came later; MemPageStore is for tests.
const std = @import("std");
const f2 = @import("format.zig");
const zio = @import("zio");

/// First data page number (0=NULL, 1=meta0, 2=meta1)
pub const FIRST_DATA_PAGE: u32 = 3;

/// Errors
pub const Error = error{
    MapFull,
    PageNotFound,
};

/// Page store runtime-polymorphic interface
pub const PageStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Allocate a page: pop from freelist or bump. Returns the page number.
        allocPage: *const fn (ptr: *anyopaque) anyerror!u32,
        /// Recycle a page onto the freelist (LIFO). Does not free page data.
        freePage: *const fn (ptr: *anyopaque, page_no: u32) void,
        /// Read a page (returns a borrowed slice, zero-copy).
        /// Borrowing contract: the slice stays valid until Store deinit — page
        /// data addresses are stable (MemPageStore: per-page heap allocation /
        /// FilePageStore: reserved mmap region), and COW guarantees published
        /// pages are never modified in place. An implementation violating
        /// either premise violates this interface.
        readPage: *const fn (ptr: *anyopaque, page_no: u32) anyerror![]const u8,
        /// Write a page (returns a mutable slice)
        writePage: *const fn (ptr: *anyopaque, page_no: u32) anyerror![]u8,
        /// Read meta (dual-page alternating recovery)
        readMeta: *const fn (ptr: *anyopaque) anyerror!?f2.MetaPage,
        /// Write meta (alternating between meta0/meta1)
        writeMeta: *const fn (ptr: *anyopaque, meta: *const f2.MetaPage) anyerror!void,
        /// Flush the data-page range to stable storage (fdatasync semantics):
        /// pages written via writePage (excluding meta pages). T-27 commit
        /// ordering: called before writeMeta in power_fail mode so the data
        /// pages meta points to are persisted no later than the meta page
        /// itself — a power loss can never recover a root pointing at dangling
        /// pages. The meta page is not yet written at call time, so the dirty
        /// pages flushed here are exactly this batch's data pages (see the
        /// FilePageStore impl comments). No-op for MemPageStore.
        syncDataPages: *const fn (ptr: *anyopaque) anyerror!void,
        /// sync (fsync to disk)
        sync: *const fn (ptr: *anyopaque) anyerror!void,
        /// mapsize (max page count)
        mapsize: *const fn (ptr: *anyopaque) u64,
    };

    pub fn allocPage(self: PageStore) !u32 {
        return self.vtable.allocPage(self.ptr);
    }
    pub fn freePage(self: PageStore, page_no: u32) void {
        self.vtable.freePage(self.ptr, page_no);
    }
    /// Read a page, returning a borrowed slice (zero-copy). No allocator
    /// parameter + `[]const u8` return type is itself the borrowing idiom
    /// (Zig convention, no Borrowed/Owned suffix needed): the slice is valid
    /// for the Store's lifetime and page contents are immutable (COW).
    /// Callers needing a copy do their own allocator.dupe.
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
    /// Flush the data-page range (fdatasync semantics, see VTable.syncDataPages contract)
    pub fn syncDataPages(self: PageStore) !void {
        return self.vtable.syncDataPages(self.ptr);
    }
    pub fn sync(self: PageStore) !void {
        return self.vtable.sync(self.ptr);
    }
    pub fn mapsize(self: PageStore) u64 {
        return self.vtable.mapsize(self.ptr);
    }
};

// ===== In-memory implementation for tests =====

/// In-memory PageStore (for tests). Page data is independently heap-allocated
/// per page (*[PAGE_SIZE]u8); page addresses never change during the lifetime
/// -> slices borrowed by readPage readers never dangle due to growth.
/// Not persistent; no cross-lifecycle recovery.
pub const MemPageStore = struct {
    allocator: std.mem.Allocator,
    // Slab page pool: an array of page pointers indexed by page number. The
    // ArrayList itself grows (pointers move), but each page is an independent
    // heap allocation with a stable address -> borrowed reader slices never
    // dangle (fixes the SEGV from a concurrent writer's allocPage growing
    // the ArrayList under a borrowed slice).
    pages: std.ArrayList(*[f2.PAGE_SIZE]u8),
    freelist: std.ArrayList(u32),
    /// pages/freelist mutex: serializes writer allocPage/writePage/ensurePage
    /// against reader readPage (guards only the pointer-array lookup; page
    /// data addresses are stable, so borrowed slices stay valid after unlock).
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
        // Pages are independently heap-allocated on demand in ensurePage;
        // stable page addresses -> borrowed reader slices never dangle.
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

    /// Allocate a standalone page for index (heap, stable address). Growing
    /// the pages pointer array moves only pointers, never page data ->
    /// already-borrowed page slices never dangle. Caller must hold mu.
    fn ensurePage(self: *MemPageStore, index: u32) !void {
        if (index < self.pages.items.len) return;
        if (index >= self.max_pages) return error.MapFull;
        const old_len = self.pages.items.len;
        try self.pages.appendNTimes(self.allocator, undefined, @as(usize, index) + 1 - old_len);
        var i: usize = old_len;
        while (i < self.pages.items.len) : (i += 1) {
            self.pages.items[i] = self.allocator.create([f2.PAGE_SIZE]u8) catch {
                // Partial-failure rollback: destroy the pages allocated in
                // this call and shrink the pointer array, so deinit never
                // destroys undefined pointers (F1)
                var j: usize = old_len;
                while (j < i) : (j += 1) self.allocator.destroy(self.pages.items[j]);
                self.pages.shrinkRetainingCapacity(old_len);
                return error.OutOfMemory;
            };
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
        // Page data is independently heap-allocated with a stable address;
        // the returned slice stays valid after unlock.
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

    /// No-op: in-memory impl, no persistence semantics (T-27)
    fn vtSyncDataPages(ptr: *anyopaque) !void {
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
    .syncDataPages = MemPageStore.vtSyncDataPages,
    .sync = MemPageStore.vtSync,
    .mapsize = MemPageStore.vtMapSize,
};

// ===== Inline tests =====
// page_store_test.zig covers MemPageStore functionally; only basic tests here.


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

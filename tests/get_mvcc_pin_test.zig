//! get_mvcc_pin_test.zig — fix-get-mvcc-pin RED test (TDD, deterministic).
//!
//! MVCC invariant under test: while a bare `Db.get`/`Db.getInto` read is in
//! flight, the COW victim pages that the in-flight snapshot still references
//! must NOT be reclaimed (they stay in pending_free => dirt > 0), and once the
//! read completes the pin must be released (dirt drains back to 0).
//!
//! Determinism: no threads, no timing. The "in-flight read" is frozen
//! mid-descent by a wrapping PageStore whose readPage fires a one-shot hook on
//! the descent's first page (the snapshot root) BEFORE returning the page
//! bytes. The hook runs the overlapping writer commit (putDirect)
//! synchronously on the same thread — the exact interleaving that applyBatch
//! step 9 (reader_count==0 => reclaimPendingFree) would hit with real
//! threads, but with zero scheduling luck involved.
//!
//! RED on base: bare get holds no reader pin => step 9 sees reader_count==0
//! => victims freed immediately => dirt_midflight == 0 => assert fails.
//! GREEN after fix (register-then-capture, mirroring Db.select/ReadTxn):
//! reader registered before the snapshot => watermark = reader seq S,
//! victims release_seq = S+1 >= S stay pending until endRead => dirt > 0
//! mid-flight, dirt == 0 after.

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;

const Db = cube.Db;

/// Wrapping page store: delegates every op to the inner store, except a
/// one-shot readPage hook on a target page.
const HookStore = struct {
    inner: ps.PageStore,
    armed: bool = false,
    target: u32 = 0,
    fired: bool = false,
    /// dirtCount observed immediately after the overlapping commit, while the
    /// bare read is still frozen mid-descent.
    dirt_midflight: u64 = 0,
    db: ?*Db = null,

    fn store(self: *HookStore) ps.PageStore {
        return .{ .ptr = self, .vtable = &hook_vtable };
    }

    fn vtAllocPage(ptr: *anyopaque) anyerror!u32 {
        const self: *HookStore = @ptrCast(@alignCast(ptr));
        return self.inner.allocPage();
    }
    fn vtFreePage(ptr: *anyopaque, page_no: u32) void {
        const self: *HookStore = @ptrCast(@alignCast(ptr));
        self.inner.freePage(page_no);
    }
    fn vtReadPage(ptr: *anyopaque, page_no: u32) anyerror![]const u8 {
        const self: *HookStore = @ptrCast(@alignCast(ptr));
        if (self.armed and !self.fired and page_no == self.target) {
            self.fired = true;
            // The overlapping writer commit, executed while the bare read is
            // frozen on its very first page (the snapshot root).
            const d = self.db.?;
            try d.putDirect("zz-hook-overlap-key", "hook-value");
            self.dirt_midflight = d.dirtCount();
        }
        return self.inner.readPage(page_no);
    }
    fn vtWritePage(ptr: *anyopaque, page_no: u32) anyerror![]u8 {
        const self: *HookStore = @ptrCast(@alignCast(ptr));
        return self.inner.writePage(page_no);
    }
    fn vtReadMeta(ptr: *anyopaque) anyerror!?cube.format.MetaPage {
        const self: *HookStore = @ptrCast(@alignCast(ptr));
        return self.inner.readMeta();
    }
    fn vtWriteMeta(ptr: *anyopaque, meta: *const cube.format.MetaPage) anyerror!void {
        const self: *HookStore = @ptrCast(@alignCast(ptr));
        return self.inner.writeMeta(meta);
    }
    fn vtSyncDataPages(ptr: *anyopaque) anyerror!void {
        const self: *HookStore = @ptrCast(@alignCast(ptr));
        return self.inner.syncDataPages();
    }
    fn vtSync(ptr: *anyopaque) anyerror!void {
        const self: *HookStore = @ptrCast(@alignCast(ptr));
        return self.inner.sync();
    }
    fn vtMapSize(ptr: *anyopaque) u64 {
        const self: *HookStore = @ptrCast(@alignCast(ptr));
        return self.inner.mapsize();
    }
};

const hook_vtable: ps.PageStore.VTable = .{
    .allocPage = HookStore.vtAllocPage,
    .freePage = HookStore.vtFreePage,
    .readPage = HookStore.vtReadPage,
    .writePage = HookStore.vtWritePage,
    .readMeta = HookStore.vtReadMeta,
    .writeMeta = HookStore.vtWriteMeta,
    .syncDataPages = HookStore.vtSyncDataPages,
    .sync = HookStore.vtSync,
    .mapsize = HookStore.vtMapSize,
};

/// Two-phase init (mirrors reader_handle_test's TestDb): the struct is moved
/// into its final address first, THEN the store/Db are wired up in-place —
/// PageStore.ptr captures &self.hook and must not dangle across a move.
const Harness = struct {
    ms: ps.MemPageStore,
    hook: HookStore,
    db: ?*Db = null,

    fn init() Harness {
        return .{ .ms = ps.MemPageStore.init(std.testing.allocator, 1000), .hook = undefined };
    }

    fn setup(self: *Harness) !void {
        self.hook = .{ .inner = self.ms.store() };
        const db = try Db.open(std.testing.allocator, self.hook.store(), .{});
        errdefer db.close();
        try db.putDirect("k0", "v0");
        try db.putDirect("k1", "v1");
        self.hook.db = db;
        self.db = db;
    }

    fn deinit(self: *Harness) void {
        if (self.db) |d| d.close();
        self.ms.deinit();
    }

    fn dbPtr(self: *Harness) *Db {
        return self.db.?;
    }

    /// Arm the one-shot mid-descent hook on the current root and reset
    /// observations. The very next readPage(root) — the first page of a
    /// get/getInto descent — runs the overlapping commit.
    fn armOnCurrentRoot(self: *Harness) void {
        self.hook.target = self.dbPtr().getRoot();
        self.hook.fired = false;
        self.hook.dirt_midflight = 0;
        self.hook.armed = true;
    }
};

test "Db.get holds an MVCC pin for the duration of an in-flight read" {
    var h = Harness.init();
    defer h.deinit();
    try h.setup();
    h.armOnCurrentRoot();

    const v = try h.dbPtr().get("k0");
    defer std.testing.allocator.free(v.?);

    // Sanity: the read itself completed correctly and the hook actually ran.
    try std.testing.expect(h.hook.fired);
    try std.testing.expectEqualStrings("v0", v.?);

    // Invariant (RED on base): the overlapping commit's COW victims are still
    // pinned — reclaimPendingFree must not have freed them while the bare
    // read was in flight.
    try std.testing.expect(h.hook.dirt_midflight > 0);

    // Pin released: after the read completes, the victims are reclaimable and
    // the pending queue drains (no leak).
    try std.testing.expectEqual(@as(u64, 0), h.dbPtr().dirtCount());
}

test "Db.getInto holds an MVCC pin for the duration of an in-flight read" {
    var h = Harness.init();
    defer h.deinit();
    try h.setup();
    h.armOnCurrentRoot();

    var buf: [64]u8 = undefined;
    const n = try h.dbPtr().getInto("k1", &buf);

    try std.testing.expect(h.hook.fired);
    try std.testing.expectEqual(@as(usize, 2), n.?);
    try std.testing.expectEqualStrings("v1", buf[0..n.?]);

    try std.testing.expect(h.hook.dirt_midflight > 0);
    try std.testing.expectEqual(@as(u64, 0), h.dbPtr().dirtCount());
}

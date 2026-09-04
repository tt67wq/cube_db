//! durability_order_test.zig - T-27: commit ordering contract (data pages hit disk before meta)
//!
//! RED stage (this file landed first): Options.durability and PageStore.syncDataPages did not exist yet,
//! so compilation failure was the RED signal (same TDD precedent as btree_test.zig's "initially failing
//! because btree.zig did not exist").
//!
//! Contract after GREEN:
//! - .power_fail tier: syncDataPages (flush data pages) happens before writeMeta,
//!   then sync after writeMeta (meta hits disk) - two syncs, byte-level commit ordering.
//! - .process_crash tier (default): keeps the old behavior - no preceding syncDataPages call,
//!   a single sync after writeMeta (if fsync=true).
//!
//! Uses RecordingStore (a vtable stub wrapping MemPageStore) to record the event sequence and assert ordering.
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const ps = cube.page_store;
const wrt = cube.writer;

const alloc = std.testing.allocator;

// ---- PageStore wrapper stub that records events ----

const Event = enum { write_page, sync_data, write_meta, sync };

const RecordingStore = struct {
    inner: ps.MemPageStore,
    events: std.ArrayList(Event),

    fn init(mapsize: u32) RecordingStore {
        return .{ .inner = ps.MemPageStore.init(alloc, mapsize), .events = .empty };
    }

    fn deinit(self: *RecordingStore) void {
        self.inner.deinit();
        self.events.deinit(alloc);
    }

    fn store(self: *RecordingStore) ps.PageStore {
        return .{ .ptr = self, .vtable = &rec_vtable };
    }

    fn firstIndex(self: *const RecordingStore, ev: Event) ?usize {
        for (self.events.items, 0..) |e, i| {
            if (e == ev) return i;
        }
        return null;
    }

    fn lastIndex(self: *const RecordingStore, ev: Event) ?usize {
        var found: ?usize = null;
        for (self.events.items, 0..) |e, i| {
            if (e == ev) found = i;
        }
        return found;
    }


    fn vtAllocPage(ptr: *anyopaque) !u32 {
        const self: *RecordingStore = @ptrCast(@alignCast(ptr));
        return self.inner.store().allocPage();
    }
    fn vtFreePage(ptr: *anyopaque, page_no: u32) void {
        const self: *RecordingStore = @ptrCast(@alignCast(ptr));
        self.inner.store().freePage(page_no);
    }
    fn vtReadPage(ptr: *anyopaque, page_no: u32) ![]const u8 {
        const self: *RecordingStore = @ptrCast(@alignCast(ptr));
        return self.inner.store().readPage(page_no);
    }
    fn vtWritePage(ptr: *anyopaque, page_no: u32) ![]u8 {
        const self: *RecordingStore = @ptrCast(@alignCast(ptr));
        self.events.append(alloc, .write_page) catch {};
        return self.inner.store().writePage(page_no);
    }
    fn vtReadMeta(ptr: *anyopaque) !?cube.format.MetaPage {
        const self: *RecordingStore = @ptrCast(@alignCast(ptr));
        return self.inner.store().readMeta();
    }
    fn vtWriteMeta(ptr: *anyopaque, meta: *const cube.format.MetaPage) !void {
        const self: *RecordingStore = @ptrCast(@alignCast(ptr));
        self.events.append(alloc, .write_meta) catch {};
        return self.inner.store().writeMeta(meta);
    }
    fn vtSyncDataPages(ptr: *anyopaque) !void {
        const self: *RecordingStore = @ptrCast(@alignCast(ptr));
        self.events.append(alloc, .sync_data) catch {};
        // no-op: the ordering-contract tests do not depend on real disk flushes
    }
    fn vtSync(ptr: *anyopaque) !void {
        const self: *RecordingStore = @ptrCast(@alignCast(ptr));
        self.events.append(alloc, .sync) catch {};
    }
    fn vtMapSize(ptr: *anyopaque) u64 {
        const self: *RecordingStore = @ptrCast(@alignCast(ptr));
        return self.inner.store().mapsize();
    }
};

const rec_vtable: ps.PageStore.VTable = .{
    .allocPage = RecordingStore.vtAllocPage,
    .freePage = RecordingStore.vtFreePage,
    .readPage = RecordingStore.vtReadPage,
    .writePage = RecordingStore.vtWritePage,
    .readMeta = RecordingStore.vtReadMeta,
    .writeMeta = RecordingStore.vtWriteMeta,
    .syncDataPages = RecordingStore.vtSyncDataPages,
    .sync = RecordingStore.vtSync,
    .mapsize = RecordingStore.vtMapSize,
};

/// Single put (a one-entry applyBatch); the event sequence is asserted by callers
fn applyOnePut(state: *wrt.State, key: []const u8, value: []const u8) !void {
    var fut: zio.Future(wrt.OpResult) = .{};
    const reqs = [_]wrt.Request{.{ .key = key, .value = value, .tombstone = false, .future = &fut }};
    try state.applyBatch(&reqs);
    _ = try fut.wait();
}

// ===== 1. power_fail tier: data pages before meta, sync after meta =====

test "durability order: power_fail - syncDataPages before writeMeta, sync after" {
    var rs = RecordingStore.init(1000);
    defer rs.deinit();
    var state = wrt.State.init(alloc, rs.store(), .{ .durability = .power_fail });
    defer state.deinit();

    try applyOnePut(&state, "k", "v");

    const i_sync_data = rs.firstIndex(.sync_data) orelse return error.TestUnexpectedResult;
    const i_meta = rs.firstIndex(.write_meta) orelse return error.TestUnexpectedResult;
    const i_sync = rs.lastIndex(.sync) orelse return error.TestUnexpectedResult;

    // data pages flushed before the meta write
    try std.testing.expect(i_sync_data < i_meta);
    // meta flushed after the meta write
    try std.testing.expect(i_meta < i_sync);
    // at least one data page written (this batch COWed new pages)
    const i_write = rs.firstIndex(.write_page) orelse return error.TestUnexpectedResult;
    try std.testing.expect(i_write < i_sync_data);
}

test "durability order: power_fail - every batch has a preceding syncDataPages (multi-batch commits)" {
    var rs = RecordingStore.init(1000);
    defer rs.deinit();
    var state = wrt.State.init(alloc, rs.store(), .{ .durability = .power_fail });
    defer state.deinit();

    try applyOnePut(&state, "a", "1");
    try applyOnePut(&state, "b", "2");

    // two batch commits -> each write_meta has its own preceding sync_data
    var meta_count: usize = 0;
    var sync_data_count: usize = 0;
    var last_sync_data: ?usize = null;
    for (rs.events.items, 0..) |e, i| {
        switch (e) {
            .write_meta => {
                meta_count += 1;
                // every write_meta must have a preceding sync_data at an earlier index
                try std.testing.expect(last_sync_data != null);
                try std.testing.expect(last_sync_data.? < i);
            },
            .sync_data => {
                sync_data_count += 1;
                last_sync_data = i;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), meta_count);
    try std.testing.expectEqual(@as(usize, 2), sync_data_count);
}

// ===== 2. process_crash tier (default): keep the old behavior =====

test "durability order: process_crash default - no syncDataPages, single sync after writeMeta" {
    // Options default value contract
    const default_opts = wrt.Options{};
    try std.testing.expectEqual(wrt.Durability.process_crash, default_opts.durability);

    var rs = RecordingStore.init(1000);
    defer rs.deinit();
    var state = wrt.State.init(alloc, rs.store(), .{});
    defer state.deinit();

    try applyOnePut(&state, "k", "v");

    // old behavior: no preceding data-page flush call
    try std.testing.expect(rs.firstIndex(.sync_data) == null);
    // single sync after writeMeta (fsync defaults to true)
    const i_meta = rs.firstIndex(.write_meta) orelse return error.TestUnexpectedResult;
    const i_sync = rs.lastIndex(.sync) orelse return error.TestUnexpectedResult;
    try std.testing.expect(i_meta < i_sync);
    var sync_count: usize = 0;
    for (rs.events.items) |e| {
        if (e == .sync) sync_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), sync_count);
}

// ===== 3. semantic smoke test: data still intact under power_fail tier (reads/writes agree through the stub) =====

test "durability order: power_fail smoke — data readable after commit" {
    var rs = RecordingStore.init(1000);
    defer rs.deinit();
    var state = wrt.State.init(alloc, rs.store(), .{ .durability = .power_fail });
    defer state.deinit();

    try applyOnePut(&state, "k", "v");
    const v = try cube.btree.get(alloc, state.store, state.getRoot(), "k");
    try std.testing.expectEqualStrings("v", v.?);
    alloc.free(v.?);
}

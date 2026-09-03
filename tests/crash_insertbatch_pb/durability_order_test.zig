//! durability_order_test.zig — T-27: 提交顺序契约（数据页先于 meta 落盘）
//!
//! RED 阶段（本文件先落）：Options.durability 与 PageStore.syncDataPages 尚不存在，
//! 编译失败即 RED（与 btree_test.zig「先 fail（btree.zig 不存在）」同款 TDD 先例）。
//!
//! GREEN 后的契约：
//! - .power_fail 档：syncDataPages（数据页落盘）先于 writeMeta，
//!   writeMeta 之后 sync（meta 落盘）——两次 sync，字节级提交顺序。
//! - .process_crash 档（默认）：保持旧行为——无 syncDataPages 前置调用，
//!   writeMeta 后（若 fsync=true）单次 sync。
//!
//! 用 RecordingStore（包装 MemPageStore 的 vtable 桩）记录事件序列断言顺序。
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const ps = cube.page_store;
const wrt = cube.writer;

const alloc = std.testing.allocator;

// ---- 记录事件的 PageStore 包装桩 ----

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
        // no-op：顺序契约测试不依赖真实落盘
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

/// 单次 put（单条 applyBatch），返回事件序列供断言
fn applyOnePut(state: *wrt.State, key: []const u8, value: []const u8) !void {
    var fut: zio.Future(wrt.OpResult) = .{};
    const reqs = [_]wrt.Request{.{ .key = key, .value = value, .tombstone = false, .future = &fut }};
    try state.applyBatch(&reqs);
    _ = try fut.wait();
}

// ===== 1. power_fail 档：数据页先于 meta 落盘，meta 之后 sync =====

test "durability order: power_fail — syncDataPages before writeMeta, sync after" {
    var rs = RecordingStore.init(1000);
    defer rs.deinit();
    var state = wrt.State.init(alloc, rs.store(), .{ .durability = .power_fail });
    defer state.deinit();

    try applyOnePut(&state, "k", "v");

    const i_sync_data = rs.firstIndex(.sync_data) orelse return error.TestUnexpectedResult;
    const i_meta = rs.firstIndex(.write_meta) orelse return error.TestUnexpectedResult;
    const i_sync = rs.lastIndex(.sync) orelse return error.TestUnexpectedResult;

    // 数据页落盘先于 meta 写入
    try std.testing.expect(i_sync_data < i_meta);
    // meta 落盘在 meta 写入之后
    try std.testing.expect(i_meta < i_sync);
    // 至少有数据页被写入（本批 COW 出了新页）
    const i_write = rs.firstIndex(.write_page) orelse return error.TestUnexpectedResult;
    try std.testing.expect(i_write < i_sync_data);
}

test "durability order: power_fail — 每个批次都有前置 syncDataPages（多批提交）" {
    var rs = RecordingStore.init(1000);
    defer rs.deinit();
    var state = wrt.State.init(alloc, rs.store(), .{ .durability = .power_fail });
    defer state.deinit();

    try applyOnePut(&state, "a", "1");
    try applyOnePut(&state, "b", "2");

    // 两次批提交 → 每批各自 write_meta 前都有 sync_data
    var meta_count: usize = 0;
    var sync_data_count: usize = 0;
    var last_sync_data: ?usize = null;
    for (rs.events.items, 0..) |e, i| {
        switch (e) {
            .write_meta => {
                meta_count += 1;
                // 每个 write_meta 之前必须存在一个更晚的 sync_data
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

// ===== 2. process_crash 档（默认）：保持旧行为 =====

test "durability order: process_crash default — no syncDataPages, single sync after writeMeta" {
    // Options 默认值契约
    const default_opts = wrt.Options{};
    try std.testing.expectEqual(wrt.Durability.process_crash, default_opts.durability);

    var rs = RecordingStore.init(1000);
    defer rs.deinit();
    var state = wrt.State.init(alloc, rs.store(), .{});
    defer state.deinit();

    try applyOnePut(&state, "k", "v");

    // 旧行为：无数据页前置落盘调用
    try std.testing.expect(rs.firstIndex(.sync_data) == null);
    // writeMeta 之后单次 sync（fsync 默认 true）
    const i_meta = rs.firstIndex(.write_meta) orelse return error.TestUnexpectedResult;
    const i_sync = rs.lastIndex(.sync) orelse return error.TestUnexpectedResult;
    try std.testing.expect(i_meta < i_sync);
    var sync_count: usize = 0;
    for (rs.events.items) |e| {
        if (e == .sync) sync_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), sync_count);
}

// ===== 3. 语义冒烟：power_fail 档下数据仍然完整（透过桩读写一致） =====

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

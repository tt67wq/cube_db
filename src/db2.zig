//! db2.zig — Db2 句柄：v2 公开 API（open/close/put/get/delete/select/putBatch）
//! 封装 PageStore + writer2 + btree2。纯同步接口。
const std = @import("std");
const zio = @import("zio");
const f2 = @import("format2.zig");
const ps = @import("page_store.zig");
const btree2 = @import("btree2.zig");
const writer2 = @import("writer2.zig");

const PageStore = ps.PageStore;
const State = writer2.State;

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
    tombstone: bool = false,
};

pub const Db2 = struct {
    allocator: std.mem.Allocator,
    state: *State,
    store: PageStore,

    /// 若 open 创建了新的 MemPageStore，close 时释放
    store_owned: bool,

    pub fn open(allocator: std.mem.Allocator, store: PageStore, opts: writer2.Options) !*Db2 {
        const state = try allocator.create(State);
        state.* = State.init(allocator, store, opts);

        // 尝试从 meta 恢复
        if (try store.readMeta()) |meta| {
            state.root.store(meta.root_page, .release);
            state.sequence.store(meta.sequence, .release);
            state.entry_count.store(meta.entry_count, .release);
            state.byte_size.store(meta.byte_size, .release);
            // ponytail: dirt 不持久化（compact 清理后归零），恢复为 0
            state.dirt.store(0, .release);
        }

        const db = try allocator.create(Db2);
        db.* = .{
            .allocator = allocator,
            .state = state,
            .store = store,
            .store_owned = false,
        };
        return db;
    }

    pub fn close(self: *Db2) void {
        _ = self.state.deinit();
        self.allocator.destroy(self.state);
        self.allocator.destroy(self);
    }

    pub fn getRoot(self: *Db2) u32 {
        return self.state.getRoot();
    }

    pub fn entryCount(self: *Db2) u64 {
        return self.state.entry_count.load(.acquire);
    }

    pub fn put(self: *Db2, key: []const u8, value: []const u8) !void {
        var future: zio.Future(writer2.OpResult) = .{};
        try self.state.applyBatch(&.{.{
            .key = key,
            .value = value,
            .tombstone = false,
            .future = &future,
        }});
        _ = try future.wait();
    }

    pub fn putBatch(self: *Db2, entries: []const Entry) !void {
        // 构造 Request 数组
        const reqs = try self.allocator.alloc(writer2.Request, entries.len);
        defer self.allocator.free(reqs);
        var futures = try self.allocator.alloc(zio.Future(writer2.OpResult), entries.len);
        defer self.allocator.free(futures);

        for (entries, 0..) |e, i| {
            futures[i] = .{};
            reqs[i] = .{
                .key = e.key,
                .value = e.value,
                .tombstone = e.tombstone,
                .future = &futures[i],
            };
        }
        try self.state.applyBatch(reqs);
        for (futures) |*f| _ = try f.wait();
    }

    pub fn get(self: *Db2, key: []const u8) !?[]u8 {
        const root = self.state.getRoot();
        return try btree2.get(self.allocator, self.store, root, key);
    }

    pub fn delete(self: *Db2, key: []const u8) !void {
        var future: zio.Future(writer2.OpResult) = .{};
        try self.state.applyBatch(&.{.{
            .key = key,
            .value = "",
            .tombstone = true,
            .future = &future,
        }});
        _ = try future.wait();
    }

    pub fn select(self: *Db2, min: ?[]const u8, max: ?[]const u8) !btree2.Iterator {
        const root = self.state.getRoot();
        return try btree2.select(self.allocator, self.store, root, min, max);
    }

    pub fn compact(self: *Db2) !void {
        try self.state.compact();
    }

    pub fn dirtCount(self: *Db2) u64 {
        return self.state.dirtCount();
    }

    pub fn beginRead(self: *Db2) u64 {
        return self.state.beginRead();
    }

    pub fn endRead(self: *Db2) void {
        self.state.endRead();
    }
};

test "db2: open default state" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try Db2.open(std.testing.allocator, ms.store(), .{});
    defer db.close();
    try std.testing.expectEqual(@as(u32, btree2.NULL_ROOT), db.getRoot());
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

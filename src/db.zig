//! db.zig — Db 句柄：v2 公开 API（open/close/put/get/delete/select/putBatch）
//! 封装 PageStore + wrt + btree。纯同步接口。
const std = @import("std");
const zio = @import("zio");
const f2 = @import("format.zig");
const ps = @import("page_store.zig");
const btree = @import("btree.zig");
const wrt = @import("writer.zig");
const memtable = @import("memtable.zig");
const wal_mod = @import("wal.zig");
const compactor_mod = @import("compactor.zig");

const PageStore = ps.PageStore;
const State = wrt.State;
const RwLock = zio.RwLock;

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
    tombstone: bool = false,
};

pub const Db = struct {
    allocator: std.mem.Allocator,
    state: *State,
    store: PageStore,
    store_owned: bool,

    // LSM fields (optional, set via open options)
    mt: ?*memtable.Memtable = null,
    wal: ?*wal_mod.Wal = null,
    rwlock: ?*RwLock = null,
    compactor: ?*compactor_mod.Compactor = null,

    pub fn open(allocator: std.mem.Allocator, store: PageStore, opts: wrt.Options) !*Db {
        const state = try allocator.create(State);
        state.* = State.init(allocator, store, opts);

        if (try store.readMeta()) |meta| {
            state.root.store(meta.root_page, .release);
            state.sequence.store(meta.sequence, .release);
            state.entry_count.store(meta.entry_count, .release);
            state.byte_size.store(meta.byte_size, .release);
            state.dirt.store(0, .release);
        }

        const db = try allocator.create(Db);
        db.* = .{
            .allocator = allocator,
            .state = state,
            .store = store,
            .store_owned = false,
        };
        return db;
    }

    pub fn close(self: *Db) void {
        _ = self.state.deinit();
        self.allocator.destroy(self.state);
        self.allocator.destroy(self);
    }

    pub fn getRoot(self: *Db) u32 {
        return self.state.getRoot();
    }

    pub fn entryCount(self: *Db) u64 {
        return self.state.entry_count.load(.acquire);
    }

    pub fn put(self: *Db, key: []const u8, value: []const u8) !void {
        // LSM path: write to memtable + WAL
        if (self.mt) |mt| {
            if (self.wal) |w| _ = try w.append(.put, key, value);
            _ = try mt.put(key, value);
            if (mt.shouldFlush()) {
                if (self.compactor) |c| c.signal(mt);
            }
            return;
        }
        // Fallback to original COW path
        var future: zio.Future(wrt.OpResult) = .{};
        try self.state.applyBatch(&.{.{
            .key = key,
            .value = value,
            .tombstone = false,
            .future = &future,
        }});
        _ = try future.wait();
    }

    pub fn putBatch(self: *Db, entries: []const Entry) !void {
        const reqs = try self.allocator.alloc(wrt.Request, entries.len);
        defer self.allocator.free(reqs);
        var futures = try self.allocator.alloc(zio.Future(wrt.OpResult), entries.len);
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

    pub fn get(self: *Db, key: []const u8) !?[]u8 {
        // LSM path: check memtable first
        if (self.mt) |mt| {
            // Take read lock if available
            if (self.rwlock) |rw| try rw.lockShared();
            defer if (self.rwlock) |rw| rw.unlockShared();

            if (mt.get(key)) |val| {
                return try self.allocator.dupe(u8, val);
            }
        }
        // Fallback to B-tree
        const root = self.state.getRoot();
        return try btree.get(self.allocator, self.store, root, key);
    }

    pub fn delete(self: *Db, key: []const u8) !void {
        if (self.mt) |mt| {
            if (self.wal) |w| _ = try w.append(.delete, key, "");
            _ = try mt.delete(key);
            return;
        }
        var future: zio.Future(wrt.OpResult) = .{};
        try self.state.applyBatch(&.{.{
            .key = key,
            .value = "",
            .tombstone = true,
            .future = &future,
        }});
        _ = try future.wait();
    }

    pub fn select(self: *Db, min: ?[]const u8, max: ?[]const u8) !btree.Iterator {
        const root = self.state.getRoot();
        return try btree.select(self.allocator, self.store, root, min, max);
    }

    pub fn compact(self: *Db) !void {
        try self.state.compact();
    }

    pub fn dirtCount(self: *Db) u64 {
        return self.state.dirtCount();
    }

    pub fn beginRead(self: *Db) u64 {
        return self.state.beginRead();
    }

    pub fn endRead(self: *Db) void {
        self.state.endRead();
    }
};

test "db: open default state" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();
    try std.testing.expectEqual(@as(u32, btree.NULL_ROOT), db.getRoot());
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

test "db: lsm get checks memtable first" {
    const allocator = std.testing.allocator;
    var ms = ps.MemPageStore.init(allocator, 1000);
    defer ms.deinit();
    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();

    // Create memtable and attach to Db
    var mt = memtable.Memtable.init(allocator, 1024);
    defer mt.deinit();
    _ = try mt.put("mem", "table");

    db.mt = &mt;

    // Get should find the value in memtable
    {
        const v = try db.get("mem");
        defer if (v) |val| allocator.free(val);
        try std.testing.expectEqualStrings("table", v.?);
    }

    // Get for non-existent key returns null
    {
        const v = try db.get("nonexistent");
        defer if (v) |val| allocator.free(val);
        try std.testing.expectEqual(@as(?[]u8, null), v);
    }

    // Detach memtable, get should return null (B-tree is empty)
    db.mt = null;
    {
        const v = try db.get("mem");
        defer if (v) |val| allocator.free(val);
        try std.testing.expectEqual(@as(?[]u8, null), v);
    }
}

test "db: lsm put writes to memtable" {
    const allocator = std.testing.allocator;
    var ms = ps.MemPageStore.init(allocator, 1000);
    defer ms.deinit();
    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();

    var mt = memtable.Memtable.init(allocator, 1024);
    defer mt.deinit();
    db.mt = &mt;

    // Put writes to memtable
    try db.put("key", "value");
    try std.testing.expectEqualStrings("value", mt.get("key").?);
    try std.testing.expectEqual(@as(usize, 1), mt.count());

    // get also finds it
    {
        const v = try db.get("key");
        defer if (v) |val| allocator.free(val);
        try std.testing.expectEqualStrings("value", v.?);
    }
}

test "db: lsm delete writes tombstone to memtable" {
    const allocator = std.testing.allocator;
    var ms = ps.MemPageStore.init(allocator, 1000);
    defer ms.deinit();
    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();

    var mt = memtable.Memtable.init(allocator, 1024);
    defer mt.deinit();
    db.mt = &mt;

    try db.put("key", "value");
    try std.testing.expectEqualStrings("value", mt.get("key").?);

    try db.delete("key");
    try std.testing.expectEqual(@as(?[]const u8, null), mt.get("key"));

    // get returns null
    {
        const v = try db.get("key");
        defer if (v) |val| allocator.free(val);
        try std.testing.expectEqual(@as(?[]u8, null), v);
    }
}
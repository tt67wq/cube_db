//! db.zig — Db 句柄：v2 公开 API（open/close/put/get/delete/select/putBatch）
//! 封装 PageStore + wrt + btree。纯同步接口。
const std = @import("std");
const zio = @import("zio");
const f2 = @import("format.zig");
const ps = @import("page_store.zig");
const btree = @import("btree.zig");
const wrt = @import("writer.zig");
const PageStore = ps.PageStore;
const State = wrt.State;
const Mutex = zio.Mutex;

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
    write_mutex: Mutex,

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
            .write_mutex = .{},
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

    // ---- 隐式 txn 便捷 API（包隐式 WriteTxn） ----

    pub fn put(self: *Db, key: []const u8, value: []const u8) !void {
        var txn = try self.beginWriteTxn();
        defer txn.deinit();
        try txn.put(key, value);
        try txn.commit();
    }

    pub fn putBatch(self: *Db, entries: []const Entry) !void {
        var txn = try self.beginWriteTxn();
        defer txn.deinit();
        for (entries) |e| {
            if (e.tombstone) try txn.delete(e.key) else try txn.put(e.key, e.value);
        }
        try txn.commit();
    }

    pub fn delete(self: *Db, key: []const u8) !void {
        var txn = try self.beginWriteTxn();
        defer txn.deinit();
        try txn.delete(key);
        try txn.commit();
    }

    // ---- 读路径（默认快照 = 当前 root） ----

    pub fn get(self: *Db, key: []const u8) !?[]u8 {
        const root = self.state.getRoot();
        return try btree.get(self.allocator, self.store, root, key);
    }

    pub fn select(self: *Db, min: ?[]const u8, max: ?[]const u8) !btree.Iterator {
        const root = self.state.getRoot();
        return try btree.select(self.allocator, self.store, root, min, max);
    }

    pub fn compact(self: *Db) !void {
        try self.state.compact();
    }

    /// 显式 sync（async 模式下手动冲刷已提交数据到磁盘）。
    pub fn sync(self: *Db) !void {
        try self.store.sync();
    }

    pub fn dirtCount(self: *Db) u64 {
        return self.state.dirtCount();
    }

    // ---- 显式事务 API（LMDB 式） ----

    /// 开写事务：单写者互斥。写暂存缓冲，commit 时 applyBatch+meta 切换+fsync。
    pub fn beginWriteTxn(self: *Db) !WriteTxn {
        self.write_mutex.lock() catch return error.LockFailed;
        return .{ .db = self, .staged = .empty, .finished = false };
    }

    /// 开读事务：取当前 root 快照，不阻写者（MVCC）。结束须调 endReadTxn/ReadTxn.end。
    pub fn beginReadTxn(self: *Db) !ReadTxn {
        _ = self.state.beginRead();
        return .{ .db = self, .snapshot_root = self.state.getRoot() };
    }

    pub fn beginRead(self: *Db) u64 {
        return self.state.beginRead();
    }

    pub fn endRead(self: *Db) void {
        self.state.endRead();
    }
};

/// 写事务（LMDB 式）。单写者互斥；写暂存缓冲，commit 时原子 applyBatch + meta 切换 + fsync。
/// abort 丢弃暂存，不应用。键/值为调用者拥有切片，事务存活期间须保持有效。
pub const WriteTxn = struct {
    db: *Db,
    staged: std.ArrayList(Entry),
    finished: bool,
    staged_freed: bool = false,

    pub fn put(self: *WriteTxn, key: []const u8, value: []const u8) !void {
        if (self.finished) return error.TxnFinished;
        try self.staged.append(self.db.allocator, .{ .key = key, .value = value, .tombstone = false });
    }

    pub fn delete(self: *WriteTxn, key: []const u8) !void {
        if (self.finished) return error.TxnFinished;
        try self.staged.append(self.db.allocator, .{ .key = key, .value = "", .tombstone = true });
    }

    /// 提交：applyBatch + meta 切换 + fsync。完成或出错后 finished=true，释放互斥。
    pub fn commit(self: *WriteTxn) !void {
        if (self.finished) return error.TxnFinished;
        self.finished = true;
        defer self.db.write_mutex.unlock();
        defer {
            self.staged_freed = true;
            self.staged.deinit(self.db.allocator);
        }
        if (self.staged.items.len == 0) return;

        const reqs = try self.db.allocator.alloc(wrt.Request, self.staged.items.len);
        defer self.db.allocator.free(reqs);
        var futures = try self.db.allocator.alloc(zio.Future(wrt.OpResult), self.staged.items.len);
        defer self.db.allocator.free(futures);
        for (self.staged.items, 0..) |e, i| {
            futures[i] = .{};
            reqs[i] = .{ .key = e.key, .value = e.value, .tombstone = e.tombstone, .future = &futures[i] };
        }
        try self.db.state.applyBatch(reqs);
        for (futures) |*f| _ = try f.wait();
    }

    /// 中止：丢弃暂存，不应用。释放互斥。
    pub fn abort(self: *WriteTxn) !void {
        if (self.finished) return;
        self.finished = true;
        self.staged_freed = true;
        self.staged.deinit(self.db.allocator);
        self.db.write_mutex.unlock();
    }

    /// 析构：未 commit/abort 时调 abort（防止泄漏互斥）。
    pub fn deinit(self: *WriteTxn) void {
        if (!self.staged_freed) {
            self.staged_freed = true;
            self.staged.deinit(self.db.allocator);
        }
        if (!self.finished) {
            self.finished = true;
            self.db.write_mutex.unlock();
        }
    }
};

/// 读事务（LMDB 式）。持有快照 root（MVCC），不阻写者。结束须调 end（或 deinit）。
pub const ReadTxn = struct {
    db: *Db,
    snapshot_root: u32,
    ended: bool = false,

    pub fn get(self: *ReadTxn, key: []const u8) !?[]u8 {
        return try btree.get(self.db.allocator, self.db.store, self.snapshot_root, key);
    }

    /// Zero-copy get: returns a borrowed slice into the page buffer.
    /// No allocation, no free needed. Valid for the ReadTxn's lifetime.
    /// Returns null for overflow values (use get() for those).
    pub fn getBorrowed(self: *ReadTxn, key: []const u8) !?[]const u8 {
        return try btree.getBorrowed(self.db.store, self.snapshot_root, key);
    }

    pub fn select(self: *ReadTxn, min: ?[]const u8, max: ?[]const u8) !btree.Iterator {
        return try btree.select(self.db.allocator, self.db.store, self.snapshot_root, min, max);
    }

    pub fn end(self: *ReadTxn) void {
        if (self.ended) return;
        self.ended = true;
        self.db.state.endRead();
    }

    pub fn deinit(self: *ReadTxn) void {
        self.end();
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
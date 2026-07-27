//! src/compactor.zig — Background compaction: flush memtable → B-tree.
//! Runs in a background thread, uses RwLock for exclusive B-tree access.
const std = @import("std");
const zio = @import("zio");
const ps = @import("page_store.zig");
const wrt = @import("writer.zig");
const wal_mod = @import("wal.zig");
const memtable_mod = @import("memtable.zig");
const db_mod = @import("db.zig");

const Mutex = zio.Mutex;
const Condition = zio.Condition;
const RwLock = zio.RwLock;

const Entry = db_mod.Entry;
const Request = wrt.Request;

/// Compactor: flushes immutable memtables to the B-tree in a background thread.
pub const Compactor = struct {
    allocator: std.mem.Allocator,
    state: *wrt.State,
    wal: *wal_mod.Wal,
    rwlock: *RwLock,

    thread: ?std.Thread,
    mutex: Mutex,
    cond: Condition,
    running: bool,
    pending_memtable: ?*memtable_mod.Memtable,

    pub fn init(
        allocator: std.mem.Allocator,
        state: *wrt.State,
        wal: *wal_mod.Wal,
        rwlock: *RwLock,
    ) Compactor {
        return .{
            .allocator = allocator,
            .state = state,
            .wal = wal,
            .rwlock = rwlock,
            .thread = null,
            .mutex = .{},
            .cond = .{},
            .running = false,
            .pending_memtable = null,
        };
    }

    pub fn deinit(self: *Compactor) void {
        self.stop();
    }

    pub fn start(self: *Compactor) !void {
        self.running = true;
        self.thread = try std.Thread.spawn(.{}, struct {
            fn run(c: *Compactor) void {
                c.threadLoop();
            }
        }.run, .{self});
    }

    pub fn stop(self: *Compactor) void {
        if (self.thread == null) return;
        self.running = false;
        {
            self.mutex.lock() catch {};
            self.cond.signal();
            self.mutex.unlock();
        }
        self.thread.?.join();
        self.thread = null;
    }

    pub fn signal(self: *Compactor, mt: *memtable_mod.Memtable) void {
        self.mutex.lock() catch {};
        defer self.mutex.unlock();
        self.pending_memtable = mt;
        self.cond.signal();
    }

    fn threadLoop(self: *Compactor) void {
        while (self.running) {
            self.mutex.lock() catch {};
            while (self.pending_memtable == null and self.running) {
                self.cond.wait(&self.mutex) catch continue;
            }
            const mt = self.pending_memtable orelse {
                self.mutex.unlock();
                continue;
            };
            self.pending_memtable = null;
            self.mutex.unlock();

            self.flush(mt) catch {};
        }
    }

    fn flush(self: *Compactor, mt: *memtable_mod.Memtable) !void {
        const entries = try mt.snapshot();
        defer self.allocator.free(entries);

        if (entries.len == 0) {
            try self.wal.truncate();
            mt.clear();
            return;
        }

        var reqs = try self.allocator.alloc(Request, entries.len);
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

        try self.rwlock.lock();
        defer self.rwlock.unlock();

        try self.state.applyBatch(reqs);

        for (futures) |*f| {
            _ = try f.wait();
        }

        try self.wal.truncate();
        mt.clear();
    }
};

test "compactor: flush memtable to empty btree" {
    const allocator = std.testing.allocator;
    var ms = ps.MemPageStore.init(allocator, 1000);
    defer ms.deinit();
    var db = try db_mod.Db.open(allocator, ms.store(), .{});
    defer db.close();

    var mt = memtable_mod.Memtable.init(allocator, 1024);
    defer mt.deinit();
    _ = try mt.put("hello", "world");
    _ = try mt.put("foo", "bar");

    const wal_path = ".wal_compactor_test1";
    defer zio.Dir.cwd().deleteFile(wal_path) catch {};
    var wal = try wal_mod.Wal.init(allocator, wal_path);
    defer wal.deinit();
    _ = try wal.append(.put, "hello", "world");
    _ = try wal.append(.put, "foo", "bar");

    var rwlock = RwLock{};
    var compactor = Compactor.init(allocator, db.state, &wal, &rwlock);
    defer compactor.deinit();

    try compactor.flush(&mt);

    {
        const v = try db.get("hello");
        defer if (v) |val| allocator.free(val);
        try std.testing.expectEqualStrings("world", v.?);
    }
    {
        const v = try db.get("foo");
        defer if (v) |val| allocator.free(val);
        try std.testing.expectEqualStrings("bar", v.?);
    }
    try std.testing.expectEqual(@as(usize, 0), mt.count());
}

test "compactor: flush with tombstones" {
    const allocator = std.testing.allocator;
    var ms = ps.MemPageStore.init(allocator, 1000);
    defer ms.deinit();
    var db = try db_mod.Db.open(allocator, ms.store(), .{});
    defer db.close();

    var mt = memtable_mod.Memtable.init(allocator, 1024);
    defer mt.deinit();
    _ = try mt.put("keep", "value");
    _ = try mt.delete("todelete");

    const wal_path = ".wal_compactor_ts";
    defer zio.Dir.cwd().deleteFile(wal_path) catch {};
    var wal = try wal_mod.Wal.init(allocator, wal_path);
    defer wal.deinit();
    _ = try wal.append(.put, "keep", "value");
    _ = try wal.append(.delete, "todelete", "");

    var rwlock = RwLock{};
    var compactor = Compactor.init(allocator, db.state, &wal, &rwlock);
    defer compactor.deinit();

    try compactor.flush(&mt);

    {
        const v = try db.get("keep");
        defer if (v) |val| allocator.free(val);
        try std.testing.expectEqualStrings("value", v.?);
    }
    const v = try db.get("todelete");
    if (v) |val| allocator.free(val);
}

test "compactor: background thread signal and flush" {
    const allocator = std.testing.allocator;
    var ms = ps.MemPageStore.init(allocator, 1000);
    defer ms.deinit();
    var db = try db_mod.Db.open(allocator, ms.store(), .{});
    defer db.close();

    var mt = memtable_mod.Memtable.init(allocator, 1024);
    defer mt.deinit();
    _ = try mt.put("bg", "thread");

    const wal_path = ".wal_compactor_bg";
    defer zio.Dir.cwd().deleteFile(wal_path) catch {};
    var wal = try wal_mod.Wal.init(allocator, wal_path);
    defer wal.deinit();
    _ = try wal.append(.put, "bg", "thread");

    var rwlock = RwLock{};
    var compactor = Compactor.init(allocator, db.state, &wal, &rwlock);
    defer compactor.deinit();

    try compactor.start();
    compactor.signal(&mt);
    // Wait for compaction to complete (spin until memtable cleared)
    var spins: u32 = 0;
    while (mt.count() > 0 and spins < 10000) : (spins += 1) {
        std.Thread.yield() catch {};
    }
    compactor.stop();

    const v = try db.get("bg");
    defer if (v) |val| allocator.free(val);
    try std.testing.expectEqualStrings("thread", v.?);
    try std.testing.expectEqual(@as(usize, 0), mt.count());
}
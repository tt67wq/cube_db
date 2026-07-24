//! compactor.zig — 自动 compaction：后台线程、分批扫描、树 diff 重放、退避重试
const std = @import("std");
const zio = @import("zio");
const f = @import("format.zig");
const store_mod = @import("store.zig");
const btree = @import("btree.zig");
const file_store = @import("file_store.zig");

const Store = store_mod.Store;

pub const Stats = struct {
    new_bt_root: u64 = btree.NULL_ROOT,
    entry_count: i64 = 0,
    live_bytes: i64 = 0,
};

pub fn tryStartCompact(db: anytype) void {
    if (db.state.closed.load(.acquire)) return;
    if (db.state.compacting.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    // join any previous compact thread before storing new one
    if (db.compact_thread) |old| {
        old.join();
        db.compact_thread = null;
    }
    if (std.Thread.spawn(.{}, runCompact, .{db})) |t| {
        db.compact_thread = t;
    } else |_| {
        db.state.compacting.store(false, .release);
    }
}

fn sleepMillis(ms: u64) void {
    if (ms == 0) return;
    var ts = std.posix.system.timespec{
        .sec = @as(isize, @intCast(ms / 1000)),
        .nsec = @as(isize, @intCast((ms % 1000) * 1_000_000)),
    };
    while (true) {
        const rc = std.posix.system.nanosleep(&ts, &ts);
        if (rc == 0) break;
    }
}

fn milliTimestamp() i64 {
    var ts: std.posix.system.timespec = undefined;
    _ = std.posix.system.clock_gettime(@as(std.posix.system.clockid_t, .MONOTONIC), &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn runCompact(db: anytype) void {
    defer db.state.compacting.store(false, .release);
    cleanupCompactFile(db);
    var attempt: u32 = 0;
    while (true) {
        const result = compactOnce(db);
        if (result) |_| {
            _ = db.state.compact_success_count.fetchAdd(1, .monotonic);
            return;
        } else |err| {
            attempt += 1;
            if (attempt >= db.state.opts.compact_max_retries or db.state.closed.load(.acquire)) {
                log.warn("auto compact gave up after {d} attempts: {s}", .{ attempt, @errorName(err) });
                _ = db.state.compact_fail_count.fetchAdd(1, .monotonic);
                return;
            }
            const shift = @min(attempt - 1, 5);
            const backoff_ms = @min(db.state.opts.compact_retry_base_ms << @intCast(shift), 60_000);
            var slept: u64 = 0;
            while (slept < backoff_ms) {
                if (db.state.closed.load(.acquire)) {
                    cleanupCompactFile(db);
                    return;
                }
                const chunk = @min(backoff_ms - slept, 100);
                sleepMillis(chunk);
                slept += chunk;
            }
            cleanupCompactFile(db);
            continue;
        }
    }
}

fn compactOnce(db: anytype) !void {
    const allocator = std.heap.c_allocator;
    const compact_path = try std.fmt.allocPrint(allocator, "{s}.compact", .{db.path});
    defer allocator.free(compact_path);

    var new_fs = try file_store.FileStore.create(allocator, compact_path);
    errdefer {
        new_fs.close();
        zio.Dir.cwd().deleteFile(compact_path) catch {};
    }
    const new_store = new_fs.store();

    const old_root_db = db.state.root.load(.acquire);
    const old_bt_root: u64 = if (old_root_db == 0) btree.NULL_ROOT else old_root_db - 1;

    var stats = Stats{};
    if (old_bt_root != btree.NULL_ROOT) {
        var it = try btree.select(allocator, db.state.store, old_bt_root, null, null);
        defer it.deinit();

        while (true) {
            const deadline = milliTimestamp() + @as(i64, @intCast(db.state.opts.compact_time_slice_ms));
            var exhausted = false;
            while (milliTimestamp() < deadline) {
                const maybe = try it.next();
                const e = maybe orelse { exhausted = true; break; };
                stats.new_bt_root = (try btree.insert(allocator, new_store, stats.new_bt_root, e.key, e.value, false)).new_root;
                stats.entry_count += 1;
                stats.live_bytes += @as(i64, @intCast(e.key.len + e.value.len + 9));
            }
            if (exhausted) break;
            if (db.state.closed.load(.acquire)) return error.Closed;
            if (db.state.opts.compact_scan_sleep_ms > 0) {
                sleepMillis(db.state.opts.compact_scan_sleep_ms);
            } else {
                std.Thread.yield() catch {};
            }
        }
    }

    try db.write_mutex.lock();
    defer db.write_mutex.unlock();

    if (db.state.closed.load(.acquire)) return error.Closed;

    const final_root_db = db.state.root.load(.acquire);
    const final_bt_root: u64 = if (final_root_db == 0) btree.NULL_ROOT else final_root_db - 1;

    if (old_bt_root != final_bt_root) {
        try diffApply(db, new_store, old_bt_root, final_bt_root, &stats);
    }

    std.debug.assert(stats.entry_count >= 0 and stats.live_bytes >= 0);

    try commitCompact(db, &new_fs, compact_path, stats.new_bt_root, @intCast(stats.entry_count), @intCast(stats.live_bytes));
    new_fs.close();
}

fn diffApply(db: anytype, new_store: Store, old_bt_root: u64, final_bt_root: u64, stats: *Stats) !void {
    const allocator = std.heap.c_allocator;
    var old_it = try btree.select(allocator, db.state.store, old_bt_root, null, null);
    defer old_it.deinit();
    var new_it = try btree.select(allocator, db.state.store, final_bt_root, null, null);
    defer new_it.deinit();

    var old_peek: ?btree.LeafEntry = null;
    var new_peek: ?btree.LeafEntry = null;

    old_peek = try old_it.next();
    new_peek = try new_it.next();

    while (true) {
        if (db.state.closed.load(.acquire)) return error.Closed;
        if (old_peek == null and new_peek == null) break;

        const use_old = old_peek != null and (new_peek == null or btree.cmpKey(old_peek.?.key, new_peek.?.key) == .lt);
        const use_new = new_peek != null and (old_peek == null or btree.cmpKey(new_peek.?.key, old_peek.?.key) == .lt);
        const use_eq = old_peek != null and new_peek != null and std.mem.eql(u8, old_peek.?.key, new_peek.?.key);

        if (use_eq) {
            const o = old_peek.?;
            const n = new_peek.?;
            if (!std.mem.eql(u8, o.value, n.value)) {
                stats.new_bt_root = (try btree.insert(allocator, new_store, stats.new_bt_root, n.key, n.value, false)).new_root;
                stats.live_bytes += @as(i64, @intCast(n.value.len)) - @as(i64, @intCast(o.value.len));
            }
            old_peek = try old_it.next();
            new_peek = try new_it.next();
        } else if (use_old) {
            const o = old_peek.?;
            stats.new_bt_root = (try btree.insert(allocator, new_store, stats.new_bt_root, o.key, "", true)).new_root;
            stats.entry_count -= 1;
            stats.live_bytes -= @as(i64, @intCast(o.key.len + o.value.len + 9));
            old_peek = try old_it.next();
        } else if (use_new) {
            const n = new_peek.?;
            stats.new_bt_root = (try btree.insert(allocator, new_store, stats.new_bt_root, n.key, n.value, false)).new_root;
            stats.entry_count += 1;
            stats.live_bytes += @as(i64, @intCast(n.key.len + n.value.len + 9));
            new_peek = try new_it.next();
        }
    }
}

pub fn commitCompact(db: anytype, new_fs: *file_store.FileStore, compact_path: []const u8, new_bt_root: u64, entry_count: u64, live_bytes: u64) !void {
    _ = try file_store.appendHeaderRecord(new_fs, .{
        .btree_root = if (new_bt_root == btree.NULL_ROOT) 0 else new_bt_root + 1,
        .entry_count = entry_count,
        .byte_size = live_bytes,
        .dirt = 0,
    });
    try new_fs.store().sync();

    db.fs.close();
    try zio.Dir.cwd().rename(compact_path, zio.Dir.cwd(), db.path);

    db.fs = try file_store.FileStore.create(db.allocator, db.path);
    db.store = db.fs.store();
    db.state.store = db.store;
    db.state.fs = &db.fs;
    db.state.root.store(if (new_bt_root == btree.NULL_ROOT) 0 else new_bt_root + 1, .release);
    db.state.dirt.store(0, .release);
    db.state.entry_count.store(entry_count, .release);
    db.state.byte_size.store(live_bytes, .release);
}

fn cleanupCompactFile(db: anytype) void {
    const compact_path = std.fmt.allocPrint(db.allocator, "{s}.compact", .{db.path}) catch return;
    defer db.allocator.free(compact_path);
    zio.Dir.cwd().deleteFile(compact_path) catch {};
}

const log = std.log.scoped(.compact);

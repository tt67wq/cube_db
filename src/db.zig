//! db.zig — DB 句柄：open/close/get/put/delete/select/compact
//! M4。D3 嵌入式库，纯同步 API。
const std = @import("std");
const zio = @import("zio");
const f = @import("format.zig");
const store_mod = @import("store.zig");
const btree = @import("btree.zig");
const file_store = @import("file_store.zig");
const writer = @import("writer.zig");
const compactor = @import("compactor.zig");

pub const Options = writer.Options;
pub const Store = store_mod.Store;

/// 批量写条目（putBatch）。
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
    tombstone: bool = false,
};

pub const Db = struct {
    allocator: std.mem.Allocator,
    fs: file_store.FileStore,
    store: Store,
    state: writer.State,
    /// 写互斥锁（串行化 applyBatch：leader 与 putBatch/compact）
    write_mutex: zio.Mutex,
    /// group commit 队列保护锁
    queue_mutex: zio.Mutex,
    /// 待合并的并发写请求（leader/follower）
    write_queue: std.ArrayListUnmanaged(writer.Request),
    /// 是否有 leader 正在服务
    has_leader: bool,
    path: []u8,

    /// auto compact OS 线程句柄（close 时 join）
    compact_thread: ?std.Thread = null,

    const Self = @This();

    /// 打开（或创建）数据库。
    pub fn open(allocator: std.mem.Allocator, path: []const u8, opts: Options) !*Db {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .fs = undefined,
            .store = undefined,
            .state = undefined,
            .write_mutex = .{},
            .queue_mutex = .{},
            .write_queue = std.ArrayListUnmanaged(writer.Request).empty,
            .has_leader = false,
            .path = try allocator.dupe(u8, path),
        };
        errdefer allocator.free(self.path);

        self.fs = try file_store.FileStore.create(allocator, path);
        self.store = self.fs.store();

        // 清除上次残留的 .compact（auto compact 半途崩溃）
        deleteCompactResidue(allocator, path);

        // 恢复 header
        const scan = try store_mod.getLatestHeader(allocator, self.store);
        var cur_root: u64 = 0;
        var cur_dirt: u64 = 0;
        var cur_count: u64 = 0;
        var cur_byte: u64 = 0;
        if (scan) |s| {
            cur_root = s.header.btree_root;
            cur_dirt = s.header.dirt;
            cur_count = s.header.entry_count;
            cur_byte = s.header.byte_size;
            // 物理截断到 header 末尾（§4.5）：消除尾部垃圾
            const header_end_logical = s.record_logical_offset + f.recordTotalSize(f.HEADER_PAYLOAD_SIZE);
            // header 记录后若还有逻辑字节则截断
            const cur_size = try self.store.size();
            if (cur_size > header_end_logical) {
                try self.store.setSize(header_end_logical);
            }
        }

        self.state = .{
            .allocator = allocator,
            .store = self.store,
            .fs = &self.fs,
            .root = std.atomic.Value(u64).init(cur_root),
            .dirt = std.atomic.Value(u64).init(cur_dirt),
            .entry_count = std.atomic.Value(u64).init(cur_count),
            .byte_size = std.atomic.Value(u64).init(cur_byte),
            .opts = opts,
            .closed = std.atomic.Value(bool).init(false),
            .compact_count = std.atomic.Value(u32).init(0),
        };
        self.write_mutex = .{};

        return self;
    }

    pub fn close(self: *Self) !void {
        self.state.closed.store(true, .release);
        // 先 join auto compact 线程
        if (self.compact_thread) |t| {
            t.join();
            self.compact_thread = null;
        }
        // 等可能正在进行的 manual compact（占 compacting 标志但无线程）
        while (self.state.compacting.load(.acquire)) {
            sleepMs(1);
        }
        self.store.sync() catch {};
        self.fs.close();
        self.write_queue.deinit(self.allocator);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    /// 读原子 root（DB 层 0=空，n>0=btree off+1；转 btree off 或 NULL_ROOT）
    fn currentBtreeRoot(self: *Self) u64 {
        const r = self.state.root.load(.acquire);
        return if (r == 0) btree.NULL_ROOT else r - 1;
    }

    /// 返回 value 由 allocator 分配，调用方负责 free。
    pub fn get(self: *Self, key: []const u8) !?[]u8 {
        const bt_root = self.currentBtreeRoot();
        return btree.get(self.allocator, self.store, bt_root, key);
    }

    pub fn put(self: *Self, key: []const u8, value: []const u8) !void {
        return self.sendRequest(key, value, false);
    }

    /// 批量写：一次 applyBatch + 一次 fsync，COW 摊薄（lever 1+2）。
    /// entries 内同 key 后者胜；不保证调用方顺序语义。
    pub fn putBatch(self: *Self, entries: []const Entry) !void {
        if (entries.len == 0) return;
        // 栈 future 受限，堆分配 future 数组（调用方释放责任轻；本函数内同生命周期）
        const futures = try self.allocator.alloc(zio.Future(writer.OpResult), entries.len);
        defer self.allocator.free(futures);
        const reqs = try self.allocator.alloc(writer.Request, entries.len);
        defer self.allocator.free(reqs);
        for (entries, 0..) |e, i| {
            futures[i] = .init;
            reqs[i] = .{
                .key = e.key,
                .value = if (e.tombstone) "" else e.value,
                .tombstone = e.tombstone,
                .future = &futures[i],
            };
        }
        try self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try writer.applyBatch(&self.state, reqs);
        // 自动 compact 触发
        tryStartAutoCompact(self);
        // 全部 future 已 set，收集结果
        var first_err: ?anyerror = null;
        for (futures) |*fut| {
            const r = try fut.wait();
            if (first_err == null) {
                if (r.value) |_| {} else |err| first_err = err;
            }
        }
        if (first_err) |err| return err;
    }

    pub fn putNoFsync(self: *Self, key: []const u8, value: []const u8) !void {
        // ponytail: MVP 不实现 fsync:false 的跳过；标记实现差异。后续 writer 按 opts.fsync 判断。
        // 当前 put 与 putNoFsync 行为一致（fsync 默认开）。
        return self.sendRequest(key, value, false);
    }

    pub fn delete(self: *Self, key: []const u8) !void {
        return self.sendRequest(key, "", true);
    }

    /// 错误路径让出 leader 身份（防 follower 死等）
    fn leaderReset(self: *Self) void {
        self.queue_mutex.lock() catch {};
        self.has_leader = false;
        self.queue_mutex.unlock();
    }

    fn sendRequest(self: *Self, key: []const u8, value: []const u8, tombstone: bool) !void {
        var future: zio.Future(writer.OpResult) = .init;
        const req: writer.Request = .{
            .key = key,
            .value = value,
            .tombstone = tombstone,
            .future = &future,
        };

        // 入队 + leader 选举（queue_mutex 保护 has_leader + write_queue）
        try self.queue_mutex.lock();
        self.write_queue.append(self.allocator, req) catch |err| {
            self.queue_mutex.unlock();
            return err;
        };
        if (self.has_leader) {
            // follower：req 已在队列，等 leader 处理后唤醒
            self.queue_mutex.unlock();
            const result = try future.wait();
            return result.value;
        }
        self.has_leader = true; // 我是 leader
        self.queue_mutex.unlock();

        // leader：持 write_mutex，循环清空队列 + applyBatch，直到队列空
        // 错误路径经 defer 让出 leader 身份；正常退出在 break 前已让出
        try self.write_mutex.lock();
        defer self.write_mutex.unlock();
        defer leaderReset(self);
        while (true) {
            try self.queue_mutex.lock();
            const batch = self.write_queue.toOwnedSlice(self.allocator) catch |err| {
                self.queue_mutex.unlock();
                return err;
            };
            if (batch.len == 0) {
                self.allocator.free(batch);
                self.has_leader = false; // 让出 leader，允许新 leader 接手
                self.queue_mutex.unlock();
                break;
            }
            self.queue_mutex.unlock();

            writer.applyBatch(&self.state, batch) catch |err| {
                // applyBatch 已 set 全部 future=err；defer leaderReset 让出 leader
                self.allocator.free(batch);
                return err;
            };
            // 自动 compact 触发
            tryStartAutoCompact(self);
            self.allocator.free(batch);
        }

        // leader 自己的 req 已被某批 applyBatch set
        const result = try future.wait();
        return result.value;
    }

    pub fn compact(self: *Self) !void {
        // 对称 CAS 占用 compacting，与 auto compact 互斥
        while (self.state.compacting.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
            sleepMs(1);
        }
        defer self.state.compacting.store(false, .release);

        try self.write_mutex.lock();
        defer self.write_mutex.unlock();
        return self.doCompact();
    }

    fn doCompact(self: *Self) !void {
        const allocator = self.allocator;
        const bt_root = self.currentBtreeRoot();
        if (bt_root == btree.NULL_ROOT) {
            self.state.dirt.store(0, .release);
            return;
        }
        const compact_path = try std.fmt.allocPrint(allocator, "{s}.compact", .{self.path});
        defer allocator.free(compact_path);
        const cwd = zio.Dir.cwd();
        cwd.deleteFile(compact_path) catch {};

        var new_fs = try file_store.FileStore.create(allocator, compact_path);
        errdefer {
            new_fs.close();
            cwd.deleteFile(compact_path) catch {};
        }
        const new_store = new_fs.store();

        var it = try btree.select(allocator, self.store, bt_root, null, null);
        defer it.deinit();
        var new_bt_root: u64 = btree.NULL_ROOT;
        var entry_count: u64 = 0;
        var live_bytes: u64 = 0;
        while (try it.next()) |e| {
            new_bt_root = (try btree.insert(allocator, new_store, new_bt_root, e.key, e.value, false)).new_root;
            entry_count += 1;
            live_bytes += e.key.len + e.value.len + 9;
        }
        _ = try file_store.appendHeaderRecord(&new_fs, .{
            .btree_root = if (new_bt_root == btree.NULL_ROOT) 0 else new_bt_root + 1,
            .entry_count = entry_count,
            .byte_size = live_bytes,
            .dirt = 0,
        });
        try new_store.sync();

        // 关旧 FD，rename 切换
        self.fs.close();
        try cwd.rename(compact_path, cwd, self.path);
        // ponytail: 父目录 fsync 跳过（MVP 注明；后续持有目录 FD + sync）

        // 重开新文件作为主 store
        self.fs = try file_store.FileStore.create(allocator, self.path);
        self.store = self.fs.store();
        self.state.store = self.store;
        self.state.fs = &self.fs;
        self.state.root.store(if (new_bt_root == btree.NULL_ROOT) 0 else new_bt_root + 1, .release);
        self.state.dirt.store(0, .release);
        self.state.entry_count.store(entry_count, .release);
        self.state.byte_size.store(live_bytes, .release);
    }

    pub fn select(self: *Self, min: ?[]const u8, max: ?[]const u8) !btree.Iterator {
        const bt_root = self.currentBtreeRoot();
        return btree.select(self.allocator, self.store, bt_root, min, max);
    }

    /// 检查 dirt 阈值，触发 auto compact
    fn tryStartAutoCompact(self: *Self) void {
        if (self.state.opts.auto_compact_dirt_ratio) |ratio| {
            const cur_dirt = self.state.dirt.load(.acquire);
            const cur_byte = self.state.byte_size.load(.acquire);
            const live = cur_byte;
            const total = cur_dirt + live;
            if (total >= self.state.opts.auto_compact_min_bytes and live > 0) {
                const dirt_ratio = @as(f64, @floatFromInt(cur_dirt)) / @as(f64, @floatFromInt(total));
                if (dirt_ratio >= @as(f64, @floatCast(ratio))) {
                    compactor.tryStartCompact(self);
                }
            }
        }
    }
};

fn sleepMs(ms: u64) void {
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

/// 清除 .compact 残留文件（open 时调用）
fn deleteCompactResidue(allocator: std.mem.Allocator, path: []const u8) void {
    const compact_path = std.fmt.allocPrint(allocator, "{s}.compact", .{path}) catch return;
    defer allocator.free(compact_path);
    zio.Dir.cwd().deleteFile(compact_path) catch {};
}

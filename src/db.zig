//! db.zig — DB 句柄：open/close/get/put/delete/select/compact
//! M4。D3 嵌入式库，纯同步 API。
const std = @import("std");
const zio = @import("zio");
const f = @import("format.zig");
const store_mod = @import("store.zig");
const btree = @import("btree.zig");
const file_store = @import("file_store.zig");
const writer = @import("writer.zig");

pub const Options = writer.Options;
pub const Store = store_mod.Store;

pub const Db = struct {
    allocator: std.mem.Allocator,
    fs: file_store.FileStore,
    store: Store,
    state: writer.State,
    /// 写互斥锁（串行化写操作）
    write_mutex: zio.Mutex,
    path: []u8,

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
            .path = try allocator.dupe(u8, path),
        };
        errdefer allocator.free(self.path);

        self.fs = try file_store.FileStore.create(allocator, path);
        self.store = self.fs.store();

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
        self.store.sync() catch {};
        self.fs.close();
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

    pub fn putNoFsync(self: *Self, key: []const u8, value: []const u8) !void {
        // ponytail: MVP 不实现 fsync:false 的跳过；标记实现差异。后续 writer 按 opts.fsync 判断。
        // 当前 put 与 putNoFsync 行为一致（fsync 默认开）。
        return self.sendRequest(key, value, false);
    }

    pub fn delete(self: *Self, key: []const u8) !void {
        return self.sendRequest(key, "", true);
    }

    fn sendRequest(self: *Self, key: []const u8, value: []const u8, tombstone: bool) !void {
        // ponytail: MVP 同步写——加写互斥锁保证串行（替代 D4 writer 协程）。
        try self.write_mutex.lock();
        defer self.write_mutex.unlock();
        var future: zio.Future(writer.OpResult) = .init;
        const req: writer.Request = .{
            .key = key,
            .value = value,
            .tombstone = tombstone,
            .future = &future,
        };
        var batch = [_]writer.Request{req};
        try writer.applyBatch(&self.state, &batch);
        const result = try future.wait();
        return result.value;
    }

    pub fn compact(self: *Self) !void {
        // ponytail: MVP 全量 compact。写互斥锁保护（与 put 串行）。
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
};

// ===== 测试 =====
// db 集成测试需 zio runtime 驱动，见 tests/db_test.zig。

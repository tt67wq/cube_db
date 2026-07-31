//! writer.zig — v2 batch 应用：COW B-tree (btree)、freelist 回收（MVCC 安全）、meta 交替提交
const std = @import("std");
const zio = @import("zio");
const f2 = @import("format.zig");
const ps = @import("page_store.zig");
const btree = @import("btree.zig");

const PageStore = ps.PageStore;

pub const Options = struct {
    fsync: bool = true,
    micro_batch: MicroBatchConfig = .{},
};

/// Micro-batching config: stage puts/deletes and commit in batches
/// to amortize COW + meta write + fsync overhead.
pub const MicroBatchConfig = struct {
    /// Max staged entries before auto-flush. 0 = disabled (direct commit).
    batch_threshold: usize = 0,
};

pub const OpResult = anyerror!void;

pub const Request = struct {
    key: []const u8,
    value: []const u8,
    tombstone: bool,
    future: *zio.Future(OpResult),
};

pub const State = struct {
    allocator: std.mem.Allocator,
    store: PageStore,
    root: std.atomic.Value(u32),
    sequence: std.atomic.Value(u64),
    dirt: std.atomic.Value(u64),
    entry_count: std.atomic.Value(u64),
    byte_size: std.atomic.Value(u64),
    opts: Options,
    closed: std.atomic.Value(bool),

    meta_index: u32,

    /// 活跃 reader 计数（0 = 无读者，可安全回收脏页）
    reader_count: std.atomic.Value(u32),

    /// 待回收的脏页（reader 活跃时积累，reader 归零后释放）
    pending_free: std.ArrayList(u32),

    pub fn init(allocator: std.mem.Allocator, store: PageStore, opts: Options) State {
        return .{
            .allocator = allocator,
            .store = store,
            .root = std.atomic.Value(u32).init(btree.NULL_ROOT),
            .sequence = std.atomic.Value(u64).init(0),
            .dirt = std.atomic.Value(u64).init(0),
            .entry_count = std.atomic.Value(u64).init(0),
            .byte_size = std.atomic.Value(u64).init(0),
            .opts = opts,
            .closed = std.atomic.Value(bool).init(false),
            .meta_index = 0,
            .reader_count = std.atomic.Value(u32).init(0),
            .pending_free = .empty,
        };
    }

    pub fn deinit(self: *State) void {
        self.closed.store(true, .release);
        // 释放剩余的 pending_free（safe: 写者线程结束，无读者）
        for (self.pending_free.items) |pn| self.store.freePage(pn);
        self.pending_free.deinit(self.allocator);
    }

    // ---- MVCC 读者 API ----

    /// 开始读事务。返回当前的 sequence（用于读一致性快照）。
    pub fn beginRead(self: *State) u64 {
        _ = self.reader_count.fetchAdd(1, .acquire);
        return self.sequence.load(.acquire);
    }

    /// 结束读事务。若 reader_count 归零，释放所有 pending dirty 页。
    pub fn endRead(self: *State) void {
        const prev = self.reader_count.fetchSub(1, .release);
        if (prev == 1) {
            // 最后一个读者退出 → 回收所有等待释放的页
            self.flushPendingFree();
        }
    }

    /// 返回当前等待释放的脏页数
    pub fn pendingFreeCount(self: *State) usize {
        return self.pending_free.items.len;
    }

    /// 返回当前 root（测试用）
    pub fn getRoot(self: *State) u32 {
        return self.root.load(.acquire);
    }

    /// compact：flush pending_free，写 meta（dirt=0），O(1)
    pub fn compact(self: *State) !void {
        // flush pending_free（无读者时立即；有读者时只 flush 当前可 flush 的）
        if (self.reader_count.load(.acquire) == 0) {
            self.flushPendingFree();
        } else {
            // 有读者：只 flush 现在的 pending 但标记为已处理
            // ponytail: MVP 不阻塞，只清计数
            self.dirt.store(0, .release);
        }
        // 写新 meta（dirt=0）
        const cur_root = self.root.load(.acquire);
        const cur_sequence = self.sequence.load(.acquire);
        const cur_entry_count = self.entry_count.load(.acquire);
        const cur_byte_size = self.byte_size.load(.acquire);
        const meta = f2.MetaPage{
            .magic = f2.MAGIC_V2,
            .version = 2,
            .mapsize = self.store.mapsize(),
            .sequence = cur_sequence + 1,
            .root_page = cur_root,
            .entry_count = cur_entry_count,
            .byte_size = cur_byte_size,
            .free_head = 0,
            .free_count = 0,
            .last_page = 0,
        };
        try self.store.writeMeta(&meta);
        if (self.opts.fsync) {
            try self.store.sync();
        }
        self.sequence.store(cur_sequence + 1, .release);
        self.dirt.store(0, .release);
    }

    /// 返回 dirt 计数（测试用）
    pub fn dirtCount(self: *State) u64 {
        return self.dirt.load(.acquire);
    }

    // ---- 内部 ----

    /// 清理 pending_free：*不*检查 reader_count（由调用方保证安全）
    fn flushPendingFree(self: *State) void {
        for (self.pending_free.items) |pn| {
            self.store.freePage(pn);
        }
        self.pending_free.clearRetainingCapacity();
        self.dirt.store(0, .release);
    }

    /// 应用一批写请求到 B-tree，提交 meta，fsync，更新原子状态
    pub fn applyBatch(self: *State, batch: []const Request) !void {
        if (self.closed.load(.acquire)) {
            for (batch) |r| r.future.set(error.Closed);
            return;
        }

        // 1. 快照当前 root
        const cur_root = self.root.load(.acquire);
        const cur_sequence = self.sequence.load(.acquire);
        const cur_entry_count = self.entry_count.load(.acquire);
        const cur_byte_size = self.byte_size.load(.acquire);

        // 2. Arena for COW path temporary allocations (key/value dupe, Leaf/Branch decode).
        // Eliminates per-allocation syscall overhead: ~145 alloc/free per btree.insert
        // collapses to arena bump-pointer, freed in one shot at batch end.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // 收集脏页（arena-backed: btree.insert 用 arena_alloc append）
        var batch_dirty = std.ArrayList(u32).empty;
        defer batch_dirty.deinit(arena_alloc);
        var batch_entry_delta: i64 = 0;
        var batch_byte_delta: i64 = 0;
        var new_root = cur_root;

        // Sort and dedup entries by key, then batch insert via shared COW path
        if (batch.len > 1) {
            const SortCtx = struct {
                fn lt(_: void, a: Request, b: Request) bool {
                    return btree.cmpKey(a.key, b.key) == .lt;
                }
            };
            std.mem.sort(Request, @constCast(batch), {}, SortCtx.lt);
        }
        // Build LeafEntry array from sorted+deduped requests (copy key/value — caller slices may not survive)
        const sorted = try arena_alloc.alloc(btree.LeafEntry, batch.len);
        var n: usize = 0;
        for (batch) |req| {
            if (n > 0 and btree.cmpKey(sorted[n - 1].key, req.key) == .eq) {
                sorted[n - 1] = .{ .tombstone = req.tombstone, .key = try arena_alloc.dupe(u8, req.key), .value = if (req.tombstone) "" else try arena_alloc.dupe(u8, req.value) };
            } else {
                sorted[n] = .{ .tombstone = req.tombstone, .key = try arena_alloc.dupe(u8, req.key), .value = if (req.tombstone) "" else try arena_alloc.dupe(u8, req.value) };
                n += 1;
            }
        }
        const entries = sorted[0..n];

        const wr = btree.insertBatch(arena_alloc, self.store, new_root, entries, &batch_dirty) catch |err| {
            for (batch) |r| r.future.set(err);
            return;
        };
        new_root = wr.new_root;
        batch_entry_delta += wr.count_delta;
        batch_byte_delta += wr.live_delta;

        // 3. 本批脏页进 pending_free（不立即回收，MVCC 安全）
        for (batch_dirty.items) |pn| {
            self.pending_free.append(self.allocator, pn) catch {};
        }

        // 4. 计算新 meta 值
        const new_sequence = cur_sequence + 1;
        const new_entry_count_signed: i64 = @as(i64, @intCast(cur_entry_count)) + batch_entry_delta;
        const new_entry_count: u64 = @intCast(@max(@as(i64, 0), new_entry_count_signed));
        const new_byte_signed: i64 = @as(i64, @intCast(cur_byte_size)) + batch_byte_delta;
        const new_byte: u64 = @intCast(@max(@as(i64, 0), new_byte_signed));

        // 5. 写 meta
        const meta = f2.MetaPage{
            .magic = f2.MAGIC_V2,
            .version = 2,
            .mapsize = self.store.mapsize(),
            .sequence = new_sequence,
            .root_page = new_root,
            .entry_count = new_entry_count,
            .byte_size = new_byte,
            .free_head = 0,
            .free_count = 0,
            .last_page = 0,
        };
        try self.store.writeMeta(&meta);

        // 6. fsync
        if (self.opts.fsync) {
            try self.store.sync();
        }

        // 7. 原子更新状态
        self.root.store(new_root, .release);
        self.sequence.store(new_sequence, .release);
        self.dirt.store(@intCast(self.pending_free.items.len), .release);
        self.entry_count.store(new_entry_count, .release);
        self.byte_size.store(new_byte, .release);

        // 8. 所有请求成功
        for (batch) |req| {
            req.future.set({});
        }

        // 9. 若此时无读者，立即回收脏页
        if (self.reader_count.load(.acquire) == 0) {
            self.flushPendingFree();
        }
    }
};

test "writer: State init defaults" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100);
    defer ms.deinit();
    var state = State.init(std.testing.allocator, ms.store(), .{});
    defer state.deinit();
    try std.testing.expectEqual(btree.NULL_ROOT, state.root.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.sequence.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.dirt.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.entry_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.byte_size.load(.acquire));
}

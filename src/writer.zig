//! writer.zig — v2 batch 应用：COW B-tree (btree)、freelist 回收（MVCC 安全）、meta 交替提交
const std = @import("std");
const zio = @import("zio");
const f2 = @import("format.zig");
const ps = @import("page_store.zig");
const btree = @import("btree.zig");

const PageStore = ps.PageStore;

/// 分段耗时剖析（#35）：编译期开启，不进生产热路径。
/// 用法：profile tool 设置 enable=true，applyBatch 各段累加耗时。
pub const ProfileStats = struct {
    pub var enable: bool = false;

    // 各段耗时（ns）与调用次数
    pub var txn_dupe_ns: u64 = 0;
    pub var txn_sort_ns: u64 = 0;
    pub var txn_dedup_ns: u64 = 0;
    pub var txn_insertbatch_ns: u64 = 0;
    pub var txn_pending_free_ns: u64 = 0;
    pub var txn_flush_free_ns: u64 = 0;
    pub var txn_meta_ns: u64 = 0;
    pub var txn_total_ns: u64 = 0;
    pub var txn_count: u64 = 0;
    pub var txn_entries: u64 = 0;
    // db 层（staging/futures）
    pub var db_staging_ns: u64 = 0;
    pub var db_reqs_ns: u64 = 0;
    pub var db_futures_wait_ns: u64 = 0;

    pub fn reset() void {
        txn_dupe_ns = 0;
        txn_sort_ns = 0;
        txn_dedup_ns = 0;
        txn_insertbatch_ns = 0;
        txn_pending_free_ns = 0;
        txn_flush_free_ns = 0;
        txn_meta_ns = 0;
        txn_total_ns = 0;
        txn_count = 0;
        txn_entries = 0;
        db_staging_ns = 0;
        db_reqs_ns = 0;
        db_futures_wait_ns = 0;
    }

    pub fn now() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
    }

    pub fn print() void {
        if (txn_count == 0) return;
        std.debug.print("\n=== applyBatch 分段耗时 (page_allocator) ===\n", .{});
        std.debug.print("  总批次数: {d}, 总条目数: {d}\n", .{ txn_count, txn_entries });
        const avg = @divFloor(txn_total_ns, txn_count);
        std.debug.print("  平均每批: {d} ns ({d:.2} ms)\n", .{ avg, @as(f64, @floatFromInt(avg)) / 1_000_000.0 });
        const per_entry = @divFloor(txn_total_ns, @max(txn_entries, 1));
        std.debug.print("  每 entry:  {d} ns ({d:.3} us)\n", .{ per_entry, @as(f64, @floatFromInt(per_entry)) / 1000.0 });
        inline for (.{
            .{ "dupe        ", txn_dupe_ns },
            .{ "sort        ", txn_sort_ns },
            .{ "dedup       ", txn_dedup_ns },
            .{ "insertBatch ", txn_insertbatch_ns },
            .{ "pending_free", txn_pending_free_ns },
            .{ "flush_free  ", txn_flush_free_ns },
            .{ "meta+write  ", txn_meta_ns },
        }) |row| {
            const pct = @as(f64, @floatFromInt(row[1])) / @as(f64, @floatFromInt(@max(txn_total_ns, 1))) * 100.0;
            const p_entry = @divFloor(row[1], @max(txn_entries, 1));
            std.debug.print("  {s}: {d:>12} ns ({d:.1}%)  {d} ns/entry\n", .{ row[0], row[1], pct, p_entry });
        }
        std.debug.print("  --- db 层 ---\n", .{});
        inline for (.{
            .{ "staging     ", db_staging_ns },
            .{ "reqs+futures", db_reqs_ns },
            .{ "futures.wait", db_futures_wait_ns },
        }) |row| {
            const p_entry = @divFloor(row[1], @max(txn_entries, 1));
            std.debug.print("  {s}: {d:>12} ns  {d} ns/entry\n", .{ row[0], row[1], p_entry });
        }
    }
};

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
        const prof = ProfileStats.enable;
        const t0 = if (prof) ProfileStats.now() else 0;
        for (self.pending_free.items) |pn| {
            self.store.freePage(pn);
        }
        self.pending_free.clearRetainingCapacity();
        self.dirt.store(0, .release);
        if (prof) ProfileStats.txn_flush_free_ns += @intCast(ProfileStats.now() - t0);
    }

    /// 应用一批写请求到 B-tree，提交 meta，fsync，更新原子状态
    pub fn applyBatch(self: *State, batch: []const Request) !void {
        if (self.closed.load(.acquire)) {
            for (batch) |r| r.future.set(error.Closed);
            return;
        }

        const prof = ProfileStats.enable;
        const t0 = if (prof) ProfileStats.now() else 0;

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

        // Fast path for single entry: use insert directly (avoids sort/dupe/insertBatch overhead)
        if (batch.len == 1) {
            const wr = btree.insert(arena_alloc, self.store, new_root, batch[0].key, batch[0].value, batch[0].tombstone, &batch_dirty) catch |err| {
                for (batch) |r| r.future.set(err);
                return;
            };
            new_root = wr.new_root;
            batch_entry_delta += wr.count_delta;
            batch_byte_delta += wr.live_delta;
        } else {
            // Copy keys/values into arena first (caller slices may not survive — e.g. stack buffer reuse)
        const t_dupe0 = if (prof) ProfileStats.now() else 0;
        const arena_entries = try arena_alloc.alloc(btree.LeafEntry, batch.len);
        // 预分配连续 key/value 缓冲区（单次分配），memcpy 进去，排序读取连续内存（热 cache）
        var key_buf_len: usize = 0;
        for (batch) |req| {
            key_buf_len += req.key.len;
            if (!req.tombstone) key_buf_len += req.value.len;
        }
        const key_buf = try arena_alloc.alloc(u8, key_buf_len);
        var key_off: usize = 0;
        for (batch, 0..) |req, i| {
            @memcpy(key_buf[key_off..][0..req.key.len], req.key);
            const k = key_buf[key_off..][0..req.key.len];
            key_off += req.key.len;
            var v: []const u8 = "";
            if (!req.tombstone) {
                @memcpy(key_buf[key_off..][0..req.value.len], req.value);
                v = key_buf[key_off..][0..req.value.len];
                key_off += req.value.len;
            }
            arena_entries[i] = .{ .tombstone = req.tombstone, .key = k, .value = v };
        }
        if (prof) ProfileStats.txn_dupe_ns += @intCast(ProfileStats.now() - t_dupe0);

        // Sort by key
        const t_sort0 = if (prof) ProfileStats.now() else 0;
        if (arena_entries.len > 1) {
            const SortCtx = struct {
                fn lt(_: void, a: btree.LeafEntry, b: btree.LeafEntry) bool {
                    return btree.cmpKey(a.key, b.key) == .lt;
                }
            };
            std.mem.sort(btree.LeafEntry, arena_entries, {}, SortCtx.lt);
        }
        if (prof) ProfileStats.txn_sort_ns += @intCast(ProfileStats.now() - t_sort0);

        // Dedup (last write wins)
        const t_dedup0 = if (prof) ProfileStats.now() else 0;
        var n: usize = 0;
        for (arena_entries) |e| {
            if (n > 0 and btree.cmpKey(arena_entries[n - 1].key, e.key) == .eq) {
                arena_entries[n - 1] = e;
            } else {
                arena_entries[n] = e;
                n += 1;
            }
        }
        const entries = arena_entries[0..n];
        if (prof) ProfileStats.txn_dedup_ns += @intCast(ProfileStats.now() - t_dedup0);

        const t_ib0 = if (prof) ProfileStats.now() else 0;
        const wr = btree.insertBatch(arena_alloc, self.store, new_root, entries, &batch_dirty) catch |err| {
            for (batch) |r| r.future.set(err);
            return;
        };
        if (prof) ProfileStats.txn_insertbatch_ns += @intCast(ProfileStats.now() - t_ib0);
        new_root = wr.new_root;
        batch_entry_delta += wr.count_delta;
        batch_byte_delta += wr.live_delta;
        } // end else (batch.len > 1)

        // 3. 本批脏页进 pending_free（不立即回收，MVCC 安全）
        const t_pf0 = if (prof) ProfileStats.now() else 0;
        for (batch_dirty.items) |pn| {
            self.pending_free.append(self.allocator, pn) catch {};
        }
        if (prof) ProfileStats.txn_pending_free_ns += @intCast(ProfileStats.now() - t_pf0);

        // 4. 计算新 meta 值
        const new_sequence = cur_sequence + 1;
        const new_entry_count_signed: i64 = @as(i64, @intCast(cur_entry_count)) + batch_entry_delta;
        const new_entry_count: u64 = @intCast(@max(@as(i64, 0), new_entry_count_signed));
        const new_byte_signed: i64 = @as(i64, @intCast(cur_byte_size)) + batch_byte_delta;
        const new_byte: u64 = @intCast(@max(@as(i64, 0), new_byte_signed));

        // 5. 写 meta
        const t_meta0 = if (prof) ProfileStats.now() else 0;
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
        if (prof) ProfileStats.txn_meta_ns += @intCast(ProfileStats.now() - t_meta0);

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

        if (prof) {
            ProfileStats.txn_total_ns += @intCast(ProfileStats.now() - t0);
            ProfileStats.txn_count += 1;
            ProfileStats.txn_entries += batch.len;
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

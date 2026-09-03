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

    /// Micro-batching: staged entries pending commit
    batch_threshold: usize,
    pending: std.ArrayList(Entry),

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
            .batch_threshold = opts.micro_batch.batch_threshold,
            .pending = .empty,
        };
        return db;
    }

    pub fn close(self: *Db) void {
        // Auto-flush any pending entries before closing
        self.flush() catch {};
        // If flush failed, still free pending to avoid leak
        for (self.pending.items) |e| {
            self.allocator.free(e.key);
            if (!e.tombstone) self.allocator.free(e.value);
        }
        self.pending.deinit(self.allocator);
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

    /// Put with optional micro-batching: if batch_threshold > 0, stages the entry;
    /// auto-flushes when threshold reached. Use flush() to force commit.
    /// Use putDirect() to bypass micro-batching entirely.
    pub fn put(self: *Db, key: []const u8, value: []const u8) !void {
        if (self.batch_threshold == 0) return self.putDirect(key, value);
        // Copy key and value — caller's slices may not live until flush
        const k = try self.allocator.dupe(u8, key);
        const v = try self.allocator.dupe(u8, value);
        try self.pending.append(self.allocator, .{ .key = k, .value = v, .tombstone = false });
        if (self.pending.items.len >= self.batch_threshold) {
            try self.flush();
        }
    }

    /// Delete with optional micro-batching (same logic as put).
    pub fn delete(self: *Db, key: []const u8) !void {
        if (self.batch_threshold == 0) return self.deleteDirect(key);
        const k = try self.allocator.dupe(u8, key);
        try self.pending.append(self.allocator, .{ .key = k, .value = "", .tombstone = true });
        if (self.pending.items.len >= self.batch_threshold) {
            try self.flush();
        }
    }

    /// Direct put — bypasses micro-batching, commits immediately.
    pub fn putDirect(self: *Db, key: []const u8, value: []const u8) !void {
        var txn = try self.beginWriteTxn();
        defer txn.deinit();
        try txn.put(key, value);
        try txn.commit();
    }

    /// Direct delete — bypasses micro-batching, commits immediately.
    pub fn deleteDirect(self: *Db, key: []const u8) !void {
        var txn = try self.beginWriteTxn();
        defer txn.deinit();
        try txn.delete(key);
        try txn.commit();
    }

    /// Flush pending staged entries via a single batch commit.
    /// No-op if nothing pending. Frees copied key/value strings after commit.
    pub fn flush(self: *Db) !void {
        if (self.pending.items.len == 0) return;
        defer {
            for (self.pending.items) |e| {
                self.allocator.free(e.key);
                if (!e.tombstone) self.allocator.free(e.value);
            }
            self.pending.clearRetainingCapacity();
        }
        try self.putBatch(self.pending.items);
    }

    /// Batch put: commit all entries in one WriteTxn (bypasses micro-batching).
    /// Keys and values are copied internally, so caller's slices only need to be
    /// valid during the putBatch call itself (not after).
    pub fn putBatch(self: *Db, entries: []const Entry) !void {
        // 直接批量构建：跳过 per-entry staging + arena dupe。
        // Request 直接引用调用方的 key/value 切片（applyBatch 内 insertBatch 会 dupe 到 leaf，
        // 切片只需在 putBatch 调用期间有效即可）。
        // 调用方须保证 entries 的 key/value 在 putBatch 调用期间有效（值语义由调用方保证）。
        self.write_mutex.lock() catch return error.LockFailed;
        defer self.write_mutex.unlock();

        const reqs = try self.allocator.alloc(wrt.Request, entries.len);
        defer self.allocator.free(reqs);
        var futures = try self.allocator.alloc(zio.Future(wrt.OpResult), entries.len);
        defer self.allocator.free(futures);

        const prof = wrt.ProfileStats.enable;
        const t0 = if (prof) wrt.ProfileStats.now() else 0;

        for (entries, 0..) |e, i| {
            futures[i] = .{};
            reqs[i] = .{ .key = e.key, .value = e.value, .tombstone = e.tombstone, .future = &futures[i] };
        }

        if (prof) wrt.ProfileStats.db_staging_ns += @intCast(wrt.ProfileStats.now() - t0);
        try self.state.applyBatch(reqs);
        for (futures) |*f| try (try f.wait()).value;
    }

    /// Delete all keys k in [min, max) — half-open, same boundary semantics as select.
    /// null min/max = unbounded (null, null) deletes every key.
    /// Idempotent on already-missing keys. No-op (success) when range is inverted/empty.
    pub fn deleteRange(self: *Db, min: ?[]const u8, max: ?[]const u8) !void {
        // Inverted/empty range → no-op success, no side effects (don't even flush).
        if (min) |m| {
            if (max) |mx| {
                if (btree.cmpKey(m, mx) != .lt) return;
            }
        }
        // Micro-batch: the select iterator reads the committed root only, so pending
        // staged puts/deletes must be flushed first to be visible (and deletable).
        try self.flush();
        // Collect keys in [min, max) — iterator entries are borrowed and next()
        // invalidates the previous entry, so dupe keys for the tombstone batch.
        var keys: std.ArrayList([]const u8) = .empty;
        defer {
            for (keys.items) |k| self.allocator.free(k);
            keys.deinit(self.allocator);
        }
        var it = try self.select(min, max);
        defer it.deinit();
        while (try it.next()) |e| {
            try keys.append(self.allocator, try self.allocator.dupe(u8, e.key));
        }
        if (keys.items.len == 0) return;
        const entries = try self.allocator.alloc(Entry, keys.items.len);
        defer self.allocator.free(entries);
        for (keys.items, 0..) |k, i| {
            entries[i] = .{ .key = k, .value = "", .tombstone = true };
        }
        try self.putBatch(entries);
    }

    // ---- 读路径（默认快照 = 当前 root） ----

    pub fn get(self: *Db, key: []const u8) !?[]u8 {
        const root = self.state.getRoot();
        return try btree.get(self.allocator, self.store, root, key);
    }

    /// 无拷贝点查（T-29 Phase A）：value 拷入调用方 buffer，返回写入字节数；
    /// key 不存在 → null；buffer 不足 → error.BufferTooSmall（buffer 不被写入/清空）。
    /// 高频读调用方（缓存/索引层）用它摆脱 get() 的 per-call alloc/free。
    pub fn getInto(self: *Db, key: []const u8, buffer: []u8) !?usize {
        const root = self.state.getRoot();
        return try btree.getInto(self.store, root, key, buffer);
    }

    /// 范围查询（T-29 Phase B 借用化）：返回借用迭代器——next() 的 entry 切片
    /// 仅到下次 next()/deinit() 有效（溢出值经内部复用缓冲拼接）；迭代器 pin 住
    /// MVCC 读者名额，写者 COW 脏页延迟到 deinit()（末位读者）才回收，迭代中
    /// 途的写提交不影响已借用页。忘记 deinit 会滞留读者名额（脏页不回收）。
    pub fn select(self: *Db, min: ?[]const u8, max: ?[]const u8) !btree.Iterator {
        // T-29 review 发现1（major）：读者名额必须先于 root 快照捕获注册——
        // 若先 getRoot() 后 beginRead()，两条指令间的窗口内写者 grace-period
        // 回收（applyBatch 见 reader_count==0 即 flush）可释放快照 root 引用的
        // 旧页。先注册后捕获：无论读到旧/新 root，其 COW 旧页均滞留 pending_free
        // 到迭代器 deinit（末位读者）才回收。
        _ = self.state.beginRead(); // MVCC pin：迭代器借用页的快照保护
        errdefer self.state.endRead();
        const root = self.state.getRoot();
        var it = try btree.select(self.allocator, self.store, root, min, max);
        it.pin_ctx = @ptrCast(self.state);
        it.pin_deinit = endReadPin;
        return it;
    }

    pub fn compact(self: *Db) !void {
        // 与 applyBatch 共享 root/sequence/meta 写，须经写互斥串行（避免 meta 交错写）。
        self.write_mutex.lock() catch return error.LockFailed;
        defer self.write_mutex.unlock();
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
        return .{
            .db = self,
            .staged = .empty,
            .finished = false,
            // Arena for staging: put/delete dupe 进 arena，commit/abort 统一释放，零 syscall
            .staging_arena = std.heap.ArenaAllocator.init(self.allocator),
        };
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
/// abort 丢弃暂存，不应用。键/值为调用者拥有切片，put/delete 时立即 dupe 进 staging arena。
pub const WriteTxn = struct {
    db: *Db,
    staged: std.ArrayList(Entry),
    finished: bool,
    staging_arena: std.heap.ArenaAllocator,
    arena_freed: bool = false,

    pub fn put(self: *WriteTxn, key: []const u8, value: []const u8) !void {
        if (self.finished) return error.TxnFinished;
        // 复制 key/value 进 arena —— 调用方 slice（如栈 buffer）可能不活到 commit
        const alloc = self.staging_arena.allocator();
        const k = try alloc.dupe(u8, key);
        const v = try alloc.dupe(u8, value);
        try self.staged.append(alloc, .{ .key = k, .value = v, .tombstone = false });
    }

    pub fn delete(self: *WriteTxn, key: []const u8) !void {
        if (self.finished) return error.TxnFinished;
        // 复制 key 进 arena —— 调用方 slice 可能不活到 commit
        const alloc = self.staging_arena.allocator();
        const k = try alloc.dupe(u8, key);
        try self.staged.append(alloc, .{ .key = k, .value = "", .tombstone = true });
    }

    /// 提交：applyBatch + meta 切换 + fsync。完成或出错后 finished=true，释放互斥。
    /// staging arena 在 commit 完成后统一释放（applyBatch 已把 key/value dupe 进自己的 arena，
    /// 页面写入是 copy 语义，无残留引用）。
    pub fn commit(self: *WriteTxn) !void {
        if (self.finished) return error.TxnFinished;
        self.finished = true;
        defer self.db.write_mutex.unlock();
        defer {
            self.arena_freed = true;
            self.staging_arena.deinit();
        }
        if (self.staged.items.len == 0) return;

        // Arena for futures allocation — avoids large stack frame when batch is big
        var commit_arena = std.heap.ArenaAllocator.init(self.db.allocator);
        defer commit_arena.deinit();
        const arena_alloc = commit_arena.allocator();

        const prof = wrt.ProfileStats.enable;
        const t_reqs0 = if (prof) wrt.ProfileStats.now() else 0;
        const reqs = try arena_alloc.alloc(wrt.Request, self.staged.items.len);
        var futures = try arena_alloc.alloc(zio.Future(wrt.OpResult), self.staged.items.len);
        for (self.staged.items, 0..) |e, i| {
            futures[i] = .{};
            reqs[i] = .{ .key = e.key, .value = e.value, .tombstone = e.tombstone, .future = &futures[i] };
        }
        if (prof) wrt.ProfileStats.db_reqs_ns += @intCast(wrt.ProfileStats.now() - t_reqs0);
        try self.db.state.applyBatch(reqs);
        const t_wait0 = if (prof) wrt.ProfileStats.now() else 0;
        for (futures) |*f| try (try f.wait()).value;
        if (prof) wrt.ProfileStats.db_futures_wait_ns += @intCast(wrt.ProfileStats.now() - t_wait0);
    }

    /// 中止：丢弃暂存，不应用。释放互斥。arena 整体释放。
    pub fn abort(self: *WriteTxn) !void {
        if (self.finished) return;
        self.finished = true;
        self.arena_freed = true;
        self.staging_arena.deinit();
        self.db.write_mutex.unlock();
    }

    /// 析构：未 commit/abort 时调 abort（防止泄漏互斥）。
    pub fn deinit(self: *WriteTxn) void {
        if (!self.arena_freed) {
            self.arena_freed = true;
            self.staging_arena.deinit();
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

    /// 无拷贝点查（T-29 Phase A）：语义同 Db.getInto（null=key 不存在，
    /// BufferTooSmall=buffer 不足且不写入），快照 pin 于本 txn 的 root。
    pub fn getInto(self: *ReadTxn, key: []const u8, buffer: []u8) !?usize {
        return try btree.getInto(self.db.store, self.snapshot_root, key, buffer);
    }

    /// 范围查询（T-29 Phase B 借用化）：借用契约同 Db.select（next() 失效上一 entry）。
    /// 快照 pin 于本 txn 的 root；迭代器另持独立 MVCC 读者名额（与 txn 的 pin
    /// 可叠加，读者计数为增量），deinit() 释放——txn 结束前迭代器仍须 deinit。
    pub fn select(self: *ReadTxn, min: ?[]const u8, max: ?[]const u8) !btree.Iterator {
        _ = self.db.state.beginRead(); // 迭代器独立 pin（deinit 释放）
        errdefer self.db.state.endRead();
        var it = try btree.select(self.db.allocator, self.db.store, self.snapshot_root, min, max);
        it.pin_ctx = @ptrCast(self.db.state);
        it.pin_deinit = endReadPin;
        return it;
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

/// btree.Iterator 的 MVCC pin 回调（T-29 Phase B）：deinit 时释放读者名额。
/// btree 层不依赖 wrt.State，经 opaque 回调解耦。
fn endReadPin(ctx: *anyopaque) void {
    const st: *wrt.State = @ptrCast(@alignCast(ctx));
    st.endRead();
}
test "db: open default state" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();
    try std.testing.expectEqual(@as(u32, btree.NULL_ROOT), db.getRoot());
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}
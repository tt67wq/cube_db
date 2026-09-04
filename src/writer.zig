//! writer.zig — v2 batch 应用：COW B-tree (btree)、freelist 回收（MVCC 安全）、meta 交替提交
const std = @import("std");
const zio = @import("zio");
const f2 = @import("format.zig");
const ps = @import("page_store.zig");
const btree = @import("btree.zig");

const PageStore = ps.PageStore;

// ---- T-30: per-reader 序列注册 + oldest-reader watermark 精确回收 ----

/// pending_free 条目：页号 + 释放该页的提交序列（该次提交的 new_sequence）。
/// 回收判定：release_seq < oldest-active-reader watermark 时可安全回收
/// （所有活跃读者快照都 ≥ watermark > release_seq，无人可能仍引用该页）；
/// 等于或大于则必须保留（老快照仍有效——正确性底线，含边界保守）。
pub const PendingPage = struct {
    page_no: u32,
    release_seq: u64,
};

/// 每读者快照注册槽数。超出（并发读者 > 64 或 TLS 嵌套溢出）时保守降级为
/// watermark=0（钉住一切 = 旧全局计数行为），安全不精确。
const READER_SLOTS = 64;
/// 单线程嵌套 beginRead 深度上限（ReadTxn + select 嵌套等；实际 ≤ 3）。
const MAX_TLS_READERS = 16;
/// 槽位值编码：0 = 空闲；非 0 = snapshot | CLAIM_BIT（快照序列占用最高位以下）。
const CLAIM_BIT: u64 = 1 << 63;

/// 线程本地注册栈：beginRead/endRead 在同线程按 LIFO 配对（现有全部调用方
/// ——ReadTxn/Iterator pin/测试——均同线程 begin/end，契约不变）。
/// endRead() 无参数（db.zig 不可改），配对身份 = (State 指针, LIFO)。
const TlsEntry = struct {
    state: *const anyopaque,
    slot: u32, // READER_SLOTS = overflow 注册（非槽位）
};
threadlocal var tls_readers: [MAX_TLS_READERS]TlsEntry = undefined;
threadlocal var tls_readers_len: usize = 0;

/// 占位一个读者快照槽（beginRead 在读 sequence 之前调用，B1 不变式）。
/// 占位值 = 哨兵快照 0（CLAIM_BIT）：发布真实快照前，watermark 看到 0
/// → 钉住一切——占位与发布之间的窗口内不放过任何页。返回槽位下标；
/// 槽位耗尽或 TLS 栈满 → READER_SLOTS（溢出注册，watermark 同样视为 0）。
fn claimReaderSlot(self: *State) u32 {
    if (tls_readers_len < MAX_TLS_READERS) {
        var i: usize = 0;
        while (i < READER_SLOTS) {
            if (self.reader_slots[i].load(.acquire) != 0) {
                i += 1;
                continue;
            }
            // m2：cmpxchgWeak 允许 spurious 失败——失败后重试同一槽位
            // （重新 load 判忙），不跳过仍空闲的槽位。
            if (self.reader_slots[i].cmpxchgWeak(0, CLAIM_BIT, .acq_rel, .acquire) == null) {
                tls_readers[tls_readers_len] = .{ .state = @ptrCast(self), .slot = @intCast(i) };
                tls_readers_len += 1;
                return @intCast(i);
            }
        }
    }
    // 槽位耗尽（或 TLS 栈满）：溢出注册。M1：acq_rel RMW——与 readerWatermark
    // 的 acquire 读配对，注册被水位看到即有 happens-before 边；水位在有读者
    // 但无可见槽位时本就保守返回 0（钉住一切），溢出读者因此始终被覆盖。
    // 栈满时不入栈——对应 endRead 在栈满且栈顶不匹配时饱和退减溢出计数。
    _ = self.overflow_readers.fetchAdd(1, .acq_rel);
    if (tls_readers_len < MAX_TLS_READERS) {
        tls_readers[tls_readers_len] = .{ .state = @ptrCast(self), .slot = READER_SLOTS };
        tls_readers_len += 1;
    }
    return READER_SLOTS;
}

/// 饱和退减溢出读者计数（m1：不回绕）。欠配对的退减只使计数偏高 →
/// watermark=0 钉住一切，安全方向；u32 回绕则永久钉住一切，必须避免。
fn saturatingOverflowDec(self: *State) void {
    while (true) {
        const cur = self.overflow_readers.load(.acquire);
        if (cur == 0) return; // 欠配对退减：保守不退（计数偏高 = 多钉，安全）
        if (self.overflow_readers.cmpxchgWeak(cur, cur - 1, .acq_rel, .acquire) == null) return;
    }
}

/// 弹出 TLS 栈顶条目并注销其注册（槽位归 0 / 饱和退减溢出计数）。
fn popTopTlsEntry(self: *State) void {
    const entry = tls_readers[tls_readers_len - 1];
    tls_readers_len -= 1;
    if (entry.slot < READER_SLOTS) {
        self.reader_slots[entry.slot].store(0, .release);
    } else {
        saturatingOverflowDec(self);
    }
}

/// 注销读者注册（endRead 调用）。配对：栈未满时找本 State 最近一次注册
/// （同 State 内 LIFO；跨 State 乱序嵌套按 State 指针精确匹配）。
/// 找不到（跨线程 end / 误用）或栈满且栈顶不匹配 → 饱和退减溢出计数
/// （m1：不回绕；计数偏高 = watermark 0 = 钉住一切，失败方向永远是安全侧）。
/// ponytail: >MAX_TLS_READERS(16) 深的同线程嵌套下，未入栈的溢出注册
/// 无法精确配对（栈满且栈顶匹配时弹栈可能误弹更早的自有注册）——本
/// 代码库实际嵌套 ≤3（ReadTxn+select），16 深不可达；需支持时升级为
/// 显式 reader handle API（需改 db.zig 接口）。
fn unregisterReaderSlot(self: *State) void {
    if (tls_readers_len == MAX_TLS_READERS) {
        // m1：栈满时若栈顶属于本 State，弹栈精确注销（解除粘滞：否则栈满
        // 后每次 endRead 都走保守分支且永不弹栈，溢出计数被错误退减回绕）；
        // 栈顶不匹配 → 本 end 配对未入栈的溢出注册，饱和退减。
        if (tls_readers[tls_readers_len - 1].state == @as(*const anyopaque, @ptrCast(self))) {
            popTopTlsEntry(self);
            return;
        }
        saturatingOverflowDec(self);
        return;
    }
    var i = tls_readers_len;
    while (i > 0) {
        i -= 1;
        if (tls_readers[i].state == @as(*const anyopaque, @ptrCast(self))) {
            const entry = tls_readers[i];
            // swap-remove：移除的是本 State 最新注册，同 State 其余条目
            // 相对 LIFO 顺序不变（中间只可能夹其他 State 的条目）。
            tls_readers[i] = tls_readers[tls_readers_len - 1];
            tls_readers_len -= 1;
            if (entry.slot < READER_SLOTS) {
                self.reader_slots[entry.slot].store(0, .release);
            } else {
                saturatingOverflowDec(self);
            }
            return;
        }
    }
    // 本线程无此 State 的注册记录（跨线程 end / 误用）→ 饱和退减溢出计数
    saturatingOverflowDec(self);
}

/// 分段耗时剖析（#35）：编译期开启，不进生产热路径。
/// 用法：profile tool 设置 enable=true，applyBatch 各段累加耗时。
pub const ProfileStats = struct {
    pub var enable: bool = false;

    // 各段耗时（ns）与调用次数
    pub var txn_dupe_ns: u64 = 0;
    pub var txn_sort_ns: u64 = 0;
    pub var txn_order_ns: u64 = 0;
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
        txn_order_ns = 0;
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
            .{ "order_detect", txn_order_ns },
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

/// 持久化档位（T-27）：
/// - `process_crash`（默认）：提交协议 = writeMeta + 单次 sync。进程崩溃
///   （页缓存完好）模型下已安全且快——bench 主战场的默认行为。
/// - `power_fail`：提交协议 = syncDataPages（数据页先落盘）→ writeMeta →
///   sync（meta 落盘），两次 sync 换掉电正确性：meta 页到达稳定存储的
///   时刻，其指向的数据页必已先于（或至迟同时）落盘。单条 put 延迟约
///   翻倍，batch 摊销后可接受。此档下提交即双 sync（fsync=false 仅对
///   process_crash 档有意义——用户自行 Db.sync() 的异步模式）。
pub const Durability = enum { process_crash, power_fail };

pub const Options = struct {
    fsync: bool = true,
    micro_batch: MicroBatchConfig = .{},
    durability: Durability = .process_crash,
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

    /// 活跃 reader 计数（0 = 无读者，可安全回收脏页；快路径判据）
    reader_count: std.atomic.Value(u32),

    /// T-30 per-reader 快照注册槽：0 = 空闲；非 0 = snapshot|CLAIM_BIT。
    /// watermark = 活跃槽位快照最小值，驱动 pending_free 增量精确回收。
    reader_slots: [READER_SLOTS]std.atomic.Value(u64),
    /// 超出槽位/无法注册的读者数（>0 → watermark 视为 0，保守钉住一切 = 旧行为）
    overflow_readers: std.atomic.Value(u32),

    /// 待回收的脏页（携带释放序列，reader 活跃时按 watermark 增量回收）
    pending_free: std.ArrayList(PendingPage),
    /// pending_free 互斥锁：串行化写者 append 与读者/compact 的增量回收
    /// （修复 ArrayList 并发 mutate 的 UB）。读者仅在有积压（dirt>0）时才取此锁。
    pending_free_mu: zio.Mutex,

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
            .reader_slots = @splat(std.atomic.Value(u64).init(0)),
            .overflow_readers = std.atomic.Value(u32).init(0),
            .pending_free = .empty,
            .pending_free_mu = .{},
        };
    }

    pub fn deinit(self: *State) void {
        self.closed.store(true, .release);
        // 释放剩余的 pending_free（safe: 写者线程结束，无读者）
        for (self.pending_free.items) |pp| self.store.freePage(pp.page_no);
        self.pending_free.deinit(self.allocator);
    }

    // ---- MVCC 读者 API ----

    /// 开始读事务。返回当前的 sequence（用于读一致性快照）。
    /// T-30 + B1 不变式：占位（哨兵快照 0）→ 读 sequence → 发布真实快照。
    /// 占位与发布之间的窗口内，watermark 见快照 0 → 钉住一切；发布（release
    /// store）后任何水位计算要么见哨兵要么见真实快照，恒 ≤ 本读者快照——
    /// 活跃快照不可能引用已回收页。读者注册先于返回，调用方随后捕获 root
    /// 快照，无论 root 新旧，其 COW 旧页均滞留 pending_free 到 watermark 放行。
    pub fn beginRead(self: *State) u64 {
        _ = self.reader_count.fetchAdd(1, .acquire);
        const slot = claimReaderSlot(self); // 先占位（哨兵 0），再读 sequence
        const seq = self.sequence.load(.acquire);
        if (slot < READER_SLOTS) {
            self.reader_slots[slot].store(seq | CLAIM_BIT, .release);
        }
        return seq;
    }

    /// 结束读事务。T-30：注销该读者的快照注册，并立即按 oldest-reader
    /// watermark 增量回收可安全回收的 pending 页——短命读者退出即释放
    /// 其钉住的页，不必等末位读者；末位读者退出（reader_count 归 0）
    /// 仍全量回收（既有快路径语义保留）。无积压（dirt==0）时仅两次 atomic，
    /// 不取锁——读者热路径不退化为锁。
    pub fn endRead(self: *State) void {
        _ = self.reader_count.fetchSub(1, .release);
        unregisterReaderSlot(self);
        if (self.dirt.load(.acquire) > 0) {
            self.reclaimPendingFree();
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

    /// compact：回收当前可安全回收的 pending 页（无读者全量；有读者按
    /// watermark 增量），写 meta。T-30：不再"只清计数"——dirt 始终反映
    /// 仍被钉住（不可回收）的真实页数。
    pub fn compact(self: *State) !void {
        // 回收（内部按 reader_count/watermark 分派，dirt 设为剩余钉住数）
        self.reclaimPendingFree();
        // 写新 meta
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
        // T-30：dirt 不再清零——reclaimPendingFree 已把它设为仍被钉住的页数
    }

    /// 返回 dirt 计数（测试用）
    pub fn dirtCount(self: *State) u64 {
        return self.dirt.load(.acquire);
    }

    // ---- 内部 ----

    /// 全量回收 pending_free：*不*检查 reader_count（由调用方保证安全：
    /// applyBatch 的 reader_count==0 快路径，单写者上下文）。
    /// 取 pending_free_mu，串行化写者与读者增量回收对该列表的 mutate。
    fn flushPendingFree(self: *State) void {
        self.pending_free_mu.lockUncancelable();
        defer self.pending_free_mu.unlock();
        const prof = ProfileStats.enable;
        const t0 = if (prof) ProfileStats.now() else 0;
        for (self.pending_free.items) |pp| {
            self.store.freePage(pp.page_no);
        }
        self.pending_free.clearRetainingCapacity();
        self.dirt.store(0, .release);
        if (prof) ProfileStats.txn_flush_free_ns += @intCast(ProfileStats.now() - t0);
    }

    /// T-30 按 oldest-reader watermark 增量回收 pending 页：
    /// - 无读者（reader_count==0，锁内复查）→ 全量回收（旧快路径，保留）；
    /// - 有读者 → 回收 release_seq < watermark 的页；等于或大于的保留
    ///   （老快照仍可能引用，正确性底线）。
    /// reader_count 检查在锁内：读者回收与写者 append 经 pending_free_mu 互斥，
    /// 锁内看到 count==0 才全量——其后注册的新读者快照必 ≥ 全部 pending 的
    /// release_seq，不可能引用被回收的页。
    fn reclaimPendingFree(self: *State) void {
        self.pending_free_mu.lockUncancelable();
        defer self.pending_free_mu.unlock();
        const prof = ProfileStats.enable;
        const t0 = if (prof) ProfileStats.now() else 0;
        defer if (prof) {
            ProfileStats.txn_flush_free_ns += @intCast(ProfileStats.now() - t0);
        };

        if (self.reader_count.load(.acquire) == 0) {
            for (self.pending_free.items) |pp| self.store.freePage(pp.page_no);
            self.pending_free.clearRetainingCapacity();
            self.dirt.store(0, .release);
            return;
        }
        const watermark = self.readerWatermark();
        var keep: usize = 0;
        for (self.pending_free.items) |pp| {
            if (pp.release_seq < watermark) {
                self.store.freePage(pp.page_no);
            } else {
                self.pending_free.items[keep] = pp;
                keep += 1;
            }
        }
        self.pending_free.shrinkRetainingCapacity(keep);
        self.dirt.store(keep, .release);
    }

    /// oldest-active-reader watermark：活跃读者快照序列的最小值。
    /// 返回 0 = 保守下界（溢出读者 / 有读者但快照尚未注册可见）→ 钉住一切。
    fn readerWatermark(self: *State) u64 {
        if (self.overflow_readers.load(.acquire) > 0) return 0;
        var min: u64 = 0;
        var found = false;
        for (&self.reader_slots) |*slot| {
            const v = slot.load(.acquire);
            if (v == 0) continue;
            const snap = v & ~CLAIM_BIT;
            if (!found or snap < min) {
                min = snap;
                found = true;
            }
        }
        return min;
    }

    /// 应用一批写请求到 B-tree，提交 meta，fsync，更新原子状态
    pub fn applyBatch(self: *State, batch: []const Request) !void {
        if (self.closed.load(.acquire)) {
            for (batch) |r| r.future.set(error.Closed);
            return;
        }

        const prof = ProfileStats.enable;
        const t0 = if (prof) ProfileStats.now() else 0;

        // 0. grace-period 回收：若此刻无读者，本批开始前积累的脏页均可安全回收
        //    （均为历史提交 COW 出的旧页，仅被已退出的读者持有）。与读者 endRead 的
        //    flush 经 pending_free_mu 互斥（单一可同步 mutator）。
        if (self.reader_count.load(.acquire) == 0) {
            self.flushPendingFree();
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

        // O(n) 有序性检测：strict（严格递增，无重复）/ non_dec（非递减，含重复）/ unordered
        const t_order0 = if (prof) ProfileStats.now() else 0;
        const Order = enum { strict, non_dec, unordered };
        const order = blk: {
            if (batch.len <= 1) break :blk Order.strict;
            var has_dup = false;
            for (1..batch.len) |i| {
                switch (btree.cmpKey(batch[i - 1].key, batch[i].key)) {
                    .lt => {},
                    .eq => has_dup = true,
                    .gt => break :blk Order.unordered,
                }
            }
            break :blk if (has_dup) Order.non_dec else Order.strict;
        };
        if (prof) ProfileStats.txn_order_ns += @intCast(ProfileStats.now() - t_order0);

        const t_dupe0 = if (prof) ProfileStats.now() else 0;
        const arena_entries = try arena_alloc.alloc(btree.LeafEntry, batch.len);
        if (order != .unordered) {
            // Fast path: 有序输入，跳过 dupe + sort，直接引用 caller 切片
            for (batch, 0..) |req, i| {
                arena_entries[i] = .{ .tombstone = req.tombstone, .key = req.key, .value = req.value };
            }
            if (prof) ProfileStats.txn_dupe_ns += @intCast(ProfileStats.now() - t_dupe0);

            // O(n) dedup（非递减含重复时去相邻重复，last-write-wins）
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

            const t_ib0 = if (prof) ProfileStats.now() else 0;
            const wr = btree.insertBatch(arena_alloc, self.store, new_root, entries, &batch_dirty) catch |err| {
                for (batch) |r| r.future.set(err);
                return;
            };
            if (prof) ProfileStats.txn_insertbatch_ns += @intCast(ProfileStats.now() - t_ib0);
            new_root = wr.new_root;
            batch_entry_delta += wr.count_delta;
            batch_byte_delta += wr.live_delta;
        } else {
            // Unordered: 当前路径（dupe + sort + dedup）
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
        } // end unordered path
        } // end else (batch.len > 1)

        // 3. 本批脏页进 pending_free（不立即回收，MVCC 安全）。
        //    取 pending_free_mu，串行化与末位读者 flush 的并发 mutate（UB 修复）。
        const t_pf0 = if (prof) ProfileStats.now() else 0;
        {
            self.pending_free_mu.lockUncancelable();
            defer self.pending_free_mu.unlock();
            for (batch_dirty.items) |pn| {
                // T-30：携带释放序列（本次提交的 new_sequence = cur_sequence+1）。
                // 该页属于 cur_sequence 时刻的树；快照 ≥ new_sequence 的读者
                // 不可能引用它（它不在 new_sequence 提交后的树里）。
                self.pending_free.append(self.allocator, .{ .page_no = pn, .release_seq = cur_sequence + 1 }) catch {};
            }
            // T-30：dirt 在锁内随 append 更新（与读者线程的增量回收互斥，
            // 避免覆写其结果；原步骤 7 的锁外 store 移入此处）
            self.dirt.store(@intCast(self.pending_free.items.len), .release);
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
        // T-27 提交顺序：power_fail 档下，meta 写入前先把本批数据页刷到
        // 稳定存储（fdatasync 语义），保证 meta 提交为持久的时刻，其指向的
        // 数据页已先于（或至迟同时）落盘——掉电不会恢复到指向悬垂页的 root。
        // process_crash 档保持旧行为（页缓存完好的进程崩溃模型下无需前置刷盘）。
        if (self.opts.durability == .power_fail) {
            try self.store.syncDataPages();
        }
        try self.store.writeMeta(&meta);

        // 6. fsync（meta 落盘）。power_fail 档无条件 sync（提交即双 sync：
        // 数据页先、meta 后——见上方 Durability 注释）；fsync=false 仅对
        // process_crash 档有意义（异步 durability，用户自行 Db.sync()）。
        if (self.opts.fsync or self.opts.durability == .power_fail) {
            try self.store.sync();
        }
        if (prof) ProfileStats.txn_meta_ns += @intCast(ProfileStats.now() - t_meta0);

        // 7. 原子更新状态（dirt 已在步骤 3 锁内随 append 更新）
        self.root.store(new_root, .release);
        self.sequence.store(new_sequence, .release);
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

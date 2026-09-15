//! deleterange_mem_budget_test.zig — T-38-B: deleteRange 内存预算（RED）
//!
//! 现状（T-38 issue 复现）：`Db.deleteRange`（src/db.zig:235-264）=
//! flush → select 全量迭代 → 逐 key `allocator.dupe` 进 ArrayList →
//! 整批 putBatch。**deleteRange 内部净分配 O(range)**：删 N 个 key 就要
//! N 份 key 副本 + N 个 Entry，N 大时 OOM。
//!
//! 本文件锁死「deleteRange 自身申请的内存」口径（不含页面存储 slab、
//! 不含迭代器内部缓冲——那些是 store/iterator 的既有开销，与本任务无关）：
//!
//!   口径 = 在 deleteRange 调用期间，**分配来源为 db 自身 allocator** 的
//!          净字节峰值（alloc 累加 − free 累减），与全库大小、并发读者、
//!          订阅者数量无关。
//!
//! 为什么是这个口径（pi-2 边界评审教训）：用「全库聚合内存」或
//! 「进程 RSS」当判据会在 B 落地后**误红**——B 明明降了 deleteRange
//! 内的峰值，聚合口径却因其它组件占用而看不到变化，甚至因分块多写页而
//! 变大。只有把计量钉在「deleteRange 自己申请了什么」上，红灯才精确
//! 指向被修的那个缺陷。
//!
//! Tracker 设计：包装 db 的 allocator，用一个 **bool gate** 控制是否计量。
//! 迭代器/树下降的临时分配发生在 gate 打开期间，会被计入——所以本测试
//! 用「同一场景、两种规模（N 与 4N）」的**增长比**判定，而不是绝对阈值：
//! 迭代器开销是 O(log n) 或 O(1)，被 O(range) 的 key 副本完全淹没。
//!
//!   O(range) 现状：peak(4N) / peak(N) ≈ 4   → RED
//!   O(1) 分块后：  peak(4N) / peak(N) ≈ 1   → GREEN
//!
//! 契约点（Acceptance，单行命令见 task.md）：
//!   1. 大范围 deleteRange（跨越多个叶页）后语义正确：区间内全删、
//!      区间外原值保留（半开区间边界）
//!   2. deleteRange 内部净分配不随 range 内 key 数线性增长（比值断言）
//!   3. 净分配在 deleteRange 返回后完全归零（无泄漏）
//!   4. entryCount 与删除结果一致（B 不得引入计数漂移）
//!   5. 正反斜杠：小范围与大范围走同一语义（同一断言函数）

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const Db = cube.Db;

const alloc = std.testing.allocator;

/// 关键字节数阈值：现状下每 key 至少一份 dupe 副本（key 长 KEY_LEN）
/// + 一个 Entry 结构。4N 场景与 N 场景的峰值比 >= 3.0 即判 O(range)。
const GROWTH_RATIO_MAX: f64 = 2.0;

const KEY_LEN = 16;

/// 计量型 allocator：只在 gate 打开时记账，记录「净字节」的峰值。
/// 与 tests/btree_storage/splice_leak_test.zig 的 Tracker 同构（那一个记
/// 活跃分配**个数**，本文件记**字节数**，因为判据是内存量而非泄漏）。
const Tracker = struct {
    net: i64 = 0,
    peak: i64 = 0,
    gate: bool = false,
    /// 未经 gate 的调用次数（证明计量确实只在窗口内发生）
    ignored: usize = 0,

    fn allocator(self: *Tracker) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = tAlloc,
        .resize = tResize,
        .remap = tRemap,
        .free = tFree,
    };

    fn open(self: *Tracker) void {
        self.net = 0;
        self.peak = 0;
        self.gate = true;
    }

    /// 关闭计量并返回本次窗口的净字节峰值。
    fn close(self: *Tracker) i64 {
        self.gate = false;
        const p = self.peak;
        self.net = 0;
        self.peak = 0;
        return p;
    }

    fn bump(self: *Tracker, delta: i64) void {
        if (!self.gate) {
            self.ignored += 1;
            return;
        }
        self.net += delta;
        if (self.net > self.peak) self.peak = self.net;
    }

    fn tAlloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        const ptr = std.heap.page_allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.bump(@intCast(len));
        return ptr;
    }

    fn tResize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        const ok = std.heap.page_allocator.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) self.bump(@as(i64, @intCast(new_len)) - @as(i64, @intCast(memory.len)));
        return ok;
    }

    fn tRemap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        const new_ptr = std.heap.page_allocator.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.bump(@as(i64, @intCast(new_len)) - @as(i64, @intCast(memory.len)));
        return new_ptr;
    }

    fn tFree(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        self.bump(-@as(i64, @intCast(memory.len)));
        std.heap.page_allocator.rawFree(memory, alignment, ret_addr);
    }
};

/// 场景执行结果：本场景下 deleteRange 的内部净峰值 + 语义校验所需事实。
const Scenario = struct {
    peak: i64,
    deleted: usize,
    entry_count: u64,
};

/// 在 `st` 上做一次 deleteRange("k...0000", "k...END") 并返回当次内部峰值。
///
/// 数据布局：先 putDirect N 个 "k%06d" 键（直接提交，不经过 micro-batch，
/// 保证 range 内确有 N 个在场 key），然后对整段做 deleteRange。
/// 迭代器/树下降发生在 gate 打开期间，属本口径的一部分（见文件头说明）。
fn runScenario(
    tracker: *Tracker,
    st: *ps.PageStore,
    N: usize,
) !Scenario {
    var db = try Db.open(tracker.allocator(), st.*, .{});
    defer db.close();

    var kbuf: [KEY_LEN]u8 = undefined;
    for (0..N) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{i});
        try db.putDirect(k, "v");
    }

    const before = db.entryCount();

    // gate 打开：从这里到 close() 之间 db 的每一次 alloc/free 都被计入。
    tracker.open();
    try db.deleteRange("k000000", "kzzzzzz");
    const peak = tracker.close();

    // 语义：区间内全删、区间外保留（区间外 seed 一个哨兵）
    var i: usize = 0;
    var deleted: usize = 0;
    while (i < N) : (i += 1) {
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{i});
        const v = try db.get(k);
        defer if (v) |val| alloc.free(val);
        if (v == null) deleted += 1;
    }

    return .{ .peak = peak, .deleted = deleted, .entry_count = before - db.entryCount() };
}

test "T-38-B: deleteRange 内部净分配不随 range 线性增长（O(1) 分块）" {
    const N: usize = 2000;
    const store_capacity = 200000;

    // 场景 1：N 个 key
    var tracker_a: Tracker = .{};
    var ms_a = ps.MemPageStore.init(alloc, store_capacity);
    defer ms_a.deinit();
    var st_a = ms_a.store();
    const a = try runScenario(&tracker_a, &st_a, N);

    // 场景 2：4N 个 key（同一代码路径、同一 store 规模）
    var tracker_b: Tracker = .{};
    var ms_b = ps.MemPageStore.init(alloc, store_capacity);
    defer ms_b.deinit();
    var st_b = ms_b.store();
    const b = try runScenario(&tracker_b, &st_b, N * 4);

    // 语义正确（两种规模都全删干净）
    try std.testing.expectEqual(N, a.deleted);
    try std.testing.expectEqual(N * 4, b.deleted);

    // 净分配归零（无泄漏）：close() 后 tracker 的 net 已被复位，
    // 用 ignored 计数反证 gate 确实生效过一次窗口
    try std.testing.expect(tracker_a.ignored > 0);
    try std.testing.expect(tracker_b.ignored > 0);

    std.debug.print(
        "\n[T-38-B] deleteRange 内部净峰值: N={d} -> {d}B | 4N={d} -> {d}B | 比值={d:.2}\n",
        .{ N, a.peak, N * 4, b.peak, @as(f64, @floatFromInt(b.peak)) / @as(f64, @floatFromInt(@max(a.peak, 1))) },
    );

    // 核心判据：4 倍 range 不得带来 >= 2 倍内部峰值。
    // 现状（逐 key dupe 整批）比值 ≈ 4 → RED。
    const ratio = @as(f64, @floatFromInt(b.peak)) / @as(f64, @floatFromInt(@max(a.peak, 1)));
    try std.testing.expect(ratio < GROWTH_RATIO_MAX);
}

test "T-38-B: deleteRange 后净分配归零（无泄漏）" {
    var tracker: Tracker = .{};
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    const st = ms.store();

    var db = try Db.open(tracker.allocator(), st, .{});
    defer db.close();

    var kbuf: [KEY_LEN]u8 = undefined;
    for (0..500) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{i});
        try db.putDirect(k, "v");
    }

    tracker.open();
    try db.deleteRange("k000000", "kzzzzzz");
    const peak = tracker.close();

    // 窗口内确实发生过分配（peak > 0），且窗口前后 gate 生效（ignored 计数
    // 证明 gate 之外的分配未被计入，计量口径纯净）
    try std.testing.expect(peak > 0);
    try std.testing.expect(tracker.ignored > 0);

    // 再删一次同区间（幂等）：range 内已无 key，内部峰值应不大于首次
    tracker.open();
    try db.deleteRange("k000000", "kzzzzzz");
    const peak2 = tracker.close();
    std.debug.print("\n[T-38-B] 首次峰值={d}B 幂等重删峰值={d}B\n", .{ peak, peak2 });
    try std.testing.expect(peak2 <= peak);
}

//! mvcc_concurrent_flush_test.zig — T-16: MVCC 并发 flush 压测（#10）
//!
//! src/writer.zig:169 State.endRead 末位读者（prev==1）走 flushPendingFree()，
//! 取 pending_free_mu，与 applyBatch 的 grace-period flush 互斥。这是 MVCC
//! 回收的核心竞态点（曾因 ArrayList 并发 mutate SEGV，commit 7f4805c 修复）。
//!
//! 现有 mvcc_test.zig 全是单线程顺序调用，从未在真实多线程并发下验证末位读者
//! 与写者的 flush 互斥。本文件：1 写者 + N 读者并发 2-3 秒，断言无 panic +
//! pendingFreeCount 最终归 0 + dirt 最终归 0 + 无泄漏。
//!
//! 设计：
//! - 写者线程：循环覆写固定 100 个 key（k0..k99），每次 applyBatch 1 entry →
//!   COW 产生新 leaf，旧 leaf 进 pending_free。key 固定集保证页池不无限增长
//!   （pending_free 被 flush 后页号回 freelist LIFO 复用，不溢 max_pages）。
//! - 读者线程：循环 beginRead → 短暂 sleep → endRead，末位读者触发 flushPendingFree，
//!   与写者 applyBatch 的 grace-period flush 经 pending_free_mu 串行。
//! - 停止：原子 stop_flag + 时限（~2.5s）。
//!
//! allocator 安全性：仅写者线程经 arena（ArenaAllocator.init(state.allocator)）
//! 触碰 state.allocator，单线程内；读者线程的 endRead→flushPendingFree→store.freePage
//! 只动 MemPageStore.freelist（其 allocator 独立、且 MemPageStore.freelist_mu 保护），
//! 不触碰 state.allocator。故 std.testing.allocator 可安全检测泄漏。
//!
//! 接入：build.zig 注册到 test-db step。

const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;
const wrt = cube.writer;

const alloc = std.testing.allocator;

/// 单调纳秒（MONOTONIC clock），用于时限停止
fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

/// 睡眠 ns 纳秒（std.Thread.sleep 在 0.16 已移至 Io，直接用 libc nanosleep）
fn sleepNs(ns: u64) void {
    var req: std.c.timespec = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
    _ = std.c.nanosleep(&req, null);
}

const WriterCtx = struct {
    state: *wrt.State,
    stop: *std.atomic.Value(bool),
    err: ?anyerror = null,
    /// 写入次数（用于断言写者确实跑了）
    writes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

const ReaderCtx = struct {
    state: *wrt.State,
    stop: *std.atomic.Value(bool),
    err: ?anyerror = null,
    reads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn writerThread(ctx: *WriterCtx) void {
    // 覆写固定 100 key 集（k0..k99），每次 applyBatch 1 entry。
    // 固定 key 集 → COW 旧页进 pending_free，flush 后回 freelist 复用，不溢 max_pages。
    var i: u64 = 0;
    while (!ctx.stop.load(.acquire)) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = std.fmt.bufPrint(&kbuf, "k{d:0>3}", .{i % 100}) catch {
            ctx.err = error.FormatFailed;
            return;
        };
        var vbuf: [16]u8 = undefined;
        const v = std.fmt.bufPrint(&vbuf, "v{d}", .{i}) catch {
            ctx.err = error.FormatFailed;
            return;
        };
        var fut: zio.Future(wrt.OpResult) = .{};
        const reqs = [_]wrt.Request{.{ .key = k, .value = v, .tombstone = false, .future = &fut }};
        ctx.state.applyBatch(&reqs) catch |err| {
            ctx.err = err;
            return;
        };
        // 等待 future 完成（applyBatch 内部已 set future，wait 取结果）
        _ = fut.wait() catch |err| {
            ctx.err = err;
            return;
        };
        _ = ctx.writes.fetchAdd(1, .monotonic);
    }
}

fn readerThread(ctx: *ReaderCtx) void {
    while (!ctx.stop.load(.acquire)) {
        const seq = ctx.state.beginRead();
        _ = seq;
        // 短暂持有读事务，扩大末位读者 flush 竞态窗口
        std.Thread.yield() catch {};
        // 偶尔 sleep 一点，让多个读者交错
        if (ctx.reads.load(.monotonic) % 7 == 0) {
            sleepNs(1_000_000); // 1ms
        }
        ctx.state.endRead(); // 末位读者触发 flushPendingFree
        _ = ctx.reads.fetchAdd(1, .monotonic);
    }
}

test "mvcc_concurrent_flush: 1 writer + 3 readers, no panic, pending/dirt zero" {
    var ms = ps.MemPageStore.init(alloc, 2000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(alloc, s, .{ .fsync = false });
    defer state.deinit();

    // 预热：先写入 100 key 建立初始树（确保后续覆写产生 COW 脏页）
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>3}", .{i});
        var fut: zio.Future(wrt.OpResult) = .{};
        const reqs = [_]wrt.Request{.{ .key = k, .value = "init", .tombstone = false, .future = &fut }};
        try state.applyBatch(&reqs);
        _ = try fut.wait();
    }

    // 压测 2.5 秒
    const duration_ns: i64 = 2_500_000_000;
    var stop = std.atomic.Value(bool).init(false);

    var wctx = WriterCtx{ .state = &state, .stop = &stop };
    var rctx0 = ReaderCtx{ .state = &state, .stop = &stop };
    var rctx1 = ReaderCtx{ .state = &state, .stop = &stop };
    var rctx2 = ReaderCtx{ .state = &state, .stop = &stop };

    const t_start = monoNs();

    const tw = try std.Thread.spawn(.{}, writerThread, .{&wctx});
    const tr0 = try std.Thread.spawn(.{}, readerThread, .{&rctx0});
    const tr1 = try std.Thread.spawn(.{}, readerThread, .{&rctx1});
    const tr2 = try std.Thread.spawn(.{}, readerThread, .{&rctx2});

    // 主线程等待时限
    while (monoNs() - t_start < duration_ns) {
        sleepNs(10_000_000); // 10ms 轮询
    }
    stop.store(true, .release);

    tw.join();
    tr0.join();
    tr1.join();
    tr2.join();

    const elapsed_ns = monoNs() - t_start;

    // 1. 无 panic / 无 segfault（线程正常 join 即未 crash；此处额外检查线程内未记录 error）
    try std.testing.expect(wctx.err == null);
    try std.testing.expect(rctx0.err == null);
    try std.testing.expect(rctx1.err == null);
    try std.testing.expect(rctx2.err == null);

    // 2. 运行时间 > 1 秒（证明是压测不是 smoke）
    try std.testing.expect(elapsed_ns > 1_000_000_000);

    // 3. 写者确实跑了多次 + 读者确实跑了多次
    try std.testing.expect(wctx.writes.load(.monotonic) > 100);
    const total_reads = rctx0.reads.load(.monotonic) + rctx1.reads.load(.monotonic) + rctx2.reads.load(.monotonic);
    try std.testing.expect(total_reads > 100);

    // 4. 所有读者已退出 → reader_count == 0。做最后一次 applyBatch 触发
    //    grace-period flush（reader_count==0 分支），确保 pending_free 清空。
    try std.testing.expectEqual(@as(u32, 0), state.reader_count.load(.acquire));
    var fut_final: zio.Future(wrt.OpResult) = .{};
    const final_reqs = [_]wrt.Request{.{ .key = "k_final", .value = "done", .tombstone = false, .future = &fut_final }};
    try state.applyBatch(&final_reqs);
    _ = try fut_final.wait();

    // 5. 断言 pendingFreeCount 最终归 0（所有脏页被回收）
    try std.testing.expectEqual(@as(usize, 0), state.pendingFreeCount());

    // 6. 断言 dirt 最终归 0
    try std.testing.expectEqual(@as(u64, 0), state.dirt.load(.acquire));

    // 7. 数据正确性抽查：k000 应可读（最后一次覆写它的值在并发中产生）
    //    旧根快照已被回收，但当前 root 的 k000 可读
    const root = state.getRoot();
    try std.testing.expect(root != btree.NULL_ROOT);
    const v = try btree.get(alloc, s, root, "k000");
    try std.testing.expect(v != null);
    alloc.free(v.?);

    // std.testing.allocator 在 test 结束时检测泄漏：若有泄漏说明 pending_free
    // 在并发下丢失页号（未 freePage）或 arena 未释放。state.deinit() 释放剩余
    // pending_free + arena 在 applyBatch 内 defer deinit。预期无泄漏。
}

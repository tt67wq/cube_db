//! staging_concurrent_test.zig — T-34 (U-13)：pending 微批 staging 并发安全
//!
//! RED 阶段（本 commit）：`batch_threshold > 0` 时 `Db.put`/`Db.delete` 无锁向
//! `self.pending`（ArrayList）追加，`write_mutex` 要到 `flush()` → `putBatch()`
//! 才拿 —— 两个线程并发写即确定性数据竞争（UB：随机丢写 / ArrayList 损坏 /
//! use-after-free）。本测试多线程并发断言不丢写、不损坏，预期失败。
//!
//! GREEN 后：staging 由独立 staging_mutex 保护（zio.Mutex 非递归——staging 锁
//! 内绝不做提交；flush 在 staging 锁内原子 steal 后释放锁再走 write_mutex 提交），
//! 本文件全部转绿。

const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const ps = cube.page_store;

const THREADS = 4;
const PER_THREAD = 250;
const THRESHOLD = 16;

fn keyFor(buf: []u8, t: usize, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "k{d:0>4}_{d:0>4}", .{ t, i }) catch unreachable;
}

fn valFor(buf: []u8, t: usize, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "v{d:0>4}_{d:0>4}", .{ t, i }) catch unreachable;
}

fn workerPuts(db: *Db, t: usize) void {
    var kbuf: [32]u8 = undefined;
    var vbuf: [32]u8 = undefined;
    for (0..PER_THREAD) |i| {
        db.put(keyFor(&kbuf, t, i), valFor(&vbuf, t, i)) catch @panic("put failed");
    }
}

// ---- T1：并发 put + threshold 自动 flush，不丢写 ----

test "staging concurrent: no lost writes with threshold auto-flush" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1 << 20);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = THRESHOLD } });
    defer db.close();

    var threads: [THREADS]std.Thread = undefined;
    for (0..THREADS) |t| {
        threads[t] = try std.Thread.spawn(.{}, workerPuts, .{ db, t });
    }
    for (&threads) |*th| th.join();
    try db.flush();

    // 不丢写：entryCount == 全部写入数
    try std.testing.expectEqual(@as(u64, THREADS * PER_THREAD), db.entryCount());

    // 全量扫描条数一致（无重复 / 无幻影）
    var it = try db.select(null, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, THREADS * PER_THREAD), n);

    // 值全查：每个 key 的 value 正确（无串写 / 无损坏）
    var kbuf: [32]u8 = undefined;
    var vbuf: [32]u8 = undefined;
    for (0..THREADS) |t| {
        for (0..PER_THREAD) |i| {
            const v = try db.get(keyFor(&kbuf, t, i));
            defer std.testing.allocator.free(v.?);
            try std.testing.expectEqualStrings(valFor(&vbuf, t, i), v.?);
        }
    }
}

// ---- T2：并发 put + 独立线程显式 flush ----

const FLUSH_ITERS = 200;

fn workerFlusher(db: *Db, done: *std.atomic.Value(bool)) void {
    while (!done.load(.acquire)) {
        db.flush() catch @panic("flush failed");
        sleepNs(1_000_000); // 1ms
    }
}

/// Sleep ns nanoseconds (std.Thread.sleep moved to Io in 0.16; libc nanosleep)
fn sleepNs(ns: u64) void {
    var req: std.c.timespec = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
    _ = std.c.nanosleep(&req, null);
}

test "staging concurrent: put + concurrent explicit flush" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1 << 20);
    defer ms.deinit();
    // threshold 极大：不自动 flush，全靠并发 flusher 线程驱动提交
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 1 << 30 } });
    defer db.close();

    var done = std.atomic.Value(bool).init(false);
    const flusher = try std.Thread.spawn(.{}, workerFlusher, .{ db, &done });

    var threads: [THREADS]std.Thread = undefined;
    for (0..THREADS) |t| {
        threads[t] = try std.Thread.spawn(.{}, workerPuts, .{ db, t });
    }
    for (&threads) |*th| th.join();
    done.store(true, .release);
    flusher.join();
    try db.flush();

    try std.testing.expectEqual(@as(u64, THREADS * PER_THREAD), db.entryCount());

    var kbuf: [32]u8 = undefined;
    var vbuf: [32]u8 = undefined;
    for (0..THREADS) |t| {
        for (0..PER_THREAD) |i| {
            const v = try db.get(keyFor(&kbuf, t, i));
            defer std.testing.allocator.free(v.?);
            try std.testing.expectEqualStrings(valFor(&vbuf, t, i), v.?);
        }
    }
}

// ---- T3：并发 put + delete 混合，最终状态不定但必须自洽 ----

fn workerDeletes(db: *Db, t: usize) void {
    var kbuf: [32]u8 = undefined;
    for (0..PER_THREAD) |i| {
        db.delete(keyFor(&kbuf, t, i)) catch @panic("delete failed");
    }
}

test "staging concurrent: mixed put/delete stays consistent" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1 << 20);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = THRESHOLD } });
    defer db.close();

    // 线程 A put d_xxx，线程 B delete 同一批 key —— 每个 key 的最终状态
    // 是 put/delete 落地顺序决定的（不定），但库必须自洽：
    // get 只返回 null 或正确 value，entryCount == 扫描条数 == present 数。
    const putter = try std.Thread.spawn(.{}, workerPuts, .{ db, 0 });
    const deleter = try std.Thread.spawn(.{}, workerDeletes, .{ db, 0 });
    putter.join();
    deleter.join();
    try db.flush();

    var present: usize = 0;
    var kbuf: [32]u8 = undefined;
    var vbuf: [32]u8 = undefined;
    for (0..PER_THREAD) |i| {
        const v = try db.get(keyFor(&kbuf, 0, i));
        if (v) |val| {
            defer std.testing.allocator.free(val);
            try std.testing.expectEqualStrings(valFor(&vbuf, 0, i), val);
            present += 1;
        }
    }

    var it = try db.select(null, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |_| n += 1;

    try std.testing.expectEqual(@as(u64, present), db.entryCount());
    try std.testing.expectEqual(present, n);
}

// ====================================================================
// 以下为 test worker（ws1-pi-2）阶段 B 补充测试（对齐阶段 A 测试计划 M3/M6/M7/M8）
// ====================================================================

// ---- T4（M8）：batch_threshold==0 直通路径并发不回归 ----
// putDirect 经 beginWriteTxn 拿 write_mutex，本已串行；验证 T-34 改动后
// 直通路径语义不变：并发 put 精确不丢、值正确。
test "staging concurrent: batch_threshold==0 direct path no regression" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1 << 20);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 0 } });
    defer db.close();

    var threads: [THREADS]std.Thread = undefined;
    for (0..THREADS) |t| {
        threads[t] = try std.Thread.spawn(.{}, workerPuts, .{ db, t });
    }
    for (&threads) |*th| th.join();

    // 直通路径即时提交，无需 flush
    try std.testing.expectEqual(@as(u64, THREADS * PER_THREAD), db.entryCount());
    var kbuf: [32]u8 = undefined;
    var vbuf: [32]u8 = undefined;
    for (0..THREADS) |t| {
        for (0..PER_THREAD) |i| {
            const v = try db.get(keyFor(&kbuf, t, i));
            defer std.testing.allocator.free(v.?);
            try std.testing.expectEqualStrings(valFor(&vbuf, t, i), v.?);
        }
    }
}

// ---- T5（M3）：确定性并发 delete ----
// 预先提交 THREADS×PER_THREAD 个 key，4 个删除线程各删互异子集（t 分片），
// threshold 极大（纯 staging），join 后统一 flush：全部删除，计数精确为 0。
test "staging concurrent: deterministic concurrent delete" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1 << 20);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 1 << 30 } });
    defer db.close();

    // 预提交：stage 全部 key 后 flush 一次
    var kbuf: [32]u8 = undefined;
    var vbuf: [32]u8 = undefined;
    for (0..THREADS) |t| {
        for (0..PER_THREAD) |i| {
            try db.put(keyFor(&kbuf, t, i), valFor(&vbuf, t, i));
        }
    }
    try db.flush();
    try std.testing.expectEqual(@as(u64, THREADS * PER_THREAD), db.entryCount());

    var threads: [THREADS]std.Thread = undefined;
    for (0..THREADS) |t| {
        threads[t] = try std.Thread.spawn(.{}, workerDeletes, .{ db, t });
    }
    for (&threads) |*th| th.join();
    try db.flush();

    // 不丢删除、无幻影：全表为空
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
    var it = try db.select(null, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 0), n);
    const v = try db.get(keyFor(&kbuf, 0, 0));
    try std.testing.expect(v == null);
}

// ---- T6（M6）：close auto-flush 提交未 flush 的 staged 条目 ----
// join 后不手动 flush，直接 close（auto-flush 路径），在同一 MemPageStore
// 上 reopen 验证：close 前所有成功返回的 put 都已落盘，不丢写。
// （并发 close-期间-put 是对已释放 Db 的 UAF，超出契约——见阶段 A 计划 §5。）
test "staging concurrent: close auto-flush commits staged entries" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1 << 20);
    defer ms.deinit();
    {
        var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 1 << 30 } });
        var threads: [THREADS]std.Thread = undefined;
        for (0..THREADS) |t| {
            threads[t] = try std.Thread.spawn(.{}, workerPuts, .{ db, t });
        }
        for (&threads) |*th| th.join();
        // 故意不 flush：pending 必然非空（threshold 极大），close 负责提交
        db.close();
    }
    // 同一 store 上 reopen：meta 记录了 close auto-flush 提交后的 root/计数
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 1 << 30 } });
    defer db.close();
    try std.testing.expectEqual(@as(u64, THREADS * PER_THREAD), db.entryCount());
    var kbuf: [32]u8 = undefined;
    var vbuf: [32]u8 = undefined;
    for (0..THREADS) |t| {
        for (0..PER_THREAD) |i| {
            const v = try db.get(keyFor(&kbuf, t, i));
            defer std.testing.allocator.free(v.?);
            try std.testing.expectEqualStrings(valFor(&vbuf, t, i), v.?);
        }
    }
}

// ---- T7（M7）：deleteRange 与并发 staging 交错 ----
// putter 持续 stage 范围外 key（"a..."）+ 范围内 key（"d..."）；
// deleter 循环 deleteRange("d000000", "e")（内部先 flush 再提交 tombstone 批）。
// 断言：无 panic；范围外 key 一个不丢（精确计数）；范围内 key 允许在场/缺席
//（删除与写入交错，非确定），但在场者 value 必须正确；entryCount == 扫描数。

const RangePutterCtx = struct {
    db: *Db,
    stop: *std.atomic.Value(bool),
    err: ?anyerror = null,
    a_puts: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    d_puts: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn workerRangePutter(ctx: *RangePutterCtx) void {
    var kbuf: [32]u8 = undefined;
    var vbuf: [32]u8 = undefined;
    var i: u64 = 0;
    while (!ctx.stop.load(.acquire)) : (i += 1) {
        const ka = std.fmt.bufPrint(&kbuf, "a{d:0>6}", .{i}) catch unreachable;
        const va = std.fmt.bufPrint(&vbuf, "va{d:0>6}", .{i}) catch unreachable;
        ctx.db.put(ka, va) catch |e| {
            ctx.err = e;
            return;
        };
        _ = ctx.a_puts.fetchAdd(1, .monotonic);
        const kd = std.fmt.bufPrint(&kbuf, "d{d:0>6}", .{i}) catch unreachable;
        const vd = std.fmt.bufPrint(&vbuf, "vd{d:0>6}", .{i}) catch unreachable;
        ctx.db.put(kd, vd) catch |e| {
            ctx.err = e;
            return;
        };
        _ = ctx.d_puts.fetchAdd(1, .monotonic);
    }
}

const RangeDeleterCtx = struct {
    db: *Db,
    stop: *std.atomic.Value(bool),
    err: ?anyerror = null,
    passes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn workerRangeDeleter(ctx: *RangeDeleterCtx) void {
    while (!ctx.stop.load(.acquire)) {
        ctx.db.deleteRange("d000000", "e") catch |e| {
            ctx.err = e;
            return;
        };
        _ = ctx.passes.fetchAdd(1, .monotonic);
        sleepNs(100_000); // 100µs
    }
}

test "staging concurrent: deleteRange interleaved with concurrent staging" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1 << 20);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 1 << 30 } });
    defer db.close();

    var stop = std.atomic.Value(bool).init(false);
    var pctx = RangePutterCtx{ .db = db, .stop = &stop };
    var dctx = RangeDeleterCtx{ .db = db, .stop = &stop };

    const tp = try std.Thread.spawn(.{}, workerRangePutter, .{&pctx});
    const td = try std.Thread.spawn(.{}, workerRangeDeleter, .{&dctx});
    sleepNs(1_000_000_000); // 1s 交错窗口
    stop.store(true, .release);
    tp.join();
    td.join();

    try std.testing.expect(pctx.err == null);
    try std.testing.expect(dctx.err == null);
    try std.testing.expect(dctx.passes.load(.monotonic) > 0); // deleter 确实跑了

    try db.flush(); // 最后一批 staged 落盘

    // 范围外 key：一个不丢（精确）
    const a_expected = pctx.a_puts.load(.acquire);
    try std.testing.expect(a_expected > 0);
    var a_present: usize = 0;
    var i: u64 = 0;
    var kbuf: [32]u8 = undefined;
    var vbuf: [32]u8 = undefined;
    while (i < a_expected) : (i += 1) {
        const k = try std.fmt.bufPrint(&kbuf, "a{d:0>6}", .{i});
        const v = try db.get(k);
        defer if (v) |val| std.testing.allocator.free(val);
        try std.testing.expect(v != null);
        const want = try std.fmt.bufPrint(&vbuf, "va{d:0>6}", .{i});
        try std.testing.expectEqualStrings(want, v.?);
        a_present += 1;
    }
    try std.testing.expectEqual(@as(u64, a_expected), @as(u64, a_present));

    // 全表自洽：entryCount == 扫描数；范围内在场 key value 合法
    var it = try db.select(null, null);
    defer it.deinit();
    var n: usize = 0;
    var d_present: usize = 0;
    while (try it.next()) |e| {
        n += 1;
        if (e.key[0] == 'd') {
            d_present += 1;
            const suffix = e.key[1..];
            var want: [32]u8 = undefined;
            const w = try std.fmt.bufPrint(&want, "vd{s}", .{suffix});
            try std.testing.expectEqualStrings(w, e.value);
        }
    }
    try std.testing.expectEqual(@as(u64, n), db.entryCount());
    try std.testing.expect(d_present <= pctx.d_puts.load(.acquire)); // 无幻影 key
}

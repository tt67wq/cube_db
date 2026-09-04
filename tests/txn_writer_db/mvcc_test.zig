//! mvcc_test.zig — MVCC reader 安全回收测试（TDD RED）
//! 覆盖：无 reader 时脏页立即回收、有 reader 时脏页延迟回收、reader 结束后回收。
//! 用 MemPageStore，先 fail（MVCC 尚未实现）。
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;
const wrt = cube.writer;

test "mvcc: no active readers — dirty pages freed immediately" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    // 写入一个 key（新建 leaf，无脏页）
    var f1: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v1", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();
    const dirt1 = state.dirt.load(.acquire);
    try std.testing.expectEqual(@as(u64, 0), dirt1); // 首次插入无脏页

    // 覆写 key（旧页进 pending_free，无读者应立即释放）
    var f2: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v2", .tombstone = false, .future = &f2 }});
    _ = try f2.wait();
    // 无读者 → pending_free 被 flush → dirt = 0（已回收）
    const dirt2 = state.dirt.load(.acquire);
    try std.testing.expectEqual(@as(u64, 0), dirt2);
    try std.testing.expectEqual(@as(usize, 0), state.pendingFreeCount());
    // pending_free 列表应为空
    try std.testing.expectEqual(@as(usize, 0), state.pendingFreeCount());
}

test "mvcc: active reader prevents dirty page recycling" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    // 写入一个 key，建立初始页
    var f1: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v1", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();

    // 在覆写前，先记下当前页数（bump 分配到的页号）
    // 此时 leaf 1 在页 FIRST_DATA_PAGE

    // 开始读事务（模拟 reader 持有旧 root 的快照）
    const reader_seq = state.beginRead();
    try std.testing.expect(reader_seq > 0);

    // 覆写 key（COW 创建新 leaf 2，释放旧 leaf 1）
    var f2: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v2", .tombstone = false, .future = &f2 }});
    _ = try f2.wait();

    // 有活跃 reader → pending_free 应 > 0（旧页未释放）
    try std.testing.expect(state.pendingFreeCount() > 0);

    // 结束读事务
    state.endRead();

    // 现在 pending_free 应已全部释放
    try std.testing.expectEqual(@as(usize, 0), state.pendingFreeCount());
}

test "mvcc: multiple readers all release before pages freed" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    var f1: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v1", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();

    // 两个读者同时活跃
    const r1 = state.beginRead();
    const r2 = state.beginRead();
    _ = r1;
    _ = r2;

    // 覆写
    var f2: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v2", .tombstone = false, .future = &f2 }});
    _ = try f2.wait();
    try std.testing.expect(state.pendingFreeCount() > 0);

    // 释放一个读者 → 页仍不应释放（还有另一个读者）
    state.endRead();
    try std.testing.expect(state.pendingFreeCount() > 0);

    // 释放第二个读者 → 页应释放
    state.endRead();
    try std.testing.expectEqual(@as(usize, 0), state.pendingFreeCount());
}

test "mvcc: dirt counter reflects pending pages" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    var f1: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v1", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();

    _ = state.beginRead();

    var f2: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v2", .tombstone = false, .future = &f2 }});
    _ = try f2.wait();

    // dirt 应等于 pending_free 数量（还未释放）
    try std.testing.expectEqual(state.pendingFreeCount(), state.dirt.load(.acquire));

    state.endRead();
    // reader 结束后，dirt 应该为 0（已释放）
    try std.testing.expectEqual(@as(u64, 0), state.dirt.load(.acquire));
}

test "mvcc: old root still readable during concurrent write" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    // 写入 key="k"="v1"
    var f1: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v1", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();
    const root_v1 = state.getRoot();

    // 开始读（模拟 reader 持有 old root 的快照）
    _ = state.beginRead();

    // 写入 key="k"="v2"（COW 产生新 root，旧 root 的页不应被回收）
    var f2: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v2", .tombstone = false, .future = &f2 }});
    _ = try f2.wait();

    // 旧 root 应仍可读（页未被回收）
    const oldv = try btree.get(std.testing.allocator, s, root_v1, "k");
    try std.testing.expectEqualStrings("v1", oldv.?);
    std.testing.allocator.free(oldv.?);

    // 新 root 读到新值
    const root_v2 = state.getRoot();
    try std.testing.expect(root_v2 != root_v1);
    const newv = try btree.get(std.testing.allocator, s, root_v2, "k");
    try std.testing.expectEqualStrings("v2", newv.?);
    std.testing.allocator.free(newv.?);

    state.endRead();
}

test "mvcc: beginRead/endRead nesting" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    // 嵌套 beginRead/endRead 应正确计数
    // 先写入一个 key，后续覆写产生脏页
    var f0: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "initial", .tombstone = false, .future = &f0 }});
    _ = try f0.wait();

    const r1 = state.beginRead();
    const r2 = state.beginRead();
    _ = r1;
    _ = r2;
    state.endRead(); // 释放第二个
    var f1: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();
    // 仍有活跃 reader（第一个），页不应释放
    try std.testing.expect(state.pendingFreeCount() > 0);
    state.endRead(); // 释放第一个
    try std.testing.expectEqual(@as(usize, 0), state.pendingFreeCount());
}
// ---- T-30: per-reader 序列注册 + oldest-reader watermark 精确回收 ----
//
// 旧模型缺陷：单一 reader_count + 末位读者 flush——任何读者活跃期间，所有提交
// COW 出的脏页都积压在 pending_free；短命读者退出也不回收，长命读者存活期间
// pending/dirt 无界增长；compact() 有读者时静默清 dirt 计数（误报 0，页仍钉住）。
//
// 新语义（T-30 期望）：
// - pending 页携带释放序列 release_seq（释放它的提交的 new_sequence）；
// - 每个活跃读者注册其快照序列；watermark = 活跃读者快照序列的最小值；
// - release_seq < watermark 的页可安全回收（无活跃读者仍可能引用它）；
//   等于或大于必须保留（老快照仍有效——正确性底线）；
// - 任意读者退出即按 watermark 增量回收，不必等末位读者；
//   末位读者退出（reader_count==0）仍全量回收（既有快路径保留）；
// - compact() 不再静默清计数：dirt 反映仍被钉住（不可回收）的真实页数。

fn applyPut(state: *wrt.State, key: []const u8, value: []const u8) !void {
    var fut: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = key, .value = value, .tombstone = false, .future = &fut }});
    _ = try fut.wait();
}

// 短命读者线程上下文：begin → 通知已开始 → 等待退出指令 → end → 通知已退出。
// B 独立线程：其 begin/end 占自己的线程本地注册栈，endRead 配对精确
// （B 退出即注销 B 的快照槽——并发读者的真实形态，参照
// mvcc_concurrent_flush_test 的线程模式；endRead 无身份参数，同线程乱序
// end 只能保守配对，跨线程才是精确配对）。
const ShortReaderCtx = struct {
    state: *wrt.State,
    snapshot: u64 = 0,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    may_exit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn shortReaderThread(ctx: *ShortReaderCtx) void {
    ctx.snapshot = ctx.state.beginRead();
    ctx.started.store(true, .release);
    while (!ctx.may_exit.load(.acquire)) {
        std.Thread.yield() catch {};
    }
    ctx.state.endRead();
    ctx.exited.store(true, .release);
}

test "mvcc watermark: short-lived reader exit reclaims pages while long-lived reader active" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    // 建树：3 次提交 → sequence=3（单叶树：root 即 leaf，每次覆写 COW 恰释放 1 页）
    try applyPut(&state, "a", "1"); // seq 1
    try applyPut(&state, "b", "1"); // seq 2
    try applyPut(&state, "c", "1"); // seq 3

    // B：短命读者，独立线程，早开始（最老快照 3）
    var bctx = ShortReaderCtx{ .state = &state };
    const tb = try std.Thread.spawn(.{}, shortReaderThread, .{&bctx});
    while (!bctx.started.load(.acquire)) {
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(u64, 3), bctx.snapshot);

    // 覆写 a → seq 4，旧叶释放（release_seq=4）
    try applyPut(&state, "a", "2");
    // 覆写 b → seq 5，旧叶释放（release_seq=5）
    try applyPut(&state, "b", "2");
    const pending_before = state.pendingFreeCount();
    try std.testing.expectEqual(@as(usize, 2), pending_before);

    // A：长命读者，晚开始（快照 5），捕获其快照 root
    const seq_a = state.beginRead();
    try std.testing.expectEqual(@as(u64, 5), seq_a);
    const root_a = state.getRoot();

    // B 退出（A 仍活跃）：通知 B 线程 end 并等待完成。
    // 旧模型：等末位读者（A）退出才回收 → pending 不变（此处 RED 失败）。
    // 新模型：B 注销其快照槽 → watermark=A 快照(5) → release_seq=4 的页
    //         回收（4<5），release_seq=5 的页保守保留（5≮5，边界页）。
    bctx.may_exit.store(true, .release);
    while (!bctx.exited.load(.acquire)) {
        std.Thread.yield() catch {};
    }
    tb.join();

    const pending_after = state.pendingFreeCount();
    try std.testing.expect(pending_after < pending_before); // 增量回收已发生
    try std.testing.expect(pending_after >= 1); // 保守边界页（release_seq==watermark）仍钉住
    // dirt 反映仍被钉住（不可回收）的真实页数
    try std.testing.expectEqual(pending_after, @as(usize, @intCast(state.dirt.load(.acquire))));

    // A 的快照树仍可读（未被回收的页内容不变）
    const va = try btree.get(std.testing.allocator, s, root_a, "a");
    try std.testing.expectEqualStrings("2", va.?);
    std.testing.allocator.free(va.?);
    const vc = try btree.get(std.testing.allocator, s, root_a, "c");
    try std.testing.expectEqualStrings("1", vc.?);
    std.testing.allocator.free(vc.?);

    // 反向正确性：A 快照(5)之后释放的页（release_seq=6），A 活跃时不得回收
    try applyPut(&state, "c", "2"); // seq 6，释放 R5 的叶（release_seq=6）
    try std.testing.expect(state.pendingFreeCount() > pending_after);
    // A 仍能读到自己的快照（c 仍是旧值 1）
    const vc2 = try btree.get(std.testing.allocator, s, root_a, "c");
    try std.testing.expectEqualStrings("1", vc2.?);
    std.testing.allocator.free(vc2.?);

    // A 退出（末位读者）→ 全量回收（既有快路径）
    state.endRead();
    try std.testing.expectEqual(@as(usize, 0), state.pendingFreeCount());
    try std.testing.expectEqual(@as(u64, 0), state.dirt.load(.acquire));
}

test "mvcc watermark: compact keeps dirt truthful with active reader" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    try applyPut(&state, "k", "v1"); // seq 1

    // A：长命读者（快照 1）
    const seq_a = state.beginRead();
    try std.testing.expectEqual(@as(u64, 1), seq_a);

    try applyPut(&state, "k", "v2"); // seq 2，旧叶释放（release_seq=2）
    try std.testing.expect(state.pendingFreeCount() > 0);
    try std.testing.expect(state.dirt.load(.acquire) > 0);

    // compact：有读者 → 无可回收页（release_seq=2 ≮ watermark=1）。
    // 旧模型：静默清计数（dirt=0 误报，页仍钉住）→ 此处 RED 失败。
    // 新模型：dirt 反映仍被钉住的真实页数，不再静默清零。
    try state.compact();
    try std.testing.expect(state.pendingFreeCount() > 0);
    try std.testing.expect(state.dirt.load(.acquire) > 0);
    try std.testing.expectEqual(state.pendingFreeCount(), @as(usize, @intCast(state.dirt.load(.acquire))));

    // 数据仍可读（compact 不影响可见性）
    const root = state.getRoot();
    const v = try btree.get(std.testing.allocator, s, root, "k");
    try std.testing.expectEqualStrings("v2", v.?);
    std.testing.allocator.free(v.?);

    // A 退出（末位读者）→ 全量回收，dirt 归 0
    state.endRead();
    try std.testing.expectEqual(@as(usize, 0), state.pendingFreeCount());
    try std.testing.expectEqual(@as(u64, 0), state.dirt.load(.acquire));
}

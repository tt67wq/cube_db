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
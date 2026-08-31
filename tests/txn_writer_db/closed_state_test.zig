//! closed_state_test.zig — T-4: applyBatch closed 分支测试
//! 验证 State.deinit() 后调 applyBatch，所有 future 收到 error.Closed 且无 segfault。
//! 覆盖 src/writer.zig:261-264 的 closed 守卫分支。
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;
const wrt = cube.writer;

const alloc = std.testing.allocator;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 10000);
}

// ---- Test 1: close 后 applyBatch，所有 future 收到 error.Closed ----
test "closed: applyBatch after deinit sets error.Closed on all futures" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(alloc, s, .{});
    // deinit 标记 closed=true，释放 pending_free
    state.deinit();
    // state.deinit 已调用，不调两次（ms.deinit 在 defer 中释放页存储）

    // 构造 batch：3 个请求
    var futures: [3]zio.Future(wrt.OpResult) = .{ .{}, .{}, .{} };
    const reqs = [_]wrt.Request{
        .{ .key = "a", .value = "1", .tombstone = false, .future = &futures[0] },
        .{ .key = "b", .value = "2", .tombstone = false, .future = &futures[1] },
        .{ .key = "c", .value = "3", .tombstone = false, .future = &futures[2] },
    };

    // applyBatch 不返回 error（closed 分支只 set future 后 return）
    try state.applyBatch(&reqs);

    // 每个 future 应收到 error.Closed
    for (&futures) |*f| {
        const result = try f.wait();
        try std.testing.expectError(error.Closed, result.value);
    }

    // 状态未被改动：root 仍为 NULL_ROOT，sequence/dirt/entry_count 仍为 0
    try std.testing.expectEqual(btree.NULL_ROOT, state.root.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.sequence.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.entry_count.load(.acquire));
}

// ---- Test 2: 先正常 putBatch 再 close 再 applyBatch，状态不被改动 ----
test "closed: normal applyBatch then deinit then applyBatch — state unchanged" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(alloc, s, .{});

    // 正常路径：applyBatch 3 个 put
    var f1: [3]zio.Future(wrt.OpResult) = .{ .{}, .{}, .{} };
    const reqs1 = [_]wrt.Request{
        .{ .key = "x", .value = "1", .tombstone = false, .future = &f1[0] },
        .{ .key = "y", .value = "2", .tombstone = false, .future = &f1[1] },
        .{ .key = "z", .value = "3", .tombstone = false, .future = &f1[2] },
    };
    try state.applyBatch(&reqs1);
    for (&f1) |*f| _ = try f.wait();

    // 记录 close 前的状态
    const root_before = state.root.load(.acquire);
    const seq_before = state.sequence.load(.acquire);
    const count_before = state.entry_count.load(.acquire);

    // close
    state.deinit();

    // close 后再 applyBatch
    var f2: [2]zio.Future(wrt.OpResult) = .{ .{}, .{} };
    const reqs2 = [_]wrt.Request{
        .{ .key = "new1", .value = "v", .tombstone = false, .future = &f2[0] },
        .{ .key = "new2", .value = "v", .tombstone = false, .future = &f2[1] },
    };
    try state.applyBatch(&reqs2);

    // 所有 future 收到 error.Closed
    for (&f2) |*f| {
        const result = try f.wait();
        try std.testing.expectError(error.Closed, result.value);
    }

    // 状态未被 close 后的 applyBatch 改动
    try std.testing.expectEqual(root_before, state.root.load(.acquire));
    try std.testing.expectEqual(seq_before, state.sequence.load(.acquire));
    try std.testing.expectEqual(count_before, state.entry_count.load(.acquire));

    // close 前的数据确实在 btree 中（通过 root 验证）
    const v = try btree.get(alloc, s, root_before, "x");
    try std.testing.expectEqualStrings("1", v.?);
    alloc.free(v.?);
}

// ---- Test 3: close 后单个请求也收到 error.Closed ----
test "closed: single request after deinit gets error.Closed" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(alloc, s, .{});
    state.deinit();

    var future: zio.Future(wrt.OpResult) = .{};
    const req = wrt.Request{
        .key = "solo",
        .value = "val",
        .tombstone = false,
        .future = &future,
    };
    try state.applyBatch(&.{req});

    const result = try future.wait();
    try std.testing.expectError(error.Closed, result.value);

    try std.testing.expectEqual(btree.NULL_ROOT, state.root.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.sequence.load(.acquire));
}

// ---- Test 4: close 后空 batch 不崩 ----
test "closed: empty batch after deinit is no-op, no crash" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(alloc, s, .{});
    state.deinit();

    // 空 batch：closed 分支 for 循环不执行，直接 return
    try state.applyBatch(&.{});

    try std.testing.expectEqual(btree.NULL_ROOT, state.root.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.sequence.load(.acquire));
}

//! writer2_test.zig — writer2 applyBatch 测试（TDD RED）
//! 覆盖：单条 put、批量 put、delete、meta 交替、root 原子更新、dirt 统计。
//! 用 MemPageStore 模拟存储，先 fail（writer2.zig 不存在）。
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const fmt2 = cube.format2;
const ps = cube.page_store;
const btree2 = cube.btree2;
const writer2 = cube.writer2;

// ---- 辅助 ----

const MAPSIZE_PAGES = 10000;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(std.testing.allocator, MAPSIZE_PAGES);
}

test "writer2: applyBatch with single put" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = writer2.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    var future: zio.Future(writer2.OpResult) = .{};
    const req = writer2.Request{
        .key = "hello",
        .value = "world",
        .tombstone = false,
        .future = &future,
    };
    try state.applyBatch(&.{req});
    _ = try future.wait();

    // 验证数据在树中
    const root = state.root.load(.acquire);
    try std.testing.expect(root != btree2.NULL_ROOT);
    const v = try btree2.get(std.testing.allocator, s, root, "hello");
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("world", v.?);
    std.testing.allocator.free(v.?);
}

test "writer2: applyBatch with multiple puts" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = writer2.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    var futures: [3]zio.Future(writer2.OpResult) = .{ .{}, .{}, .{} };
    const reqs = [_]writer2.Request{
        .{ .key = "a", .value = "1", .tombstone = false, .future = &futures[0] },
        .{ .key = "b", .value = "2", .tombstone = false, .future = &futures[1] },
        .{ .key = "c", .value = "3", .tombstone = false, .future = &futures[2] },
    };
    try state.applyBatch(&reqs);
    for (&futures) |*f| _ = try f.wait();

    const root = state.root.load(.acquire);
    for (reqs) |r| {
        const v = try btree2.get(std.testing.allocator, s, root, r.key);
        try std.testing.expect(v != null);
        std.testing.allocator.free(v.?);
    }
}

test "writer2: applyBatch with delete" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = writer2.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    // 先 put
    var f1: zio.Future(writer2.OpResult) = .{};
    try state.applyBatch(&.{.{
        .key = "x", .value = "y", .tombstone = false, .future = &f1,
    }});
    _ = try f1.wait();

    // 再 delete
    var f2: zio.Future(writer2.OpResult) = .{};
    try state.applyBatch(&.{.{
        .key = "x", .value = "", .tombstone = true, .future = &f2,
    }});
    _ = try f2.wait();

    const root = state.root.load(.acquire);
    const v = try btree2.get(std.testing.allocator, s, root, "x");
    try std.testing.expectEqual(@as(?[]u8, null), v);
}

test "writer2: meta page alternates after each applyBatch" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = writer2.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    // 第一次 applyBatch → meta page 0
    var f1: zio.Future(writer2.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k1", .value = "v1", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();
    const meta_after_1 = try s.readMeta();
    try std.testing.expect(meta_after_1 != null);
    try std.testing.expectEqual(@as(u64, 1), meta_after_1.?.sequence);
    try std.testing.expect(meta_after_1.?.root_page != fmt2.NULL_PAGE);

    // 第二次 applyBatch → meta page 1（sequence=2）
    var f2: zio.Future(writer2.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k2", .value = "v2", .tombstone = false, .future = &f2 }});
    _ = try f2.wait();
    const meta_after_2 = try s.readMeta();
    try std.testing.expect(meta_after_2 != null);
    try std.testing.expectEqual(@as(u64, 2), meta_after_2.?.sequence);

    // 第三次 → meta page 0（sequence=3）
    var f3: zio.Future(writer2.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k3", .value = "v3", .tombstone = false, .future = &f3 }});
    _ = try f3.wait();
    const meta_after_3 = try s.readMeta();
    try std.testing.expect(meta_after_3 != null);
    try std.testing.expectEqual(@as(u64, 3), meta_after_3.?.sequence);
}

test "writer2: root atomically updated after each batch" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = writer2.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    try std.testing.expectEqual(btree2.NULL_ROOT, state.root.load(.acquire));

    var f1: zio.Future(writer2.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "a", .value = "1", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();
    const r1 = state.root.load(.acquire);
    try std.testing.expect(r1 != btree2.NULL_ROOT);

    var f2: zio.Future(writer2.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "b", .value = "2", .tombstone = false, .future = &f2 }});
    _ = try f2.wait();
    const r2 = state.root.load(.acquire);
    try std.testing.expect(r2 != r1); // COW → new root
}

test "writer2: dirt count reflects pending free pages" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = writer2.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    // 第一次 put：新建 leaf → dirt 应为 0（无旧页回收）
    var f1: zio.Future(writer2.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v1", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();
    try std.testing.expectEqual(@as(u64, 0), state.dirt.load(.acquire));

    // 第二次 overwrite：旧页被回收 → dirt > 0
    var f2: zio.Future(writer2.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v2", .tombstone = false, .future = &f2 }});
    _ = try f2.wait();
    try std.testing.expect(state.dirt.load(.acquire) > 0);
}

test "writer2: entry_count and byte_size updated correctly" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = writer2.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    try std.testing.expectEqual(@as(u64, 0), state.entry_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.byte_size.load(.acquire));

    // put "hello"="world" (5+5+9=19 bytes)
    var f1: zio.Future(writer2.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "hello", .value = "world", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();
    try std.testing.expectEqual(@as(u64, 1), state.entry_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 19), state.byte_size.load(.acquire));

    // delete "hello" (tombstone, but entry count should go to 0)
    var f2: zio.Future(writer2.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "hello", .value = "", .tombstone = true, .future = &f2 }});
    _ = try f2.wait();
    try std.testing.expectEqual(@as(u64, 0), state.entry_count.load(.acquire));
}

test "writer2: batch with mixed ops" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = writer2.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    var futures: [4]zio.Future(writer2.OpResult) = .{ .{}, .{}, .{}, .{} };
    const reqs = [_]writer2.Request{
        .{ .key = "a", .value = "1", .tombstone = false, .future = &futures[0] },
        .{ .key = "b", .value = "2", .tombstone = false, .future = &futures[1] },
        .{ .key = "a", .value = "", .tombstone = true, .future = &futures[2] }, // delete a
        .{ .key = "c", .value = "3", .tombstone = false, .future = &futures[3] },
    };
    try state.applyBatch(&reqs);
    for (&futures) |*f| _ = try f.wait();

    const root = state.root.load(.acquire);
    // "a" 被删了
    try std.testing.expectEqual(@as(?[]u8, null), try btree2.get(std.testing.allocator, s, root, "a"));
    // "b" 和 "c" 应存在
    const vb = try btree2.get(std.testing.allocator, s, root, "b");
    try std.testing.expectEqualStrings("2", vb.?);
    std.testing.allocator.free(vb.?);
    const vc = try btree2.get(std.testing.allocator, s, root, "c");
    try std.testing.expectEqualStrings("3", vc.?);
    std.testing.allocator.free(vc.?);
    // entry_count = 2 (b, c)
    try std.testing.expectEqual(@as(u64, 2), state.entry_count.load(.acquire));
}
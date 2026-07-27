//! tutorial_smoke_test.zig — 验证 docs/tutorial/ 所有可运行片段语法正确
//! 读者复制其中任意片段到独立 test 文件均可独立运行。
const std = @import("std");
const cube = @import("cube_db");
const zio = @import("zio");

const format = cube.format;
const MemPageStore = cube.page_store.MemPageStore;
const btree = cube.btree;

// ---- 第 01 章：页格式 ----
test "T01 页头编解码和 CRC 校验" {
    const h = format.PageHeader{
        .page_no = 42,
        .page_type = format.PAGE_TYPE_LEAF,
        .gen = 1000,
        .nkeys = 16,
        .free_next = 0,
    };

    var buf: [format.PAGE_HEADER_SIZE]u8 = undefined;
    format.encodePageHeader(&buf, &h);
    const got = format.decodePageHeader(&buf);
    try std.testing.expectEqual(h.page_no, got.page_no);
    try std.testing.expectEqual(h.page_type, got.page_type);
    try std.testing.expectEqual(h.gen, got.gen);

    var page: [format.PAGE_SIZE]u8 = undefined;
    @memset(&page, 0);
    format.encodePageHeader(&page, &h);
    @memset(page[format.PAGE_HEADER_SIZE .. format.PAGE_SIZE - 4], 0xbb);

    const cs = format.computePageChecksum(&page);
    format.setPageChecksum(&page, cs);
    try std.testing.expect(format.verifyPageChecksum(&page));

    page[100] ^= 0xff;
    try std.testing.expect(!format.verifyPageChecksum(&page));
}

// ---- 第 02 章：B-tree ----
test "T02 B-tree 插入和查询" {
    const allocator = std.testing.allocator;
    var ms = MemPageStore.init(allocator, 1 << 10);
    defer ms.deinit();
    const store = ms.store();

    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    var root: u32 = 0;

    for ([_][]const u8{ "alice", "bob", "carol" }, 0..) |k, i| {
        var buf: [8]u8 = undefined;
        const v = try std.fmt.bufPrint(&buf, "val_{d}", .{i});
        const result = try btree.insert(allocator, store, root, k, v, false, &dirty);
        root = result.new_root;
    }

    const v = try btree.get(allocator, store, root, "bob");
    defer if (v) |val| allocator.free(val);
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("val_1", v.?);

    const nv = try btree.get(allocator, store, root, "zoe");
    try std.testing.expect(nv == null);
}

// ---- 第 03 章：COW 写入 ----
test "T03 applyBatch 批量写入 + compact" {
    const allocator = std.testing.allocator;
    var ms = MemPageStore.init(allocator, 1 << 10);
    defer ms.deinit();
    const store = ms.store();

    const wrt = cube.writer;
    var state = wrt.State.init(allocator, store, .{ .fsync = false });
    defer state.deinit();

    var f1: zio.Future(wrt.OpResult) = .{};
    var f2: zio.Future(wrt.OpResult) = .{};
    var f3: zio.Future(wrt.OpResult) = .{};

    const batch = [_]wrt.Request{
        .{ .key = "alpha", .value = "100", .tombstone = false, .future = &f1 },
        .{ .key = "beta", .value = "200", .tombstone = false, .future = &f2 },
        .{ .key = "gamma", .value = "300", .tombstone = false, .future = &f3 },
    };

    try state.applyBatch(&batch);
    _ = try f1.wait();
    _ = try f2.wait();
    _ = try f3.wait();

    try state.compact();
    try std.testing.expectEqual(@as(u64, 0), state.dirtCount());
}

// ---- 第 04 章：MVCC ----
test "T04 MVCC 读者延迟回收" {
    const allocator = std.testing.allocator;
    var ms = MemPageStore.init(allocator, 1 << 10);
    defer ms.deinit();
    const store = ms.store();

    const wrt = cube.writer;
    var state = wrt.State.init(allocator, store, .{ .fsync = false });
    defer state.deinit();

    // 先写一条，让树有数据（后续 insert 才会产生脏页）
    {
        var f0: zio.Future(wrt.OpResult) = .{};
        try state.applyBatch(&.{.{ .key = "seed", .value = "x",
            .tombstone = false, .future = &f0 }});
        _ = try f0.wait();
    }

    // 启动读者
    const snap = state.beginRead();
    defer state.endRead();

    try std.testing.expect(snap >= 0);
    try std.testing.expectEqual(@as(u32, 1), state.reader_count.load(.acquire));

    var future: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "mvcc", .value = "test",
        .tombstone = false, .future = &future }});
    _ = try future.wait();
    try std.testing.expect(state.dirtCount() > 0);
    try std.testing.expect(state.pendingFreeCount() > 0);
}

// ---- 第 05 章：溢出页 ----
test "T05 大 value 溢出页链" {
    const allocator = std.testing.allocator;
    var ms = MemPageStore.init(allocator, 1 << 12);
    defer ms.deinit();
    const store = ms.store();

    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    var root: u32 = 0;

    const big_value = try allocator.alloc(u8, 5000);
    defer allocator.free(big_value);
    @memset(big_value, 0xAB);

    const result = try btree.insert(allocator, store, root, "bigkey", big_value, false, &dirty);
    root = result.new_root;

    const v = try btree.get(allocator, store, root, "bigkey");
    defer if (v) |val| allocator.free(val);

    try std.testing.expect(v != null);
    try std.testing.expectEqual(@as(usize, 5000), v.?.len);
    try std.testing.expectEqual(@as(u8, 0xAB), v.?[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), v.?[4999]);
}

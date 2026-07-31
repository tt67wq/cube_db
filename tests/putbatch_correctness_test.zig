//! putbatch_correctness_test.zig — putBatch 正确性测试
//! 回归保护：防止 applyBatch 排序去重时 key/value 共享导致数据丢失
//! （#20 曾引入 bug：共享栈 buffer 的 entry 排序去重后 collapse 成 1 条）
const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const MemPageStore = cube.page_store.MemPageStore;

fn newStore() MemPageStore {
    return MemPageStore.init(std.testing.allocator, 100000);
}

/// 关键场景：entries 的 key 共享同一个栈 buffer（模拟 bench.zig 的 runPutBatch）
/// 之前这个场景会让 insertBatch 的排序去重 collapse 成 1 条
test "putbatch: shared stack buffer keys, all N inserted correctly" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 1000;
    var entries = try std.testing.allocator.alloc(cube.Entry, n);
    defer std.testing.allocator.free(entries);

    // 用共享栈 buffer 生成 key（复现 bench.zig 的模式）
    var kbuf: [12]u8 = undefined;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i});
        entries[i] = .{ .key = k, .value = "v" };
    }

    try db.putBatch(entries);

    // 关键验证：N 条必须全部可读
    try std.testing.expectEqual(@as(u64, n), db.entryCount());
    var vkbuf: [12]u8 = undefined;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&vkbuf, "{d:0>10}", .{i});
        const v = try db.get(k);
        defer if (v) |val| std.testing.allocator.free(val);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings("v", v.?);
    }
}

/// putBatch 后逐条验证 + delete 全部后 count 归零
test "putbatch: 10K entries all inserted, then all deleted" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 10000;
    var entries = try std.testing.allocator.alloc(cube.Entry, n);
    defer std.testing.allocator.free(entries);

    var kbuf: [12]u8 = undefined;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i});
        entries[i] = .{ .key = k, .value = "v" };
    }

    try db.putBatch(entries);
    try std.testing.expectEqual(@as(u64, n), db.entryCount());

    // 逐条验证
    var vkbuf: [12]u8 = undefined;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&vkbuf, "{d:0>10}", .{i});
        const v = try db.get(k);
        defer if (v) |val| std.testing.allocator.free(val);
        try std.testing.expect(v != null);
    }

    // 全部 delete
    var txn = try db.beginWriteTxn();
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&vkbuf, "{d:0>10}", .{i});
        try txn.delete(k);
    }
    try txn.commit();

    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

/// 两个 putBatch 连续插入（不同 key 集），验证都能正确插入
test "putbatch: two batches with distinct keys" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 500;
    var kbuf: [12]u8 = undefined;

    // Batch 1: keys 0..499
    {
        var entries = try std.testing.allocator.alloc(cube.Entry, n);
        defer std.testing.allocator.free(entries);
        for (0..n) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i});
            entries[i] = .{ .key = k, .value = "b1" };
        }
        try db.putBatch(entries);
    }

    // Batch 2: keys 500..999
    {
        var entries = try std.testing.allocator.alloc(cube.Entry, n);
        defer std.testing.allocator.free(entries);
        for (0..n) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i + n});
            entries[i] = .{ .key = k, .value = "b2" };
        }
        try db.putBatch(entries);
    }

    try std.testing.expectEqual(@as(u64, 2 * n), db.entryCount());

    // 验证 batch1 和 batch2 的 key 都在
    var vkbuf: [12]u8 = undefined;
    for (0..2 * n) |i| {
        const k = try std.fmt.bufPrint(&vkbuf, "{d:0>10}", .{i});
        const v = try db.get(k);
        defer if (v) |val| std.testing.allocator.free(val);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings(if (i < n) "b1" else "b2", v.?);
    }
}

/// putBatch 含 tombstone（delete）
test "putbatch: mixed put + delete in one batch" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    // 先插入一批
    var kbuf: [12]u8 = undefined;
    {
        var entries = try std.testing.allocator.alloc(cube.Entry, 100);
        defer std.testing.allocator.free(entries);
        for (0..100) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i});
            entries[i] = .{ .key = k, .value = "v" };
        }
        try db.putBatch(entries);
    }

    // 一个 batch 里：删除 0-49，更新 50-99
    {
        var entries = try std.testing.allocator.alloc(cube.Entry, 100);
        defer std.testing.allocator.free(entries);
        for (0..100) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i});
            entries[i] = .{
                .key = k,
                .value = if (i < 50) "" else "v2",
                .tombstone = i < 50,
            };
        }
        try db.putBatch(entries);
    }

    try std.testing.expectEqual(@as(u64, 50), db.entryCount());

    var vkbuf: [12]u8 = undefined;
    for (0..100) |i| {
        const k = try std.fmt.bufPrint(&vkbuf, "{d:0>10}", .{i});
        const v = try db.get(k);
        defer if (v) |val| std.testing.allocator.free(val);
        if (i < 50) {
            try std.testing.expectEqual(@as(?[]u8, null), v);
        } else {
            try std.testing.expect(v != null);
            try std.testing.expectEqualStrings("v2", v.?);
        }
    }
}
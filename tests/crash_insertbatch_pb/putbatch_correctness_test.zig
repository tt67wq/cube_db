//! putbatch_correctness_test.zig — putBatch 正确性测试
//! 回归保护：防止 putBatch 数据丢失。
//! 关键教训：调用方绝不能共享 buffer 生成 batch entries 的 key
//! （所有 key 会变成最后一个值，insertBatch 排序去重后 collapse 成 1 条）。
const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const MemPageStore = cube.page_store.MemPageStore;

fn newStore() MemPageStore {
    return MemPageStore.init(std.testing.allocator, 100000);
}

// 大批量 putBatch（独立分配 key），验证 N 条全部插入
test "putbatch: heap keys, all N inserted correctly" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 1000;
    var entries = try std.testing.allocator.alloc(cube.Entry, n);
    defer std.testing.allocator.free(entries);
    for (0..n) |i| {
        entries[i] = .{ .key = try std.fmt.allocPrint(std.testing.allocator, "{d:0>10}", .{i}), .value = "v" };
    }
    defer {
        for (entries) |e| std.testing.allocator.free(e.key);
    }

    try db.putBatch(entries);

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

// putBatch 后逐条验证 + delete 全部后 count 归零
test "putbatch: 10K entries all inserted, then all deleted" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 10000;
    var entries = try std.testing.allocator.alloc(cube.Entry, n);
    defer std.testing.allocator.free(entries);
    for (0..n) |i| {
        entries[i] = .{ .key = try std.fmt.allocPrint(std.testing.allocator, "{d:0>10}", .{i}), .value = "v" };
    }
    defer {
        for (entries) |e| std.testing.allocator.free(e.key);
    }

    try db.putBatch(entries);
    try std.testing.expectEqual(@as(u64, n), db.entryCount());

    var vkbuf: [12]u8 = undefined;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&vkbuf, "{d:0>10}", .{i});
        const v = try db.get(k);
        defer if (v) |val| std.testing.allocator.free(val);
        try std.testing.expect(v != null);
    }

    var txn = try db.beginWriteTxn();
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&vkbuf, "{d:0>10}", .{i});
        try txn.delete(k);
    }
    try txn.commit();

    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

// 两个 putBatch 连续插入（不同 key 集），验证都能正确插入
test "putbatch: two batches with distinct keys" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 500;

    {
        var entries = try std.testing.allocator.alloc(cube.Entry, n);
        defer std.testing.allocator.free(entries);
        for (0..n) |i| {
            entries[i] = .{ .key = try std.fmt.allocPrint(std.testing.allocator, "{d:0>10}", .{i}), .value = "b1" };
        }
        defer {
            for (entries) |e| std.testing.allocator.free(e.key);
        }
        try db.putBatch(entries);
    }

    {
        var entries = try std.testing.allocator.alloc(cube.Entry, n);
        defer std.testing.allocator.free(entries);
        for (0..n) |i| {
            entries[i] = .{ .key = try std.fmt.allocPrint(std.testing.allocator, "{d:0>10}", .{i + n}), .value = "b2" };
        }
        defer {
            for (entries) |e| std.testing.allocator.free(e.key);
        }
        try db.putBatch(entries);
    }

    try std.testing.expectEqual(@as(u64, 2 * n), db.entryCount());

    var vkbuf: [12]u8 = undefined;
    for (0..2 * n) |i| {
        const k = try std.fmt.bufPrint(&vkbuf, "{d:0>10}", .{i});
        const v = try db.get(k);
        defer if (v) |val| std.testing.allocator.free(val);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings(if (i < n) "b1" else "b2", v.?);
    }
}

// putBatch 含 tombstone（delete）
test "putbatch: mixed put + delete in one batch" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    {
        var entries = try std.testing.allocator.alloc(cube.Entry, 100);
        defer std.testing.allocator.free(entries);
        for (0..100) |i| {
            entries[i] = .{ .key = try std.fmt.allocPrint(std.testing.allocator, "{d:0>10}", .{i}), .value = "v" };
        }
        defer {
            for (entries) |e| std.testing.allocator.free(e.key);
        }
        try db.putBatch(entries);
    }

    {
        var entries = try std.testing.allocator.alloc(cube.Entry, 100);
        defer std.testing.allocator.free(entries);
        for (0..100) |i| {
            entries[i] = .{
                .key = try std.fmt.allocPrint(std.testing.allocator, "{d:0>10}", .{i}),
                .value = if (i < 50) "" else "v2",
                .tombstone = i < 50,
            };
        }
        defer {
            for (entries) |e| std.testing.allocator.free(e.key);
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
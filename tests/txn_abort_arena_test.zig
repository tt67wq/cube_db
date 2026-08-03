//! txn_abort_arena_test.zig — #32 验收：WriteTxn abort 路径正确性
//! @archon 要求：staging 后 abort，再读验证无脏数据
//! 覆盖 WriteTxn arena 生命周期风险点
const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const MemPageStore = cube.page_store.MemPageStore;
const testing = std.testing;

// 基本 abort：put 后 abort，验证数据未应用
test "abort: put then abort, no data applied" {
    var ms = MemPageStore.init(testing.allocator, 100000);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    {
        var txn = try db.beginWriteTxn();
        try txn.put("k1", "v1");
        try txn.put("k2", "v2");
        try txn.abort();
    }

    try testing.expectEqual(@as(u64, 0), db.entryCount());
    const v1 = try db.get("k1");
    defer if (v1) |val| testing.allocator.free(val);
    try testing.expectEqual(@as(?[]u8, null), v1);
}

// abort 后继续正常写入，验证互不影响
test "abort: then commit another txn works" {
    var ms = MemPageStore.init(testing.allocator, 100000);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    {
        var txn = try db.beginWriteTxn();
        try txn.put("aborted", "no");
        try txn.abort();
    }
    {
        var txn = try db.beginWriteTxn();
        try txn.put("committed", "yes");
        try txn.commit();
    }

    try testing.expectEqual(@as(u64, 1), db.entryCount());
    const v = try db.get("committed");
    defer if (v) |val| testing.allocator.free(val);
    try testing.expectEqualStrings("yes", v.?);
    const av = try db.get("aborted");
    defer if (av) |val| testing.allocator.free(val);
    try testing.expectEqual(@as(?[]u8, null), av);
}

// 大 batch put 后 abort（staging 大量数据），验证 arena 释放后无残留
test "abort: large staging then abort, clean state" {
    var ms = MemPageStore.init(testing.allocator, 100000);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 10000;
    {
        var txn = try db.beginWriteTxn();
        var kbuf: [16]u8 = undefined;
        for (0..n) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{i});
            try txn.put(k, "value");
        }
        try txn.abort();
    }

    try testing.expectEqual(@as(u64, 0), db.entryCount());
    // 抽查几个 key 确认无残留
    var vkbuf: [16]u8 = undefined;
    for ([_]usize{ 0, 1, 100, 5000, 9999 }) |i| {
        const k = try std.fmt.bufPrint(&vkbuf, "k{d:0>6}", .{i});
        const v = try db.get(k);
        defer if (v) |val| testing.allocator.free(val);
        try testing.expectEqual(@as(?[]u8, null), v);
    }
}

// putBatch 大量 entries 后 abort（通过 db.putBatch 的 abort 路径）
// 注意：db.putBatch 内部 commit，不暴露 abort —— 这里用 WriteTxn 手动 abort 模拟
test "abort: mixed put/delete staging then abort" {
    var ms = MemPageStore.init(testing.allocator, 100000);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    // 先 commit 一批
    {
        var txn = try db.beginWriteTxn();
        try txn.put("base1", "v");
        try txn.put("base2", "v");
        try txn.commit();
    }
    const count_before = db.entryCount();

    // staging 混合 put/delete 后 abort
    {
        var txn = try db.beginWriteTxn();
        try txn.put("base1", "changed"); // update existing
        try txn.delete("base2"); // delete existing
        try txn.put("new1", "v"); // insert new
        try txn.abort();
    }

    // abort 后一切保持原样
    try testing.expectEqual(count_before, db.entryCount());
    const v1 = try db.get("base1");
    defer if (v1) |val| testing.allocator.free(val);
    try testing.expectEqualStrings("v", v1.?);
    const v2 = try db.get("base2");
    defer if (v2) |val| testing.allocator.free(val);
    try testing.expectEqualStrings("v", v2.?);
    const vn = try db.get("new1");
    defer if (vn) |val| testing.allocator.free(val);
    try testing.expectEqual(@as(?[]u8, null), vn);
}

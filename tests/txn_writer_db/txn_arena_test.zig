//! txn_arena_test.zig — TDD: WriteTxn staging arena 化
//! 验证 arena 化后的正确性：put/delete/commit/abort 语义不变，
//! 且 arena 释放无泄漏、无残留引用。
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const Db = cube.Db;

fn newStore(comptime n: usize) ps.MemPageStore {
    return ps.MemPageStore.init(std.testing.allocator, n);
}

// Test 1: put/commit roundtrip — staged entries 正确应用
test "txn arena: put/commit roundtrip" {
    var ms = newStore(100000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var txn = try db.beginWriteTxn();
    defer txn.deinit();
    try txn.put("key1", "value1");
    try txn.put("key2", "value2");
    try txn.delete("key1");
    try txn.commit();

    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
    try std.testing.expectEqual(@as(?[]u8, null), try db.get("key1"));
    const v2 = try db.get("key2");
    defer if (v2) |v| std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("value2", v2.?);
}

// Test 2: abort 后无脏数据（@archon 风险点：arena 释放后无残留引用）
test "txn arena: abort discards staged, no dirty data" {
    var ms = newStore(100000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    // 先写入一条 committed 数据
    try db.putDirect("base", "keep");

    // txn 暂存后 abort
    var txn = try db.beginWriteTxn();
    defer txn.deinit();
    try txn.put("aborted1", "x");
    try txn.put("aborted2", "y");
    try txn.delete("base");
    try txn.abort();

    // abort 后：committed 数据保持，aborted 数据不存在
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
    const v = try db.get("base");
    defer if (v) |val| std.testing.allocator.free(val);
    try std.testing.expectEqualStrings("keep", v.?);
    try std.testing.expectEqual(@as(?[]u8, null), try db.get("aborted1"));
    try std.testing.expectEqual(@as(?[]u8, null), try db.get("aborted2"));
}

// Test 3: stack buffer keys — txn.put 立即 dupe，key 不活到 commit 也安全
test "txn arena: stack buffer keys survive until commit" {
    var ms = newStore(100000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var txn = try db.beginWriteTxn();
    defer txn.deinit();
    // 共享栈 buffer：模拟调用方复用 buffer 的场景
    var kbuf: [16]u8 = undefined;
    {
        const k1 = try std.fmt.bufPrint(&kbuf, "key_{d}", .{1});
        try txn.put(k1, "v1");
    }
    {
        const k2 = try std.fmt.bufPrint(&kbuf, "key_{d}", .{2});
        try txn.put(k2, "v2");
    }
    try txn.commit();

    try std.testing.expectEqual(@as(u64, 2), db.entryCount());
    const v1 = try db.get("key_1");
    defer if (v1) |v| std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("v1", v1.?);
    const v2 = try db.get("key_2");
    defer if (v2) |v| std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("v2", v2.?);
}

// Test 4: 大批量 put（1000 条）后 entryCount 正确
test "txn arena: large batch put count correct" {
    var ms = newStore(500000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 1000;
    var txn = try db.beginWriteTxn();
    defer txn.deinit();
    var kbuf: [16]u8 = undefined;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>6}", .{i});
        try txn.put(k, "v");
    }
    try txn.commit();

    try std.testing.expectEqual(@as(u64, n), db.entryCount());
    var kbuf2: [16]u8 = undefined;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf2, "key_{d:0>6}", .{i});
        const v = try db.get(k);
        try std.testing.expectEqualStrings("v", v.?);
        std.testing.allocator.free(v.?);
    }
}

// Test 5: 多次 commit/abort 交替 — arena 生命周期正确，无泄漏
test "txn arena: alternating commit and abort" {
    var ms = newStore(500000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var kbuf: [16]u8 = undefined;
    for (0..20) |round| {
        var txn = try db.beginWriteTxn();
        defer txn.deinit();
        for (0..50) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "r{d}_{d:0>4}", .{ round, i });
            try txn.put(k, "v");
        }
        if (round % 2 == 0) {
            try txn.commit();
        } else {
            try txn.abort();
        }
    }
    // 10 轮 commit × 50 = 500 entries
    try std.testing.expectEqual(@as(u64, 500), db.entryCount());
}

// Test 6: putBatch 使用共享栈 buffer — 语义保持（值语义由调用方保证）
test "txn arena: putBatch with shared buffer collapses (caller semantics)" {
    var ms = newStore(100000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    // 模拟 bench_baseline 曾经的共享 buffer 模式：所有 entry 的 key 指向同一 buffer
    var kbuf: [12]u8 = undefined;
    const entries = try std.testing.allocator.alloc(cube.Entry, 10);
    defer std.testing.allocator.free(entries);
    for (entries) |*e| {
        const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{7});
        e.* = .{ .key = k, .value = "v" };
    }
    try db.putBatch(entries);
    // 所有 key 相同 → collapse 到 1 条（这是调用方语义，不是 putBatch 的 bug）
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
}

// Test 7: deinit 未 commit 的 txn — 不泄漏、不崩
test "txn arena: deinit without commit or abort" {
    var ms = newStore(100000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var kbuf: [16]u8 = undefined;
    {
        var txn = try db.beginWriteTxn();
        defer txn.deinit();
        for (0..10) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "tmp_{d}", .{i});
            try txn.put(k, "v");
        }
        // 不 commit 不 abort，直接出作用域（deinit 触发 abort）
    }
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
    // 互斥锁应已释放 — 能再开新 txn
    var txn2 = try db.beginWriteTxn();
    defer txn2.deinit();
    try txn2.put("after", "ok");
    try txn2.commit();
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
}

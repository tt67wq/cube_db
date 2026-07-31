//! insertbatch_overflow_test.zig — #26 回归测试
//! insertBatch leaf 容量溢出修复的验收测试
//! 覆盖：大批量同 leaf 范围、随机分布、逆序、重复 key
const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const MemPageStore = cube.page_store.MemPageStore;
const testing = std.testing;

fn newStore(mapsize: u32) MemPageStore {
    return MemPageStore.init(testing.allocator, mapsize);
}

// 核心场景 1：大量 key 落在同一 leaf 范围（连续 key，超过 32 条/leaf 上限）
test "insertbatch_overflow: 10K sequential keys (dense leaf range)" {
    var ms = newStore(50003);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 10000;
    var keys = try testing.allocator.alloc([]u8, n);
    defer {
        for (keys) |k| testing.allocator.free(k);
        testing.allocator.free(keys);
    }
    for (0..n) |i| {
        keys[i] = try std.fmt.allocPrint(testing.allocator, "{d:0>10}", .{i});
    }

    var entries = try testing.allocator.alloc(cube.Entry, n);
    defer testing.allocator.free(entries);
    for (0..n) |i| {
        entries[i] = .{ .key = keys[i], .value = "v" };
    }

    try db.putBatch(entries);
    try testing.expectEqual(@as(u64, n), db.entryCount());

    for (keys) |k| {
        const v = try db.get(k);
        defer if (v) |val| testing.allocator.free(val);
        try testing.expect(v != null);
    }
}

// 核心场景 2：随机分布 key（跨多个 leaf，但单个 batch 大）
test "insertbatch_overflow: 10K random keys in one batch" {
    var ms = newStore(50003);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 10000;
    var prng = std.Random.DefaultPrng.init(0xABCD);
    const rnd = prng.random();

    var keys = try testing.allocator.alloc([]u8, n);
    defer {
        for (keys) |k| testing.allocator.free(k);
        testing.allocator.free(keys);
    }
    for (0..n) |i| {
        keys[i] = try std.fmt.allocPrint(testing.allocator, "k{d:0>10}-{d:0>6}", .{ rnd.uintLessThan(usize, 100000), i });
    }

    var entries = try testing.allocator.alloc(cube.Entry, n);
    defer testing.allocator.free(entries);
    for (0..n) |i| {
        entries[i] = .{ .key = keys[i], .value = "v" };
    }

    try db.putBatch(entries);
    try testing.expectEqual(@as(u64, n), db.entryCount());

    for (keys) |k| {
        const v = try db.get(k);
        defer if (v) |val| testing.allocator.free(val);
        try testing.expect(v != null);
    }
}

// 核心场景 3：逆序 key（key 排序与插入顺序相反）
test "insertbatch_overflow: 10K reverse-ordered keys" {
    var ms = newStore(50003);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 10000;
    var keys = try testing.allocator.alloc([]u8, n);
    defer {
        for (keys) |k| testing.allocator.free(k);
        testing.allocator.free(keys);
    }
    for (0..n) |i| {
        keys[i] = try std.fmt.allocPrint(testing.allocator, "{d:0>10}", .{n - 1 - i});
    }

    var entries = try testing.allocator.alloc(cube.Entry, n);
    defer testing.allocator.free(entries);
    for (0..n) |i| {
        entries[i] = .{ .key = keys[i], .value = "v" };
    }

    try db.putBatch(entries);
    try testing.expectEqual(@as(u64, n), db.entryCount());

    for (keys) |k| {
        const v = try db.get(k);
        defer if (v) |val| testing.allocator.free(val);
        try testing.expect(v != null);
    }
}

// 场景 4：同一 leaf 内重复 key（最后写入获胜）
test "insertbatch_overflow: duplicate keys in batch, last wins" {
    var ms = newStore(50003);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 100;
    const dup: usize = 3;
    var entries = try testing.allocator.alloc(cube.Entry, n * dup);
    defer testing.allocator.free(entries);
    for (0..n) |i| {
        for (0..dup) |d| {
            const idx = i * dup + d;
            entries[idx] = .{
                .key = try std.fmt.allocPrint(testing.allocator, "{d:0>10}", .{i}),
                .value = try std.fmt.allocPrint(testing.allocator, "v{d}", .{d}),
            };
        }
    }
    defer {
        for (entries) |e| {
            testing.allocator.free(e.key);
            testing.allocator.free(e.value);
        }
    }

    try db.putBatch(entries);
    try testing.expectEqual(@as(u64, n), db.entryCount());

    for (0..n) |i| {
        const k = try std.fmt.allocPrint(testing.allocator, "{d:0>10}", .{i});
        defer testing.allocator.free(k);
        const v = try db.get(k);
        defer if (v) |val| testing.allocator.free(val);
        try testing.expect(v != null);
        try testing.expectEqualStrings("v2", v.?);
    }
}

// 场景 5：大 batch 顺序 key（10KB value，触发 overflow 页 + 分裂）
test "insertbatch_overflow: 10K sequential keys with 10KB values" {
    // 10KB × 10000 ≈ 100MB 数据，mapsize 需要足够大
    var ms = newStore(300000000);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 10000;
    var big: [10000]u8 = undefined;
    @memset(&big, 'x');

    var keys = try testing.allocator.alloc([]u8, n);
    defer {
        for (keys) |k| testing.allocator.free(k);
        testing.allocator.free(keys);
    }
    var entries = try testing.allocator.alloc(cube.Entry, n);
    defer testing.allocator.free(entries);
    for (0..n) |i| {
        keys[i] = try std.fmt.allocPrint(testing.allocator, "{d:0>10}", .{i});
        entries[i] = .{ .key = keys[i], .value = &big };
    }

    try db.putBatch(entries);
    try testing.expectEqual(@as(u64, n), db.entryCount());

    for (keys[0..100]) |k| {
        const v = try db.get(k);
        defer if (v) |val| testing.allocator.free(val);
        try testing.expect(v != null);
        try testing.expectEqual(@as(usize, 10000), v.?.len);
    }
}
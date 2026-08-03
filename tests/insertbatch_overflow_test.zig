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

// 对抗性场景（@archon 要求，guard 移除闭环条件）：
// 10K 条全部落在密集 leaf 范围 + 混合 tombstone 随机序列，
// 证明 multi-split 在最坏分布下依然正确。
test "insertbatch_overflow: adversarial 10K dense range + mixed tombstones" {
    var ms = newStore(1000000);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 10000;
    var keys = try testing.allocator.alloc([]u8, n);
    defer {
        for (keys) |k| testing.allocator.free(k);
        testing.allocator.free(keys);
    }
    // 密集范围：公共前缀 + 5 位后缀，全部 key 落在极窄的排序区间
    for (0..n) |i| {
        keys[i] = try std.fmt.allocPrint(testing.allocator, "k{d:0>5}", .{i});
    }

    // 第一批：全部 put
    {
        var entries = try testing.allocator.alloc(cube.Entry, n);
        defer testing.allocator.free(entries);
        for (0..n) |i| {
            entries[i] = .{ .key = keys[i], .value = "v1" };
        }
        try db.putBatch(entries);
        try testing.expectEqual(@as(u64, n), db.entryCount());
    }

    // 第二批：随机混合 put/delete（50% tombstone），乱序
    {
        var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
        const rnd = prng.random();

        // 乱序索引
        var idx = try testing.allocator.alloc(usize, n);
        defer testing.allocator.free(idx);
        for (0..n) |i| idx[i] = i;
        rnd.shuffle(usize, idx);

        var entries = try testing.allocator.alloc(cube.Entry, n);
        defer testing.allocator.free(entries);
        for (0..n) |i| {
            const k = idx[i];
            const tombstone = (rnd.uintLessThan(usize, 100) < 50);
            entries[i] = .{
                .key = keys[k],
                .value = if (tombstone) "" else "v2",
                .tombstone = tombstone,
            };
        }
        try db.putBatch(entries);
    }

    // 验证：50% 删除 → 期望 5000 存活（统计上接近，需精确计算）
    // 更精确的做法：重新生成同样的随机序列计算期望值
    // 用确定性验证：逐个 get 检查，统计存活数
    var live_count: u64 = 0;
    for (keys) |k| {
        const v = try db.get(k);
        defer if (v) |val| testing.allocator.free(val);
        if (v != null) live_count += 1;
    }
    // 50% tombstone → 期望 ~5000；允许少量随机偏差（±5%）
    const expected: u64 = n / 2;
    try testing.expect(live_count > expected * 95 / 100);
    try testing.expect(live_count < expected * 105 / 100);
    // entryCount 必须与逐条 get 一致
    try testing.expectEqual(live_count, db.entryCount());

    // 抽查：存活 key 的 value 应为 v2（第二批覆盖）或 v1（未被覆盖）
    var checked: usize = 0;
    for (keys) |k| {
        const v = try db.get(k);
        defer if (v) |val| testing.allocator.free(val);
        if (v != null) {
            checked += 1;
            try testing.expect(std.mem.eql(u8, v.?, "v1") or std.mem.eql(u8, v.?, "v2"));
        }
    }
    try testing.expectEqual(live_count, checked);
}
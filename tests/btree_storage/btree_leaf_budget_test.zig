//! btree_leaf_budget_test.zig — T-26: insertIntoLeaf 字节预算越界（TDD）
//! issues/insert-into-leaf-fast-path-stack-overflow.md：
//! 快路径只校验条数（LEAF_MAX_ENTRIES=32）不校验字节数（payload 容量 4068B）。
//! 31 条 ~130B 的合法满叶 + 1 条超限 entry（new_count=32 不触发条数分裂）
//! 会在固定 4068B 栈缓冲上 @memcpy 越界。修复后应 fallback 到 insertIntoLeafSplit
//! 且数据完整。
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;
const Db = cube.Db;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(std.testing.allocator, 10000);
}

test "leaf budget: 31x130B full leaf + oversized entry -> split fallback, data intact" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);

    // 31 条 × (10 固定开销 + 4B key + 116B value) = 130B/条，
    // payload = 3 头 + 4030 = 4033B ≤ 4068B —— 合法满叶。
    var small: [116]u8 = undefined;
    @memset(&small, 'x');
    var i: usize = 0;
    while (i < 31) : (i += 1) {
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>3}", .{i});
        dirty.clearRetainingCapacity();
        root = (try btree.insert(std.testing.allocator, s, root, k, &small, false, &dirty)).new_root;
    }

    // 第 32 条：new_count=32 ≤ LEAF_MAX_ENTRIES（条数不分裂），
    // 但 4033 + (10+4+400) = 4447 > 4068 → 未修复时栈越界；修复后走 split。
    var big: [400]u8 = undefined;
    @memset(&big, 'y');
    dirty.clearRetainingCapacity();
    root = (try btree.insert(std.testing.allocator, s, root, "k031", &big, false, &dirty)).new_root;

    // 数据完整：32 个 key 全部可读、值正确
    i = 0;
    while (i < 32) : (i += 1) {
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>3}", .{i});
        const v = try btree.get(std.testing.allocator, s, root, k);
        try std.testing.expect(v != null);
        const want: []const u8 = if (i < 31) small[0..] else big[0..];
        try std.testing.expectEqualSlices(u8, want, v.?);
        std.testing.allocator.free(v.?);
    }
}

test "leaf budget: live_delta accounting overhead = 10 (byte_size consistency)" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);
    var acc: i64 = 0;

    // 10 个 key（4B），变长 value
    for (0..10) |i| {
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key{d}", .{i});
        var vbuf: [64]u8 = undefined;
        const vlen = 8 + i * 5;
        @memset(vbuf[0..vlen], 'v');
        dirty.clearRetainingCapacity();
        const wr = try btree.insert(std.testing.allocator, s, root, k, vbuf[0..vlen], false, &dirty);
        root = wr.new_root;
        acc += wr.live_delta;
    }
    // 覆写 key3（value 100B）
    {
        var vbuf: [128]u8 = undefined;
        @memset(vbuf[0..100], 'w');
        dirty.clearRetainingCapacity();
        const wr = try btree.insert(std.testing.allocator, s, root, "key3", vbuf[0..100], false, &dirty);
        root = wr.new_root;
        acc += wr.live_delta;
    }
    // 删除 key5（tombstone：value 记 0，key 保留在叶内）
    {
        dirty.clearRetainingCapacity();
        const wr = try btree.insert(std.testing.allocator, s, root, "key5", "", true, &dirty);
        root = wr.new_root;
        acc += wr.live_delta;
    }

    // 逐条独立计算：每 entry 10 + key.len + value.len（tombstone value=0），
    // 与 leafPayloadSize 口径一致（原实现固定开销 9，每条少记 1B）。
    var expected: i64 = 0;
    for (0..10) |i| {
        const vlen: i64 = if (i == 3) 100 else if (i == 5) 0 else @intCast(8 + i * 5);
        expected += 10 + 4 + vlen;
    }
    try std.testing.expectEqual(expected, acc);

    // 数据完整性抽查
    const v3 = try btree.get(std.testing.allocator, s, root, "key3");
    try std.testing.expectEqual(@as(usize, 100), v3.?.len);
    std.testing.allocator.free(v3.?);
    const v5 = try btree.get(std.testing.allocator, s, root, "key5");
    try std.testing.expect(v5 == null);
}

// ---- T-26 review 发现1：found + old_is_overflow + 字节预算 fallback → dirty 双 free ----

test "leaf budget: overwrite overflow entry hitting byte-budget fallback -> dirty no dup pages, no corruption" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);

    // 30 × (10+4+100)=114B inline + 1 条 5000B 溢出 entry（叶内 10+4+4=18B）
    // payload = 3 + 3420 + 18 = 3441B ≤ 4068 —— 合法满叶（31 条）
    var v100: [100]u8 = undefined;
    @memset(&v100, 'x');
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>3}", .{i});
        dirty.clearRetainingCapacity();
        root = (try btree.insert(std.testing.allocator, s, root, k, &v100, false, &dirty)).new_root;
    }
    var ov: [5000]u8 = undefined;
    @memset(&ov, 'o');
    dirty.clearRetainingCapacity();
    root = (try btree.insert(std.testing.allocator, s, root, "k030", &ov, false, &dirty)).new_root;

    // 覆写溢出 entry 为 700B inline：found=true, old_is_overflow=true，
    // 3 + 3420 + (10+4+700) = 4137 > 4068 → 字节预算 fallback 到 split。
    // 修复前：insertIntoLeaf 先 freeOverflowPages 旧链，split 的 fromPayload
    // 再 free 一次 → dirty 重复页号 → freelist 双重分配 → 页别名损坏。
    var v700: [700]u8 = undefined;
    @memset(&v700, 'y');
    dirty.clearRetainingCapacity();
    root = (try btree.insert(std.testing.allocator, s, root, "k030", &v700, false, &dirty)).new_root;

    // dirty 无重复页号
    for (dirty.items, 0..) |pn, idx| {
        for (dirty.items[idx + 1 ..]) |pn2| {
            try std.testing.expect(pn != pn2);
        }
    }

    // 模拟 writer：把 dirty 全部 freePage，继续插入 400 条，断言无页别名损坏
    for (dirty.items) |pn| s.freePage(pn);
    i = 0;
    while (i < 400) : (i += 1) {
        var kbuf: [12]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "m{d:0>5}", .{i});
        dirty.clearRetainingCapacity();
        root = (try btree.insert(std.testing.allocator, s, root, k, "v", false, &dirty)).new_root;
    }

    // 全量校验：30 旧 inline + 覆写值 + 400 新 key
    i = 0;
    while (i < 30) : (i += 1) {
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>3}", .{i});
        const v = try btree.get(std.testing.allocator, s, root, k);
        try std.testing.expect(v != null);
        try std.testing.expectEqualSlices(u8, &v100, v.?);
        std.testing.allocator.free(v.?);
    }
    {
        const v = try btree.get(std.testing.allocator, s, root, "k030");
        try std.testing.expect(v != null);
        try std.testing.expectEqualSlices(u8, &v700, v.?);
        std.testing.allocator.free(v.?);
    }
    i = 0;
    while (i < 400) : (i += 1) {
        var kbuf: [12]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "m{d:0>5}", .{i});
        const v = try btree.get(std.testing.allocator, s, root, k);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings("v", v.?);
        std.testing.allocator.free(v.?);
    }
}


// ---- T-26 review 发现2：insertBatchIntoLeaf 尾部追加循环 live_delta 口径 ----

test "leaf budget: putBatch ordered append byte_size == per-entry sum (overhead 10)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var expected: u64 = 0;

    // 第一批：空树（insertBatchFresh 路径）
    {
        var entries: [20]cube.Entry = undefined;
        var kbufs: [20][8]u8 = undefined;
        var vbufs: [20][64]u8 = undefined;
        for (0..20) |i| {
            const k = try std.fmt.bufPrint(&kbufs[i], "a{d:0>3}", .{i});
            const vlen = 10 + i;
            @memset(vbufs[i][0..vlen], 'v');
            entries[i] = .{ .key = k, .value = vbufs[i][0..vlen] };
            expected += 10 + k.len + vlen;
        }
        try db.putBatch(&entries);
    }

    // 第二批：全部 key 大于现有叶内 key（"b*" > "a*"）且批内有序 →
    // insertBatchIntoLeaf merge 的「Remaining batch entries」尾部循环
    //（原 +9 漏改，每条少记 1B）
    {
        var entries: [30]cube.Entry = undefined;
        var kbufs: [30][8]u8 = undefined;
        var vbufs: [30][64]u8 = undefined;
        for (0..30) |i| {
            const k = try std.fmt.bufPrint(&kbufs[i], "b{d:0>3}", .{i});
            const vlen = 10 + i;
            @memset(vbufs[i][0..vlen], 'w');
            entries[i] = .{ .key = k, .value = vbufs[i][0..vlen] };
            expected += 10 + k.len + vlen;
        }
        try db.putBatch(&entries);
    }

    try std.testing.expectEqual(@as(u64, 50), db.entryCount());
    try std.testing.expectEqual(expected, db.state.byte_size.load(.acquire));

    // 数据抽查
    const va = try db.get("a000");
    try std.testing.expectEqual(@as(usize, 10), va.?.len);
    std.testing.allocator.free(va.?);
    const vb = try db.get("b029");
    try std.testing.expectEqual(@as(usize, 39), vb.?.len);
    std.testing.allocator.free(vb.?);
}

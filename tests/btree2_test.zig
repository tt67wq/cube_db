//! btree2_test.zig — 页号 COW B-tree 测试（TDD RED）
//! 覆盖：empty get、put/get roundtrip、overwrite、delete、COW old root、
//! select 有序、select 范围、select 跳 tombstone、随机模型测试。
//! 全部使用 MemPageStore，先 fail（btree2.zig 不存在）。
const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format2;
const ps = cube.page_store;
const btree2 = cube.btree2;

// ---- 辅助 ----

fn newStore() ps.MemPageStore {
    // 10000 页 ≈ 40MB data，足够 10k key 测试
    return ps.MemPageStore.init(std.testing.allocator, 10000);
}

// ---- 测试 ----

test "btree2: empty get -> null" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    const v = try btree2.get(std.testing.allocator, s, btree2.NULL_ROOT, "k");
    try std.testing.expectEqual(@as(?[]u8, null), v);
}

test "btree2: single put/get roundtrip" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);
    const wr = try btree2.insert(std.testing.allocator, s, btree2.NULL_ROOT, "k", "v", false, &dirty);
    try std.testing.expect(wr.new_root != btree2.NULL_ROOT);
    const v = try btree2.get(std.testing.allocator, s, wr.new_root, "k");
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("v", v.?);
    std.testing.allocator.free(v.?);
}

test "btree2: 10k random keys all readable" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree2.NULL_ROOT;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var keys = std.ArrayList([]u8).empty;
    defer {
        for (keys.items) |k| std.testing.allocator.free(k);
        keys.deinit(std.testing.allocator);
    }
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const klen = rnd.uintLessThan(usize, 14) + 2;
        for (0..klen) |j| kbuf[j] = 'a' + rnd.uintLessThan(u8, 26);
        const k = try std.testing.allocator.dupe(u8, kbuf[0..klen]);
        try keys.append(std.testing.allocator, k);
    }
    // 排序去重后插入
    std.mem.sort([]u8, keys.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool { return std.mem.order(u8, a, b) == .lt; }
    }.lt);
    var unique = std.ArrayList([]u8).empty;
    defer unique.deinit(std.testing.allocator);
    for (keys.items) |k| {
        if (unique.items.len == 0 or std.mem.order(u8, unique.items[unique.items.len - 1], k) != .eq) {
            try unique.append(std.testing.allocator, k);
        }
    }
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);
    for (unique.items) |k| {
        dirty.clearRetainingCapacity();
        root = (try btree2.insert(std.testing.allocator, s, root, k, "val", false, &dirty)).new_root;
    }
    // 验证全部可读
    for (unique.items) |k| {
        const v = try btree2.get(std.testing.allocator, s, root, k);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings("val", v.?);
        std.testing.allocator.free(v.?);
    }
}

test "btree2: overwrite key -> new value" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);
    var root = (try btree2.insert(std.testing.allocator, s, btree2.NULL_ROOT, "k", "v1", false, &dirty)).new_root;
    dirty.clearRetainingCapacity();
    root = (try btree2.insert(std.testing.allocator, s, root, "k", "v2", false, &dirty)).new_root;
    const v = try btree2.get(std.testing.allocator, s, root, "k");
    try std.testing.expectEqualStrings("v2", v.?);
    std.testing.allocator.free(v.?);
}

test "btree2: delete key -> get null" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);
    var root = (try btree2.insert(std.testing.allocator, s, btree2.NULL_ROOT, "k", "v", false, &dirty)).new_root;
    dirty.clearRetainingCapacity();
    root = (try btree2.insert(std.testing.allocator, s, root, "k", "", true, &dirty)).new_root;
    const v = try btree2.get(std.testing.allocator, s, root, "k");
    try std.testing.expectEqual(@as(?[]u8, null), v);
}

test "btree2: COW old root still points to old version" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);
    const r1 = try btree2.insert(std.testing.allocator, s, btree2.NULL_ROOT, "k", "v1", false, &dirty);
    dirty.clearRetainingCapacity();
    const r2 = try btree2.insert(std.testing.allocator, s, r1.new_root, "k", "v2", false, &dirty);
    // 用旧 root 读到旧值
    const oldv = try btree2.get(std.testing.allocator, s, r1.new_root, "k");
    try std.testing.expectEqualStrings("v1", oldv.?);
    std.testing.allocator.free(oldv.?);
    // 用新 root 读到新值
    const newv = try btree2.get(std.testing.allocator, s, r2.new_root, "k");
    try std.testing.expectEqualStrings("v2", newv.?);
    std.testing.allocator.free(newv.?);
}

test "btree2: select null,null full ordered output" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree2.NULL_ROOT;
    const keys = [_][]const u8{ "banana", "apple", "cherry" };
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);
    for (keys) |k| {
        dirty.clearRetainingCapacity();
        root = (try btree2.insert(std.testing.allocator, s, root, k, "v", false, &dirty)).new_root;
    }
    var it = try btree2.select(std.testing.allocator, s, root, null, null);
    defer it.deinit();
    var got = std.ArrayList([]const u8).empty;
    defer got.deinit(std.testing.allocator);
    while (try it.next()) |e| {
        try got.append(std.testing.allocator, try std.testing.allocator.dupe(u8, e.key));
    }
    try std.testing.expectEqual(@as(usize, 3), got.items.len);
    try std.testing.expectEqualStrings("apple", got.items[0]);
    try std.testing.expectEqualStrings("banana", got.items[1]);
    try std.testing.expectEqualStrings("cherry", got.items[2]);
    for (got.items) |g| std.testing.allocator.free(g);
}

test "btree2: select min,max inclusive min exclusive max" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree2.NULL_ROOT;
    const keys = [_][]const u8{ "a", "b", "c", "d", "e" };
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);
    for (keys) |k| {
        dirty.clearRetainingCapacity();
        root = (try btree2.insert(std.testing.allocator, s, root, k, "v", false, &dirty)).new_root;
    }
    var it = try btree2.select(std.testing.allocator, s, root, "b", "d");
    defer it.deinit();
    var got = std.ArrayList([]const u8).empty;
    defer got.deinit(std.testing.allocator);
    while (try it.next()) |e| {
        try got.append(std.testing.allocator, try std.testing.allocator.dupe(u8, e.key));
    }
    try std.testing.expectEqual(@as(usize, 2), got.items.len);
    try std.testing.expectEqualStrings("b", got.items[0]);
    try std.testing.expectEqualStrings("c", got.items[1]);
    for (got.items) |g| std.testing.allocator.free(g);
}

test "btree2: select empty range min>max -> empty" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree2.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);
    root = (try btree2.insert(std.testing.allocator, s, btree2.NULL_ROOT, "a", "v", false, &dirty)).new_root;
    var it = try btree2.select(std.testing.allocator, s, root, "z", "a");
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "btree2: select skips tombstones" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree2.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);
    root = (try btree2.insert(std.testing.allocator, s, btree2.NULL_ROOT, "a", "va", false, &dirty)).new_root;
    dirty.clearRetainingCapacity();
    root = (try btree2.insert(std.testing.allocator, s, root, "b", "vb", false, &dirty)).new_root;
    dirty.clearRetainingCapacity();
    root = (try btree2.insert(std.testing.allocator, s, root, "a", "", true, &dirty)).new_root;
    var it = try btree2.select(std.testing.allocator, s, root, null, null);
    defer it.deinit();
    var got = std.ArrayList([]const u8).empty;
    defer got.deinit(std.testing.allocator);
    while (try it.next()) |e| {
        try got.append(std.testing.allocator, try std.testing.allocator.dupe(u8, e.key));
    }
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqualStrings("b", got.items[0]);
    for (got.items) |g| std.testing.allocator.free(g);
}

test "btree2: model test random ops vs StringHashMap (seed 7)" {
    const allocator = std.testing.allocator;
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree2.NULL_ROOT;
    var model = std.StringHashMap([]u8).init(allocator);
    defer {
        var it = model.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        model.deinit();
    }
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    const ops = 2000;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);
    var i: usize = 0;
    while (i < ops) : (i += 1) {
        var kbuf: [8]u8 = undefined;
        const klen = 4 + rnd.uintLessThan(usize, 5);
        for (0..klen) |j| kbuf[j] = 'a' + rnd.uintLessThan(u8, 8);
        const key = kbuf[0..klen];
        dirty.clearRetainingCapacity();
        if (rnd.boolean()) {
            // put
            const val = try allocator.dupe(u8, "V");
            const wr = try btree2.insert(allocator, s, root, key, val, false, &dirty);
            root = wr.new_root;
            allocator.free(val);
            const gop = try model.getOrPut(key);
            if (gop.found_existing) {
                allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = try allocator.dupe(u8, "V");
            } else {
                gop.key_ptr.* = try allocator.dupe(u8, key);
                gop.value_ptr.* = try allocator.dupe(u8, "V");
            }
        } else {
            // delete
            const wr = try btree2.insert(allocator, s, root, key, "", true, &dirty);
            root = wr.new_root;
            if (model.fetchRemove(key)) |kv| {
                allocator.free(kv.key);
                allocator.free(kv.value);
            }
        }
        // 验证该 key
        const mv = model.get(key);
        const bv = try btree2.get(allocator, s, root, key);
        if (mv == null) {
            try std.testing.expect(bv == null);
        } else {
            try std.testing.expect(bv != null);
            try std.testing.expectEqualStrings(mv.?, bv.?);
            allocator.free(bv.?);
        }
    }
    // 全量比对
    var it = try btree2.select(allocator, s, root, null, null);
    defer it.deinit();
    var bcount: usize = 0;
    while (try it.next()) |_| bcount += 1;
    try std.testing.expectEqual(model.count(), bcount);
}

test "btree2: sequential 1000 keys all readable" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree2.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "{d}", .{i});
        dirty.clearRetainingCapacity();
        root = (try btree2.insert(std.testing.allocator, s, root, k, "v", false, &dirty)).new_root;
    }
    i = 0;
    while (i < 1000) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "{d}", .{i});
        const v = try btree2.get(std.testing.allocator, s, root, k);
        if (v == null) return error.TestUnexpectedResult;
        std.testing.allocator.free(v.?);
    }
}

test "btree2: insert returns WriteResult with correct live_delta and count_delta" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);
    // 新 key → live_delta > 0, count_delta = 1
    const wr1 = try btree2.insert(std.testing.allocator, s, btree2.NULL_ROOT, "k", "v", false, &dirty);
    try std.testing.expect(wr1.live_delta > 0);
    try std.testing.expectEqual(@as(i64, 1), wr1.count_delta);
    // overwrite → live_delta ≈ 0（key 已存在）, count_delta = 0
    dirty.clearRetainingCapacity();
    const wr2 = try btree2.insert(std.testing.allocator, s, wr1.new_root, "k", "v2", false, &dirty);
    try std.testing.expectEqual(@as(i64, 0), wr2.count_delta);
    // 删除 → count_delta = -1（降到 0）
    dirty.clearRetainingCapacity();
    const wr3 = try btree2.insert(std.testing.allocator, s, wr2.new_root, "k", "", true, &dirty);
    try std.testing.expectEqual(@as(i64, -1), wr3.count_delta);
    // key 不存在再删 → count_delta = 0, live_delta = 0
    dirty.clearRetainingCapacity();
    const wr4 = try btree2.insert(std.testing.allocator, s, wr3.new_root, "k", "", true, &dirty);
    try std.testing.expectEqual(@as(i64, 0), wr4.count_delta);
    try std.testing.expectEqual(@as(i64, 0), wr4.live_delta);
}
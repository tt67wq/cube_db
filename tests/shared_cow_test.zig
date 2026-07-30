//! shared_cow_test.zig — TDD: 单 txn 内共享 COW 路径
//! 测试 batch insert 的正确性：多条 entry 在同一 txn 内提交，
//! 沿 B-tree 路径一次遍历，到每个 leaf 批量应用。
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;
const Db = cube.Db;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(std.testing.allocator, 100000);
}

// ---- Test 1: batch insert multiple keys, all readable ----
test "shared_cow: batch insert 10 keys, all readable" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var entries: [10]cube.Entry = undefined;
    var ekeybuf: [10][16]u8 = undefined;
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const k = try std.fmt.bufPrint(&ekeybuf[i], "key_{d:0>4}", .{i});
        entries[i] = .{ .key = k, .value = "val" };
    }
    try db.putBatch(&entries);

    i = 0;
    while (i < 10) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        const v = try db.get(k);
        try std.testing.expectEqualStrings("val", v.?);
        std.testing.allocator.free(v.?);
    }
}

// ---- Test 2: batch insert with overwrites ----
test "shared_cow: batch with overwrites, last write wins" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const entries = [_]cube.Entry{
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "2" },
        .{ .key = "a", .value = "3" }, // overwrite a
        .{ .key = "c", .value = "4" },
        .{ .key = "b", .value = "5" }, // overwrite b
    };
    try db.putBatch(&entries);

    const va = try db.get("a");
    try std.testing.expectEqualStrings("3", va.?);
    std.testing.allocator.free(va.?);

    const vb = try db.get("b");
    try std.testing.expectEqualStrings("5", vb.?);
    std.testing.allocator.free(vb.?);

    const vc = try db.get("c");
    try std.testing.expectEqualStrings("4", vc.?);
    std.testing.allocator.free(vc.?);
}

// ---- Test 3: batch insert causes leaf split ----
test "shared_cow: batch insert triggers leaf split, all readable" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    // Insert more than LEAF_MAX_ENTRIES (32) in one batch → must split
    const n: usize = 50;
    const entries = try std.testing.allocator.alloc(cube.Entry, n);
    defer std.testing.allocator.free(entries);
    for (entries, 0..) |*e, i| {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>4}", .{i});
        e.* = .{ .key = try std.testing.allocator.dupe(u8, k), .value = "v" };
    }
    defer for (entries) |e| std.testing.allocator.free(e.key);
    try db.putBatch(entries);

    for (0..n) |i| {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>4}", .{i});
        const v = try db.get(k);
        try std.testing.expectEqualStrings("v", v.?);
        std.testing.allocator.free(v.?);
    }
}

// ---- Test 4: batch insert on existing tree ----
test "shared_cow: batch insert into existing multi-level tree" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    // Pre-populate with 100 keys
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        try db.put(k, "old");
    }

    // Batch insert new keys + overwrite some
    const entries = [_]cube.Entry{
        .{ .key = "key_0005", .value = "updated" },
        .{ .key = "key_0050", .value = "updated" },
        .{ .key = "new_001", .value = "new" },
        .{ .key = "new_002", .value = "new" },
        .{ .key = "key_0099", .value = "updated" },
    };
    try db.putBatch(&entries);

    // Check overwrites
    {
        const v5 = try db.get("key_0005");
        try std.testing.expectEqualStrings("updated", v5.?);
        std.testing.allocator.free(v5.?);
    }
    {
        const v50 = try db.get("key_0050");
        try std.testing.expectEqualStrings("updated", v50.?);
        std.testing.allocator.free(v50.?);
    }
    {
        const v99 = try db.get("key_0099");
        try std.testing.expectEqualStrings("updated", v99.?);
        std.testing.allocator.free(v99.?);
    }

    // Check new
    {
        const vn1 = try db.get("new_001");
        try std.testing.expectEqualStrings("new", vn1.?);
        std.testing.allocator.free(vn1.?);
    }
    {
        const vn2 = try db.get("new_002");
        try std.testing.expectEqualStrings("new", vn2.?);
        std.testing.allocator.free(vn2.?);
    }

    // Check untouched
    {
        const v0 = try db.get("key_0000");
        try std.testing.expectEqualStrings("old", v0.?);
        std.testing.allocator.free(v0.?);
    }
    {
        const v49 = try db.get("key_0049");
        try std.testing.expectEqualStrings("old", v49.?);
        std.testing.allocator.free(v49.?);
    }
}

// ---- Test 5: batch delete in same txn ----
test "shared_cow: batch insert + delete in same txn" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    // Pre-populate
    try db.put("a", "1");
    try db.put("b", "2");
    try db.put("c", "3");

    // Batch: delete b, update a, add d
    const entries = [_]cube.Entry{
        .{ .key = "b", .value = "", .tombstone = true },
        .{ .key = "a", .value = "updated" },
        .{ .key = "d", .value = "4" },
    };
    try db.putBatch(&entries);

    {
        const va = try db.get("a");
        try std.testing.expectEqualStrings("updated", va.?);
        std.testing.allocator.free(va.?);
    }
    try std.testing.expectEqual(@as(?[]u8, null), try db.get("b"));
    {
        const vc = try db.get("c");
        try std.testing.expectEqualStrings("3", vc.?);
        std.testing.allocator.free(vc.?);
    }
    {
        const vd = try db.get("d");
        try std.testing.expectEqualStrings("4", vd.?);
        std.testing.allocator.free(vd.?);
    }
}

// ---- Test 6: COW consistency — old root unchanged after batch ----
test "shared_cow: COW old root unchanged after batch insert" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try Db.open(std.testing.allocator, s, .{});
    defer db.close();

    // Single put to get initial root
    try db.put("k1", "v1");
    const old_root = db.getRoot();

    // Batch insert more
    const entries = [_]cube.Entry{
        .{ .key = "k2", .value = "v2" },
        .{ .key = "k3", .value = "v3" },
        .{ .key = "k4", .value = "v4" },
    };
    try db.putBatch(&entries);

    // Old root still sees only k1
    const v1 = try btree.get(std.testing.allocator, s, old_root, "k1");
    try std.testing.expectEqualStrings("v1", v1.?);
    std.testing.allocator.free(v1.?);

    const v2_old = try btree.get(std.testing.allocator, s, old_root, "k2");
    try std.testing.expectEqual(@as(?[]u8, null), v2_old);
}

// ---- Test 7: large batch (1000 keys) ----
test "shared_cow: 1000 keys batch, all readable" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 1000;
    const entries = try std.testing.allocator.alloc(cube.Entry, n);
    defer std.testing.allocator.free(entries);
    for (entries, 0..) |*e, i| {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>6}", .{i});
        e.* = .{ .key = try std.testing.allocator.dupe(u8, k), .value = "val" };
    }
    defer for (entries) |e| std.testing.allocator.free(e.key);
    try db.putBatch(entries);

    try std.testing.expectEqual(@as(u64, n), db.entryCount());
    for (0..n) |i| {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>6}", .{i});
        const v = try db.get(k);
        try std.testing.expectEqualStrings("val", v.?);
        std.testing.allocator.free(v.?);
    }
}

// ---- Test 8: random order batch vs sorted batch, same result ----
test "shared_cow: random order batch produces correct result" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var prng = std.Random.DefaultPrng.init(123);
    const rnd = prng.random();
    const n: usize = 200;
    var order = try std.testing.allocator.alloc(usize, n);
    defer std.testing.allocator.free(order);
    for (0..n) |i| order[i] = i;
    rnd.shuffle(usize, order);

    const entries = try std.testing.allocator.alloc(cube.Entry, n);
    defer std.testing.allocator.free(entries);
    for (entries, 0..) |*e, i| {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{order[i]});
        e.* = .{ .key = try std.testing.allocator.dupe(u8, k), .value = "val" };
    }
    defer for (entries) |e| std.testing.allocator.free(e.key);
    try db.putBatch(entries);

    for (0..n) |i| {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        const v = try db.get(k);
        try std.testing.expectEqualStrings("val", v.?);
        std.testing.allocator.free(v.?);
    }
}

//! insertbatch_capaware_test.zig — TDD: insertBatch leaf-capacity-aware 彻底修复
//! 验证大 batch（>LEAF_MAX_ENTRIES）落同一 leaf 时正确分裂，不走 fallback。
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;
const Db = cube.Db;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(std.testing.allocator, 500000);
}

test "capaware: 100 sequential keys batch, all readable" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 100;
    const entries = try std.testing.allocator.alloc(cube.Entry, n);
    defer std.testing.allocator.free(entries);
    const keybufs = try std.testing.allocator.alloc([12]u8, n);
    defer std.testing.allocator.free(keybufs);
    for (entries, 0..) |*e, idx| {
        const k = try std.fmt.bufPrint(&keybufs[idx], "{d:0>10}", .{idx});
        e.* = .{ .key = k, .value = "v" };
    }
    try db.putBatch(entries);

    try std.testing.expectEqual(@as(u64, n), db.entryCount());
    for (0..n) |idx| {
        var tmp: [12]u8 = undefined; const k = try std.fmt.bufPrint(&tmp, "{d:0>10}", .{idx});
        const v = try db.get(k);
        try std.testing.expectEqualStrings("v", v.?);
        std.testing.allocator.free(v.?);
    }
}

test "capaware: 1000 keys into existing tree, all readable" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var kbuf: [16]u8 = undefined;
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        try db.putDirect(k, "old");
    }

    const n: usize = 1000;
    const entries = try std.testing.allocator.alloc(cube.Entry, n);
    defer std.testing.allocator.free(entries);
    const keybufs = try std.testing.allocator.alloc([16]u8, n);
    defer std.testing.allocator.free(keybufs);
    for (entries, 0..) |*e, idx| {
        const k = try std.fmt.bufPrint(&keybufs[idx], "new_{d:0>6}", .{idx});
        e.* = .{ .key = k, .value = "new" };
    }
    try db.putBatch(entries);

    try std.testing.expectEqual(@as(u64, 1050), db.entryCount());
    for (0..n) |idx| {
        var tmp: [16]u8 = undefined; const k = try std.fmt.bufPrint(&tmp, "new_{d:0>6}", .{idx});
        const v = try db.get(k);
        std.testing.allocator.free(v.?);
    }
    i = 0;
    while (i < 50) : (i += 1) {
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        const v = try db.get(k);
        try std.testing.expectEqualStrings("old", v.?);
        std.testing.allocator.free(v.?);
    }
}

test "capaware: 500 random keys, correct after batch" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    const n: usize = 500;
    const entries = try std.testing.allocator.alloc(cube.Entry, n);
    defer std.testing.allocator.free(entries);
    const keybufs = try std.testing.allocator.alloc([12]u8, n);
    defer std.testing.allocator.free(keybufs);
    var order = try std.testing.allocator.alloc(usize, n);
    defer std.testing.allocator.free(order);
    for (0..n) |idx| order[idx] = idx;
    rnd.shuffle(usize, order);
    for (entries, 0..) |*e, idx| {
        const k = try std.fmt.bufPrint(&keybufs[idx], "{d:0>10}", .{order[idx]});
        e.* = .{ .key = k, .value = "v" };
    }
    try db.putBatch(entries);

    try std.testing.expectEqual(@as(u64, n), db.entryCount());
    for (0..n) |idx| {
        var tmp: [12]u8 = undefined; const k = try std.fmt.bufPrint(&tmp, "{d:0>10}", .{idx});
        const v = try db.get(k);
        try std.testing.expectEqualStrings("v", v.?);
        std.testing.allocator.free(v.?);
    }
}

test "capaware: 200 entries with overwrites, last write wins" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 200;
    const entries = try std.testing.allocator.alloc(cube.Entry, n * 2);
    defer std.testing.allocator.free(entries);
    const keybufs = try std.testing.allocator.alloc([12]u8, n);
    defer std.testing.allocator.free(keybufs);
    for (0..n) |idx| {
        const k = try std.fmt.bufPrint(&keybufs[idx], "{d:0>10}", .{idx});
        entries[idx] = .{ .key = k, .value = "v1" };
        entries[n + idx] = .{ .key = k, .value = "v2" };
    }
    try db.putBatch(entries[0 .. n * 2]);

    try std.testing.expectEqual(@as(u64, n), db.entryCount());
    for (0..n) |idx| {
        var tmp: [12]u8 = undefined; const k = try std.fmt.bufPrint(&tmp, "{d:0>10}", .{idx});
        const v = try db.get(k);
        try std.testing.expectEqualStrings("v2", v.?);
        std.testing.allocator.free(v.?);
    }
}

test "capaware: mixed put + delete in large batch" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var kbuf: [16]u8 = undefined;
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        try db.putDirect(k, "keep");
    }

    const n: usize = 125;
    const entries = try std.testing.allocator.alloc(cube.Entry, n);
    defer std.testing.allocator.free(entries);
    const keybufs = try std.testing.allocator.alloc([16]u8, n);
    defer std.testing.allocator.free(keybufs);
    for (0..100) |idx| {
        const k = try std.fmt.bufPrint(&keybufs[idx], "new_{d:0>6}", .{idx});
        entries[idx] = .{ .key = k, .value = "new" };
    }
    for (0..25) |idx| {
        const k = try std.fmt.bufPrint(&keybufs[100 + idx], "key_{d:0>4}", .{idx});
        entries[100 + idx] = .{ .key = k, .value = "", .tombstone = true };
    }
    try db.putBatch(entries);

    try std.testing.expectEqual(@as(u64, 125), db.entryCount());
    for (0..25) |idx| {
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{idx});
        try std.testing.expectEqual(@as(?[]u8, null), try db.get(k));
    }
    for (25..50) |idx| {
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{idx});
        const v = try db.get(k);
        try std.testing.expectEqualStrings("keep", v.?);
        std.testing.allocator.free(v.?);
    }
}

test "capaware: 100 entries with 10KB values, all readable" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 100;
    var big: [10000]u8 = undefined;
    @memset(&big, 'x');
    const entries = try std.testing.allocator.alloc(cube.Entry, n);
    defer std.testing.allocator.free(entries);
    const keybufs = try std.testing.allocator.alloc([12]u8, n);
    defer std.testing.allocator.free(keybufs);
    for (entries, 0..) |*e, idx| {
        const k = try std.fmt.bufPrint(&keybufs[idx], "{d:0>10}", .{idx});
        e.* = .{ .key = k, .value = &big };
    }
    try db.putBatch(entries);

    try std.testing.expectEqual(@as(u64, n), db.entryCount());
    for (0..n) |idx| {
        var tmp: [12]u8 = undefined; const k = try std.fmt.bufPrint(&tmp, "{d:0>10}", .{idx});
        const v = try db.get(k);
        try std.testing.expectEqual(@as(usize, 10000), v.?.len);
        std.testing.allocator.free(v.?);
    }
}

test "capaware: COW old root sees old state after large batch" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try Db.open(std.testing.allocator, s, .{});
    defer db.close();

    try db.putDirect("k1", "v1");
    const old_root = db.getRoot();

    const n: usize = 100;
    const entries = try std.testing.allocator.alloc(cube.Entry, n);
    defer std.testing.allocator.free(entries);
    const keybufs = try std.testing.allocator.alloc([12]u8, n);
    defer std.testing.allocator.free(keybufs);
    for (entries, 0..) |*e, idx| {
        const k = try std.fmt.bufPrint(&keybufs[idx], "batch_{d:0>4}", .{idx});
        e.* = .{ .key = k, .value = "v" };
    }
    try db.putBatch(entries);

    const old_v = try btree.get(std.testing.allocator, s, old_root, "k1");
    try std.testing.expectEqualStrings("v1", old_v.?);
    std.testing.allocator.free(old_v.?);
    const old_batch = try btree.get(std.testing.allocator, s, old_root, "batch_0000");
    try std.testing.expectEqual(@as(?[]u8, null), old_batch);
}

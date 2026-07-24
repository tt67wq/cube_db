//! db_test.zig — Db2 集成测试（TDD RED）
//! 覆盖：open/close、put/get、putBatch、delete、select、meta 恢复。
//! 用 MemPageStore 模拟持久化。先 fail（db.zig 不存在）。
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const wrt = cube.writer;
const dbi = cube.db;
const btree = cube.btree;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(std.testing.allocator, 10000);
}

fn fmtKey(buf: *[12]u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>10}", .{i}) catch unreachable;
}

test "db: open with default state" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();
    try std.testing.expectEqual(@as(u32, btree.NULL_ROOT), db.getRoot());
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

test "db: put and get roundtrip" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();
    try db.put("hello", "world");
    const v = try db.get("hello");
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("world", v.?);
    std.testing.allocator.free(v.?);
}

test "db: get missing key returns null" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();
    try std.testing.expectEqual(@as(?[]u8, null), try db.get("nonexistent"));
}

test "db: put overwrite" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();
    try db.put("k", "v1");
    try db.put("k", "v2");
    const v = try db.get("k");
    try std.testing.expectEqualStrings("v2", v.?);
    std.testing.allocator.free(v.?);
}

test "db: delete removes key" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();
    try db.put("k", "v");
    try db.delete("k");
    try std.testing.expectEqual(@as(?[]u8, null), try db.get("k"));
}

test "db: putBatch then get all" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();
    const entries = [_]dbi.Entry{
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "2" },
        .{ .key = "c", .value = "3" },
    };
    try db.putBatch(&entries);
    for (entries) |e| {
        const v = try db.get(e.key);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings(e.value, v.?);
        std.testing.allocator.free(v.?);
    }
}

test "db: select range" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();
    const keys = [_][]const u8{ "apple", "banana", "cherry" };
    for (keys) |k| try db.put(k, k);
    var it = try db.select("banana", "d");
    defer it.deinit();
    var count: usize = 0;
    var got = std.ArrayList([]const u8).empty;
    defer got.deinit(std.testing.allocator);
    while (try it.next()) |e| {
        count += 1;
        try got.append(std.testing.allocator, try std.testing.allocator.dupe(u8, e.key));
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("banana", got.items[0]);
    try std.testing.expectEqualStrings("cherry", got.items[1]);
    for (got.items) |g| std.testing.allocator.free(g);
}

test "db: 100 sequential puts all readable" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var kbuf: [12]u8 = undefined;
        const k = fmtKey(&kbuf, i);
        try db.put(k, "val");
    }
    i = 0;
    while (i < 100) : (i += 1) {
        var kbuf: [12]u8 = undefined;
        const k = fmtKey(&kbuf, i);
        const v = try db.get(k);
        try std.testing.expect(v != null);
        std.testing.allocator.free(v.?);
    }
}

test "db: select full range ordered" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();
    try db.put("z", "last");
    try db.put("a", "first");
    try db.put("m", "mid");
    var it = try db.select(null, null);
    defer it.deinit();
    var got = std.ArrayList([]const u8).empty;
    defer got.deinit(std.testing.allocator);
    while (try it.next()) |e| {
        try got.append(std.testing.allocator, try std.testing.allocator.dupe(u8, e.key));
    }
    try std.testing.expectEqual(@as(usize, 3), got.items.len);
    try std.testing.expectEqualStrings("a", got.items[0]);
    try std.testing.expectEqualStrings("m", got.items[1]);
    try std.testing.expectEqualStrings("z", got.items[2]);
    for (got.items) |g| std.testing.allocator.free(g);
}

test "db: close and reopen recovers from meta" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    // 第一次打开，写入数据
    var db = try dbi.Db.open(std.testing.allocator, s, .{});
    try db.put("persist", "me");
    try db.put("another", "key");
    try db.delete("another");
    const root_seq1 = db.getRoot();
    db.close();

    // 第二次打开（同一个 store，meta 应恢复）
    var db2_ = try dbi.Db.open(std.testing.allocator, s, .{});
    defer db2_.close();
    // 根应不同（因为上次 close 后 meta 持久化了 COW 状态）
    _ = root_seq1;
    const v = try db2_.get("persist");
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("me", v.?);
    std.testing.allocator.free(v.?);
    // another 应被删了
    try std.testing.expectEqual(@as(?[]u8, null), try db2_.get("another"));
}

test "db: meta alternation — write, corrupt one meta, recover" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    // 写两个 batch → meta 交替到 page 1
    var db = try dbi.Db.open(std.testing.allocator, s, .{});
    try db.put("k1", "v1");
    try db.put("k2", "v2");
    const expected_root = db.getRoot();
    db.close();

    // 损坏 meta page 0（使 checksum 不对 — 用垃圾数据）
    // MemPageStore 的 writePage 返回 meta0 的可变指针
    _ = try s.writePage(1);
    const corrupted_page = try s.writePage(1);
    @memset(corrupted_page, 0xff);
    // 保留 checksum 有效性（故意让 checksum 也错—不走 setPageChecksum）

    // 第三次打开 — 应从 meta page 1 恢复
    var db2_ = try dbi.Db.open(std.testing.allocator, s, .{});
    defer db2_.close();
    // k1 和 k2 应还在
    const v1 = try db2_.get("k1");
    try std.testing.expectEqualStrings("v1", v1.?);
    std.testing.allocator.free(v1.?);
    const v2 = try db2_.get("k2");
    try std.testing.expectEqualStrings("v2", v2.?);
    std.testing.allocator.free(v2.?);
    // root 应匹配
    try std.testing.expectEqual(expected_root, db2_.getRoot());
}
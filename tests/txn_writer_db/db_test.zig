//! db_test.zig — Db2 integration tests (TDD RED)
//! Covers: open/close, put/get, putBatch, delete, select, meta recovery.
//! Uses MemPageStore to simulate persistence. Written to fail first (db.zig does not exist).
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

    // First open: write data
    var db = try dbi.Db.open(std.testing.allocator, s, .{});
    try db.put("persist", "me");
    try db.put("another", "key");
    try db.delete("another");
    const root_seq1 = db.getRoot();
    db.close();

    // Second open (same store; meta should be recovered)
    var db2_ = try dbi.Db.open(std.testing.allocator, s, .{});
    defer db2_.close();
    // The root should differ (the last close persisted the COW state via meta)
    _ = root_seq1;
    const v = try db2_.get("persist");
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("me", v.?);
    std.testing.allocator.free(v.?);
    // "another" should have been deleted
    try std.testing.expectEqual(@as(?[]u8, null), try db2_.get("another"));
}

test "db: meta alternation — write, corrupt one meta, recover" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    // Write two batches -> meta alternates to page 1
    var db = try dbi.Db.open(std.testing.allocator, s, .{});
    try db.put("k1", "v1");
    try db.put("k2", "v2");
    const expected_root = db.getRoot();
    db.close();

    // Corrupt meta page 0 (break the checksum — with garbage bytes)
    // MemPageStore's writePage returns a mutable pointer to meta0
    _ = try s.writePage(1);
    const corrupted_page = try s.writePage(1);
    @memset(corrupted_page, 0xff);
    // Leave the checksum invalid (deliberately skip setPageChecksum)

    // Third open — should recover from meta page 1
    var db2_ = try dbi.Db.open(std.testing.allocator, s, .{});
    defer db2_.close();
    // k1 and k2 should still be there
    const v1 = try db2_.get("k1");
    try std.testing.expectEqualStrings("v1", v1.?);
    std.testing.allocator.free(v1.?);
    const v2 = try db2_.get("k2");
    try std.testing.expectEqualStrings("v2", v2.?);
    std.testing.allocator.free(v2.?);
    // The root should match
    try std.testing.expectEqual(expected_root, db2_.getRoot());
}
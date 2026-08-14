//! zero_copy_test.zig — TDD: zero-copy get 返回借用切片
//! 测试 ReadTxn.get 返回的切片是借用的（不需要调用方 free），
//! 且在 ReadTxn 生命周期内有效。
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(std.testing.allocator, 100000);
}

// ---- Test 1: borrowed get returns valid slice, no alloc needed ----
test "zero_copy: get returns borrowed slice (no free needed)" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try cube.Db.open(std.testing.allocator, s, .{});
    defer db.close();

    try db.put("key1", "value1");

    var txn = try db.beginReadTxn();
    defer txn.end();

    // getBorrowed returns a borrowed slice — no allocation, no free needed
    const val = try txn.getBorrowed("key1");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("value1", val.?);
    // No free! The slice is borrowed from the page buffer.
}

// ---- Test 2: borrowed get on missing key returns null ----
test "zero_copy: getBorrowed missing key -> null" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try cube.Db.open(std.testing.allocator, s, .{});
    defer db.close();

    try db.put("key1", "value1");

    var txn = try db.beginReadTxn();
    defer txn.end();

    const val = try txn.getBorrowed("nonexistent");
    try std.testing.expectEqual(@as(?[]const u8, null), val);
}

// ---- Test 3: borrowed get sees snapshot (MVCC isolation) ----
test "zero_copy: borrowed get snapshot isolation" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try cube.Db.open(std.testing.allocator, s, .{});
    defer db.close();

    try db.put("key1", "value1");

    var txn = try db.beginReadTxn();
    defer txn.end();

    // Writer commits new value
    try db.put("key1", "value2");

    // Reader still sees old snapshot
    const val = try txn.getBorrowed("key1");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("value1", val.?);
}

// ---- Test 4: borrowed get on tombstone returns null ----
test "zero_copy: borrowed get after delete -> null" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try cube.Db.open(std.testing.allocator, s, .{});
    defer db.close();

    try db.put("key1", "value1");
    try db.delete("key1");

    var txn = try db.beginReadTxn();
    defer txn.end();

    const val = try txn.getBorrowed("key1");
    try std.testing.expectEqual(@as(?[]const u8, null), val);
}

// ---- Test 5: borrowed get works with multiple keys ----
test "zero_copy: multiple borrowed gets in one txn" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try cube.Db.open(std.testing.allocator, s, .{});
    defer db.close();

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        try db.put(k, "val");
    }

    var txn = try db.beginReadTxn();
    defer txn.end();

    i = 0;
    while (i < 100) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        const val = try txn.getBorrowed(k);
        try std.testing.expect(val != null);
        try std.testing.expectEqualStrings("val", val.?);
    }
}

// ---- Test 6: borrowed get with overflow (large value) ----
test "zero_copy: borrowed get with 10KB overflow value" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try cube.Db.open(std.testing.allocator, s, .{});
    defer db.close();

    var big: [10000]u8 = undefined;
    @memset(&big, 'x');
    try db.put("big", &big);

    var txn = try db.beginReadTxn();
    defer txn.end();

    // Overflow values can't be borrowed (span multiple pages) — getBorrowed returns null
    const borrowed = try txn.getBorrowed("big");
    try std.testing.expectEqual(@as(?[]const u8, null), borrowed);

    // Use regular get() for overflow values
    const val = try txn.get("big");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(usize, 10000), val.?.len);
    try std.testing.expect(val.?[0] == 'x');
    try std.testing.expect(val.?[9999] == 'x');
    std.testing.allocator.free(val.?);
}

// ---- Test 7: existing get() still works (backward compat) ----
test "zero_copy: existing get() still works alongside getBorrowed" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try cube.Db.open(std.testing.allocator, s, .{});
    defer db.close();

    try db.put("key1", "value1");

    // Old API: returns owned, needs free
    const v1 = try db.get("key1");
    try std.testing.expectEqualStrings("value1", v1.?);
    std.testing.allocator.free(v1.?);

    // New API: returns borrowed, no free
    var txn = try db.beginReadTxn();
    defer txn.end();
    const v2 = try txn.getBorrowed("key1");
    try std.testing.expectEqualStrings("value1", v2.?);
}

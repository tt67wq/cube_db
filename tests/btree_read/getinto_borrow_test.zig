//! getinto_borrow_test.zig - T-29 Phase A: contract tests for the getInto(key, buffer) zero-copy read API
//!
//! RED stage (this file landed first): Db.getInto / ReadTxn.getInto / btree.getInto did not exist yet,
//! so compilation failure was the RED signal (same TDD precedent as T-27 durability_order_test).
//!
//! Contract after GREEN:
//! - Hit: value is copied into the caller's buffer, the written byte count is returned; a buffer
//!   of exactly the right size also succeeds.
//! - Missing key (or tombstone): returns null - the null meaning is reserved exclusively for "not
//!   present", fully decoupled from the "null ambiguity" that led to removing the borrowed API in T-23.
//! - Buffer too small: error.BufferTooSmall, and the buffer contents are never written/cleared
//!   (the caller can safely retry with a larger buffer, or rely on the original contents).
//! - Overflow values (> MAX_INLINE_VALUE 3800B): copied into the buffer via the overflow page chain, contents identical.
//! - Semantics consistent across Db / ReadTxn / btree layers.
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;
const Db = cube.Db;

const alloc = std.testing.allocator;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 100000);
}

test "getInto: hit — value copied into caller buffer, returns length" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    try db.put("hello", "world");

    var buf: [64]u8 = undefined;
    const n = (try db.getInto("hello", &buf)).?;
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("world", buf[0..n]);
}

test "getInto: missing key returns null, buffer untouched" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    try db.put("hello", "world");

    var buf: [16]u8 = undefined;
    @memset(&buf, 0xAA);
    const r = try db.getInto("nonexistent", &buf);
    try std.testing.expect(r == null);
    // buffer must not be written or cleared
    for (buf) |b| try std.testing.expectEqual(@as(u8, 0xAA), b);
}

test "getInto: tombstone key returns null" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    try db.put("k", "v");
    try db.delete("k");

    var buf: [16]u8 = undefined;
    const r = try db.getInto("k", &buf);
    try std.testing.expect(r == null);
}

test "getInto: BufferTooSmall when buffer shorter than value - no partial write" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    const val = "0123456789"; // 10B
    try db.put("k", val);

    var buf: [9]u8 = undefined; // 1 byte short
    @memset(&buf, 0xBB);
    try std.testing.expectError(error.BufferTooSmall, db.getInto("k", &buf));
    // failure path: no write, no clear
    for (buf) |b| try std.testing.expectEqual(@as(u8, 0xBB), b);
}

test "getInto: exact-size buffer succeeds" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    const val = "0123456789";
    try db.put("k", val);

    var buf: [10]u8 = undefined; // exactly the right size
    const n = (try db.getInto("k", &buf)).?;
    try std.testing.expectEqual(@as(usize, 10), n);
    try std.testing.expectEqualStrings(val, buf[0..n]);
}

test "getInto: overflow value (>3800B) copied via overflow chain" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    var val: [5000]u8 = undefined;
    for (&val, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
    try db.put("big", &val);

    // byte-identical to the old get
    const want = try db.get("big");
    defer alloc.free(want.?);
    try std.testing.expectEqualSlices(u8, &val, want.?);

    // getInto: large enough buffer
    var buf: [5000]u8 = undefined;
    const n = (try db.getInto("big", &buf)).?;
    try std.testing.expectEqual(@as(usize, 5000), n);
    try std.testing.expectEqualSlices(u8, &val, buf[0..n]);

    // exact boundary for overflow value: exact-size succeeds, 1 byte short gives BufferTooSmall
    var exact: [5000]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5000), (try db.getInto("big", &exact)).?);
    var short: [4999]u8 = undefined;
    @memset(&short, 0xCC);
    try std.testing.expectError(error.BufferTooSmall, db.getInto("big", &short));
    for (short) |b| try std.testing.expectEqual(@as(u8, 0xCC), b);
}

test "getInto: ReadTxn snapshot semantics match Db level" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    try db.put("k", "v1");

    var r = try db.beginReadTxn();
    defer r.end();

    // snapshot pin: overwrites after the txn are invisible inside it
    try db.put("k", "v2");

    var buf: [16]u8 = undefined;
    const n = (try r.getInto("k", &buf)).?;
    try std.testing.expectEqualStrings("v1", buf[0..n]);

    // BufferTooSmall / null semantics consistent at the ReadTxn layer
    var small: [1]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, r.getInto("k", &small));
    try std.testing.expect((try r.getInto("nope", &buf)) == null);
}

test "getInto: btree level direct - descent path matches get()" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(alloc);

    // many keys / many leaves (enough entries to trigger splits), covering branch descent
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>4}", .{i});
        dirty.clearRetainingCapacity();
        root = (try btree.insert(alloc, s, root, k, "value-42", false, &dirty)).new_root;
    }

    var buf: [16]u8 = undefined;
    const n = (try btree.getInto(s, root, "k0100", &buf)).?;
    try std.testing.expectEqualStrings("value-42", buf[0..n]);

    // matches get() result; missing key -> null
    const want = try btree.get(alloc, s, root, "k0100");
    defer alloc.free(want.?);
    try std.testing.expectEqualSlices(u8, want.?, buf[0..n]);
    try std.testing.expect((try btree.getInto(s, root, "k9999", &buf)) == null);

    // empty buffer succeeds for zero-length value, BufferTooSmall for non-zero value
    root = (try btree.insert(alloc, s, root, "empty", "", false, &dirty)).new_root;
    var zero: [0]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try btree.getInto(s, root, "empty", &zero)).?);
    try std.testing.expectError(error.BufferTooSmall, btree.getInto(s, root, "k0100", &zero));
}

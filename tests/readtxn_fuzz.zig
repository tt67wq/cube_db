//! readtxn_fuzz.zig — ReadTxn 生命周期 fuzz
//! 验证 getBorrowed 返回的借用切片在 ReadTxn 生命周期内有效，
//! 以及 txn 结束后访问借用切片的行为。
//!
//! 覆盖场景：
//! 1. 嵌套 ReadTxn — 内外层各自的借用切片生命周期
//! 2. 并发写/读 — 写者提交后读者快照的借用切片安全
//! 3. Overflow fallback — getBorrowed null → get() 路径
//! 4. 多个重叠 ReadTxn — 不同树状态的快照一致性
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(std.testing.allocator, 100000);
}

// ---- Nested ReadTxn ----
test "readtxn_fuzz: nested ReadTxn, inner and outer borrow" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try cube.Db.open(std.testing.allocator, s, .{});
    defer db.close();

    try db.put("a", "outer_val");
    try db.put("b", "inner_val");

    // Outer txn
    var outer = try db.beginReadTxn();
    defer outer.end();

    const va = try outer.getBorrowed("a");
    try std.testing.expectEqualStrings("outer_val", va.?);

    {
        // Inner txn (nested)
        var inner = try db.beginReadTxn();
        defer inner.end();

        const vb = try inner.getBorrowed("b");
        try std.testing.expectEqualStrings("inner_val", vb.?);

        // Outer slice still valid while both txns alive
        try std.testing.expectEqualStrings("outer_val", va.?);
    }
    // After inner txn ends: outer slice still valid
    try std.testing.expectEqualStrings("outer_val", va.?);
}

// ---- Nested ReadTxn with writer between them ----
test "readtxn_fuzz: nested ReadTxn with writer in between" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try cube.Db.open(std.testing.allocator, s, .{});
    defer db.close();

    try db.put("a", "original");

    var outer = try db.beginReadTxn();
    defer outer.end();

    const v_outer = try outer.getBorrowed("a");
    try std.testing.expectEqualStrings("original", v_outer.?);

    // Writer updates value
    try db.put("a", "updated");

    // Inner txn sees the NEW value (after writer commit)
    var inner = try db.beginReadTxn();
    defer inner.end();

    const v_inner = try inner.getBorrowed("a");
    try std.testing.expectEqualStrings("updated", v_inner.?);

    // Outer txn still sees SNAPSHOT value
    try std.testing.expectEqualStrings("original", v_outer.?);
}

// ---- Multiple overlapping ReadTxns ----
test "readtxn_fuzz: three overlapping txns at different tree states" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try cube.Db.open(std.testing.allocator, s, .{});
    defer db.close();

    try db.put("k", "v0");

    var txn0 = try db.beginReadTxn();
    defer txn0.end();
    try std.testing.expectEqualStrings("v0", (try txn0.getBorrowed("k")).?);

    try db.put("k", "v1");

    var txn1 = try db.beginReadTxn();
    defer txn1.end();
    try std.testing.expectEqualStrings("v1", (try txn1.getBorrowed("k")).?);

    try db.put("k", "v2");

    var txn2 = try db.beginReadTxn();
    defer txn2.end();
    try std.testing.expectEqualStrings("v2", (try txn2.getBorrowed("k")).?);

    // txn0 still sees v0, txn1 still sees v1
    try std.testing.expectEqualStrings("v0", (try txn0.getBorrowed("k")).?);
    try std.testing.expectEqualStrings("v1", (try txn1.getBorrowed("k")).?);
    try std.testing.expectEqualStrings("v2", (try txn2.getBorrowed("k")).?);
}

// ---- Multiple keys, mixed operations between txns ----
test "readtxn_fuzz: insert/delete between overlapping txns" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try cube.Db.open(std.testing.allocator, s, .{});
    defer db.close();

    try db.put("keep", "stays");
    try db.put("temp", "will_be_deleted");

    var txn1 = try db.beginReadTxn();
    defer txn1.end();

    try db.delete("temp");
    try db.put("new", "added_after_txn1");

    var txn2 = try db.beginReadTxn();
    defer txn2.end();

    // txn1: sees original state
    try std.testing.expectEqualStrings("stays", (try txn1.getBorrowed("keep")).?);
    try std.testing.expectEqualStrings("will_be_deleted", (try txn1.getBorrowed("temp")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try txn1.getBorrowed("new"));

    // txn2: sees updated state
    try std.testing.expectEqualStrings("stays", (try txn2.getBorrowed("keep")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try txn2.getBorrowed("temp"));
    try std.testing.expectEqualStrings("added_after_txn1", (try txn2.getBorrowed("new")).?);
}

// ---- Overflow fallback path ----
test "readtxn_fuzz: overflow value getBorrowed returns null, get works" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try cube.Db.open(std.testing.allocator, s, .{});
    defer db.close();

    var big: [10000]u8 = undefined;
    @memset(&big, 'x');

    try db.put("big", &big);
    try db.put("small", "inline");

    var txn = try db.beginReadTxn();
    defer txn.end();

    // Overflow: getBorrowed returns null
    try std.testing.expectEqual(@as(?[]const u8, null), try txn.getBorrowed("big"));

    // Fallback to get()
    const val = try txn.get("big");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(usize, 10000), val.?.len);
    std.testing.allocator.free(val.?);

    // Inline value still works with getBorrowed
    try std.testing.expectEqualStrings("inline", (try txn.getBorrowed("small")).?);
}

// ---- Mix of inline and overflow in same txn ----
test "readtxn_fuzz: mixed inline/overflow in same ReadTxn" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try cube.Db.open(std.testing.allocator, s, .{});
    defer db.close();

    var big: [8000]u8 = undefined;
    @memset(&big, 'x');

    try db.put("a", "small_a");
    try db.put("b", &big);
    try db.put("c", "small_c");

    var txn = try db.beginReadTxn();
    defer txn.end();

    // inline
    try std.testing.expectEqualStrings("small_a", (try txn.getBorrowed("a")).?);

    // overflow → null
    try std.testing.expectEqual(@as(?[]const u8, null), try txn.getBorrowed("b"));

    // inline
    try std.testing.expectEqualStrings("small_c", (try txn.getBorrowed("c")).?);
}

// ---- Large number of keys with ReadTxn ----
test "readtxn_fuzz: 1000 keys in one ReadTxn" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try cube.Db.open(std.testing.allocator, s, .{});
    defer db.close();

    const n = 1000;
    var kbuf: [16]u8 = undefined;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        try db.put(k, "val");
    }

    var txn = try db.beginReadTxn();
    defer txn.end();

    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        const val = try txn.getBorrowed(k);
        try std.testing.expect(val != null);
        try std.testing.expectEqualStrings("val", val.?);
    }
}

// ---- Repeat txn begin/end cycles ----
test "readtxn_fuzz: repeated txn begin/end cycles" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try cube.Db.open(std.testing.allocator, s, .{});
    defer db.close();

    try db.put("k", "v");

    for (0..50) |_| {
        var txn = try db.beginReadTxn();
        defer txn.end();

        const val = try txn.getBorrowed("k");
        try std.testing.expectEqualStrings("v", val.?);
    }
}

// ---- get on Db level vs getBorrowed on ReadTxn ----
test "readtxn_fuzz: db.get and txn.getBorrowed consistency" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var db = try cube.Db.open(std.testing.allocator, s, .{});
    defer db.close();

    try db.put("a", "hello");
    try db.put("b", "world");

    // Direct db.get
    const va = try db.get("a");
    defer std.testing.allocator.free(va.?);
    try std.testing.expectEqualStrings("hello", va.?);

    var txn = try db.beginReadTxn();
    defer txn.end();

    // txn.getBorrowed in same tree state
    try std.testing.expectEqualStrings("hello", (try txn.getBorrowed("a")).?);
    try std.testing.expectEqualStrings("world", (try txn.getBorrowed("b")).?);
}

//! read_txn_borrowed_test.zig — T-7: ReadTxn.getBorrowed 公开 API 测试
//! 验证 src/db.zig:347 getBorrowed 的三个契约：
//!   1. 小 value（inline）返回借用切片，内容匹配
//!   2. 大 value（overflow >3800B）返回 null
//!   3. tombstone key 返回 null
//!   4. 缺失 key 返回 null
//!   5. 快照隔离：ReadTxn 持有旧 root，写者提交新值后仍读旧借用切片
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const Db = cube.Db;

const alloc = std.testing.allocator;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 10000);
}

// ---- Test 1: 小 value 返回借用切片，内容匹配 ----
test "getBorrowed: small inline value returns borrowed slice" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    try db.putDirect("k", "hello");

    var rt = try db.beginReadTxn();
    defer rt.end();

    const borrowed = try rt.getBorrowed("k");
    try std.testing.expect(borrowed != null);
    try std.testing.expectEqualStrings("hello", borrowed.?);
    // 不需 free — 借用切片指向 page 缓冲
}

// ---- Test 2: 大 value（overflow >3800B）返回 null ----
test "getBorrowed: overflow value returns null" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    // MAX_INLINE_VALUE = 3800; 用 5000 字节触发 overflow 页
    const big = try alloc.alloc(u8, 5000);
    defer alloc.free(big);
    @memset(big, 'x');

    try db.putDirect("big", big);

    var rt = try db.beginReadTxn();
    defer rt.end();

    // getBorrowed 对 overflow 返回 null（文档契约）
    const borrowed = try rt.getBorrowed("big");
    try std.testing.expectEqual(@as(?[]const u8, null), borrowed);

    // 但 get() 应能读回完整值（对照：overflow 走 get 而非 getBorrowed）
    const v = try rt.get("big");
    defer if (v) |val| alloc.free(val);
    try std.testing.expect(v != null);
    try std.testing.expectEqual(@as(usize, 5000), v.?.len);
}

// ---- Test 3: tombstone key 返回 null ----
test "getBorrowed: tombstone key returns null" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    try db.putDirect("k", "v");
    try db.deleteDirect("k"); // tombstone

    var rt = try db.beginReadTxn();
    defer rt.end();

    const borrowed = try rt.getBorrowed("k");
    try std.testing.expectEqual(@as(?[]const u8, null), borrowed);
}

// ---- Test 4: 缺失 key 返回 null ----
test "getBorrowed: missing key returns null" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    try db.putDirect("exists", "v");

    var rt = try db.beginReadTxn();
    defer rt.end();

    const borrowed = try rt.getBorrowed("nonexistent");
    try std.testing.expectEqual(@as(?[]const u8, null), borrowed);
}

// ---- Test 5: 快照隔离 — 写者提交新值后，ReadTxn 仍读旧借用切片 ----
test "getBorrowed: snapshot isolation — old borrowed slice valid after writer commits" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    try db.putDirect("k", "v1");

    var rt = try db.beginReadTxn();
    defer rt.end();

    // 写者提交新值（COW 不原地改，旧页保留供 reader）
    try db.putDirect("k", "v2");

    // reader 仍读快照旧值
    const borrowed = try rt.getBorrowed("k");
    try std.testing.expect(borrowed != null);
    try std.testing.expectEqualStrings("v1", borrowed.?);

    // 结束读后，新值可见
    rt.end();
    const v2 = try db.get("k");
    defer if (v2) |val| alloc.free(val);
    try std.testing.expectEqualStrings("v2", v2.?);
}

// ---- Test 6: 空 Db 上 getBorrowed 返回 null（root == NULL_ROOT）----
test "getBorrowed: empty db returns null" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    var rt = try db.beginReadTxn();
    defer rt.end();

    const borrowed = try rt.getBorrowed("anything");
    try std.testing.expectEqual(@as(?[]const u8, null), borrowed);
}

// ---- Test 7: 多 key 场景，getBorrowed 正确返回各自的借用切片 ----
test "getBorrowed: multiple keys each return correct borrowed slice" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    try db.putDirect("a", "alpha");
    try db.putDirect("b", "beta");
    try db.putDirect("c", "gamma");

    var rt = try db.beginReadTxn();
    defer rt.end();

    const a = try rt.getBorrowed("a");
    try std.testing.expectEqualStrings("alpha", a.?);
    const b = try rt.getBorrowed("b");
    try std.testing.expectEqualStrings("beta", b.?);
    const c = try rt.getBorrowed("c");
    try std.testing.expectEqualStrings("gamma", c.?);
}

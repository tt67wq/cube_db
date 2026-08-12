//! range_delete_test.zig — Db.deleteRange 契约测试
//! 覆盖契约点：
//!   1. [min, max) 半开区间删除（字节序比较，同 select）
//!   2. null min/max = 无界；(null, null) 清空全库
//!   3. 区间外 key 不受影响（存在性 + 值保留）
//!   4. 反向/空区间 (min >= max) → no-op 成功
//!   5. 仅缺失/已删除 key → no-op 成功（幂等）
//!   6. micro_batch 下 pending puts 在区间内也须被删除
//!   7. entryCount() 反映删除（同 delete 的记账）
//!   8. MemPageStore + FilePageStore 行为一致
//!   9. 无新公开类型（编译器保证，deleteRange 返回 !void）
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const FilePageStore = cube.file_page_store.FilePageStore;
const Db = cube.Db;

const alloc = std.testing.allocator;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

fn expectGet(db: *Db, key: []const u8, expected: ?[]const u8) !void {
    const v = try db.get(key);
    defer if (v) |val| alloc.free(val);
    if (expected) |exp| {
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings(exp, v.?);
    } else {
        try std.testing.expect(v == null);
    }
}

// ---- 公共种子数据：覆盖区间内/边界/区间外（直接提交，绕过 micro-batching）----
fn seedDirect(db: *Db) !void {
    try db.putDirect("a", "1");
    try db.putDirect("b", "2");
    try db.putDirect("c", "3");
    try db.putDirect("d", "4");
    try db.putDirect("e", "5");
}

test "deleteRange: basic range delete [b, d)" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);

    try db.deleteRange("b", "d"); // 删除 b, c

    try expectGet(db, "a", "1");
    try expectGet(db, "b", null);
    try expectGet(db, "c", null);
    try expectGet(db, "d", "4");
    try expectGet(db, "e", "5");
}

test "deleteRange: boundary [min, max) excludes max" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);

    // [b, c)：只删 b；c 是上界，须保留
    try db.deleteRange("b", "c");
    try expectGet(db, "a", "1");
    try expectGet(db, "b", null);
    try expectGet(db, "c", "3");
    try expectGet(db, "d", "4");
}

test "deleteRange: (null, null) clears whole store" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);

    try db.deleteRange(null, null);
    try expectGet(db, "a", null);
    try expectGet(db, "c", null);
    try expectGet(db, "e", null);
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

test "deleteRange: null min unbounded below" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);

    try db.deleteRange(null, "c"); // 删 a, b
    try expectGet(db, "a", null);
    try expectGet(db, "b", null);
    try expectGet(db, "c", "3");
    try expectGet(db, "e", "5");
}

test "deleteRange: null max unbounded above" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);

    try db.deleteRange("c", null); // 删 c, d, e
    try expectGet(db, "a", "1");
    try expectGet(db, "b", "2");
    try expectGet(db, "c", null);
    try expectGet(db, "e", null);
}

test "deleteRange: inverted range (min >= max) is no-op" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);
    const count_before = db.entryCount();

    try db.deleteRange("d", "b"); // 反向
    try db.deleteRange("c", "c"); // 空区间 [c, c)

    try expectGet(db, "b", "2");
    try expectGet(db, "c", "3");
    try expectGet(db, "d", "4");
    try std.testing.expectEqual(count_before, db.entryCount());
}

test "deleteRange: keys outside range untouched (existence + value)" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);

    try db.deleteRange("a", "b"); // 只删 a
    try expectGet(db, "b", "2");
    try expectGet(db, "e", "5");
    // 再验证完整遍历：剩余 key 集合正确
    var it = try db.select(null, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |e| {
        n += 1;
        try std.testing.expect(!std.mem.eql(u8, e.key, "a"));
    }
    try std.testing.expectEqual(@as(usize, 4), n);
}

test "deleteRange: micro_batch pending puts inside range are deleted" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
    defer db.close();
    // Committed baseline (bypasses micro-batching so the tree is non-empty):
    try db.putDirect("a", "1");
    try db.putDirect("e", "5");

    // pending（未 flush）：m1/m2 在区间内，m3 在区间外
    try db.put("m1", "pending-1");
    try db.put("m2", "pending-2");
    try db.put("m3", "pending-3");
    try std.testing.expectEqual(@as(usize, 3), db.pending.items.len);

    try db.deleteRange("m1", "m3"); // 应删 m1, m2；m3 保留

    // pending 已被 deleteRange 消费（flush），无残留
    try std.testing.expectEqual(@as(usize, 0), db.pending.items.len);
    try expectGet(db, "m1", null);
    try expectGet(db, "m2", null);
    try expectGet(db, "m3", "pending-3");
    // 已提交的区间外 key 不受影响
    try expectGet(db, "a", "1");
    try expectGet(db, "e", "5");
}

test "deleteRange: micro_batch pending deletes + staged put outside range" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
    defer db.close();
    // Committed baseline (bypasses micro-batching):
    try db.putDirect("a", "1");
    try db.putDirect("b", "2");
    try db.putDirect("c", "3");
    try db.putDirect("d", "4");
    try db.putDirect("e", "5");

    try db.delete("c"); // pending tombstone（区间内）
    try db.put("x", "9"); // pending put，区间外
    try db.deleteRange("b", "d"); // [b,d) 半开：删 b；c 已 pending tombstone；d 是上界保留

    try expectGet(db, "a", "1");
    try expectGet(db, "b", null);
    try expectGet(db, "c", null);
    try expectGet(db, "d", "4"); // 上界，保留
    try expectGet(db, "x", "9");
}

test "deleteRange: idempotent on already-missing keys" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);

    try db.deleteRange("f", "z"); // 全是缺失 key
    try std.testing.expectEqual(@as(u64, 5), db.entryCount());
    try expectGet(db, "e", "5");

    // 删除后再次删除同一区间 → 仍成功
    try db.deleteRange("b", "d");
    try db.deleteRange("b", "d");
    try expectGet(db, "b", null);
    try expectGet(db, "c", null);
    try expectGet(db, "d", "4");
    // 空 store 上 deleteRange 也成功
    try db.deleteRange(null, null);
    try db.deleteRange(null, null);
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

test "deleteRange: entryCount reflects deletions" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);
    try std.testing.expectEqual(@as(u64, 5), db.entryCount());

    try db.deleteRange("b", "d"); // 删 b, c
    try std.testing.expectEqual(@as(u64, 3), db.entryCount());

    try db.deleteRange("a", "b"); // 删 a
    try std.testing.expectEqual(@as(u64, 2), db.entryCount());

    try db.deleteRange(null, null); // 清空
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

test "deleteRange: FilePageStore identical behavior" {
    const path = ".test_range_delete.db";
    defer unlinkPath(path);
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();
    try seedDirect(db);

    try db.deleteRange("b", "d");
    try expectGet(db, "a", "1");
    try expectGet(db, "b", null);
    try expectGet(db, "c", null);
    try expectGet(db, "d", "4");
    try expectGet(db, "e", "5");
    try std.testing.expectEqual(@as(u64, 3), db.entryCount());

    // (null, null) 清空同样工作
    try db.deleteRange(null, null);
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

test "deleteRange: byte-order comparison matches select" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    // 数字 key 的字典序： "10" < "2"
    try db.putDirect("1", "v1");
    try db.putDirect("10", "v10");
    try db.putDirect("2", "v2");
    try db.putDirect("20", "v20");

    try db.deleteRange("10", "2"); // 字节序上 [10, 2) = {10}（"10" < "2"）
    try expectGet(db, "1", "v1");
    try expectGet(db, "10", null);
    try expectGet(db, "2", "v2");
    try expectGet(db, "20", "v20");
}

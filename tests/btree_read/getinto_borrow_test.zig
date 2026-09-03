//! getinto_borrow_test.zig — T-29 Phase A: getInto(key, buffer) 无拷贝读 API 契约测试
//!
//! RED 阶段（本文件先落）：Db.getInto / ReadTxn.getInto / btree.getInto 尚不存在，
//! 编译失败即 RED（与 T-27 durability_order_test 同款 TDD 先例）。
//!
//! GREEN 后的契约：
//! - 命中：value 拷入调用方 buffer，返回写入字节数；buffer 恰好等长也成功。
//! - key 不存在（或 tombstone）：返回 null——null 语义唯一保留给"不存在"，
//!   与 T-23 移除 borrowed API 时的"null 多义性"彻底解耦。
//! - buffer 不足：error.BufferTooSmall，且 buffer 内容完全不被写入/清空
//!   （调用方可安全换大 buffer 重试，或依赖原内容不变）。
//! - 溢出值（> MAX_INLINE_VALUE 3800B）：经溢出页链拷入 buffer，内容一致。
//! - Db 层 / ReadTxn 层 / btree 层三级语义一致。
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
    // buffer 不被写入/清空
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

test "getInto: BufferTooSmall when buffer shorter than value — no partial write" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    const val = "0123456789"; // 10B
    try db.put("k", val);

    var buf: [9]u8 = undefined; // 差 1 字节
    @memset(&buf, 0xBB);
    try std.testing.expectError(error.BufferTooSmall, db.getInto("k", &buf));
    // 失败路径不写入、不清空
    for (buf) |b| try std.testing.expectEqual(@as(u8, 0xBB), b);
}

test "getInto: exact-size buffer succeeds" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    const val = "0123456789";
    try db.put("k", val);

    var buf: [10]u8 = undefined; // 恰好等长
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

    // 与旧 get 逐字节一致
    const want = try db.get("big");
    defer alloc.free(want.?);
    try std.testing.expectEqualSlices(u8, &val, want.?);

    // getInto：足够大的 buffer
    var buf: [5000]u8 = undefined;
    const n = (try db.getInto("big", &buf)).?;
    try std.testing.expectEqual(@as(usize, 5000), n);
    try std.testing.expectEqualSlices(u8, &val, buf[0..n]);

    // 溢出值精确边界：恰好等长成功，差 1 字节 BufferTooSmall
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

    // 快照 pin：txn 内看不到 txn 后的覆写
    try db.put("k", "v2");

    var buf: [16]u8 = undefined;
    const n = (try r.getInto("k", &buf)).?;
    try std.testing.expectEqualStrings("v1", buf[0..n]);

    // ReadTxn 层 BufferTooSmall / null 语义一致
    var small: [1]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, r.getInto("k", &small));
    try std.testing.expect((try r.getInto("nope", &buf)) == null);
}

test "getInto: btree level direct — descent path matches get()" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(alloc);

    // 多 key 多叶（足够条数触发分裂），覆盖 branch 下降
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

    // 与 get() 结果一致；不存在 key → null
    const want = try btree.get(alloc, s, root, "k0100");
    defer alloc.free(want.?);
    try std.testing.expectEqualSlices(u8, want.?, buf[0..n]);
    try std.testing.expect((try btree.getInto(s, root, "k9999", &buf)) == null);

    // 空 buffer 对零长 value 成功、对非零 value BufferTooSmall
    root = (try btree.insert(alloc, s, root, "empty", "", false, &dirty)).new_root;
    var zero: [0]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try btree.getInto(s, root, "empty", &zero)).?);
    try std.testing.expectError(error.BufferTooSmall, btree.getInto(s, root, "k0100", &zero));
}

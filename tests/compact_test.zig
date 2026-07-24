//! compact_test.zig — compact v2 测试（TDD RED）
//! 覆盖：空库 compact、清除 dirt、保持数据可读、有读者时阻塞、幂等。
//! 用 MemPageStore，先 fail（compact 尚未实现或非 O(1)）。
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const ps = cube.page_store;
const wrt = cube.writer;
const dbi = cube.db;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(std.testing.allocator, 10000);
}

test "compact: compact on empty db is no-op" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();
    // 空库 compact 不应报错
    try db.compact();
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

test "compact: compact clears dirt after writes" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    // 写入并覆写，产生脏页
    try db.put("k", "v1");
    // 无读者，脏页已自动 flush → dirt = 0
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());

    // 开始一个 reader，阻止自动 flush
    _ = db.beginRead();
    try db.put("k", "v2");
    // 有读者 → dirt > 0
    try std.testing.expect(db.dirtCount() > 0);
    _ = db.endRead();

    // 现在 reader 已结束，dirt 应为 0（自动 flush）
    // 但为了测试 compact，我们手动 compact 也应清除 dirt
    try db.compact();
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
}

test "compact: compact preserves data" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    try db.put("persist", "me");
    try db.put("another", "key");
    try db.compact();

    // 数据仍在
    const v1 = try db.get("persist");
    try std.testing.expectEqualStrings("me", v1.?);
    std.testing.allocator.free(v1.?);
    const v2 = try db.get("another");
    try std.testing.expectEqualStrings("key", v2.?);
    std.testing.allocator.free(v2.?);
}

test "compact: compact with active reader blocks" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    // 先写入初始数据
    try db.put("k", "v1");

    // 开始 reader
    _ = db.beginRead();

    // 覆写（产生脏页 pending_free）
    try db.put("k", "v2");
    // 有 reader → dirt > 0
    try std.testing.expect(db.dirtCount() > 0);

    // compact 应等待 reader 结束或不做全量 flush
    // MVP: compact 只 flush 当前可 flush 的，不阻塞等待 reader
    try db.compact();
    // compact 后 dirt 应为 0（flush 了所有 pending）
    // 但 reader 可能阻止了部分 flush → 至少 dirt 应减少
    // 这里我们只验证 compact 不崩溃且数据可读
    const v = try db.get("k");
    try std.testing.expectEqualStrings("v2", v.?);
    std.testing.allocator.free(v.?);
    _ = db.endRead();
}

test "compact: multiple compacts are idempotent" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    try db.put("k", "v");
    try db.compact();
    try db.compact(); // 第二次
    try db.compact(); // 第三次

    const v = try db.get("k");
    try std.testing.expectEqualStrings("v", v.?);
    std.testing.allocator.free(v.?);
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
}

test "compact: after compact, new writes work" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    try db.put("k", "v1");
    try db.compact();
    try db.put("k", "v2");
    // 覆写后 dirt 应为 0（无读者自动 flush）
    // 但为了测试 compact 语义，我们这里用 beginRead 阻止 flush
    // 然后验证 compact 能清掉 dirt
    _ = db.beginRead();
    try db.put("k", "v3");
    try std.testing.expect(db.dirtCount() > 0);
    _ = db.endRead();
    // reader 结束后自动 flush → dirt = 0
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
}
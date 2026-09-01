//! compact_strong_assert_test.zig — T-22: compact 强断言测试
//!
//! 补充 compact_test.zig 中缺失的强断言：不只要"数据可读"，还要断言
//! dirt / pendingFreeCount 的具体数值，验证 compact 的实际语义。
//!
//! 核心语义（src/writer.zig:185 State.compact）：
//! - 无读者时：compact → flushPendingFree() → pending_free 清空, dirt=0
//! - 有读者时：compact → 只 dirt.store(0)（清计数不 flush 页）→ pending_free 非空
//! - reader 结束（末位）→ flushPendingFree() → pending_free 清空
//!
//! 不改 src/ 和现有 compact_test.zig。

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const wrt = cube.writer;

const alloc = std.testing.allocator;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 10000);
}

// ---- Test 1: compact 有读者时清 dirt 但不 flush 页 ----
// put(k, v1) → beginRead → put(k, v2) → dirt > 0, pendingFree > 0
// compact() → dirt == 0（compact 清了计数）
// 但 pendingFreeCount > 0（页未实际回收，因为 reader 还在）
// endRead → pendingFreeCount == 0（reader 结束触发 flush）
test "compact_strong: with reader — compact clears dirt but not pendingFree" {
    var ms = newStore();
    defer ms.deinit();
    var db = try cube.Db.open(alloc, ms.store(), .{});
    defer db.close();

    // 初始写入（无读者 → 自动 flush → dirt=0）
    try db.put("k", "v1");
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
    try std.testing.expectEqual(@as(usize, 0), db.state.pendingFreeCount());

    // 开始 reader，阻止自动 flush
    _ = db.beginRead();

    // 覆写产生脏页 → pending_free 积累, dirt > 0
    try db.put("k", "v2");
    try std.testing.expect(db.dirtCount() > 0);
    try std.testing.expect(db.state.pendingFreeCount() > 0);

    // compact：有读者 → 只清 dirt 计数，不 flush 页
    try db.compact();
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
    // 关键断言：pendingFreeCount 仍 > 0（页未回收）
    try std.testing.expect(db.state.pendingFreeCount() > 0);

    // 数据仍可读（compact 不影响数据可见性）
    const v = try db.get("k");
    try std.testing.expectEqualStrings("v2", v.?);
    alloc.free(v.?);

    // reader 结束 → 末位读者触发 flushPendingFree
    _ = db.endRead();

    // 关键断言：reader 结束后 pendingFreeCount 归 0
    try std.testing.expectEqual(@as(usize, 0), db.state.pendingFreeCount());
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
}

// ---- Test 2: compact 无读者时全 flush ----
// put(k, v1) → put(k, v2) → dirt == 0（无读者自动 flush）
// compact() → dirt == 0, pendingFreeCount == 0
test "compact_strong: no reader — compact flushes all pending pages" {
    var ms = newStore();
    defer ms.deinit();
    var db = try cube.Db.open(alloc, ms.store(), .{});
    defer db.close();

    // 写入并覆写（无读者 → 自动 flush）
    try db.put("k", "v1");
    try db.put("k", "v2");

    // 无读者时 put 已自动 flush → dirt=0, pendingFree=0
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
    try std.testing.expectEqual(@as(usize, 0), db.state.pendingFreeCount());

    // compact 无读者 → flushPendingFree（无积压可 flush）
    try db.compact();

    // 关键断言：dirt=0 且 pendingFreeCount=0
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
    try std.testing.expectEqual(@as(usize, 0), db.state.pendingFreeCount());

    // 数据可读
    const v = try db.get("k");
    try std.testing.expectEqualStrings("v2", v.?);
    alloc.free(v.?);
}

// ---- Test 3: compact 后 entry_count / byte_size 不变 ----
// compact 是元数据操作（flush dirty + write meta），不改逻辑数据。
test "compact_strong: entry_count and byte_size unchanged after compact" {
    var ms = newStore();
    defer ms.deinit();
    var db = try cube.Db.open(alloc, ms.store(), .{});
    defer db.close();

    // 写入多个 key
    try db.put("a", "11111");
    try db.put("b", "22222");
    try db.put("c", "33333");

    const entry_count_before = db.entryCount();
    const byte_size_before = db.state.byte_size.load(.acquire);

    try std.testing.expect(entry_count_before == 3);
    try std.testing.expect(byte_size_before > 0);

    try db.compact();

    // 关键断言：compact 不改变逻辑数据量
    try std.testing.expectEqual(entry_count_before, db.entryCount());
    try std.testing.expectEqual(byte_size_before, db.state.byte_size.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
}

// ---- Test 4: compact 后 meta 已写入 — reopen 数据可读 ----
// compact 写新 meta（dirt=0），reopen 后从 meta 恢复正确状态。
test "compact_strong: after compact, reopen — meta restored, data readable" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    {
        var db = try cube.Db.open(alloc, s, .{});
        // 写入 + 覆写产生脏页
        try db.put("k1", "v1");
        try db.put("k2", "v2");
        try db.put("k1", "override"); // 覆写产生脏页
        try db.compact();
        try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
        db.close();
    }

    // Reopen — meta 应恢复正确 root/sequence/entry_count
    var db2 = try cube.Db.open(alloc, s, .{});
    defer db2.close();

    try std.testing.expectEqual(@as(u64, 2), db2.entryCount());
    try std.testing.expectEqual(@as(u64, 0), db2.dirtCount());

    // k1 应为覆写后的值
    const v1 = try db2.get("k1");
    try std.testing.expectEqualStrings("override", v1.?);
    alloc.free(v1.?);

    // k2 不受覆写影响
    const v2 = try db2.get("k2");
    try std.testing.expectEqualStrings("v2", v2.?);
    alloc.free(v2.?);
}

// ---- Test 5: compact 多次覆写后 pendingFree 积累 → reader 中 compact → endRead 清空 ----
// 更复杂场景：多次覆写在 reader 持续期间产生多批 pendingFree
test "compact_strong: multiple overwrites during reader — compact clears dirt, endRead clears pages" {
    var ms = newStore();
    defer ms.deinit();
    var db = try cube.Db.open(alloc, ms.store(), .{});
    defer db.close();

    try db.put("k", "v0");
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());

    _ = db.beginRead();

    // 多次覆写（每次产生脏页，pending_free 积累）
    try db.put("k", "v1");
    const dirt_after_v1 = db.dirtCount();
    const pending_after_v1 = db.state.pendingFreeCount();
    try std.testing.expect(dirt_after_v1 > 0);
    try std.testing.expect(pending_after_v1 > 0);

    try db.put("k", "v2");
    try std.testing.expect(db.dirtCount() > 0);
    try std.testing.expect(db.state.pendingFreeCount() > pending_after_v1);

    // compact：清 dirt 但不清 pendingFree
    try db.compact();
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
    try std.testing.expect(db.state.pendingFreeCount() > 0);

    // 再覆写 → dirt 再次 > 0（compact 清了计数但页没回收）
    try db.put("k", "v3");
    try std.testing.expect(db.dirtCount() > 0);

    // 第二次 compact
    try db.compact();
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
    try std.testing.expect(db.state.pendingFreeCount() > 0);

    // 数据正确
    const v = try db.get("k");
    try std.testing.expectEqualStrings("v3", v.?);
    alloc.free(v.?);

    // reader 结束 → flush 所有积压
    _ = db.endRead();
    try std.testing.expectEqual(@as(usize, 0), db.state.pendingFreeCount());
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
}

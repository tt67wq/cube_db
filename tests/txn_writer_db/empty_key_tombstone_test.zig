//! T-57 RED — 空 key（`""`）在区间墓碑库上**不得**遮蔽无关 key。
//!
//! 由 conductor 预写（TDD 纪律：先红后绿）。**实现者不得修改本文件**
//! （门会校验其 blob 哈希与 RED 提交一致）。
//!
//! 背景：`src/format.zig` 的 `TombBound{bytes, append_zero}` 用「存 len 0、无 flag」
//! 表示 `null`（无界），而空 key 端点 `{bytes:"", append_zero:false}` 的编码与之**完全相同**。
//! 给空 key 打洞时留下的 `[min, "")` 段（max 界 = 空 key）解码后变成 `[min, null)` = 全库，
//! 于是 `put("")` 使**所有**已存在 key 不可见，而 `entryCount()` 仍报真实条数。

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const dbi = cube.db;

fn open(ms: *ps.MemPageStore) !*dbi.Db {
    return dbi.Db.open(std.testing.allocator, ms.store(), .{});
}

/// 收集 `select(null, null)` 可见的 key 数（迭代器由调用方 deinit）。
fn visibleCount(db: *dbi.Db) !usize {
    var it = try db.select(null, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    return n;
}

fn expectVisible(db: *dbi.Db, key: []const u8) !void {
    const v = try db.get(key);
    defer if (v) |x| std.testing.allocator.free(x);
    try std.testing.expect(v != null);
}

/// 构造「已有区间墓碑 + 已打洞的 key」的库：aaa/bbb 被 deleteRange 全删，ccc/ddd 重新可见。
fn setupTombstoned(ms: *ps.MemPageStore) !*dbi.Db {
    var db = try open(ms);
    errdefer db.close();
    try db.put("aaa", "1");
    try db.put("bbb", "2");
    try db.deleteRange(null, null);
    try db.put("ccc", "3");
    try db.put("ddd", "4");
    return db;
}

// =====================================================================
// 核心 RED：put("") 不得遮蔽已存在 key
// =====================================================================

test "T-57 e1: put(empty key) must not shadow unrelated existing keys" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    var db = try setupTombstoned(&ms);
    defer db.close();

    // 前置守卫：打洞后 ccc/ddd 必须可见
    try expectVisible(db, "ccc");
    try expectVisible(db, "ddd");

    try db.put("", "");

    // 💥 当前实现：ccc/ddd 全部不可见
    try expectVisible(db, "ccc");
    try expectVisible(db, "ddd");
}

test "T-57 e2: entryCount must agree with the number of visible keys after put(empty)" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    var db = try setupTombstoned(&ms);
    defer db.close();

    try db.put("", "");

    const visible = try visibleCount(db);
    // 物理条数（ccc/ddd/"" 三条）必须与可见条数一致 —— 两个口径不得背离
    try std.testing.expectEqual(@as(u64, 3), db.entryCount());
    try std.testing.expectEqual(@as(usize, 3), visible);
}

test "T-57 e3: put(empty key) shadowing must not survive close+reopen" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();

    {
        var db = try setupTombstoned(&ms);
        defer db.close();
        try db.put("", "");
    }

    var db = try open(&ms);
    defer db.close();
    try expectVisible(db, "ccc");
    try expectVisible(db, "ddd");
    try std.testing.expectEqual(@as(u64, 3), db.entryCount());
}

// =====================================================================
// 守卫：以下两条在 main 上本就应当绿（防止修复引入新问题）
// =====================================================================

test "T-57 e4 (guard): put(empty key) on a tombstone-free db is harmless" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    var db = try open(&ms);
    defer db.close();

    try db.put("aaa", "1");
    try db.put("bbb", "2");
    try db.put("", "");

    try expectVisible(db, "aaa");
    try expectVisible(db, "bbb");
    try std.testing.expectEqual(@as(u64, 3), db.entryCount());
}

test "T-57 e5 (guard): deleteRange with an empty upper bound is a no-op" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    var db = try open(&ms);
    defer db.close();

    try db.put("aaa", "1");
    try db.put("bbb", "2");
    // [aaa, "") 是空区间（没有 key 小于空 key 且 >= "aaa"）→ 必须零副作用
    try db.deleteRange("aaa", "");

    try expectVisible(db, "aaa");
    try expectVisible(db, "bbb");
    try std.testing.expectEqual(@as(u64, 2), db.entryCount());
}

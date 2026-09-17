//! range_tombstone_read_test.zig — T-38-2 阶段 2（读路径墓碑遮蔽）RED 测试（pi-3，测试者）
//!
//! 契约：.agents/tasks/T-38-2/task.md「验收②」的 10 条场景，编号一一对应。
//! 设计依据：docs/design/T-38-range-tombstone-probe.md §3.1（遮蔽判定：
//!   min 含 / max 不含 / 纯空间判定，无 seq 比较）、§1.4（append_zero = succ(k)）、
//!   §1.2（链页 free_next）。
//!
//! 本文件是 TDD RED：阶段 2（读路径接入遮蔽）未实现，本 step 必须失败。
//! RED 类型=断言失败（编译通过——只用现有公开 API + 阶段 1 的
//! f2.encodeTombPage / f2.MetaPage.tomb_head 构造库状态）。
//!
//! 构造方式（不经写路径，契约指定）：MemPageStore 上开库 → putDirect 数据 →
//! close → 在 ms.next_free 起手工写墓碑链页（f2.encodeTombPage）→ 改写 meta
//! 为 v3（tomb_head=链头，sequence+1 走交替槽取高）→ 重新 Db.open。
//! 墓碑页从 ms.next_free 起编号并同步递增，避免与 freelist / 后续分配冲突
//! （本测试注入后只读；唯一的写事务是 put+abort，abort 不落页）。
//!
//! 10 条场景（契约验收②）：
//!  1 点查遮蔽（区间内 null / 区间外原值）
//!  2 半开边界 [min,max)：min 含、max 不含（get 与 select 一致）
//!  3 无界：min=null / max=null / 双 null（全库遮蔽）
//!  4 select 跳过被遮蔽 key，且输出与逐 key get 判定一致
//!  5 getInto 遮蔽：null 且 buffer 未被写
//!  6 append_zero 边界：succ(k)=k++0x00 作 min/max 的含/不含语义
//!  7 多页链（free_next 串 ≥2 页）跨页遮蔽
//!  8 tomb_head==0 短路：无墓碑库行为不变（回归守卫，RED 期应绿）
//!  9 ReadTxn 路径：beginReadTxn 后 get/getInto/select 同样遮蔽；写事务流产不泄漏
//! 10 损坏传播：墓碑链页 CRC 翻转 → 读路径 error.CorruptCrc，不得静默当无墓碑

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const wrt = cube.writer;
const dbi = cube.db;
const btree = cube.btree;
const f2 = cube.format;

const alloc = std.testing.allocator;

// ===== 构造工具 =====

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 10000);
}

fn tomb(min: ?[]const u8, max: ?[]const u8) f2.RangeTombstone {
    return .{
        .min = if (min) |m| .{ .bytes = m } else null,
        .max = if (max) |m| .{ .bytes = m } else null,
    };
}


/// 基础数据集：8 个 key（含 append_zero 语义所需的 b\0 / c\0 邻界 key）。
const all_keys = [_][]const u8{ "a", "b", "b\x00", "ba", "c", "c\x00", "d", "e" };

fn putAll(db: *dbi.Db) !void {
    for (all_keys) |k| try db.putDirect(k, "v");
}

/// 关库后注入墓碑链（1~2 页，free_next 串接）+ meta v3（tomb_head=链头，
/// sequence+1）。返回链头页号。不重开库——caller 自行 Db.open。
fn injectTombs(ms: *ps.MemPageStore, tobs1: []const f2.RangeTombstone, tobs2: []const f2.RangeTombstone) !u32 {
    const s = ms.store();
    var meta = (try s.readMeta()).?;
    const p1: u32 = ms.next_free;
    ms.next_free += 1;
    var p2: u32 = 0;
    {
        const buf = try s.writePage(p1);
        if (tobs2.len > 0) {
            p2 = ms.next_free;
            ms.next_free += 1;
        }
        try f2.encodeTombPage(buf[0..f2.PAGE_SIZE], p1, tobs1, meta.sequence + 1, p2);
    }
    if (tobs2.len > 0) {
        const buf = try s.writePage(p2);
        try f2.encodeTombPage(buf[0..f2.PAGE_SIZE], p2, tobs2, meta.sequence + 1, 0);
    }
    meta.version = 3;
    meta.tomb_head = p1;
    meta.sequence += 1;
    try s.writeMeta(&meta);
    return p1;
}

/// 开库+写数据+关库 → 注入墓碑 → 重开。返回重开的 Db（caller close）。
fn openWithTombs(ms: *ps.MemPageStore, opts: wrt.Options, tobs1: []const f2.RangeTombstone, tobs2: []const f2.RangeTombstone) !*dbi.Db {
    {
        var db = try dbi.Db.open(alloc, ms.store(), opts);
        defer db.close();
        try putAll(db);
    }
    _ = try injectTombs(ms, tobs1, tobs2);
    return try dbi.Db.open(alloc, ms.store(), opts);
}

// ===== 断言工具（free 纪律：即使断言失败也不泄漏，RED 输出保持干净的断言失败） =====

fn expectShadowed(db: *dbi.Db, key: []const u8) !void {
    const v = try db.get(key);
    defer if (v) |s| alloc.free(s);
    try std.testing.expectEqual(@as(?[]u8, null), v); // 墓碑覆盖 → 当不存在
}

fn expectVisible(db: *dbi.Db, key: []const u8) !void {
    const v = try db.get(key);
    defer if (v) |s| alloc.free(s);
    try std.testing.expect(v != null);
    if (v) |s| try std.testing.expectEqualStrings("v", s);
}

/// select 结果收集（key dupe 保序）。caller 负责 deinit + 逐项 free。
fn collectKeys(it: *btree.Iterator) !std.ArrayList([]const u8) {
    var got = std.ArrayList([]const u8).empty;
    errdefer {
        for (got.items) |g| alloc.free(g);
        got.deinit(alloc);
    }
    while (try it.next()) |e| {
        try got.append(alloc, try alloc.dupe(u8, e.key));
    }
    return got;
}

fn freeKeys(got: *std.ArrayList([]const u8)) void {
    for (got.items) |g| alloc.free(g);
    got.deinit(alloc);
}

fn containsKey(got: []const []const u8, key: []const u8) bool {
    for (got) |g| if (std.mem.eql(u8, g, key)) return true;
    return false;
}

// =====================================================================
// 场景 1：点查遮蔽 —— 区间内 key → null；区间外 → 原值
// =====================================================================

test "T-38-2 s1: point get shadowed inside [min,max), visible outside" {
    var ms = newStore();
    defer ms.deinit();
    var db = try openWithTombs(&ms, .{}, &.{tomb("b", "d")}, &.{});
    defer db.close();

    // 区间内（含 min、区间中部、min 的邻界延伸 key）
    try expectShadowed(db, "b"); // min 含
    try expectShadowed(db, "ba"); // 区间中部
    try expectShadowed(db, "c"); // 区间中部
    // 区间外
    try expectVisible(db, "a"); // < min
    try expectVisible(db, "d"); // max 不含
    try expectVisible(db, "e"); // > max
}

// =====================================================================
// 场景 2：半开边界 [min,max) —— min 被遮蔽、max 不被遮蔽（get 与 select 一致）
// =====================================================================

test "T-38-2 s2: half-open boundary — min covered, max not (get and select agree)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try openWithTombs(&ms, .{}, &.{tomb("b", "d")}, &.{});
    defer db.close();

    try expectShadowed(db, "b"); // min 侧：含
    try expectVisible(db, "d"); // max 侧：不含

    // select 边界与 get 一致：select("b","d") 吐出 b\0、ba（b、c 被遮蔽）
    var it = try db.select("b", "d");
    defer it.deinit();
    var got = try collectKeys(&it);
    defer freeKeys(&got);
    try std.testing.expectEqual(@as(usize, 2), got.items.len);
    try std.testing.expectEqualStrings("b\x00", got.items[0]);
    try std.testing.expectEqualStrings("ba", got.items[1]);
}

// =====================================================================
// 场景 3：无界 —— min=null（负无穷）/ max=null（正无穷）/ 双 null（全库遮蔽）
// =====================================================================

test "T-38-2 s3a: unbounded min (null = -inf)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try openWithTombs(&ms, .{}, &.{tomb(null, "c")}, &.{});
    defer db.close();

    try expectShadowed(db, "a");
    try expectShadowed(db, "b");
    try expectVisible(db, "c"); // max 不含
    try expectVisible(db, "d");
    try expectVisible(db, "e");
}

test "T-38-2 s3b: unbounded max (null = +inf)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try openWithTombs(&ms, .{}, &.{tomb("c", null)}, &.{});
    defer db.close();

    try expectVisible(db, "a");
    try expectVisible(db, "b");
    try expectShadowed(db, "c"); // min 含
    try expectShadowed(db, "d");
    try expectShadowed(db, "e");
}

test "T-38-2 s3c: both bounds null — whole-db shadowed, select empty" {
    var ms = newStore();
    defer ms.deinit();
    var db = try openWithTombs(&ms, .{}, &.{tomb(null, null)}, &.{});
    defer db.close();

    for (all_keys) |k| try expectShadowed(db, k);
    var it = try db.select(null, null);
    defer it.deinit();
    var got = try collectKeys(&it);
    defer freeKeys(&got);
    try std.testing.expectEqual(@as(usize, 0), got.items.len); // 全库遮蔽 → 空
}

// =====================================================================
// 场景 4：select 跳过被遮蔽 key；输出与「逐 key get 判定」一致
// =====================================================================

test "T-38-2 s4: select skips shadowed keys and agrees with per-key get" {
    var ms = newStore();
    defer ms.deinit();
    var db = try openWithTombs(&ms, .{}, &.{tomb("b", "d")}, &.{});
    defer db.close();

    var it = try db.select(null, null);
    defer it.deinit();
    var got = try collectKeys(&it);
    defer freeKeys(&got);

    // 直接断言：被遮蔽的 key 不得出现（b、b\0、ba、c 都在 [b,d) 内）
    try std.testing.expect(!containsKey(got.items, "b"));
    try std.testing.expect(!containsKey(got.items, "b\x00"));
    try std.testing.expect(!containsKey(got.items, "ba"));
    try std.testing.expect(!containsKey(got.items, "c"));
    // 一致性断言：数据集每个 key，「get 可见 ⟺ select 吐出」
    for (all_keys) |k| {
        const v = try db.get(k);
        defer if (v) |s| alloc.free(s);
        try std.testing.expectEqual(v != null, containsKey(got.items, k));
    }
    // 剩余可见集（有序）：a、d、e
    try std.testing.expectEqual(@as(usize, 3), got.items.len);
    try std.testing.expectEqualStrings("a", got.items[0]);
    try std.testing.expectEqualStrings("d", got.items[1]);
    try std.testing.expectEqualStrings("e", got.items[2]);
}

// =====================================================================
// 场景 5：getInto 遮蔽 —— 返回 null 且 buffer 未被写
// =====================================================================

test "T-38-2 s5: getInto shadowed — null and buffer untouched" {
    var ms = newStore();
    defer ms.deinit();
    var db = try openWithTombs(&ms, .{}, &.{tomb("b", "d")}, &.{});
    defer db.close();

    // 被遮蔽 → null + buffer 原样（0xAA 哨兵不动）
    var buf: [16]u8 = undefined;
    @memset(&buf, 0xAA);
    const r = try db.getInto("c", &buf);
    try std.testing.expectEqual(@as(?usize, null), r);
    for (buf) |b| try std.testing.expectEqual(@as(u8, 0xAA), b);

    // 未遮蔽 → 正常（值 "v"、长度 1）
    @memset(&buf, 0xAA);
    const r2 = try db.getInto("d", &buf);
    try std.testing.expectEqual(@as(?usize, 1), r2);
    try std.testing.expectEqual(@as(u8, 'v'), buf[0]);
}

// =====================================================================
// 场景 6：append_zero 边界 —— succ(k)=k++0x00 作 min/max 的含/不含语义
// =====================================================================

test "T-38-2 s6: append_zero bounds — [succ(b), succ(c)) semantics" {
    var ms = newStore();
    defer ms.deinit();
    // 墓碑 [succ("b"), succ("c")) = ["b\0", "c\0")：双侧 append_zero 紧凑边界
    // （succ(k) = k ++ 0x00，> k 的最短字节串，设计 §1.4）
    const tobs = [_]f2.RangeTombstone{
        .{ .min = .{ .bytes = "b", .append_zero = true }, .max = .{ .bytes = "c", .append_zero = true } },
    };
    var db = try openWithTombs(&ms, .{}, &tobs, &.{});
    defer db.close();

    // min = succ("b")：b 不含（b < b\0）、b\0 含、ba 含（b\0 < ba < c\0）
    try expectVisible(db, "b");
    try expectShadowed(db, "b\x00");
    try expectShadowed(db, "ba");
    // max = succ("c")：c 含（c < c\0）、c\0 不含
    try expectShadowed(db, "c");
    try expectVisible(db, "c\x00");
    // 区间外
    try expectVisible(db, "a");
    try expectVisible(db, "d");

    // select 与 get 一致：可见集 = {a, b, c\0, d, e}
    var it = try db.select(null, null);
    defer it.deinit();
    var got = try collectKeys(&it);
    defer freeKeys(&got);
    try std.testing.expectEqual(@as(usize, 5), got.items.len);
    try std.testing.expectEqualStrings("a", got.items[0]);
    try std.testing.expectEqualStrings("b", got.items[1]);
    try std.testing.expectEqualStrings("c\x00", got.items[2]);
    try std.testing.expectEqualStrings("d", got.items[3]);
    try std.testing.expectEqualStrings("e", got.items[4]);
}

// =====================================================================
// 场景 7：多页链 —— 墓碑链跨 ≥2 页（free_next 串联），跨页遮蔽正确
// =====================================================================

test "T-38-2 s7: multi-page tomb chain — shadowing across free_next pages" {
    var ms = newStore();
    defer ms.deinit();
    // 页 1：[a,b)；页 2：[c,d) + [db,dc)（两条，验证链尾页多条目）
    const page1 = [_]f2.RangeTombstone{tomb("a", "b")};
    const page2 = [_]f2.RangeTombstone{ tomb("c", "d"), tomb("db", "dc") };
    var db = try openWithTombs(&ms, .{}, &page1, &page2);
    defer db.close();

    // 页 1 的墓碑
    try expectShadowed(db, "a");
    try expectVisible(db, "b");
    // 页 2 的墓碑（链跨页后仍生效）
    try expectShadowed(db, "c");
    try expectShadowed(db, "c\x00");
    try expectVisible(db, "d"); // [c,d) 的 max 不含
    try expectShadowed(db, "db"); // 页 2 第 2 条
    try expectShadowed(db, "dba");
    try expectVisible(db, "dc"); // [db,dc) 的 max 不含
    try expectVisible(db, "e");

    // select 跨页一致：可见集 = {b, b\0, ba, d, dc, e}
    var it = try db.select(null, null);
    defer it.deinit();
    var got = try collectKeys(&it);
    defer freeKeys(&got);
    const want = [_][]const u8{ "b", "b\x00", "ba", "d", "dc", "e" };
    try std.testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| try std.testing.expectEqualStrings(w, g);
}

// =====================================================================
// 场景 8：tomb_head==0 短路 —— 无墓碑库行为不变（回归守卫，RED 期应绿）
// =====================================================================

test "T-38-2 s8: tomb_head==0 short-circuit — no behavior change without tombs" {
    var ms = newStore();
    defer ms.deinit();
    {
        var db = try dbi.Db.open(alloc, ms.store(), .{});
        defer db.close();
        try putAll(db);
    }
    // 显式断言：普通写路径产生 v2 meta、tomb_head=0
    const meta = (try ms.store().readMeta()).?;
    try std.testing.expectEqual(@as(u16, 2), meta.version);
    try std.testing.expectEqual(@as(u32, 0), meta.tomb_head);

    var db = try dbi.Db.open(alloc, ms.store(), .{});
    defer db.close();
    // 全部读路径照常
    for (all_keys) |k| try expectVisible(db, k);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 1), try db.getInto("a", &buf));
    var it = try db.select(null, null);
    defer it.deinit();
    var got = try collectKeys(&it);
    defer freeKeys(&got);
    try std.testing.expectEqual(all_keys.len, got.items.len);
    // ReadTxn 照常
    var txn = try db.beginReadTxn();
    defer txn.deinit();
    const v = try txn.get("a");
    defer if (v) |s| alloc.free(s);
    try std.testing.expect(v != null);
}

// =====================================================================
// 场景 9：ReadTxn 路径 —— beginReadTxn 后 get/getInto/select 同样遮蔽；
//         写事务流产不泄漏
// =====================================================================

test "T-38-2 s9: ReadTxn get/getInto/select shadowed; aborted write txn leaks nothing" {
    var ms = newStore();
    defer ms.deinit();
    var db = try openWithTombs(&ms, .{}, &.{tomb("b", "d")}, &.{});
    defer db.close();

    var txn = try db.beginReadTxn();
    defer txn.deinit();

    // get：遮蔽 → null；未遮蔽 → 值
    {
        const v = try txn.get("c");
        defer if (v) |s| alloc.free(s);
        try std.testing.expectEqual(@as(?[]u8, null), v);
    }
    {
        const v = try txn.get("d");
        defer if (v) |s| alloc.free(s);
        try std.testing.expect(v != null);
    }
    // getInto：遮蔽 → null + buffer 不动
    var buf: [16]u8 = undefined;
    @memset(&buf, 0xAA);
    try std.testing.expectEqual(@as(?usize, null), try txn.getInto("ba", &buf));
    for (buf) |b| try std.testing.expectEqual(@as(u8, 0xAA), b);
    // select：跳过被遮蔽
    var it = try txn.select(null, null);
    defer it.deinit();
    var got = try collectKeys(&it);
    defer freeKeys(&got);
    try std.testing.expectEqual(@as(usize, 3), got.items.len); // a、d、e
    try std.testing.expectEqualStrings("a", got.items[0]);
    try std.testing.expectEqualStrings("d", got.items[1]);
    try std.testing.expectEqualStrings("e", got.items[2]);

    // 写事务流产：put 后 abort，不落页、不泄漏（testing.allocator 兜底检测）
    var w = try db.beginWriteTxn();
    try w.put("zz", "vz");
    try w.abort();
    w.deinit();
    // 流产后墓碑仍生效、流产 key 不可见
    try expectShadowed(db, "c");
    try expectShadowed(db, "zz");
}

// =====================================================================
// 场景 10：损坏传播 —— 墓碑链页 CRC 翻转 → 读路径 error.CorruptCrc，
//          不得静默当无墓碑
// =====================================================================

test "T-38-2 s10: corrupted tomb page CRC propagates as error.CorruptCrc" {
    var ms = newStore();
    defer ms.deinit();
    {
        var db = try dbi.Db.open(alloc, ms.store(), .{});
        defer db.close();
        try putAll(db);
    }
    const p1 = try injectTombs(&ms, &.{tomb("c", "d")}, &.{});

    // 手工翻转墓碑页一字节（CRC 破坏）
    {
        const buf = try ms.store().writePage(p1);
        buf[f2.PAGE_HEADER_SIZE + 3] ^= 0x40;
    }

    var db = try dbi.Db.open(alloc, ms.store(), .{ .crc_check = .full });
    defer db.close();

    // 点查被遮蔽区间的 key：必须报 CorruptCrc（不得静默当无墓碑返回原值）
    if (db.get("c")) |maybe_v| {
        defer if (maybe_v) |s| alloc.free(s);
        try std.testing.expect(false); // RED：当前返回原值——应返回 error.CorruptCrc
    } else |e| {
        try std.testing.expectEqual(error.CorruptCrc, e);
    }
    // select 遮蔽区间：同样必须报错
    if (db.select("b", "e")) |it_res| {
        var it = it_res;
        defer it.deinit();
        var got = try collectKeys(&it);
        defer freeKeys(&got);
        try std.testing.expect(false); // RED：当前静默吐出——应返回 error.CorruptCrc
    } else |e| {
        try std.testing.expectEqual(error.CorruptCrc, e);
    }
}

// =====================================================================
// 缺口用例 G-6（spec-precheck HIGH）：链环防护 —— free_next 成环的墓碑链
// 必须返回 typed error，不得无限循环 / OOM / panic（盘上数据不可信，
// trust boundary）。测试若真 hang 会被超时判死——这正是要抓的形态。
// =====================================================================

test "T-38-2 g6: tomb chain cycle (free_next ring) must error, not hang" {
    var ms = newStore();
    defer ms.deinit();
    {
        var db = try dbi.Db.open(alloc, ms.store(), .{});
        defer db.close();
        try putAll(db);
    }
    // 手工构造环：p1 → p2 → p1（两页 CRC 均合法，只是链成环）
    const s = ms.store();
    var meta = (try s.readMeta()).?;
    const p1: u32 = ms.next_free;
    ms.next_free += 1;
    const p2: u32 = ms.next_free;
    ms.next_free += 1;
    {
        const buf = try s.writePage(p1);
        try f2.encodeTombPage(buf[0..f2.PAGE_SIZE], p1, &.{tomb("c", "d")}, meta.sequence + 1, p2);
    }
    {
        const buf = try s.writePage(p2);
        try f2.encodeTombPage(buf[0..f2.PAGE_SIZE], p2, &.{tomb("a", "b")}, meta.sequence + 1, p1); // 指回 p1 = 环
    }
    meta.version = 3;
    meta.tomb_head = p1;
    meta.sequence += 1;
    try s.writeMeta(&meta);

    var db = try dbi.Db.open(alloc, ms.store(), .{});
    defer db.close();

    // 点查被墓碑覆盖的 key：必须以 error 返回（任意 typed error 均可），
    // 不得返回原值、不得挂起（挂起 = 测试超时死亡，同样是失败）
    if (db.get("c")) |maybe_v| {
        defer if (maybe_v) |s2| alloc.free(s2);
        try std.testing.expect(false); // RED：当前返回原值——应返回 typed error
    } else |_| {} // 任意 error 可接受（Truncated / CorruptCrc / 专用错误名均可）

    // select 全区间同样不得挂起：必须以 error 返回
    if (db.select(null, null)) |it_res| {
        var it = it_res;
        defer it.deinit();
        var got = try collectKeys(&it);
        defer freeKeys(&got);
        try std.testing.expect(false); // RED：当前静默吐出——应返回 typed error
    } else |_| {}
}

// =====================================================================
// 缺口用例 G-9（spec-precheck LOW）：乱序链 —— 墓碑链不按 min 排序
// （排序是阶段 3 写入者的义务，格式层不强制；手工注入可以无序）。
// 读路径必须按线性扫描语义判定，不得假设链/条目有序。
// =====================================================================

test "T-38-2 g9: out-of-order tomb chain — linear scan semantics" {
    var ms = newStore();
    defer ms.deinit();
    // 页 1 内部乱序（min 降序：[d,e) 在 [a,b) 前）；
    // 页 2 的 min ("ba") 又小于页 1 两条 —— 跨页也乱序。
    const page1 = [_]f2.RangeTombstone{ tomb("d", "e"), tomb("a", "b") };
    const page2 = [_]f2.RangeTombstone{tomb("ba", "c")};
    var db = try openWithTombs(&ms, .{}, &page1, &page2);
    defer db.close();

    // [a,b)：a 遮蔽、b 可见
    try expectShadowed(db, "a");
    try expectVisible(db, "b");
    // [ba,c)：b\0 可见（< ba）、ba 遮蔽、c 遮蔽、c\0 可见
    try expectVisible(db, "b\x00");
    try expectShadowed(db, "ba");
    try expectShadowed(db, "c");
    try expectVisible(db, "c\x00");
    // [d,e)：d 遮蔽、e 可见
    try expectShadowed(db, "d");
    try expectVisible(db, "e");

    // select 与逐 get 一致：可见集 = {b, b\0, c\0, e}
    var it = try db.select(null, null);
    defer it.deinit();
    var got = try collectKeys(&it);
    defer freeKeys(&got);
    const want = [_][]const u8{ "b", "b\x00", "c\x00", "e" };
    try std.testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| try std.testing.expectEqualStrings(w, g);
}

// =====================================================================
// 缺口用例 G-10（spec-precheck LOW）：空键边界 —— effective "\x00"
// （= succ("")，紧凑表示 Bound{bytes="", append_zero=true}）作 min/max
// 对空键 "" 的含/不含语义（设计 §1.4：len=0 且有标志 ≠ null）。
// =====================================================================

test "T-38-2 g10: empty-key boundary — effective NUL (0x00) min/max vs empty key" {
    // (a) min = succ("") = "\x00"（effective）：["\x00", null) —— "" 不含、"\x00" 含
    {
        var ms = newStore();
        defer ms.deinit();
        {
            var db = try dbi.Db.open(alloc, ms.store(), .{});
            defer db.close();
            try db.putDirect("", "v"); // 空键合法（checkKeySize 只限上界）
            try db.putDirect("\x00", "v");
            try db.putDirect("a", "v");
        }
        const tobs = [_]f2.RangeTombstone{
            .{ .min = .{ .bytes = "", .append_zero = true }, .max = null },
        };
        var db = try openWithTombs(&ms, .{}, &tobs, &.{});
        defer db.close();

        try expectVisible(db, ""); // "" < "\x00" → 不含（min 含但 ""≠"\x00"）
        try expectShadowed(db, "\x00"); // 恰等于 effective min → 含
        try expectShadowed(db, "a"); // > "\x00" → 含
    }

    // (b) max = succ("") = "\x00"（effective）：[null, "\x00") —— "" 含、"\x00" 不含
    {
        var ms = newStore();
        defer ms.deinit();
        {
            var db = try dbi.Db.open(alloc, ms.store(), .{});
            defer db.close();
            try db.putDirect("", "v-empty");
            try db.putDirect("\x00", "v");
            try db.putDirect("a", "v");
        }
        const tobs = [_]f2.RangeTombstone{
            .{ .min = null, .max = .{ .bytes = "", .append_zero = true } },
        };
        var db = try openWithTombs(&ms, .{}, &tobs, &.{});
        defer db.close();

        try expectShadowed(db, ""); // "" < "\x00"（max 不含端点本身）→ 含
        try expectVisible(db, "\x00"); // 恰等于 effective max → 不含
        try expectVisible(db, "a"); // > "\x00" → 不含
    }
}

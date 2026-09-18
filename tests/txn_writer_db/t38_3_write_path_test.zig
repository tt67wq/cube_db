//! t38_3_write_path_test.zig — T-38 阶段 3（写路径）RED 测试（conductor 编写）
//!
//! 契约：.agents/tasks/T-38-3/task.md「必须实现的行为」C1 / C3 / C4 / C5。
//! 设计依据：docs/design/T-38-range-tombstone-probe.md §4.1（新 deleteRange 流程）、
//!   §2（version 2→3 策略）、§3.1（entryCount 流式修正）、§4.4（幂等）、
//!   §5（崩溃安全：链页 CRC 失败 = error.CorruptCrc，不得静默当无墓碑）。
//!
//! 本文件是 TDD RED：阶段 3 写路径未实现，本 step 必须失败。
//! RED 类型 = **断言失败**（编译通过——只用现有公开 API + 阶段 1 的
//! f2.encodeTombPage / f2.MetaPage.tomb_head / f2.decodeTombPage）。
//!
//! 关键设计：本测试**只走公开 Db API**（put / deleteRange / get / select /
//! entryCount / close+reopen），不手工注入墓碑页——手工注入是阶段 2 的
//! 构造方式（那时写路径不存在）。阶段 3 要验的恰恰是「deleteRange 自己
//! 建出墓碑链并落盘」。落盘性用 **close → 重开 → 语义保持** 来验。
//!
//! 用例（a1..a10）：
//!   a1 墓碑链真的建出来了：deleteRange 后 tomb_head != 0 且 meta.version == 3
//!   a2 重开后遮蔽保持（落盘实证，非仅内存态）
//!   a3 entryCount 精确（三口径一致：entryCount / select / get）
//!   a4 version 策略：普通 put 不升级（v2 库保持 2）；首次 deleteRange 升到 3；v3 上 put 保持 3
//!   a5 幂等：同区间重复删，entryCount 不再变、语义不变
//!   a6 无墓碑路径零行为变化（回归门：纯 put/delete 库 version 仍为 2、tomb_head==0）
//!   a7 打洞：deleteRange 后 put 回区间内 key → 该 key 活；区间内其它 key 仍被遮蔽
//!   a8 打洞右段不丢（F1）：近-MAX key 打洞后，建碑前已存在且被删的 key 不得复活
//!   a9 空/倒置区间 no-op 且**零副作用**（不建墓碑、不改 version、不 flush）
//!  a10 链页 CRC 翻转 → 读路径 error.CorruptCrc（不得静默当无墓碑）

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const wrt = cube.writer;
const dbi = cube.db;
const f2 = cube.format;

const alloc = std.testing.allocator;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 10000);
}

/// 默认选项：micro_batch 关闭，让每次 put 直接落 commit（便于断言 version/sequence）。
fn opts() wrt.Options {
    return .{ .micro_batch = .{ .batch_threshold = 0 } };
}

/// 读当前 meta（取高 sequence 槽，与 readMetaPage 同口径）。
fn readMeta(ms: *ps.MemPageStore) !f2.MetaPage {
    return (try ms.store().readMeta()).?;
}

// =====================================================================
// a1 — deleteRange 必须建出墓碑链并落盘（tomb_head != 0, version == 3）
// =====================================================================
test "T-38-3 a1: deleteRange writes a tombstone chain (tomb_head!=0) and switches meta to v3" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    for ([_][]const u8{ "a", "b", "c", "d", "e" }) |k| try db.putDirect(k, "v");

    // 建碑前：无墓碑、version 仍是 2
    {
        const m = try readMeta(&ms);
        try std.testing.expectEqual(@as(u32, 0), m.tomb_head);
        try std.testing.expectEqual(@as(u16, 2), m.version);
    }

    try db.deleteRange("b", "d"); // 删 b, c

    // 建碑后：墓碑链头非 0、version 升到 3
    {
        const m = try readMeta(&ms);
        if (m.tomb_head == 0) {
            std.debug.print("\nRED: deleteRange did not write a tombstone chain (tomb_head==0) — stage 3 write path missing\n", .{});
            return error.NoTombChainWritten;
        }
        if (m.version != 3) {
            std.debug.print("\nRED: meta.version={d}, expected 3 after first tombstone write\n", .{m.version});
            return error.VersionNotUpgraded;
        }
    }
}

// =====================================================================
// a2 — 重开后遮蔽保持（落盘实证：墓碑真的在盘上，不是内存态）
// =====================================================================
test "T-38-3 a2: tombstone survives close+reopen (masking is persisted, not in-memory only)" {
    var ms = newStore();
    defer ms.deinit();
    {
        var db = try dbi.Db.open(alloc, ms.store(), opts());
        defer db.close();
        for ([_][]const u8{ "a", "b", "c", "d", "e" }) |k| try db.putDirect(k, "v");
        try db.deleteRange("b", "d"); // 删 b, c
    }
    // 重开：b/c 必须仍被遮蔽（阶段 2 遗留：任何 commit 会把 meta 重写回 v2 → 丢墓碑）
    {
        var db = try dbi.Db.open(alloc, ms.store(), opts());
        defer db.close();
        {
            const ga = try db.get("a");
            try std.testing.expect(ga != null);
            if (ga) |v| alloc.free(v);
        }
        const gb = try db.get("b");
        if (gb != null) {
            std.debug.print("\nRED: 'b' resurrected after reopen — tombstone lost on commit (stage-2 known limitation)\n", .{});
            alloc.free(gb.?);
            return error.TombstoneLostOnReopen;
        }
        const gc = try db.get("c");
        if (gc != null) {
            std.debug.print("\nRED: 'c' resurrected after reopen\n", .{});
            alloc.free(gc.?);
            return error.TombstoneLostOnReopen;
        }
        const gd = try db.get("d");
        try std.testing.expect(gd != null); // d 在区间外，必须活
        if (gd) |v| alloc.free(v);
    }
}

// =====================================================================
// a3 — entryCount 精确：三口径一致（entryCount / select / get）
// =====================================================================
test "T-38-3 a3: entryCount is exact after deleteRange (entryCount == select count == get count)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    var keys: [20][]const u8 = undefined;
    const letters = "abcdefghijklmnopqrst";
    for (0..20) |i| {
        keys[i] = try alloc.dupe(u8, letters[i .. i + 1]);
        try db.putDirect(keys[i], "v");
    }
    defer for (keys) |k| alloc.free(k);

    try std.testing.expectEqual(@as(u64, 20), db.entryCount());

    // 删 [e, o) = e f g h i j k l m n = 10 个
    try db.deleteRange("e", "o");
    const after = db.entryCount();
    if (after != 10) {
        std.debug.print("\nRED: entryCount={d} after deleting 10 in-range keys, expected 10\n", .{after});
        return error.EntryCountInexact;
    }

    // select 口径
    var it = try db.select(null, null);
    defer it.deinit();
    var n: u64 = 0;
    while (try it.next()) |_| n += 1;
    try std.testing.expectEqual(@as(u64, 10), n);

    // get 口径（逐 key 判定与 select 一致）
    var alive: u64 = 0;
    for (keys) |k| {
        if (try db.get(k)) |v| {
            alive += 1;
            alloc.free(v);
        }
    }
    try std.testing.expectEqual(@as(u64, 10), alive);
}

// =====================================================================
// a4 — version 策略：普通写不升级；首次 deleteRange 升到 3；v3 上普通写保持 3
// =====================================================================
test "T-38-3 a4: version policy — plain writes keep v2, first deleteRange upgrades to 3" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    // v2 库上大量普通写：version 必须保持 2（避免无关写触发全库升级）
    for ([_][]const u8{ "a", "b", "c", "d", "e", "f", "g" }) |k| try db.putDirect(k, "v");
    try db.deleteDirect("g");
    {
        const m = try readMeta(&ms);
        if (m.version != 2) {
            std.debug.print("\nRED: plain writes upgraded meta.version to {d}, expected 2 (no tombstone yet)\n", .{m.version});
            return error.UnrelatedWriteUpgradedVersion;
        }
    }

    // 首次 deleteRange → 升到 3
    try db.deleteRange("b", "d");
    {
        const m = try readMeta(&ms);
        if (m.version != 3) {
            std.debug.print("\nRED: first deleteRange did not upgrade meta.version (got {d}, want 3)\n", .{m.version});
            return error.VersionNotUpgraded;
        }
    }

    // v3 库上普通写：保持 3（不得回退到 2 —— 回退即丢墓碑）
    try db.putDirect("h", "v");
    try db.deleteDirect("h");
    {
        const m = try readMeta(&ms);
        if (m.version != 3) {
            std.debug.print("\nRED: plain write on a v3 db reset meta.version to {d}, expected 3 (tombstone would be lost)\n", .{m.version});
            return error.VersionDowngraded;
        }
        if (m.tomb_head == 0) {
            std.debug.print("\nRED: plain write on a v3 db cleared tomb_head\n", .{});
            return error.TombHeadCleared;
        }
    }
}

// =====================================================================
// a5 — 幂等：同区间重复删，entryCount 不再变、语义不变
// =====================================================================
test "T-38-3 a5: repeated deleteRange on the same range is idempotent" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    for ([_][]const u8{ "a", "b", "c", "d", "e", "f" }) |k| try db.putDirect(k, "v");

    try db.deleteRange("b", "e"); // 删 b,c,d → 剩 a,e,f = 3
    const c1 = db.entryCount();
    try std.testing.expectEqual(@as(u64, 3), c1);

    try db.deleteRange("b", "e"); // 第二次：in-range 在场 key = 0
    const c2 = db.entryCount();
    if (c2 != c1) {
        std.debug.print("\nRED: repeated deleteRange changed entryCount {d} -> {d} (not idempotent)\n", .{ c1, c2 });
        return error.NotIdempotent;
    }

    try db.deleteRange("b", "e"); // 第三次
    try std.testing.expectEqual(c1, db.entryCount());

    // 语义不变
    {
        const ga = try db.get("a");
        try std.testing.expect(ga != null);
        if (ga) |v| alloc.free(v);
    }
    {
        const ge = try db.get("e");
        try std.testing.expect(ge != null);
        if (ge) |v| alloc.free(v);
    }
    const gb = try db.get("b");
    try std.testing.expect(gb == null);
    if (gb) |v| alloc.free(v);
}

// =====================================================================
// a6 — 无墓碑路径零行为变化（回归门）
// =====================================================================
test "T-38-3 a6: no-tombstone path is byte-for-byte unchanged (version stays 2, tomb_head stays 0)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    for ([_][]const u8{ "a", "b", "c", "d", "e" }) |k| try db.putDirect(k, "v");
    try db.deleteDirect("c");
    try db.putDirect("f", "v");

    const m = try readMeta(&ms);
    if (m.version != 2) {
        std.debug.print("\nRED: no-tombstone library has meta.version={d}, expected 2 (regression gate)\n", .{m.version});
        return error.VersionChangedWithoutTombstone;
    }
    if (m.tomb_head != 0) {
        std.debug.print("\nRED: no-tombstone library has tomb_head={d}, expected 0 (regression gate)\n", .{m.tomb_head});
        return error.TombHeadSetWithoutTombstone;
    }

    // 语义：a,b,d,e,f 活；c 死  （put a..e + put f = 6，delete c → 5 活）
    try std.testing.expect((try db.get("c")) == null);
    for ([_][]const u8{ "a", "b", "d", "e", "f" }) |k| {
        const v = try db.get(k);
        try std.testing.expect(v != null);
        if (v) |vv| alloc.free(vv);
    }
    try std.testing.expectEqual(@as(u64, 5), db.entryCount());
}

// =====================================================================
// a9 — 空/倒置区间 no-op 且零副作用
// =====================================================================
test "T-38-3 a9: empty/inverted range is a no-op with zero side effects" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    for ([_][]const u8{ "a", "b", "c" }) |k| try db.putDirect(k, "v");
    const seq_before = (try readMeta(&ms)).sequence;

    try db.deleteRange("b", "b"); // 空区间
    try db.deleteRange("z", "a"); // 倒置
    try db.deleteRange("c", "b"); // 倒置

    const m = try readMeta(&ms);
    if (m.tomb_head != 0) {
        std.debug.print("\nRED: empty/inverted range wrote a tombstone (tomb_head={d}) — must be a no-op\n", .{m.tomb_head});
        return error.EmptyRangeHadSideEffects;
    }
    if (m.version != 2) {
        std.debug.print("\nRED: empty/inverted range upgraded meta.version to {d} — must be a no-op\n", .{m.version});
        return error.EmptyRangeHadSideEffects;
    }
    if (m.sequence != seq_before) {
        std.debug.print("\nRED: empty/inverted range bumped sequence {d} -> {d} — must not even flush\n", .{ seq_before, m.sequence });
        return error.EmptyRangeHadSideEffects;
    }

    // 数据全在
    for ([_][]const u8{ "a", "b", "c" }) |k| {
        const v = try db.get(k);
        try std.testing.expect(v != null);
        if (v) |vv| alloc.free(vv);
    }
}

// =====================================================================
// a10 — 链页 CRC 翻转 → 读路径 error.CorruptCrc（不得静默当无墓碑）
// =====================================================================
test "T-38-3 a10: a corrupted tombstone chain page reports error.CorruptCrc, never silent no-tomb" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    for ([_][]const u8{ "a", "b", "c", "d", "e" }) |k| try db.putDirect(k, "v");
    try db.deleteRange("b", "d");
    const head = (try readMeta(&ms)).tomb_head;
    db.close();

    if (head == 0) {
        std.debug.print("\nRED: no tombstone chain to corrupt (stage 3 write path missing)\n", .{});
        return error.NoTombChainWritten;
    }

    // 翻转链头页的一个字节（CRC 必然失配）
    {
        const buf = try ms.store().writePage(head);
        buf[100] ^= 0xFF;
    }

    // 重开后读被遮蔽 key：必须是 typed 错误，绝不能返回「无墓碑」而复活数据
    var db2 = try dbi.Db.open(alloc, ms.store(), opts());
    defer db2.close();

    const r = db2.get("b");
    if (r) |v| {
        std.debug.print("\nRED: corrupted tomb chain page read returned a value ('b' resurrected) — silent no-tomb\n", .{});
        if (v) |vv| alloc.free(vv);
        return error.SilentNoTombOnCorruption;
    } else |e| {
        if (e != error.CorruptCrc) {
            std.debug.print("\nRED: expected error.CorruptCrc, got {any}\n", .{e});
            return error.WrongError;
        }
    }
}

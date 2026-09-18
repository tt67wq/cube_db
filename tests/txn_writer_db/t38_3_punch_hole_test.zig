//! t38_3_punch_hole_test.zig — T-38 阶段 3 打洞/分裂 RED 测试（conductor 编写）
//!
//! 契约：.agents/tasks/T-38-3/task.md「C2 打洞 / 分裂（INV-RT1）」。
//! 设计依据：docs/design/T-38-range-tombstone-probe.md §4.3（含 F1 返工记录）。
//!
//! 本文件是 TDD RED（断言失败型）。
//!
//! INV-RT1：盘上任意时刻，墓碑覆盖的 key 集合与「其后写入的活 entry」不相交。
//! put(k) 落在墓碑 t=[min,max) 内 → 必须分裂为 [t.min, k) 与 [succ(k), t.max)，
//! succ(k) = k ++ 0x00，右段用 append_zero 紧凑边界表示。
//!
//! 用例：
//!   a7a 基本打洞：put 回区间内 key → 该 key 活，区间内其它 key 仍遮蔽
//!   a7b 左段为空（t.min == k）→ 跳过左段，右段生效
//!   a7c 右段为空（t.max == succ(k)）→ 唯此情形可完全消费墓碑
//!   a8  F1 核心反例：近-MAX key 打洞 → 右段不得丢弃（否则区间内已删 key 复活）
//!   a8b F1 变体：右段装不下（k.len + t.max_stored > 4052）→ 必须走兜底，
//!       不得丢弃右段、不得 panic

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

fn opts() wrt.Options {
    return .{ .micro_batch = .{ .batch_threshold = 0 } };
}

/// RED 前置断言：打洞语义只有在**真建出区间墓碑链**之后才有意义。
/// 旧实现（逐 key tombstone）下 put 回来当然活——那是 false green。
/// 所以每个打洞用例必须先证明 deleteRange 确实建了墓碑链。
fn requireTombChain(ms: *ps.MemPageStore) !void {
    const m = (try ms.store().readMeta()).?;
    if (m.tomb_head == 0 or m.version != 3) {
        std.debug.print(
            "\nRED: punch-hole premise not met — deleteRange wrote no range-tombstone chain " ++
                "(tomb_head={d}, version={d}); stage-3 write path missing, these cases would be false-green\n",
            .{ m.tomb_head, m.version },
        );
        return error.NoTombChainWritten;
    }
}

fn expectAlive(db: *dbi.Db, key: []const u8) !void {
    const v = try db.get(key);
    if (v == null) {
        std.debug.print("\nRED: '{s}' should be alive but is shadowed\n", .{key});
        return error.ShouldBeAlive;
    }
    alloc.free(v.?);
}

fn expectDead(db: *dbi.Db, key: []const u8) !void {
    const v = try db.get(key);
    if (v != null) {
        std.debug.print("\nRED: '{s}' should be shadowed but resurrected\n", .{key});
        alloc.free(v.?);
        return error.ShouldBeShadowed;
    }
}

// =====================================================================
// a7a — 基本打洞
// =====================================================================
test "T-38-3 a7a: punching a hole revives only the put-back key" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    for ([_][]const u8{ "a", "b", "c", "d", "e" }) |k| try db.putDirect(k, "v");
    try db.deleteRange("b", "e"); // 墓碑 [b, e)：b,c,d 遮蔽
    try requireTombChain(&ms);
    try db.putDirect("c", "back"); // 打洞

    try expectAlive(db, "c");
    try expectDead(db, "b");
    try expectDead(db, "d");
    try expectAlive(db, "a");
    try expectAlive(db, "e");

    const gc = try db.get("c");
    try std.testing.expectEqualStrings("back", gc.?);
    alloc.free(gc.?);
}

// =====================================================================
// a7b — 左段为空（t.min == k）
// =====================================================================
test "T-38-3 a7b: punching at the tombstone's min leaves no left segment" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    for ([_][]const u8{ "a", "b", "c", "d", "e" }) |k| try db.putDirect(k, "v");
    try db.deleteRange("b", "e"); // 墓碑 [b, e)
    try requireTombChain(&ms);
    try db.putDirect("b", "back"); // k == t.min → 左段 [b, b) 为空

    try expectAlive(db, "b");
    try expectDead(db, "c");
    try expectDead(db, "d");
    try expectAlive(db, "e");
}

// =====================================================================
// a7c — 右段为空（t.max == succ(k)）→ 唯此情形可完全消费墓碑
// =====================================================================
test "T-38-3 a7c: tombstone fully consumed only when max == succ(k)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    try db.putDirect("b", "v");
    // 墓碑 [b, b\x00)：b 与 succ(b)=b\x00 之间不存在任何字节串
    try db.deleteRange("b", "b\x00");
    try requireTombChain(&ms);
    try expectDead(db, "b");

    try db.putDirect("b", "back"); // succ(b) == t.max → 右段真空，墓碑被完全消费
    try expectAlive(db, "b");

    // 语义等价于「墓碑没了」
    var it = try db.select(null, null);
    defer it.deinit();
    var n: u32 = 0;
    while (try it.next()) |_| n += 1;
    try std.testing.expectEqual(@as(u32, 1), n);
}

// =====================================================================
// a8 — F1 核心反例（设计 §4.3 的返工用例）
// =====================================================================
test "T-38-3 a8: F1 — near-MAX punch must keep the right segment (no resurrection)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    // 反例形状（设计 §4.3原文）：
    //   put "r"(seq1) → deleteRange ["a","z")(seq2) → put big='q'×4051(seq3)
    //   基线（F1 前）右段被丢弃 → "r" 复活（错）
    try db.putDirect("r", "orig");
    try db.putDirect("z", "orig");
    try db.deleteRange("a", "zz");
    try requireTombChain(&ms);
    try expectDead(db, "r");

    const big = try alloc.alloc(u8, 4051);
    defer alloc.free(big);
    @memset(big, 'q');
    try db.putDirect(big, "bigv");

    try expectAlive(db, big);
    // 右段 [succ(big), "zz") 必须保留：'r'(0x72)、'z'(0x7a) 均 > 'q'(0x71)
    try expectDead(db, "r");
    try expectDead(db, "z");
}

// =====================================================================
// a8b — 右段装不下：必须走兜底，不得丢弃右段、不得 panic
// =====================================================================
test "T-38-3 a8b: right segment that exceeds the single-entry envelope falls back, never drops" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    // 双长边界：k 近-MAX（4051B）且 t.max 也长 → k.len + t.max_stored > 4052
    // → 编码器返回 error.TombBoundTooLarge，实现必须物化兜底（O(range)），
    //   而不是丢弃右段。
    const big = try alloc.alloc(u8, 4051);
    defer alloc.free(big);
    @memset(big, 'q');

    // 建一个 max 边界也很长的墓碑：用 4051B 的 max。
    const big_max = try alloc.alloc(u8, 4051);
    defer alloc.free(big_max);
    @memset(big_max, 'z');

    try db.putDirect("r", "orig"); // 会被墓碑删掉，且排在 big 之后
    try db.deleteRange("a", big_max); // 墓碑 [a, 'z'×4051)
    try requireTombChain(&ms);
    try expectDead(db, "r");

    // 打洞：k=big（'q'×4051），t.max='z'×4051 → 右段条目超单条 envelope
    try db.putDirect(big, "bigv"); // 不得 panic、不得返回错误

    try expectAlive(db, big);
    // 'r' < 'z'×4051 且 > big？ "r"(0x72) < 'z'(0x7a) → 右段 [succ(big), t.max) 覆盖 "r"
    try expectDead(db, "r");
}

// =====================================================================
// a8c — 打洞后重开：分裂结果必须落盘
// =====================================================================
test "T-38-3 a8c: punch-hole result survives close+reopen" {
    var ms = newStore();
    defer ms.deinit();
    {
        var db = try dbi.Db.open(alloc, ms.store(), opts());
        defer db.close();
        for ([_][]const u8{ "a", "b", "c", "d", "e" }) |k| try db.putDirect(k, "v");
        try db.deleteRange("b", "e");
        try requireTombChain(&ms);
        try db.putDirect("c", "back");
    }
    {
        var db = try dbi.Db.open(alloc, ms.store(), opts());
        defer db.close();
        try expectAlive(db, "c");
        try expectDead(db, "b");
        try expectDead(db, "d");
        const gc = try db.get("c");
        try std.testing.expectEqualStrings("back", gc.?);
        alloc.free(gc.?);
    }
}

//! t38_4_tomb_gc_test.zig — T-38 阶段 4（GC / 水位收割）RED 测试（conductor 编写）
//!
//! 契约：.agents/tasks/T-38-4/task.md「必须实现的行为」C1 / C2 / C3 / C4 / C5。
//! 设计依据：docs/design/T-38-range-tombstone-probe.md §6（GC / 收敛出口）、
//!   docs/design/T-38-probe-report.md §4（阶段 4：水位收割 + 交叠归并）。
//!
//! RED 类型 = **断言失败**（编译通过）：Db.gcTombstones 用 @hasDecl 守卫探测，
//! 链遍历只用现有公开 API（f2.decodeTombPage + store.readPage + readMeta）。
//!
//! 为什么 g3 要「注入」空区间：C1 落地后 deleteRange 再也不会产生空区间
//!（墓碑只遮蔽「建碑时已存在的物理 entry」，punch-hole 保证后来的 put 会打洞），
//! 所以「旧库遗留的空区间」只能用 writer 内部 API 构造。这是本测试的意图，不是绕过。
//!
//! 用例：
//!   g1  无链库上 gcTombstones 是零副作用 no-op
//!   g2  安全陷阱：遮蔽真实 entry 的区间不得被收割（丢了 = key 复活）
//!   g3  收割：遗留空区间被丢弃，同链里的非空区间保留
//!   g4  收割后三口径计数一致 + 无复活
//!   g5  收割结果落盘（close → reopen 语义保持）
//!   g6  规范化：交叠区间归并为并集
//!   g7  C1：删除「区间内无可见 key」→ tomb_head/sequence/version 全不变
//!   g8  C1 反向守卫：删除「区间内有 key」→ 仍正常建碑
//!   g9  规范化：相邻区间归并为并集
//!   g10 收割时有活跃 reader：旧快照仍能一致读取（链页退休纪律）
//!   g11 compact() 不改变链（保护公开的 O(1) 承诺）

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
// helpers
// =====================================================================

/// 当前链上区间的总数（顺链遍历所有墓碑页）。
/// decodeTombPage 的 tobs 由调用方释放；bound 字节借用页缓冲（只数数量，无妨）。
fn chainIntervalCount(ms: *ps.MemPageStore) !usize {
    var head: u32 = (try readMeta(ms)).tomb_head;
    var n: usize = 0;
    var hops: usize = 0;
    while (head != 0) {
        hops += 1;
        if (hops > 1024) return error.ChainTooLong;
        const raw = try ms.store().readPage(head);
        const tp = try f2.decodeTombPage(alloc, raw[0..f2.PAGE_SIZE]);
        defer alloc.free(tp.tobs);
        n += tp.tobs.len;
        head = tp.next;
    }
    return n;
}

/// gcTombstones 必须在 main 上可编译（RED = 断言失败，不是编译失败）。
fn gcOrFail(db: *dbi.Db) !void {
    if (@hasDecl(dbi.Db, "gcTombstones")) {
        return db.gcTombstones();
    }
    std.debug.print("\nRED: Db.gcTombstones is missing — stage 4 GC (water-mark harvest) not implemented\n", .{});
    return error.NoGcTombstones;
}

fn expectInvisible(db: *dbi.Db, key: []const u8, why: []const u8) !void {
    const v = try db.get(key);
    if (v) |vv| {
        std.debug.print("\nRED: key '{s}' is VISIBLE but must stay shadowed ({s}) — resurrection\n", .{ key, why });
        alloc.free(vv);
        return error.KeyResurrected;
    }
}

fn expectVisible(db: *dbi.Db, key: []const u8) !void {
    const v = try db.get(key) orelse {
        std.debug.print("\nRED: key '{s}' is invisible but must be visible\n", .{key});
        return error.KeyMissing;
    };
    alloc.free(v);
}

fn selectCount(db: *dbi.Db) !u64 {
    var it = try db.select(null, null);
    defer it.deinit();
    var n: u64 = 0;
    while (try it.next()) |_| n += 1;
    return n;
}

/// 三口径一致：entryCount() == select(null,null) 计数。
fn expectCountsConsistent(db: *dbi.Db) !void {
    const ec = db.entryCount();
    const sc = try selectCount(db);
    if (ec != sc) {
        std.debug.print("\nRED: entryCount={d} != select count={d}\n", .{ ec, sc });
        return error.CountMismatch;
    }
}

/// 构造「旧库遗留状态」：链里同时有一个真的遮蔽 entry 的区间 [b,d) 和一个空区间。
/// 只能用 writer 内部 API —— C1 落地后 deleteRange 再也造不出空区间（见文件头注释）。
/// [b,d) 遮蔽 b、c；调用者需保证 b、c 已在树里且此前已被同一区间遮蔽（count delta = 0）。
fn injectLegacyEmptyInterval(db: *dbi.Db, empty_min: []const u8, empty_max: []const u8) !void {
    const legacy: [2]f2.RangeTombstone = .{
        .{ .min = .{ .bytes = "b" }, .max = .{ .bytes = "d" } },
        .{ .min = .{ .bytes = empty_min }, .max = .{ .bytes = empty_max } },
    };
    try db.state.commitTombSwap(&legacy, &.{}, 0, 0);
}

fn seedFive(db: *dbi.Db) !void {
    for ([_][]const u8{ "a", "b", "c", "d", "e" }) |k| try db.putDirect(k, "v");
}

// =====================================================================
// g1 — 无链库上 gcTombstones 是零副作用 no-op
// =====================================================================
test "T-38-4 g1: gc on a tombstone-free db is a zero-side-effect no-op" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    try seedFive(db);
    const before = try readMeta(&ms);
    try std.testing.expectEqual(@as(u32, 0), before.tomb_head);

    try gcOrFail(db);

    const after = try readMeta(&ms);
    if (after.tomb_head != 0) {
        std.debug.print("\nRED: gc created a tombstone head ({d}) on a chain-free db\n", .{after.tomb_head});
        return error.GcHadSideEffects;
    }
    if (after.sequence != before.sequence) {
        std.debug.print("\nRED: gc bumped sequence {d} -> {d} on a chain-free db (must be a no-op)\n", .{ before.sequence, after.sequence });
        return error.GcHadSideEffects;
    }
    try expectVisible(db, "b");
}

// =====================================================================
// g2 — ★ 安全陷阱：遮蔽真实 entry 的区间不得被收割
// =====================================================================
test "T-38-4 g2: gc must NOT harvest an interval that shadows physically-present entries" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    try seedFive(db);
    try db.deleteRange("b", "d"); // [b,d) 遮蔽 b、c；两者仍在树里（阶段 3 不打叶写）

    if (try chainIntervalCount(&ms) != 1) {
        std.debug.print("\nRED: expected 1 interval after deleteRange, got {d}\n", .{try chainIntervalCount(&ms)});
        return error.NoTombChainWritten;
    }

    try gcOrFail(db);

    // 区间必须还在：b、c 是物理在场的，丢掉区间 = 复活
    const n = try chainIntervalCount(&ms);
    if (n != 1) {
        std.debug.print("\nRED: gc dropped a shadowing interval (chain now {d} intervals, want 1) — data loss direction\n", .{n});
        return error.ShadowingIntervalHarvested;
    }
    if ((try readMeta(&ms)).tomb_head == 0) {
        std.debug.print("\nRED: gc cleared tomb_head although a shadowing interval exists\n", .{});
        return error.ShadowingIntervalHarvested;
    }
    try expectInvisible(db, "b", "gc must not resurrect");
    try expectInvisible(db, "c", "gc must not resurrect");
    try expectVisible(db, "a");
    try expectVisible(db, "d");
    try expectVisible(db, "e");
}

// =====================================================================
// g3 — 收割：遗留空区间被丢弃，非空区间保留
// =====================================================================
test "T-38-4 g3: gc harvests an empty interval but keeps the shadowing one beside it" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    try seedFive(db);
    try db.deleteRange("b", "d"); // [b,d) 真遮蔽 b、c
    try injectLegacyEmptyInterval(db, "x", "z"); // 遗留空区间（树里没有 x..y）

    if (try chainIntervalCount(&ms) != 2) {
        std.debug.print("\nRED: setup expected 2 intervals, got {d}\n", .{try chainIntervalCount(&ms)});
        return error.SetupWrongIntervalCount;
    }

    try gcOrFail(db);

    const n = try chainIntervalCount(&ms);
    if (n != 1) {
        std.debug.print("\nRED: after gc expected exactly 1 interval (empty one harvested), got {d}\n", .{n});
        return error.HarvestWrongIntervalCount;
    }
    // 保留的必须是遮蔽区间：b、c 仍不可见
    try expectInvisible(db, "b", "shadowing interval must survive the harvest");
    try expectInvisible(db, "c", "shadowing interval must survive the harvest");
    try expectVisible(db, "a");
    try expectVisible(db, "d");
}

// =====================================================================
// g4 — 收割后计数一致 + 无复活
// =====================================================================
test "T-38-4 g4: counts stay exact across gc (entryCount == select == get)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    try seedFive(db);
    try db.deleteRange("b", "d");
    try injectLegacyEmptyInterval(db, "x", "z");

    const before = db.entryCount();
    try gcOrFail(db);
    const after = db.entryCount();

    if (before != after) {
        std.debug.print("\nRED: gc changed entryCount {d} -> {d} (harvesting an empty interval cannot change visible counts)\n", .{ before, after });
        return error.GcChangedEntryCount;
    }
    try expectCountsConsistent(db);
    try expectInvisible(db, "b", "count/gc");
    try expectInvisible(db, "c", "count/gc");
    try expectVisible(db, "a");
    try expectVisible(db, "d");
    try expectVisible(db, "e");
}

// =====================================================================
// g5 — 收割结果落盘（close → reopen）
// =====================================================================
test "T-38-4 g5: the harvested (canonical) chain survives close+reopen" {
    var ms = newStore();
    defer ms.deinit();

    {
        var db = try dbi.Db.open(alloc, ms.store(), opts());
        defer db.close();
        try seedFive(db);
        try db.deleteRange("b", "d");
        try injectLegacyEmptyInterval(db, "x", "z");
        try gcOrFail(db);
        if (try chainIntervalCount(&ms) != 1) {
            std.debug.print("\nRED: gc left {d} intervals, want 1\n", .{try chainIntervalCount(&ms)});
            return error.HarvestWrongIntervalCount;
        }
    }

    var db2 = try dbi.Db.open(alloc, ms.store(), opts());
    defer db2.close();

    if (try chainIntervalCount(&ms) != 1) {
        std.debug.print("\nRED: chain not persisted (reopened with {d} intervals, want 1)\n", .{try chainIntervalCount(&ms)});
        return error.ChainNotPersisted;
    }
    try expectInvisible(db2, "b", "persisted harvest");
    try expectInvisible(db2, "c", "persisted harvest");
    try expectVisible(db2, "a");
    try expectVisible(db2, "d");
    try expectCountsConsistent(db2);
}

// =====================================================================
// g6 — 规范化：交叠区间归并为并集
// =====================================================================
test "T-38-4 g6: overlapping intervals are published as their canonical union" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    for ([_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" }) |k| try db.putDirect(k, "v");

    try db.deleteRange("a", "f"); // [a,f)：a..e 可见 → count>0，正常建碑
    // 第二次与 [a,f) 交叠；f..i 可见 → count>0，走通用路径（C1 短路不适用）
    try db.deleteRange("d", "j");

    const n = try chainIntervalCount(&ms);
    if (n != 1) {
        std.debug.print("\nRED: chain has {d} intervals after two overlapping deleteRanges; the union is one interval [a,j)\n", .{n});
        return error.ChainNotCanonical;
    }
    // 语义不变：a..i 全不可见，j 可见
    for ([_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i" }) |k| try expectInvisible(db, k, "overlap union");
    try expectVisible(db, "j");
    try expectCountsConsistent(db);
}

// =====================================================================
// g7 — C1：删除「区间内无可见 key」→ 零副作用
// =====================================================================
test "T-38-4 g7: deleteRange over a range with no visible key is a zero-side-effect no-op" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    for ([_][]const u8{ "a", "b", "c" }) |k| try db.putDirect(k, "v");
    const before = try readMeta(&ms);

    try db.deleteRange("x", "z"); // 树里没有任何 x..y

    const after = try readMeta(&ms);
    if (after.tomb_head != 0) {
        std.debug.print("\nRED: deleteRange over a key-free range wrote a tombstone (tomb_head={d}) — provably redundant\n", .{after.tomb_head});
        return error.RedundantTombstoneWritten;
    }
    if (after.sequence != before.sequence) {
        std.debug.print("\nRED: deleteRange over a key-free range bumped sequence {d} -> {d}\n", .{ before.sequence, after.sequence });
        return error.RedundantTombstoneWritten;
    }
    if (after.version != before.version) {
        std.debug.print("\nRED: deleteRange over a key-free range changed version {d} -> {d}\n", .{ before.version, after.version });
        return error.RedundantTombstoneWritten;
    }
    try expectVisible(db, "b");
}

// =====================================================================
// g8 — C1 反向守卫：区间内有 key 时仍必须建碑（防过度短路）
// =====================================================================
test "T-38-4 g8: a deleteRange with visible keys still publishes a tombstone (no over-short-circuit)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    for ([_][]const u8{ "a", "b", "c" }) |k| try db.putDirect(k, "v");
    const before = try readMeta(&ms);

    try db.deleteRange("a", "c"); // b 可见 → count>0

    const after = try readMeta(&ms);
    if (after.tomb_head == 0) {
        std.debug.print("\nRED: deleteRange with a visible in-range key wrote no tombstone — over-short-circuited\n", .{});
        return error.MissingTombstone;
    }
    if (after.sequence == before.sequence) {
        std.debug.print("\nRED: deleteRange with a visible in-range key did not commit (sequence unchanged)\n", .{});
        return error.MissingTombstone;
    }
    if (after.version != 3) {
        std.debug.print("\nRED: version={d}, expected 3 after the first tombstone\n", .{after.version});
        return error.VersionNotUpgraded;
    }
    try expectInvisible(db, "b", "C1 counter-case");
    try expectInvisible(db, "a", "C1 counter-case");
    try expectVisible(db, "c");
    if (try chainIntervalCount(&ms) != 1) {
        std.debug.print("\nRED: expected 1 interval, got {d}\n", .{try chainIntervalCount(&ms)});
        return error.ChainNotCanonical;
    }
}

// =====================================================================
// g9 — 规范化：相邻区间归并为并集
// =====================================================================
test "T-38-4 g9: adjacent intervals are published as their canonical union" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    for ([_][]const u8{ "a", "b", "c", "d", "e", "f" }) |k| try db.putDirect(k, "v");

    try db.deleteRange("a", "c"); // [a,c)：a、b
    try db.deleteRange("c", "e"); // [c,e)：c、d 可见 → count>0 → 通用路径；与上者相邻

    const n = try chainIntervalCount(&ms);
    if (n != 1) {
        std.debug.print("\nRED: chain has {d} intervals after two adjacent deleteRanges; [a,c)+[c,e) = [a,e) is one interval\n", .{n});
        return error.ChainNotCanonical;
    }
    for ([_][]const u8{ "a", "b", "c", "d" }) |k| try expectInvisible(db, k, "adjacent union");
    try expectVisible(db, "e");
    try expectVisible(db, "f");
    try expectCountsConsistent(db);
}

// =====================================================================
// g10 — 收割时有活跃 reader：旧快照仍能一致读取
// =====================================================================
test "T-38-4 g10: gc with an active reader leaves the reader's old snapshot consistent" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    try seedFive(db);
    try db.deleteRange("b", "d");
    try injectLegacyEmptyInterval(db, "x", "z");

    // 活跃 reader：快照 = 当前的 (root, tomb_head)
    var rt = try db.beginReadTxn();
    defer rt.deinit();

    try gcOrFail(db);

    // reader 仍按旧链判遮蔽：b、c 必须不可见（旧链页未被回收/复用）
    const vb = try rt.get("b");
    if (vb) |vv| {
        std.debug.print("\nRED: reader saw 'b' resurrected after gc — old chain pages were reclaimed under it\n", .{});
        alloc.free(vv);
        return error.ReaderSawResurrection;
    }
    const vc = try rt.get("c");
    if (vc) |vv| {
        std.debug.print("\nRED: reader saw 'c' resurrected after gc\n", .{});
        alloc.free(vv);
        return error.ReaderSawResurrection;
    }
    const va = try rt.get("a") orelse {
        std.debug.print("\nRED: reader lost 'a' after gc\n", .{});
        return error.ReaderLostKey;
    };
    alloc.free(va);

    // 新快照同样一致
    try expectInvisible(db, "b", "post-gc");
    try expectCountsConsistent(db);
}

// =====================================================================
// g11 — compact() 不改变链（保护公开的 O(1) 承诺）
// =====================================================================
test "T-38-4 g11: compact() must not touch the tombstone chain (documented O(1) promise)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), opts());
    defer db.close();

    try seedFive(db);
    try db.deleteRange("b", "d");
    try injectLegacyEmptyInterval(db, "x", "z");

    const head_before = (try readMeta(&ms)).tomb_head;
    const n_before = try chainIntervalCount(&ms);
    if (n_before != 2) {
        std.debug.print("\nRED: setup expected 2 intervals, got {d}\n", .{n_before});
        return error.SetupWrongIntervalCount;
    }

    try db.compact();

    const head_after = (try readMeta(&ms)).tomb_head;
    const n_after = try chainIntervalCount(&ms);
    if (head_after != head_before) {
        std.debug.print("\nRED: compact changed tomb_head {d} -> {d} (compact must stay O(1), no chain rewrite)\n", .{ head_before, head_after });
        return error.CompactTouchedChain;
    }
    if (n_after != n_before) {
        std.debug.print("\nRED: compact changed the chain ({d} -> {d} intervals) — harvesting must not live in compact()\n", .{ n_before, n_after });
        return error.CompactTouchedChain;
    }
}

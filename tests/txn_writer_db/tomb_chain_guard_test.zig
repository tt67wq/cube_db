//! T-52 — 墓碑链环防护在 FilePageStore 上形同虚设（准 hang / 资源炸弹）
//!
//! 本文件由 **conductor 亲自编写**（TDD：先红后绿）。impl worker **不得修改本文件**。
//! 若认为断言有误 → 标 `blocked`，由 conductor 裁决。
//!
//! 背景：`src/db.zig` `walkTombChain` 用「步数上界 = `store.mapsize()`」防环。
//! `MemPageStore.mapsize()` = 页数（测试里 10000）→ 防护有效；
//! `FilePageStore.mapsize()` = `region_size / PAGE_SIZE` = 2^28 = 268,435,456
//! → 环链要跑 2.68 亿步、吃 ~12 GiB 才报错 = 准 hang / 资源炸弹。
//!
//! 本文件把阶段 2 的 g6（MemPageStore + 「任意 error 均可」宽松断言）**升级**为
//! FilePageStore 上的**严格判定**：
//!   1. 必须返回 typed error（不是静默返回原值）；
//!   2. error 必须是 `error.Truncated`（环 = 链超界，T-52 处置建议的语义）；
//!   3. 必须在**有界时间内**返回（用墙体时钟断言，抓准 hang）。
//!
//! 判定 (3) 是抓 bug 的关键：MemPageStore 上该用例毫秒级完成，
//! FilePageStore 上 RED 期会跑 ~2.68 亿步 → 远超阈值 → 断言失败（而非测试超时挂死）。
//! 用**软阈值 + 显式失败**而非依赖 harness 超时，这样 RED 输出是一条清晰的断言失败。

const std = @import("std");
const c = @cImport({
    @cInclude("unistd.h");
});
const cube = @import("cube_db");
const ps = cube.page_store;
const dbi = cube.db;
const f2 = cube.format;
const FilePageStore = cube.file_page_store.FilePageStore;

const alloc = std.testing.allocator;

/// 环链防护允许的墙体时钟上限。正常实现（visited-set / 收紧上界）应在微秒~毫秒级返回；
/// RED 期（2.68 亿步 + 全页 CRC）会远超此值。取 2 秒留足 CI 抖动余量，
/// 同时远小于 2.68 亿步所需时间（分钟~小时级），因此能可靠区分红/绿。
const ring_guard_budget_ns: u64 = 2 * std.time.ns_per_s;

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

/// 单调时钟（仓库既有 idiom：std.c.clock_gettime MONOTONIC）
fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

fn tomb(min: ?[]const u8, max: ?[]const u8) f2.RangeTombstone {
    return .{
        .min = if (min) |m| .{ .bytes = m } else null,
        .max = if (max) |m| .{ .bytes = m } else null,
    };
}

const all_keys = [_][]const u8{ "a", "b", "b\x00", "ba", "c", "c\x00", "d", "e" };

fn putAll(db: *dbi.Db) !void {
    for (all_keys) |k| try db.putDirect(k, "v");
}

// =====================================================================
// a1 — FilePageStore 上的环链必须「有界 + typed error.Truncated」
//      RED 期：跑 2.68 亿步 → 超时阈值 → 断言失败（清晰、不挂死）
// =====================================================================

test "T-52 a1: FilePageStore — CRC-valid tomb chain ring returns bounded error.Truncated" {
    const path = ".test_t52_ring.db";
    defer unlinkPath(path);

    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    const s = fps.store();

    // 1) 建库 + 写基础数据
    {
        var db = try dbi.Db.open(alloc, s, .{});
        defer db.close();
        try putAll(db);
    }

    // 2) 手工注入**环链**：p1 → p2 → p1（两页 CRC 均合法，仅 free_next 指回已访问页）。
    //    decodeTombPage 不校验 free_next，故环可构造 —— 这正是 H-1 trust boundary。
    var meta = (try s.readMeta()).?;
    const p1 = try s.allocPage();
    const p2 = try s.allocPage();
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

    // 3) 重开（读路径在 open 后首次点查时走 walkTombChain）
    var db = try dbi.Db.open(alloc, s, .{});
    defer db.close();

    // 点查被环内墓碑覆盖的 key（"c" 落在 p1 的 [c,d) 内）。
    // 必须：快速 + typed error.Truncated。不得静默返回原值、不得挂起。
    const t0 = monoNs();
    const elapsed_ns: u64 = blk: {
        if (db.get("c")) |maybe_v| {
            defer if (maybe_v) |v| alloc.free(v);
            // 静默返回值 = 把损坏链当「无墓碑」→ 数据复活 → 明确失败
            try std.testing.expect(false);
        } else |e| {
            // 必须是有语义的 typed error：环 = 链超界 → Truncated
            try std.testing.expectEqual(error.Truncated, e);
        }
        break :blk @intCast(monoNs() - t0);
    };

    try std.testing.expect(elapsed_ns < ring_guard_budget_ns);
}

// =====================================================================
// a2 — FilePageStore 上的**无环**长链：不得误报 Truncated
//      （防止用「收紧上界到 1」之类的错误修法把正常链也打死）
// =====================================================================

test "T-52 a2: FilePageStore — acyclic tomb chain still walks correctly (no false positive)" {
    const path = ".test_t52_chain.db";
    defer unlinkPath(path);

    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    const s = fps.store();

    {
        var db = try dbi.Db.open(alloc, s, .{});
        defer db.close();
        try putAll(db);
    }

    var meta = (try s.readMeta()).?;
    const p1 = try s.allocPage();
    const p2 = try s.allocPage();
    {
        const buf = try s.writePage(p1);
        try f2.encodeTombPage(buf[0..f2.PAGE_SIZE], p1, &.{tomb("c", "d")}, meta.sequence + 1, p2);
    }
    {
        const buf = try s.writePage(p2);
        try f2.encodeTombPage(buf[0..f2.PAGE_SIZE], p2, &.{tomb("e", "f")}, meta.sequence + 1, 0); // 尾
    }
    meta.version = 3;
    meta.tomb_head = p1;
    meta.sequence += 1;
    try s.writeMeta(&meta);

    var db = try dbi.Db.open(alloc, s, .{});
    defer db.close();

    // 链：p1=[c,d), p2=[e,f)。关键：**不得返回 error.Truncated**——无环链必须正常走完。
    {
        const got = try db.get("a"); // 若有 error 会在这里向上抛 → 测试失败
        defer if (got) |v| alloc.free(v);
        try std.testing.expect(got != null);
    }
    {
        const got = try db.get("c"); // 被 p1 的 [c,d) 遮蔽
        defer if (got) |v| alloc.free(v);
        try std.testing.expectEqual(@as(?[]u8, null), got);
    }
    {
        const got = try db.get("e"); // 被 p2 的 [e,f) 遮蔽（跨页链走通）
        defer if (got) |v| alloc.free(v);
        try std.testing.expectEqual(@as(?[]u8, null), got);
    }
    {
        const got = try db.get("d"); // 半开区间：d 不在 [c,d)，也不在 [e,f) → 可见
        defer if (got) |v| alloc.free(v);
        try std.testing.expect(got != null);
    }
}

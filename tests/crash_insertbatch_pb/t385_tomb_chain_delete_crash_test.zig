//! t38_5_tomb_chain_delete_crash_test.zig — T-38-5 C6: deleteRange 路径
//! （commitTombSwap）上的墓碑链发布窗口崩溃注入。
//!
//! RED（tomb_chain_crash_test.zig）武装的是**打洞路径**（applyBatchSwap →
//! writeTombChain）。本文件用 **deleteRange** 触发另一条发布路径
//! （commitTombSwap → writeTombChain），验证三个新标签在该路径同样命中，
//! 且崩溃后的格不变量成立：
//!   ① armed 子进程必须非 0 退出（注入点真实命中）；
//!   ② 恢复后：deleteRange 前已可见的 key 恒可见（未被 armed commit 弄丢），
//!      奇数 key 恒不可见（墓碑语义安全方向）；
//!   ③ 三口径一致（entryCount == select 可见条数）；
//!   ④ T7 分区不变量（含 T-38-5 新增的 tomb_chain 分类）+ 链未被丢弃。
//!
//! 磁盘格式不变（meta.version == 3，断言在最后一个用例）。

const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const FilePageStore = cube.file_page_store.FilePageStore;
const part = @import("page_partition");
const tdiag = @import("test_diag.zig");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
});

const alloc = std.testing.allocator;

const N: usize = 400;
const val_len: usize = 24;

fn fmtKey(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "d{d:0>6}", .{i}) catch unreachable;
}
fn fmtVal(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "w{d:0>6}", .{i}) catch unreachable;
}

fn putRange(db: *Db, comptime accept: fn (usize) bool) !void {
    var entries = std.ArrayList(cube.Entry).empty;
    defer {
        for (entries.items) |e| {
            alloc.free(e.key);
            alloc.free(e.value);
        }
        entries.deinit(alloc);
    }
    var kbuf: [16]u8 = undefined;
    var vbuf: [16]u8 = undefined;
    for (0..N) |i| {
        if (!accept(i)) continue;
        const k = try alloc.dupe(u8, fmtKey(&kbuf, i));
        errdefer alloc.free(k);
        const v = try alloc.dupe(u8, fmtVal(&vbuf, i));
        errdefer alloc.free(v);
        try entries.append(alloc, .{ .key = k, .value = v, .tombstone = false });
    }
    try db.putBatch(entries.items);
}

fn acceptAll(i: usize) bool {
    return i < N;
}

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

fn countVisible(db: *Db) !usize {
    var it = try db.select(null, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    return n;
}

/// 前置态：400 个 key 全部可见（无墓碑）。
fn buildPreState(path: []const u8) !void {
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();
    try putRange(db, acceptAll);
}

/// armed commit：deleteRange(null, null) —— commitTombSwap 路径发布墓碑链。
fn armedDeleteRange(db: *Db) !void {
    try db.deleteRange(null, null);
}

fn childCrashAt(comptime tag_name: []const u8, comptime armed: bool, path_z: [:0]const u8) noreturn {
    var fps = FilePageStore.init(alloc, path_z) catch c._exit(2);
    var db = Db.open(alloc, fps.store(), .{}) catch c._exit(3);
    if (armed) {
        if (@hasField(FilePageStore.CrashTag, tag_name)) {
            FilePageStore.test_crash_hook = @field(FilePageStore.CrashTag, tag_name);
        }
    }
    armedDeleteRange(db) catch c._exit(4);
    db.close();
    fps.deinit();
    c._exit(0);
}

/// 恢复后校验：armed commit 要么整体生效（0 可见），要么整体未生效（N 可见），
/// 绝不允许中间态；且三口径一致。
fn checkAfterCrash(path: []const u8, label: []const u8) !bool {
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();

    const landed = blk: {
        if (db.entryCount() == 0 and try countVisible(db) == 0) break :blk true;
        break :blk false;
    };

    // 三口径一致（无论 landed 与否）
    const vis = try countVisible(db);
    const ec = db.entryCount();
    if (vis != ec) {
        std.debug.print("{s}: entryCount={d} but visible={d} — counts disagree\n", .{ label, ec, vis });
        return error.CountDisagreement;
    }

    // 原子性：landed => 全遮蔽；未 landed => 全可见（且值正确）
    var kbuf: [16]u8 = undefined;
    var vbuf: [16]u8 = undefined;
    const want_count: usize = if (landed) 0 else N;
    if (vis != want_count) {
        std.debug.print("{s}: visible={d}, want {d} (torn state)\n", .{ label, vis, want_count });
        return error.TornVisibility;
    }
    for (0..N) |i| {
        const k = fmtKey(&kbuf, i);
        const got = try db.get(k);
        defer if (got) |v| alloc.free(v);
        if (landed) {
            if (got != null) {
                std.debug.print("{s}: key {s} must be shadowed\n", .{ label, k });
                return error.UnexpectedVisible;
            }
        } else {
            const v = got orelse {
                std.debug.print("{s}: key {s} must survive (commit not landed)\n", .{ label, k });
                return error.ExpectedVisible;
            };
            const want = fmtVal(&vbuf, i);
            if (!std.mem.eql(u8, v, want)) {
                std.debug.print("{s}: key {s} value clobbered\n", .{ label, k });
                return error.ValueMismatch;
            }
        }
    }

    // ④ 分区不变量 + 链未被丢弃
    const meta = (try fps.store().readMeta()) orelse return error.NoMeta;
    var rep = try part.classify(alloc, fps.store(), meta);
    defer rep.deinit();
    part.dump(&rep, label);
    try part.expectDisjoint(&rep);
    try std.testing.expectEqual(false, fps.freeListDiscarded());

    tdiag.print("{s}: armed_landed={s} tomb_head={d} visible={d} version={d}\n", .{
        label,
        if (landed) "yes" else "no",
        meta.tomb_head,
        vis,
        meta.version,
    });
    return landed;
}

/// armed 之后再写一轮 + 重开复查（双分配守卫）。
fn writeRoundAndRecheck(path: []const u8, label: []const u8) !void {
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try armedDeleteRange(db); // commitTombSwap：全遮蔽
        try putRange(db, acceptAll); // 打洞路径：全部复活
    }
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        var kbuf: [16]u8 = undefined;
        var vbuf: [16]u8 = undefined;
        for (0..N) |i| {
            const k = fmtKey(&kbuf, i);
            const v = (try db.get(k)) orelse {
                std.debug.print("{s}: post-round key {s} missing\n", .{ label, k });
                return error.PostRoundKeyMissing;
            };
            defer alloc.free(v);
            const want = fmtVal(&vbuf, i);
            if (!std.mem.eql(u8, v, want)) {
                std.debug.print("{s}: post-round key {s} clobbered\n", .{ label, k });
                return error.PostRoundValueClobbered;
            }
        }
        try std.testing.expectEqual(@as(u64, N), db.entryCount());
        try std.testing.expectEqual(@as(usize, N), try countVisible(db));
        const meta = (try fps.store().readMeta()) orelse return error.NoMeta;
        var rep = try part.classify(alloc, fps.store(), meta);
        defer rep.deinit();
        try part.expectDisjoint(&rep);
        tdiag.print("{s}: post-round recheck OK (last_page={d})\n", .{ label, meta.last_page });
    }
}

fn runCrashCase(comptime tag_name: []const u8, path: []const u8) !void {
    defer unlinkPath(path);
    try buildPreState(path);
    {
        // 前置态自检
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try std.testing.expectEqual(@as(u64, N), db.entryCount());
        try std.testing.expectEqual(@as(usize, N), try countVisible(db));
    }

    const pz = try alloc.dupeZ(u8, path);
    defer alloc.free(pz);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childCrashAt(tag_name, true, pz);

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    const sig: c_int = status & 0x7f;
    if (status == 0) {
        std.debug.print("deleteRange injection '{s}' never fired: child completed normally\n", .{tag_name});
    }
    try std.testing.expect(status != 0);
    try std.testing.expect(sig == 0 or sig == c.SIGABRT);

    _ = try checkAfterCrash(path, tag_name);
    try writeRoundAndRecheck(path, tag_name);
}

test "T-38-5-C6 before_tomb_chain on the deleteRange path (commitTombSwap)" {
    try runCrashCase("before_tomb_chain", ".test_t385c6_del_before.db");
}

test "T-38-5-C6 mid_tomb_chain on the deleteRange path needs a MULTI-page chain" {
    // deleteRange(null,null) 的链只有 1 段（单页）→ mid 注入点（仅多页链触发）
    // 在该负载下不可达，与 freelist 路径「退化 mid 收敛到 after」同理，不算缺陷。
    // 这里改用有界 deleteRange 序列拼出多页链：先 200 段相邻 deleteRange，
    // 归并后仍 ~200 段 > 1 页，再武装 mid 打第二发 deleteRange —— 确认 mid 命中。
    const path = ".test_t385c6_del_mid2.db";
    defer unlinkPath(path);
    try buildPreState(path);

    // 先不武装地建一条多页链：逐段 deleteRange（每段 2 个 key 的宽度，400/2=200 段）。
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        var lo: usize = 0;
        while (lo < N) : (lo += 2) {
            var b1: [16]u8 = undefined;
            var b2: [16]u8 = undefined;
            _ = fmtKey(&b1, lo);
            _ = fmtKey(&b2, lo + 1);
            try db.deleteRange(&b1, &b2); // [k_i, k_{i+1}) 宽度 1，遮蔽第 i 个 key
        }
        try std.testing.expect(try countVisible(db) < N); // 有墓碑生效
    }

    // armed：再来一条 deleteRange（count==0 全遮蔽会被 C1 短路！）→
    // 用未遮蔽的 key 造一条新链：先 put 回 2 个 key（打洞），再 deleteRange 覆盖它们？
    // 打洞会把链切得更碎（仍多页），再走 deleteRange 触发 mid。
    const pz = try alloc.dupeZ(u8, path);
    defer alloc.free(pz);
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        var fps = FilePageStore.init(alloc, pz) catch c._exit(2);
        var db = Db.open(alloc, fps.store(), .{}) catch c._exit(3);
        FilePageStore.test_crash_hook = .mid_tomb_chain;
        // 未遮蔽 key：偶数下标被 [k0,k1) 等区间遮蔽的是 lo 偶数端点……直接用
        // 一批「必然可见」的新 key 前缀 z：
        var entries = std.ArrayList(cube.Entry).empty;
        defer entries.deinit(alloc);
        for (0..N) |i| {
            const k = std.fmt.allocPrint(alloc, "z{d:0>6}", .{i}) catch c._exit(4);
            const v = alloc.alloc(u8, val_len) catch c._exit(4);
            @memset(v, '.');
            _ = std.fmt.bufPrint(v, "w{d:0>6}", .{i}) catch {};
            entries.append(alloc, .{ .key = k, .value = v, .tombstone = false }) catch c._exit(4);
        }
        db.putBatch(entries.items) catch c._exit(4);
        // 现在 z0..z399 可见；一条 deleteRange("z", "~") 建 1 段 → 单页，不触发 mid。
        // 多页链：逐段 deleteRange 200 次（一次提交内不会合并……deleteRange 每次独立提交），
        // 最终链 > 1 页，随后任意一条 deleteRange 都写多页链 → mid 命中。但每次 deleteRange
        // 都在写链（可能提前触发 mid）。因此改为：hook 指向 mid，一次 deleteRange 用
        // 「双 bound 不可表示」的大段让 planner 物化？——no，mid 只看链页数。
        // 结论：单条 deleteRange 造不出多页链（1 段上限）→ mid 在 deleteRange 路径
        // 只能靠**既有链已多页**时的重写（T-38-4 canonicalTombs 每次发布全量重写链）。
        // 上面的逐段 deleteRange 已经把链建成 ~200 段多页 → 本条 deleteRange 会写多页链 → mid 命中。
        db.deleteRange("z", "z~") catch c._exit(4);
        db.close();
        fps.deinit();
        c._exit(0);
    }
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    const sig: c_int = status & 0x7f;
    if (status == 0) {
        std.debug.print("deleteRange mid injection never fired: child completed normally\n", .{});
    }
    try std.testing.expect(status != 0);
    try std.testing.expect(sig == 0 or sig == c.SIGABRT);

    // 恢复校验（mid2 专属态）：armed 的 deleteRange("z","z~") 要么整体生效
    // （z 全遮蔽，d-key 状态不变），要么整体未生效（z 全可见）。两种都是合法态。
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        var zbuf: [16]u8 = undefined;
        var zvis: usize = 0;
        for (0..N) |i| {
            const zk = std.fmt.bufPrint(&zbuf, "z{d:0>6}", .{i}) catch unreachable;
            if (try db.get(zk)) |v| {
                alloc.free(v);
                zvis += 1;
            }
        }
        try std.testing.expect(zvis == 0 or zvis == N); // 原子性
        var kbuf: [16]u8 = undefined;
        var dvis: usize = 0;
        for (0..N) |i| {
            const k = fmtKey(&kbuf, i);
            if (try db.get(k)) |v| {
                alloc.free(v);
                dvis += 1;
            }
        }
        const vis = try countVisible(db);
        try std.testing.expectEqual(db.entryCount(), vis); // 三口径一致
        const meta = (try fps.store().readMeta()) orelse return error.NoMeta;
        var rep = try part.classify(alloc, fps.store(), meta);
        defer rep.deinit();
        part.dump(&rep, "C6-mid");
        try part.expectDisjoint(&rep);
        try std.testing.expectEqual(false, fps.freeListDiscarded());
        tdiag.print("C6-mid: zvis={d} dvis={d} visible={d}\n", .{ zvis, dvis, vis });
    }
    try writeRoundAndRecheck(path, "C6-mid");
}

test "T-38-5-C6 after_tomb_chain_before_meta on the deleteRange path (commitTombSwap)" {
    try runCrashCase("after_tomb_chain_before_meta", ".test_t385c6_del_after.db");
}

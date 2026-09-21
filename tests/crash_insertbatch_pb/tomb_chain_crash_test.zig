//! T-38-5 RED — 墓碑链**发布窗口**的崩溃注入矩阵。
//!
//! 由 conductor 预写（TDD：先红后绿）。**实现者不得修改本文件**
//! （门会校验其 blob 哈希与 RED 提交一致）。
//!
//! ## 背景（缺口）
//!
//! `writeTombChain`（`src/writer.zig`）通过 `PageStore` vtable 写墓碑链页
//! （`allocPage` + `writePage` + `encodeTombPage`），而 FilePageStore 的崩溃注入点
//! （`CrashTag` / `test_crash_hook` / `fireCrashHook`）目前**只覆盖 freelist 链与元数据写入路径**。
//! 于是「墓碑链页已写、元数据尚未切换」这个窗口**无法注入**：
//! `commitTombSwap` 的顺序是 `canonicalTombs → writeTombChain → queuePendingFree → writeCommitMeta`，
//! 探路报告 §5 关于「墓碑 commit 复用同一提交路径、崩溃模型不变」的结论目前是**分析**，不是实证。
//!
//! ## 契约（只钉**可观测接口**，不钉实现机制）
//!
//! `FilePageStore.CrashTag` 必须新增三个标签，并以与既有 4 个**相同**的方式生效
//! （即经 `FilePageStore.test_crash_hook` 静态变量被 `armCrashHook` 武装后，进程在该点 abort）：
//!
//!   tag                          | 注入点
//!   -----------------------------|--------------------------------------------------
//!   before_tomb_chain            | 归并完成、尚未写任何墓碑链页
//!   mid_tomb_chain               | 墓碑链页写了一半（本工作负载下链为多页，必须能命中）
//!   after_tomb_chain_before_meta | 墓碑链页全部写完、元数据尚未切换
//!
//! 机制自由：`writer.zig` 只持有 `PageStore` vtable，如何把注入点从 writer 暴露到
//! file store（扩 vtable / pub 透传 / 其他）由实现者决定；本文件只通过
//! `FilePageStore` 的既有开关武装与观察。
//!
//! ## 工作负载与断言
//!
//! 前置态：`put k0..k399` → `deleteRange(null, null)`（全区间墓碑，链 1 段，全部 key 被遮蔽）。
//! armed commit：`putBatch(偶数 key)`（200 个 key 打洞 → 链 ≈ 201 段 ≈ 6KB > 4068B → **多页**）。
//!
//! 恢复后必须成立：
//!   ① **绝不复活**：奇数 key 在任何恢复态下都不得可见（打洞语义的安全方向）；
//!   ② **批量原子性**：偶数 key 必须**全可见或全不可见**，不允许一半；
//!   ③ **三口径一致**：`entryCount()` 必须等于 `select(null,null)` 的可见条数
//!      （T-57 那类「计数与可见性背离」的守卫：崩溃恢复不得制造它）；
//!   ④ **分区不变量**（T7 `page_partition`）+ 链未被丢弃（进程崩溃只能让旧链继续当值）；
//!   ⑤ **再写一轮 + 重开 + 复查**：一轮「全删 + 全写」（同时走 `commitTombSwap` 与打洞两条发布路径），
//!      然后把 400 个 key 的值逐个复查 —— 若恢复期把活页错放进 freelist，
//!      新写入的 COW 会把崩溃前的数据覆盖坏，这里就会暴露。
//!
//! 在 main 上：三个新标签都不存在 → `armCrashHook` 什么也不做 → 子进程正常提交并 `_exit(0)`
//! → 父进程「armed 子进程必须非 0 退出」的断言失败 = RED。

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const Db = cube.Db;
const FilePageStore = cube.file_page_store.FilePageStore;
const part = @import("page_partition");
const tdiag = @import("test_diag.zig");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
});

const alloc = std.testing.allocator;

/// k000000 .. k000399
const N: usize = 400;
const val_len: usize = 24;

// ===== crash-hook bridge（与既有 T5 测试同一套守卫写法，保证本文件在 main 上也能编译）=====

fn crashHookAvailable() bool {
    if (!@hasDecl(FilePageStore, "CrashTag")) return false;
    return @hasDecl(FilePageStore, "test_crash_hook") or @hasField(FilePageStore, "test_crash_hook");
}

fn hookHasTag(comptime tag_name: []const u8) bool {
    if (!@hasDecl(FilePageStore, "CrashTag")) return false;
    return @hasField(FilePageStore.CrashTag, tag_name);
}

fn armCrashHook(fps: *FilePageStore, comptime tag_name: []const u8) void {
    if (@hasDecl(FilePageStore, "CrashTag")) {
        const Tag = FilePageStore.CrashTag;
        if (@hasField(Tag, tag_name)) {
            const tag = @field(Tag, tag_name);
            if (@hasDecl(FilePageStore, "test_crash_hook")) {
                FilePageStore.test_crash_hook = tag;
            } else if (@hasField(FilePageStore, "test_crash_hook")) {
                fps.test_crash_hook = tag;
            }
        }
    }
}

fn discardedOf(fps: *const FilePageStore) bool {
    if (@hasDecl(FilePageStore, "freeListDiscarded")) return fps.freeListDiscarded();
    return false;
}

// ===== 工作负载 =====

fn fmtKey(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "k{d:0>6}", .{i}) catch unreachable;
}

fn fmtVal(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "v{d:0>6}", .{i}) catch unreachable;
}

/// put 指定下标的 key（一次性 putBatch：打洞路径一条提交写多页链）。
fn putSubset(db: *Db, comptime accept: fn (usize) bool) !void {
    var entries = std.ArrayList(cube.Entry).empty;
    defer {
        for (entries.items) |e| {
            alloc.free(e.key);
            alloc.free(e.value);
        }
        entries.deinit(alloc);
    }
    for (0..N) |i| {
        if (!accept(i)) continue;
        const k = try std.fmt.allocPrint(alloc, "k{d:0>6}", .{i});
        errdefer alloc.free(k);
        const v = try alloc.alloc(u8, val_len);
        errdefer alloc.free(v);
        @memset(v, '.');
        _ = try std.fmt.bufPrint(v, "v{d:0>6}", .{i});
        try entries.append(alloc, .{ .key = k, .value = v, .tombstone = false });
    }
    try db.putBatch(entries.items);
}

fn acceptAll(i: usize) bool {
    return i < N;
}
fn acceptEven(i: usize) bool {
    return i % 2 == 0;
}

/// 前置态：400 个 key 全写入，再被一条全区间墓碑整体遮蔽。
fn buildPreState(path: []const u8) !void {
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();
    try putSubset(db, acceptAll);
    try db.deleteRange(null, null);
}

/// armed commit：给全部偶数 key 打洞（一条墓碑链，多页）。
fn punchEven(db: *Db) !void {
    try putSubset(db, acceptEven);
}

// ===== 子进程 =====

fn childCrashAt(comptime tag_name: []const u8, comptime armed: bool, path_z: [:0]const u8) noreturn {
    var fps = FilePageStore.init(alloc, path_z) catch c._exit(2);
    var db = Db.open(alloc, fps.store(), .{}) catch c._exit(3);
    if (armed) armCrashHook(&fps, tag_name);
    punchEven(db) catch c._exit(4);
    db.close();
    fps.deinit();
    c._exit(0);
}

// ===== 父进程侧校验 =====

fn countVisible(db: *Db) !usize {
    var it = try db.select(null, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    return n;
}

/// ① + ② + ③：按「armed commit 是否落盘」校验可见性与三口径一致。
fn expectPunchState(db: *Db, armed_landed: bool, label: []const u8) !void {
    var kbuf: [16]u8 = undefined;
    var vbuf: [16]u8 = undefined;
    for (0..N) |i| {
        const k = fmtKey(&kbuf, i);
        const want_visible = armed_landed and (i % 2 == 0);
        const got = try db.get(k);
        defer if (got) |v| alloc.free(v);
        if (want_visible) {
            const v = got orelse {
                std.debug.print("{s}: key {s} should be visible but is missing\n", .{ label, k });
                return error.ExpectedVisible;
            };
            const want = fmtVal(&vbuf, i);
            if (v.len < want.len or !std.mem.eql(u8, v[0..want.len], want)) {
                std.debug.print("{s}: key {s} value mismatch\n", .{ label, k });
                return error.ValueMismatch;
            }
        } else if (got != null) {
            std.debug.print("{s}: key {s} MUST be invisible (landed={s})\n", .{ label, k, if (armed_landed) "yes" else "no" });
            return error.UnexpectedVisible;
        }
    }
    const vis = try countVisible(db);
    const ec = db.entryCount();
    if (vis != ec) {
        std.debug.print("{s}: entryCount={d} but visible={d} — counts disagree\n", .{ label, ec, vis });
        return error.CountDisagreement;
    }
    const want_count: usize = if (armed_landed) N / 2 else 0;
    if (vis != want_count) {
        std.debug.print("{s}: visible={d}, want {d}\n", .{ label, vis, want_count });
        return error.WrongVisibleCount;
    }
}

/// expectPunchState 的静默孪生：逻辑逐条一致，但所有失败路径不打印 ——
/// T-38-6 NB-2：投机探测（landed=true 那次尝试）按定义多半失败，若打印会让
/// build runner 对**成功** step 回显 stderr 并打 `failed command:`（gate1 假红）。
/// 正式校验仍走会打印的 expectPunchState（断言强度不变）。
fn expectPunchStateSilent(db: *Db, armed_landed: bool) !void {
    var kbuf: [16]u8 = undefined;
    var vbuf: [16]u8 = undefined;
    for (0..N) |i| {
        const k = fmtKey(&kbuf, i);
        const want_visible = armed_landed and (i % 2 == 0);
        const got = try db.get(k);
        defer if (got) |v| alloc.free(v);
        if (want_visible) {
            const v = got orelse return error.ExpectedVisible;
            const want = fmtVal(&vbuf, i);
            if (v.len < want.len or !std.mem.eql(u8, v[0..want.len], want)) return error.ValueMismatch;
        } else if (got != null) {
            return error.UnexpectedVisible;
        }
    }
    const vis = try countVisible(db);
    const ec = db.entryCount();
    if (vis != ec) return error.CountDisagreement;
    const want_count: usize = if (armed_landed) N / 2 else 0;
    if (vis != want_count) return error.WrongVisibleCount;
}

/// 判断 armed commit 是否落盘（原子的两种合法态之一），并做 ④ 校验。
fn checkAfterCrash(path: []const u8, label: []const u8) !bool {
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();

    const landed = blk: {
        // T-38-6 NB-2: speculative probe is silent (was expectPunchState(db, true, label),
        // whose stderr prints leaked into a green build's `failed command:` line).
        expectPunchStateSilent(db, true) catch break :blk false;
        break :blk true;
    };
    try expectPunchState(db, landed, label);

    // ④ 分区不变量 + 链未被丢弃
    const meta = (try fps.store().readMeta()) orelse return error.NoMeta;
    var rep = try part.classify(alloc, fps.store(), meta);
    defer rep.deinit();
    part.dump(&rep, label);
    try part.expectDisjoint(&rep);
    try std.testing.expectEqual(false, discardedOf(&fps));

    tdiag.print("{s}: armed_landed={s} tomb_head={d} visible={d}\n", .{
        label,
        if (landed) "yes" else "no",
        meta.tomb_head,
        try countVisible(db),
    });
    return landed;
}

/// ⑤ 再写一轮（全删 + 全写，两条发布路径都走）+ 重开 + 逐 key 复查值。
fn writeRoundAndRecheck(path: []const u8, label: []const u8) !void {
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try db.deleteRange(null, null); // commitTombSwap 路径
        try putSubset(db, acceptAll); // 打洞路径（一次提交写多页链）
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
                std.debug.print("{s}: post-round key {s} missing (clobbered?)\n", .{ label, k });
                return error.PostRoundKeyMissing;
            };
            defer alloc.free(v);
            const want = fmtVal(&vbuf, i);
            if (v.len < want.len or !std.mem.eql(u8, v[0..want.len], want)) {
                std.debug.print("{s}: post-round key {s} value clobbered\n", .{ label, k });
                return error.PostRoundValueClobbered;
            }
        }
        try std.testing.expectEqual(@as(u64, N), db.entryCount());
        try std.testing.expectEqual(@as(usize, N), try countVisible(db));

        const meta = (try fps.store().readMeta()) orelse return error.NoMeta;
        var rep = try part.classify(alloc, fps.store(), meta);
        defer rep.deinit();
        try part.expectDisjoint(&rep); // 无页同时属于两类 = 无双分配
        tdiag.print("{s}: post-round recheck OK (last_page={d})\n", .{ label, meta.last_page });
    }
}

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

/// 一个注入点：建前置态 -> fork 出 armed 子进程 -> 崩溃后校验格与复查。
fn runCrashCase(comptime tag_name: []const u8, comptime armed: bool, path: []const u8) !void {
    defer unlinkPath(path);
    try buildPreState(path);
    {
        // 前置态自检（防止 RED 因工作负载写错而假绿）
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try std.testing.expectEqual(@as(u64, 0), db.entryCount());
        try std.testing.expectEqual(@as(usize, 0), try countVisible(db));
    }

    const pz = try alloc.dupeZ(u8, path);
    defer alloc.free(pz);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childCrashAt(tag_name, armed, pz);

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);

    if (armed) {
        // armed 子进程必须在注入点被拿下：非 0 退出（_exit）或 SIGABRT。
        // 若它正常 _exit(0)，说明注入点没生效 —— 这正是 main 上的 RED 症状。
        const sig: c_int = status & 0x7f;
        if (status == 0) {
            std.debug.print("injection point '{s}' never fired: child completed normally\n", .{tag_name});
        }
        try std.testing.expect(status != 0);
        try std.testing.expect(sig == 0 or sig == c.SIGABRT);
    }

    const label = if (armed) tag_name else "unarmed-baseline";
    _ = try checkAfterCrash(path, label);
    try writeRoundAndRecheck(path, label);

    // 契约最后收口：该标签必须存在
    if (armed) try std.testing.expect(hookHasTag(tag_name));
}

// ===== 用例 =====

test "T-38-5 before_tomb_chain: 崩溃于写任何墓碑链页之前" {
    try runCrashCase("before_tomb_chain", true, ".test_tomb_crash_before_chain.db");
}

test "T-38-5 mid_tomb_chain: 崩溃于多页墓碑链写了一半" {
    try runCrashCase("mid_tomb_chain", true, ".test_tomb_crash_mid_chain.db");
}

test "T-38-5 after_tomb_chain_before_meta: 崩溃于链已写完、元数据未切换" {
    // 最锋利的一例：旧元数据仍当值，它的链页不得已被本次提交回收，
    // 否则恢复会读到一条指着活页的链。
    try runCrashCase("after_tomb_chain_before_meta", true, ".test_tomb_crash_after_chain.db");
}

test "T-38-5-b: 无 hook 的基线（子进程完整提交后退出）" {
    // 控制组：保持测试自身诚实 —— 若格只在 armed 下成立，就什么也没证明。
    try runCrashCase("after_tomb_chain_before_meta", false, ".test_tomb_crash_baseline.db");
}

test "T-38-5 契约: CrashTag 必须暴露三个墓碑链注入点" {
    try std.testing.expect(@hasDecl(FilePageStore, "CrashTag"));
    if (@hasDecl(FilePageStore, "CrashTag")) {
        try std.testing.expect(@hasField(FilePageStore.CrashTag, "before_tomb_chain"));
        try std.testing.expect(@hasField(FilePageStore.CrashTag, "mid_tomb_chain"));
        try std.testing.expect(@hasField(FilePageStore.CrashTag, "after_tomb_chain_before_meta"));
    }
    try std.testing.expect(crashHookAvailable());
}

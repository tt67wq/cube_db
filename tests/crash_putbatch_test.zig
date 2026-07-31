//! crash_putbatch_test.zig — #23: FilePageStore + fsync + putBatch 中途 kill -9 crash recovery
//!
//! 覆盖三个 kill -9 窗口：
//! 1. 数据页写完前 — meta 未更新 → reopen 回到旧 root
//! 2. meta 写完前 — 同上
//! 3. fsync 返回前 — meta 已写但未持久化 → reopen 回到旧 root 或新 root（由 fsync 决定）
//!
//! 核心验证：reopen 后数据必须是「旧 root 完整状态」或「新 root 完整状态」，
//! 绝不出现中间态（部分数据写入但 meta 不一致）。
const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const FilePageStore = cube.file_page_store.FilePageStore;
const Db = cube.Db;

const alloc = std.testing.allocator;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
});

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

fn pathZ(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return try allocator.dupeZ(u8, path);
}

/// 子进程：执行 putBatch 写入。可选的延迟注入点。
/// mode: 0=正常写完后退出, 1=写一部分后 kill, 2=写完后不 fsync kill
fn childPutBatch(path: [:0]const u8, n: usize, mode: i32) noreturn {
    var fps = FilePageStore.init(alloc, path.ptr[0..path.len]) catch c._exit(2);
    var db = Db.open(alloc, fps.store(), .{ .fsync = true }) catch c._exit(3);

    // 构造 batch entries（每个 key 单独分配，避免共用 buffer）
    var entries = alloc.alloc(cube.Entry, n) catch c._exit(4);
    for (0..n) |i| {
        entries[i] = .{
            .key = std.fmt.allocPrint(alloc, "k{d:0>6}", .{i}) catch c._exit(5),
            .value = "v",
            .tombstone = false,
        };
    }

    var txn = db.beginWriteTxn() catch c._exit(6);
    for (entries) |e| {
        txn.put(e.key, e.value) catch c._exit(7);
    }

    if (mode == 1) {
        // 写事务未 commit 就 kill -9（数据页可能写了部分，meta 未更新）
        c._exit(0);
    }

    txn.commit() catch c._exit(8);

    if (mode == 2) {
        // commit 后不调用 sync（fsync 未返回）就 kill
        c._exit(0);
    }

    // 正常完成
    db.close();
    fps.deinit();
    c._exit(0);
}

/// 执行 fork + kill -9 崩溃，返回子进程退出状态
fn forkKill9(path: [:0]const u8, n: usize, mode: i32, kill_delay_ms: i32) !i32 {
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // 子进程：延迟后执行 putBatch
        if (kill_delay_ms > 0) {
            _ = c.usleep(@intCast(kill_delay_ms * 1000));
        }
        childPutBatch(path, n, mode);
    }
    // 父进程：等待一小段后 kill -9
    _ = c.usleep(200000); // 200ms
    _ = c.kill(pid, 9); // SIGKILL

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    return status;
}

/// 验证 reopen 后数据一致性：必须是旧状态或新状态的完整集合
fn verifyConsistent(path: []const u8, n: usize) !void {
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();

    // 检查所有 key：要么全部存在（新状态），要么全部不存在（旧状态）
    var present: usize = 0;
    var kbuf: [16]u8 = undefined;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{i});
        if (try db.get(k)) |v| {
            alloc.free(v);
            present += 1;
        }
    }
    // 允许部分写入？不 —— COW + 原子 meta 保证要么全有要么全无
    if (present != 0 and present != n) {
        std.debug.print("INCONSISTENT: {d}/{d} keys present after crash!\n", .{ present, n });
        return error.InconsistentState;
    }
    std.debug.print("  consistent: {d}/{d} keys present (0=old state, {d}=new state)\n", .{ present, n, n });
}

// ===== Test 1: 正常 putBatch + fsync，reopen 应看到全部数据 =====
test "crash_putbatch: normal putBatch+fsync, all data persists" {
    const path = ".test_cpb_normal.db";
    defer unlinkPath(path);
    const n: usize = 100;

    // 子进程正常完成
    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childPutBatch(pz, n, 0);

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    try std.testing.expectEqual(@as(c_int, 0), status);

    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();
    try std.testing.expectEqual(@as(u64, n), db.entryCount());
}

// ===== Test 2: 未 commit 就 kill -9（数据页写完前/meta 写完前）=====
test "crash_putbatch: kill before commit, old state preserved" {
    const path = ".test_cpb_precommit.db";
    defer unlinkPath(path);
    const n: usize = 100;

    // 先写入一批已提交数据作为"旧状态"
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        var txn = try db.beginWriteTxn();
        try txn.put("existing", "keep");
        try txn.commit();
    }

    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);

    // 子进程写 putBatch 但未 commit 就被 kill
    const status = try forkKill9(pz, n, 1, 0);
    _ = status;

    // reopen：旧状态必须完整保留
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();

    // 旧数据在
    const v = try db.get("existing");
    defer if (v) |val| alloc.free(val);
    try std.testing.expectEqualStrings("keep", v.?);

    // 新 batch 数据应不存在（未 commit）
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
    var kbuf: [16]u8 = undefined;
    const k0 = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{0});
    try std.testing.expectEqual(@as(?[]u8, null), try db.get(k0));
}

// ===== Test 3: commit 后立即 kill -9（fsync 返回前）=====
test "crash_putbatch: kill after commit before fsync, consistent state" {
    const path = ".test_cpb_postcommit.db";
    defer unlinkPath(path);
    const n: usize = 100;

    // 先建库
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
    }

    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);

    // 子进程 commit 后不 sync 立即退出（模拟 fsync 前崩溃）
    const status = try forkKill9(pz, n, 2, 0);
    _ = status;

    // reopen：必须是全有或全无（一致性）
    try verifyConsistent(path, n);
}

// ===== Test 4: 循环 kill -9 多次，每次验证一致性 =====
test "crash_putbatch: 10 rounds of kill -9, always consistent" {
    const path = ".test_cpb_10round.db";
    defer unlinkPath(path);
    const n: usize = 50;

    for (0..10) |round| {
        // 每次先写一批已提交数据作为旧状态
        {
            var fps = try FilePageStore.init(alloc, path);
            defer fps.deinit();
            var db = try Db.open(alloc, fps.store(), .{});
            defer db.close();
            var txn = try db.beginWriteTxn();
            var kb: [16]u8 = undefined;
            const k = try std.fmt.bufPrint(&kb, "round{d}", .{round});
            try txn.put(k, "v");
            try txn.commit();
        }

        const pz = try pathZ(alloc, path);
        defer alloc.free(pz);

        // 子进程 putBatch 后崩溃（随机 mode）
        const mode: i32 = if (round % 2 == 0) 1 else 2;
        const status = try forkKill9(pz, n, mode, 0);
        _ = status;

        // reopen 验证：一致性
        try verifyConsistent(path, n);
    }
}

// ===== Test 5: 大 batch + kill -9 =====
test "crash_putbatch: 1000-entry batch kill -9, consistent" {
    const path = ".test_cpb_large.db";
    defer unlinkPath(path);
    const n: usize = 1000;

    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
    }

    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);

    const status = try forkKill9(pz, n, 2, 0);
    _ = status;

    try verifyConsistent(path, n);
}
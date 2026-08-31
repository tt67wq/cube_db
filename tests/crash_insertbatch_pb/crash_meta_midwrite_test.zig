//! crash_meta_midwrite_test.zig — T-6: meta 写入中途崩溃测试
//! 覆盖 src/writer.zig:435-439 writeMeta + sync 之间的崩溃窗口。
//!
//! 策略（方案 C）：fork 子进程，用 fsync=false 提交（writeMeta 执行但 sync 不执行），
//! 然后立即 _exit(0) 模拟崩溃。reopen 后验证：
//!   - meta 校验和有效（db 可正常 open，不 panic）
//!   - 数据要么全有（新 meta 已生效）要么全无（旧 meta 兜底）
//!   - 绝不出现 meta 页校验和失效导致全库不可读
//!
//! 另测 fsync=true + commit 中途 kill -9（更宽窗口，覆盖 writeMeta-sync 之间）。
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

/// 子进程：用 fsync=false putBatch 一批 key，commit 后 _exit（sync 未调用）。
/// writeMeta 已执行（meta 页写入 mmap），但 fsync 未调用 → 模拟 writeMeta-sync 间崩溃。
fn childCommitNoSync(path: [:0]const u8, n: usize) noreturn {
    var fps = FilePageStore.init(alloc, path) catch c._exit(2);
    defer fps.deinit();
    // fsync=false：commit 走 writeMeta 但跳过 sync
    var db = Db.open(alloc, fps.store(), .{ .fsync = false }) catch c._exit(3);
    defer db.close();

    var entries = alloc.alloc(cube.Entry, n) catch c._exit(4);
    for (0..n) |i| {
        entries[i] = .{
            .key = std.fmt.allocPrint(alloc, "k{d:0>6}", .{i}) catch c._exit(5),
            .value = "v",
            .tombstone = false,
        };
    }

    // putBatch → applyBatch → writeMeta（已执行）→ skip sync（fsync=false）
    db.putBatch(entries) catch c._exit(6);
    // close 会 flush pending + deinit，但不再 sync
    // _exit 直接退出，模拟崩溃
    c._exit(0);
}

/// 子进程：用 fsync=true putBatch 一批 key，在 commit 过程中 kill -9。
/// 父进程在短延迟后 kill，可能命中 writeMeta-sync 之间窗口。
fn childCommitKillable(path: [:0]const u8, n: usize) noreturn {
    var fps = FilePageStore.init(alloc, path) catch c._exit(2);
    var db = Db.open(alloc, fps.store(), .{ .fsync = true }) catch c._exit(3);

    var entries = alloc.alloc(cube.Entry, n) catch c._exit(4);
    for (0..n) |i| {
        entries[i] = .{
            .key = std.fmt.allocPrint(alloc, "k{d:0>6}", .{i}) catch c._exit(5),
            .value = "v",
            .tombstone = false,
        };
    }

    db.putBatch(entries) catch c._exit(6);
    // 若执行到这里，commit 已完成（包括 fsync）
    db.close();
    fps.deinit();
    c._exit(0);
}

/// 验证 reopen 后数据一致性：要么全有要么全无，meta 校验和有效
fn verifyMetaConsistency(path: []const u8, n: usize) !void {
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();

    // db 能 open = meta 校验和有效（readMetaPage 选了有效 meta 页）
    // 数据要么全有要么全无
    var present: usize = 0;
    var kbuf: [16]u8 = undefined;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{i});
        if (try db.get(k)) |v| {
            alloc.free(v);
            present += 1;
        }
    }
    if (present != 0 and present != n) {
        std.debug.print("INCONSISTENT: {d}/{d} keys present after meta crash!\n", .{ present, n });
        return error.InconsistentState;
    }
}

// ===== Test 1: fsync=false commit 后 _exit，reopen meta 一致 =====
test "crash_meta: fsync=false commit then exit, reopen meta consistent" {
    const path = ".test_cmm_nosync.db";
    defer unlinkPath(path);

    // 先建空库
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
    }

    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);

    const n: usize = 100;
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childCommitNoSync(pz, n);

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    // 子进程应正常退出（_exit(0)）
    try std.testing.expectEqual(@as(c_int, 0), status);

    // reopen：meta 必须有效，数据要么全有要么全无
    try verifyMetaConsistency(path, n);
}

// ===== Test 2: fsync=true commit 中途 kill -9，reopen meta 一致 =====
test "crash_meta: kill -9 during commit, reopen meta consistent" {
    const path = ".test_cmm_kill9.db";
    defer unlinkPath(path);

    // 先写入旧状态（已提交数据）
    const n: usize = 100;
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try db.putDirect("existing", "keep");
    }

    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childCommitKillable(pz, n);

    // 等一小段后 kill -9（可能命中 writeMeta-sync 窗口）
    _ = c.usleep(200000); // 200ms
    _ = c.kill(pid, 9);

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);

    // reopen：旧数据应在，新数据要么全有要么全无
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();

    // 旧状态数据存活
    const v = try db.get("existing");
    defer if (v) |val| alloc.free(val);
    try std.testing.expectEqualStrings("keep", v.?);

    // 新 batch 一致性：要么全有要么全无
    var present: usize = 0;
    var kbuf: [16]u8 = undefined;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{i});
        if (try db.get(k)) |val| {
            alloc.free(val);
            present += 1;
        }
    }
    try std.testing.expect(present == 0 or present == n);
}

// ===== Test 3: 多轮 writeMeta 崩溃，每次 reopen 一致 =====
test "crash_meta: 5 rounds of nosync commit, always consistent" {
    const path = ".test_cmm_5round.db";
    defer unlinkPath(path);

    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
    }

    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);

    for (0..5) |round| {
        // 每轮 fork 子进程做 nosync commit
        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            // 子进程：putBatch 一批新 key（每轮不同 key 前缀）
            var fps = FilePageStore.init(alloc, pz) catch c._exit(2);
            var db = Db.open(alloc, fps.store(), .{ .fsync = false }) catch c._exit(3);
            var entries = alloc.alloc(cube.Entry, 10) catch c._exit(4);
            for (0..10) |i| {
                entries[i] = .{
                    .key = std.fmt.allocPrint(alloc, "r{d}_k{d}", .{ round, i }) catch c._exit(5),
                    .value = "v",
                    .tombstone = false,
                };
            }
            db.putBatch(entries) catch c._exit(6);
            db.close();
            fps.deinit();
            c._exit(0);
        }

        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);

        // 每轮后 reopen 验证 meta 一致
        try verifyMetaConsistency(path, 0);
    }
}

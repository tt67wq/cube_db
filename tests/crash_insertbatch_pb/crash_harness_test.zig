//! crash_harness_test.zig — P4 TDD: 真实进程崩溃 harness（fork+kill）
//! 模拟崩溃：fork 子进程写/不写后 _exit，父进程 reopen 验证一致性。
//! COW + 原子 meta 切换保证：未提交的写入崩溃后不污染已提交数据。

const std = @import("std");
const cube = @import("cube_db");
const FilePageStore = cube.file_page_store.FilePageStore;
const Db = cube.Db;

const alloc = std.testing.allocator;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/wait.h");
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

/// 子进程：写入并提交（fsync）后正常退出
fn childCommitExit(path: [:0]const u8, k: []const u8, v: []const u8) noreturn {
    var fps = FilePageStore.init(alloc, path) catch c._exit(2);
    defer fps.deinit();
    var db = Db.open(alloc, fps.store(), .{}) catch c._exit(3);
    defer db.close();
    var txn = db.beginWriteTxn() catch c._exit(4);
    txn.put(k, v) catch c._exit(5);
    txn.commit() catch c._exit(6);
    c._exit(0);
}

test "crash harness: child commits cleanly, parent reopens sees data" {
    const path = ".test_crashfork_commit.db";
    defer unlinkPath(path);
    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childCommitExit(pz, "c1", "child1");

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    try std.testing.expectEqual(@as(c_int, 0), status); // 子正常退出

    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();
    const v = try db.get("c1");
    defer if (v) |val| alloc.free(val);
    try std.testing.expectEqualStrings("child1", v.?);
}

/// 子进程：写入但提交前 _exit（崩溃）→ 父 reopen 不应有该写入
fn childCrashBeforeCommit(path: [:0]const u8, committed_k: []const u8, committed_v: []const u8, lost_k: []const u8, lost_v: []const u8) noreturn {
    var fps = FilePageStore.init(alloc, path) catch c._exit(2);
    defer fps.deinit();
    var db = Db.open(alloc, fps.store(), .{}) catch c._exit(3);
    defer db.close();
    // 先提交一笔（应存活）
    var t1 = db.beginWriteTxn() catch c._exit(4);
    t1.put(committed_k, committed_v) catch c._exit(5);
    t1.commit() catch c._exit(6);
    // 再开写事务写第二笔，但 _exit 前不 commit（崩溃）→ 不应落盘
    var t2 = db.beginWriteTxn() catch c._exit(7);
    t2.put(lost_k, lost_v) catch c._exit(8);
    // 模拟崩溃：不 commit 直接退出
    c._exit(0);
}

test "crash harness: child crashes before commit, uncommitted write lost, committed survives" {
    const path = ".test_crashfork_lost.db";
    defer unlinkPath(path);
    // 先父进程建空库
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
    }
    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childCrashBeforeCommit(pz, "keep", "K", "lost", "L");

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);

    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();
    // committed 笔存活
    const k = try db.get("keep");
    defer if (k) |val| alloc.free(val);
    try std.testing.expectEqualStrings("K", k.?);
    // 未提交的写入应丢失
    const l = try db.get("lost");
    defer if (l) |val| alloc.free(val);
    try std.testing.expectEqual(@as(?[]u8, null), l);
}

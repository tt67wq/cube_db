//! crash_harness_test.zig - P4 TDD: real process-crash harness (fork+kill)
//! Crash simulation: fork a child that writes (or not) then _exit; the parent reopens and verifies consistency.
//! COW + atomic meta switching guarantee: uncommitted writes never pollute committed data after a crash.
//!
//! T-62 flock 语义差（防回归注记）：macOS/BSD 的 flock 按进程关联（同进程经新 fd
//! 再 flock 会转换成功），Linux 严格按 open file description 判冲突——同进程双开、
//! 或锁持有者死后仍有继承者（fork 复制的 fd 表）存活，都会 error.FileLocked。
//! 本文件的 fork 子进程入口必须调 closeInheritedFds（本文件 helper），
//! parent 的 reopen 站点用 openWithRetry（有界重试，仅对 FileLocked）。
//! 详见 issues/T-62-macos-flock-reopen-ci-red.md；不要删这些卫生调用。

const std = @import("std");
const cube = @import("cube_db");
const FilePageStore = cube.file_page_store.FilePageStore;
const Db = cube.Db;
const tdiag = @import("test_diag.zig");

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

/// Child process: write and commit (fsync), then exit normally
fn childCommitExit(path: [:0]const u8, k: []const u8, v: []const u8) noreturn {
    tdiag.closeInheritedFds(&.{});
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
    try std.testing.expectEqual(@as(c_int, 0), status); // child exited normally

    var fps = try tdiag.initStoreWithRetry(FilePageStore, alloc, path, 10);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();
    const v = try db.get("c1");
    defer if (v) |val| alloc.free(val);
    try std.testing.expectEqualStrings("child1", v.?);
}

/// Child process: write but _exit before commit (crash) -> parent reopen must not see the write
fn childCrashBeforeCommit(path: [:0]const u8, committed_k: []const u8, committed_v: []const u8, lost_k: []const u8, lost_v: []const u8) noreturn {
    tdiag.closeInheritedFds(&.{});
    var fps = FilePageStore.init(alloc, path) catch c._exit(2);
    defer fps.deinit();
    var db = Db.open(alloc, fps.store(), .{}) catch c._exit(3);
    defer db.close();
    // commit one record first (should survive)
    var t1 = db.beginWriteTxn() catch c._exit(4);
    t1.put(committed_k, committed_v) catch c._exit(5);
    t1.commit() catch c._exit(6);
    // open another write txn for a second record, but _exit before commit (crash) -> must not hit disk
    var t2 = db.beginWriteTxn() catch c._exit(7);
    t2.put(lost_k, lost_v) catch c._exit(8);
    // simulate crash: exit without committing
    c._exit(0);
}

test "crash harness: child crashes before commit, uncommitted write lost, committed survives" {
    const path = ".test_crashfork_lost.db";
    defer unlinkPath(path);
    // parent creates an empty DB first
    {
        var fps = try tdiag.initStoreWithRetry(FilePageStore, alloc, path, 10);
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

    var fps = try tdiag.initStoreWithRetry(FilePageStore, alloc, path, 10);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();
    // committed record survives
    const k = try db.get("keep");
    defer if (k) |val| alloc.free(val);
    try std.testing.expectEqualStrings("K", k.?);
    // uncommitted write must be lost
    const l = try db.get("lost");
    defer if (l) |val| alloc.free(val);
    try std.testing.expectEqual(@as(?[]u8, null), l);
}

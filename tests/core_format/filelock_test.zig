//! filelock_test.zig - T-34 RED: 多进程打开防护（advisory file lock）
//!
//! Spec: .agents/tasks/t34-filelock/task.md. FilePageStore.init currently opens the
//! file with O_RDWR|O_CREAT and mmaps it with NO cross-process mutual exclusion:
//! a second process opening the same path gets its own OFD, its own pool, and the
//! two writers clobber each other's meta slots and (post-T-33) freelist chain
//! pages silently.
//!
//! GREEN contract under test: init takes `flock(fd, LOCK_EX | LOCK_NB)` right
//! after open; when the lock is held by anyone else (another process, or another
//! fd in this process — flock conflicts are per open-file-description, not per
//! process), init closes the fd and returns `error.FileLocked`. The lock is
//! released by deinit (close of the fd) and, on holder death, by the kernel
//! closing the fd — no stale locks.
//!
//! RED status on main (31b63b5): there is no flock, so
//!   - A1 (in-process second open)  : the second init SUCCEEDS → expectError fails
//!   - A1-fork (child open)         : child exits 7 ("unexpectedly opened") → parent assert fails
//!   - A2 / A3 are controls that already pass on main and must stay green after GREEN.
//!
//! Fork discipline (the OFD-inheritance trap from the shared spec):
//!   - A1-fork: the PARENT holds the store; the child opens a *fresh* fd (new
//!     OFD) → legitimately conflicts post-GREEN. The inherited parent fd is never
//!     used by the child.
//!   - A3: the parent holds NOTHING while the child is the sole holder; the
//!     parent only opens after kill -9 + waitpid. No inheritance hazard.
//!   Children use std.heap.page_allocator: a forked child shares the testing
//!   allocator's internal state with the parent — never touch it after fork.
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

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
});

const alloc = std.testing.allocator;

fn unlinkPath(path: []const u8) void {
    const pz = alloc.dupeZ(u8, path) catch return;
    defer alloc.free(pz);
    _ = c.unlink(pz);
}

fn pathZ(path: []const u8) ![:0]u8 {
    return alloc.dupeZ(u8, path);
}

/// Exit codes of the forked children (distinct from crash-test conventions on
/// purpose: every non-zero, non-signal exit here is a test-verdict, not a crash).
const exit_got_lock = 42; // child saw error.FileLocked (the expected outcome)
const exit_opened = 7; // child opened successfully (the T-34 bug, post-GREEN impossible)
const exit_other = 3; // any other error / unexpected path

// ===== A1: same-process second concurrent open is rejected =====


// ===== T-62: Linux flock reopen 卫生（本文件独立副本；core_format 目录不引 test_diag） =====
//
// macOS/BSD 的 flock 按进程关联（同进程经新 fd 再 flock 会转换成功）；Linux 严格
// 按 open file description 判冲突——锁持有者死后仍有继承者（fork 复制的 fd 表）存活
// 时会 error.FileLocked。A3 的子进程入口先关闭继承 fd（保留管道写端），kill+waitpid
// 后的 reopen 用有界重试（仅对 FileLocked）。详见 issues/T-62-macos-flock-reopen-ci-red.md。

const f62_c = @cImport({
    @cInclude("unistd.h");
});

fn closeInheritedFds(except: []const c_int) void {
    var fd: c_int = 3;
    while (fd < 1024) : (fd += 1) {
        var keep = false;
        for (except) |x| {
            if (x == fd) keep = true;
        }
        if (!keep) _ = f62_c.close(fd);
    }
}

fn initStoreWithRetry(path: []const u8, attempts: usize) !FilePageStore {
    var attempt: usize = 0;
    while (true) {
        if (FilePageStore.init(alloc, path)) |fps| {
            return fps;
        } else |e| {
            if (e != error.FileLocked or attempt >= attempts) return e;
            var req: std.c.timespec = .{ .sec = 0, .nsec = 50_000_000 };
            _ = std.c.nanosleep(&req, null);
            attempt += 1;
        }
    }
}

test "filelock A1: second concurrent open of the same path returns error.FileLocked" {
    const path = ".test_filelock_a1.db";
    defer unlinkPath(path);

    var a = try FilePageStore.init(alloc, path);
    defer a.deinit();

    // A different fd in the SAME process still conflicts: flock is per
    // open-file-description, not per process. This is the in-process form of
    // "two writers", and the minimal pin of the GREEN contract.
    // RED on main: init succeeds, expectError fails.
    var second = FilePageStore.init(alloc, path) catch |err| {
        try std.testing.expectEqual(error.FileLocked, err);
        return;
    };
    // RED on main: control reaches here — the path opened a second time with no
    // lock at all. Close the stray store (fd + 1TB mmap), then fail the test.
    second.deinit();
    return error.TestUnexpectedResult; // opened without the lock — T-34 not implemented
}

// ===== A2: close releases; the path reopens immediately =====

test "filelock A2: after deinit the same path can be reopened" {
    const path = ".test_filelock_a2.db";
    defer unlinkPath(path);

    {
        var a = try FilePageStore.init(alloc, path);
        a.deinit(); // explicit, before the reopen
    }

    var b = try FilePageStore.init(alloc, path);
    b.deinit();
}

// ===== A1-fork: a real second process is rejected =====

test "filelock A1-fork: child process open while parent holds is rejected" {
    const path = ".test_filelock_a1f.db";
    defer unlinkPath(path);

    var a = try FilePageStore.init(alloc, path);
    defer a.deinit();

    const pz = try pathZ(path);
    defer alloc.free(pz);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Child: fresh open → fresh OFD. Post-GREEN this must hit the flock held
        // by the parent's (inherited but unused) fd. RED on main: it opens fine.
        // T-62: 仍先关继承 fd——锁语义不变（parent 的锁在 parent 自己的 fd 上）。
        closeInheritedFds(&.{});
        var s = FilePageStore.init(std.heap.page_allocator, pz) catch |err| {
            c._exit(if (err == error.FileLocked) exit_got_lock else exit_other);
        };
        s.deinit();
        c._exit(exit_opened);
    }

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    const code: u32 = @as(u32, @intCast(status >> 8)) & 0xff;
    // RED on main: code == exit_opened (7) → this assertion fails.
    try std.testing.expectEqual(exit_got_lock, code);
}

// ===== A3: the lock dies with a killed holder =====

test "filelock A3: kill -9 the holder, the lock is released by the kernel" {
    const path = ".test_filelock_a3.db";
    defer unlinkPath(path);

    const pz = try pathZ(path);
    defer alloc.free(pz);

    // Pipe: the child writes one byte AFTER its init returns, so the parent
    // knows the lock is held before it kills.
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.close(fds[0]);
        // T-62: 关继承 fd，但保留管道写端 fds[1]（parent 靠它感知锁已持有）
        closeInheritedFds(&.{fds[1]});
        var s = FilePageStore.init(std.heap.page_allocator, pz) catch c._exit(exit_other);
        _ = c.write(fds[1], "L", 1); // lock (should be) held
        // Hold until killed. sleep in a loop: nanosleep may return early.
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            var req: std.c.timespec = .{ .sec = 1, .nsec = 0 };
            _ = std.c.nanosleep(&req, null);
        }
        s.deinit(); // unreachable in practice (parent kills us); keep symmetry
        c._exit(0);
    }

    _ = c.close(fds[1]);
    var got: u8 = 0;
    while (true) {
        const n = c.read(fds[0], &got, 1);
        if (n == 1) break; // child holds the lock
        if (n == 0) return error.ChildDiedEarly; // EOF: child exited before signalling
    }
    _ = c.close(fds[0]);

    // SIGKILL the holder: the kernel closes its fds, the flock must evaporate.
    _ = c.kill(pid, c.SIGKILL);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    try std.testing.expectEqual(@as(c_int, c.SIGKILL), status & 0x7f);

    // The parent held nothing; the sole holder is dead. Reopen must succeed.
    // T-62: 有界重试——Linux 上 SIGKILL+waitpid 后的瞬态 FileLocked（CI 实证）。
    var b = try initStoreWithRetry(pz, 10);
    b.deinit();
}

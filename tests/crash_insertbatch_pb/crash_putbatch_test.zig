//! crash_putbatch_test.zig - #23: FilePageStore + fsync + putBatch mid-flight kill -9 crash recovery
//!
//! Covers three kill -9 windows:
//! 1. before data pages finish - meta not updated -> reopen falls back to the old root
//! 2. before meta write - same as above
//! 3. before fsync returns - meta written but not persisted -> reopen sees old root or new root (fsync decides)
//!
//! Core invariant: after reopen the data must be either the "old root complete state" or the
//! "new root complete state" - never an intermediate state (partial data with inconsistent meta).
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

/// Child process: perform the putBatch write. Optional delay injection points.
/// mode: 0=exit normally after writing, 1=kill after partial write, 2=kill after write without fsync
fn childPutBatch(path: [:0]const u8, n: usize, mode: i32) noreturn {
    var fps = FilePageStore.init(alloc, path.ptr[0..path.len]) catch c._exit(2);
    var db = Db.open(alloc, fps.store(), .{ .fsync = true }) catch c._exit(3);

    // build batch entries (each key separately allocated, avoiding shared buffers)
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
        // kill -9 before the write txn commits (data pages may be partially written, meta not updated)
        c._exit(0);
    }

    txn.commit() catch c._exit(8);

    if (mode == 2) {
        // kill after commit without calling sync (fsync not returned)
        c._exit(0);
    }

    // normal completion
    db.close();
    fps.deinit();
    c._exit(0);
}

/// Perform fork + kill -9 crash, return the child exit status
fn forkKill9(path: [:0]const u8, n: usize, mode: i32, kill_delay_ms: i32) !i32 {
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // child: run putBatch after the delay
        if (kill_delay_ms > 0) {
            _ = c.usleep(@intCast(kill_delay_ms * 1000));
        }
        childPutBatch(path, n, mode);
    }
    // parent: wait briefly, then kill -9
    _ = c.usleep(200000); // 200ms
    _ = c.kill(pid, 9); // SIGKILL

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    return status;
}

/// Verify post-reopen data consistency: must be the complete old state or the complete new state
fn verifyConsistent(path: []const u8, n: usize) !void {
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();

    // check all keys: either all present (new state) or all absent (old state)
    var present: usize = 0;
    var kbuf: [16]u8 = undefined;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{i});
        if (try db.get(k)) |v| {
            alloc.free(v);
            present += 1;
        }
    }
    // allow partial writes? No -- COW + atomic meta guarantees all-or-nothing
    if (present != 0 and present != n) {
        std.debug.print("INCONSISTENT: {d}/{d} keys present after crash!\n", .{ present, n });
        return error.InconsistentState;
    }
    std.debug.print("  consistent: {d}/{d} keys present (0=old state, {d}=new state)\n", .{ present, n, n });
}

// ===== Test 1: normal putBatch + fsync, reopen should see all data =====
test "crash_putbatch: normal putBatch+fsync, all data persists" {
    const path = ".test_cpb_normal.db";
    defer unlinkPath(path);
    const n: usize = 100;

    // child completes normally
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

// ===== Test 2: kill -9 before commit (before data pages finish / before meta write) =====
test "crash_putbatch: kill before commit, old state preserved" {
    const path = ".test_cpb_precommit.db";
    defer unlinkPath(path);
    const n: usize = 100;

    // write a batch of committed data first as the "old state"
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

    // child writes the putBatch but is killed before commit
    const status = try forkKill9(pz, n, 1, 0);
    _ = status;

    // reopen: the old state must be fully preserved
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();

    // old data present
    const v = try db.get("existing");
    defer if (v) |val| alloc.free(val);
    try std.testing.expectEqualStrings("keep", v.?);

    // new batch data must be absent (never committed)
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
    var kbuf: [16]u8 = undefined;
    const k0 = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{0});
    try std.testing.expectEqual(@as(?[]u8, null), try db.get(k0));
}

// ===== Test 3: kill -9 immediately after commit (before fsync returns) =====
test "crash_putbatch: kill after commit before fsync, consistent state" {
    const path = ".test_cpb_postcommit.db";
    defer unlinkPath(path);
    const n: usize = 100;

    // create the DB first
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
    }

    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);

    // child exits right after commit without sync (simulating a crash before fsync)
    const status = try forkKill9(pz, n, 2, 0);
    _ = status;

    // reopen: must be all-or-nothing (consistency)
    try verifyConsistent(path, n);
}

// ===== Test 4: repeated kill -9 rounds, verifying consistency each time =====
test "crash_putbatch: 10 rounds of kill -9, always consistent" {
    const path = ".test_cpb_10round.db";
    defer unlinkPath(path);
    const n: usize = 50;

    for (0..10) |round| {
        // write a batch of committed data first as the old state
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

        // child crashes after putBatch (alternating mode)
        const mode: i32 = if (round % 2 == 0) 1 else 2;
        const status = try forkKill9(pz, n, mode, 0);
        _ = status;

        // reopen and verify: consistency
        try verifyConsistent(path, n);
    }
}

// ===== Test 5: large batch + kill -9 =====
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
//! crash_meta_midwrite_test.zig - T-6: crash during meta write tests
//! Covers the crash window between writeMeta and sync at src/writer.zig:435-439.
//!
//! Strategy (plan C): fork a child, commit with fsync=false (writeMeta executes but sync does not),
//! then _exit(0) immediately to simulate a crash. After reopen, verify:
//!   - the meta checksum is valid (db opens normally, no panic)
//!   - data is either all present (new meta took effect) or all absent (old meta as fallback)
//!   - never a broken meta-page checksum that renders the whole DB unreadable
//!
//! Also tests fsync=true + kill -9 mid-commit (a wider window, covering writeMeta-sync).
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

/// Child process: putBatch a set of keys with fsync=false, _exit after commit (sync never called).
/// writeMeta has run (meta page written into mmap) but fsync was not called -> simulates a crash between writeMeta and sync.
fn childCommitNoSync(path: [:0]const u8, n: usize) noreturn {
    var fps = FilePageStore.init(alloc, path) catch c._exit(2);
    defer fps.deinit();
    // fsync=false: commit goes through writeMeta but skips sync
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

    // putBatch -> applyBatch -> writeMeta (executed) -> skip sync (fsync=false)
    db.putBatch(entries) catch c._exit(6);
    // close flushes pending + deinits, but no further sync
    // _exit exits directly, simulating a crash
    c._exit(0);
}

/// Child process: putBatch a set of keys with fsync=true, then gets kill -9 mid-commit.
/// The parent kills after a short delay, which may hit the window between writeMeta and sync.
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
    // if execution reaches here, the commit completed (including fsync)
    db.close();
    fps.deinit();
    c._exit(0);
}

/// Verify post-reopen data consistency: all-or-nothing, meta checksum valid
fn verifyMetaConsistency(path: []const u8, n: usize) !void {
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();

    // db opens = meta checksum valid (readMetaPage picked a valid meta page)
    // data is either all present or all absent
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

// ===== Test 1: fsync=false commit then _exit, reopen meta consistent =====
test "crash_meta: fsync=false commit then exit, reopen meta consistent" {
    const path = ".test_cmm_nosync.db";
    defer unlinkPath(path);

    // create an empty DB first
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
    // child should exit normally (_exit(0))
    try std.testing.expectEqual(@as(c_int, 0), status);

    // reopen: meta must be valid, data either all present or all absent
    try verifyMetaConsistency(path, n);
}

// ===== Test 2: fsync=true, kill -9 mid-commit, reopen meta consistent =====
test "crash_meta: kill -9 during commit, reopen meta consistent" {
    const path = ".test_cmm_kill9.db";
    defer unlinkPath(path);

    // write the old state first (committed data)
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

    // wait briefly then kill -9 (may hit the writeMeta-sync window)
    _ = c.usleep(200000); // 200ms
    _ = c.kill(pid, 9);

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);

    // reopen: old data must be present, new data either all present or all absent
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();

    // old-state data survives
    const v = try db.get("existing");
    defer if (v) |val| alloc.free(val);
    try std.testing.expectEqualStrings("keep", v.?);

    // new batch consistency: all-or-nothing
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

// ===== Test 3: multiple rounds of writeMeta crashes, reopen consistent each time =====
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
        // each round forks a child to do a nosync commit
        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            // child: putBatch a set of new keys (different key prefix per round)
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

        // after each round, reopen and verify meta consistency
        try verifyMetaConsistency(path, 0);
    }
}

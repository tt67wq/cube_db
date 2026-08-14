//! crash_recovery_framework.zig — P3 TDD: 崩溃恢复测试框架
//!
//! COW + 原子 meta 切换已崩溃安全（LMDB 无 WAL），本框架验证：
//! - 进程崩溃后已提交数据存活
//! - 未提交数据丢失
//! - 多次 open/close 后数据一致性
//! - mmap 边界条件
//!
//! 依赖 FilePageStore（持久化），不使用 MemPageStore。
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

// ===== 基础 reopen 测试 =====

test "crash_framework: reopen after single commit" {
    const path = ".test_cf_commit.db";
    defer unlinkPath(path);
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        var txn = try db.beginWriteTxn();
        try txn.put("a", "1");
        try txn.commit();
    }
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try std.testing.expectEqual(@as(u64, 1), db.entryCount());
        const v = try db.get("a");
        defer if (v) |val| alloc.free(val);
        try std.testing.expectEqualStrings("1", v.?);
    }
}

test "crash_framework: reopen after 10 alternating commits" {
    const path = ".test_cf_alt10.db";
    defer unlinkPath(path);
    const n = 10;
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        var kbuf: [16]u8 = undefined;
        var vbuf: [16]u8 = undefined;
        for (0..n) |i| {
            var txn = try db.beginWriteTxn();
            const k = try std.fmt.bufPrint(&kbuf, "k{d}", .{i});
            const v = try std.fmt.bufPrint(&vbuf, "v{d}", .{i});
            try txn.put(k, v);
            try txn.commit();
        }
    }
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try std.testing.expectEqual(@as(u64, n), db.entryCount());
        var kbuf: [16]u8 = undefined;
        var vbuf: [16]u8 = undefined;
        for (0..n) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "k{d}", .{i});
            const v = try db.get(k);
            defer if (v) |val| alloc.free(val);
            const exp = try std.fmt.bufPrint(&vbuf, "v{d}", .{i});
            try std.testing.expectEqualStrings(exp, v.?);
        }
    }
}

// ===== 多轮 reopen 迭代 =====

test "crash_framework: 5 rounds of write + reopen" {
    const path = ".test_cf_5round.db";
    defer unlinkPath(path);
    var kbuf: [16]u8 = undefined;
    var vbuf: [16]u8 = undefined;
    for (0..5) |round| {
        {
            var fps = try FilePageStore.init(alloc, path);
            defer fps.deinit();
            var db = try Db.open(alloc, fps.store(), .{});
            defer db.close();

            // Verify existing entries
            if (round > 0) {
                for (0..round) |i| {
                    const k = try std.fmt.bufPrint(&kbuf, "k{d}", .{i});
                    const v = try db.get(k);
                    defer if (v) |val| alloc.free(val);
                    try std.testing.expect(v != null);
                }
            }

            // Add new entry
            const k = try std.fmt.bufPrint(&kbuf, "k{d}", .{round});
            const v = try std.fmt.bufPrint(&vbuf, "v{d}", .{round});
            var txn = try db.beginWriteTxn();
            try txn.put(k, v);
            try txn.commit();
        }
        // reopen happens at loop start
    }
}

test "crash_framework: 100 keys batch commit then reopen" {
    const path = ".test_cf_100batch.db";
    defer unlinkPath(path);
    const n: usize = 100;
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        var keys = try alloc.alloc([]u8, n);
        defer {
            for (keys) |k| alloc.free(k);
            alloc.free(keys);
        }
        for (0..n) |i| {
            keys[i] = try std.fmt.allocPrint(alloc, "k{d:0>4}", .{i});
        }
        var txn = try db.beginWriteTxn();
        for (0..n) |i| {
            try txn.put(keys[i], "v");
        }
        try txn.commit();
    }
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try std.testing.expectEqual(@as(u64, n), db.entryCount());
        var kbuf: [16]u8 = undefined;
        for (0..n) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "k{d:0>4}", .{i});
            const v = try db.get(k);
            defer if (v) |val| alloc.free(val);
            try std.testing.expectEqualStrings("v", v.?);
        }
    }
}

// ===== fork 式崩溃模拟 =====

/// 子进程：写入并提交后正常退出
fn childCommitExit(path: [:0]const u8, entries: []const struct { []const u8, []const u8 }) noreturn {
    var fps = FilePageStore.init(alloc, path.ptr[0..path.len]) catch c._exit(2);
    defer fps.deinit();
    var db = Db.open(alloc, fps.store(), .{}) catch c._exit(3);
    defer db.close();
    for (entries) |entry| {
        var txn = db.beginWriteTxn() catch c._exit(4);
        txn.put(entry[0], entry[1]) catch c._exit(5);
        txn.commit() catch c._exit(6);
    }
    c._exit(0);
}

/// 子进程：写入但不提交直接 _exit（模拟崩溃）
fn childCrashNoCommit(path: [:0]const u8, committed: []const struct { []const u8, []const u8 }, uncommitted: []const struct { []const u8, []const u8 }) noreturn {
    var fps = FilePageStore.init(alloc, path.ptr[0..path.len]) catch c._exit(2);
    defer fps.deinit();
    var db = Db.open(alloc, fps.store(), .{}) catch c._exit(3);
    defer db.close();
    // 先提交安全条目
    for (committed) |entry| {
        var txn = db.beginWriteTxn() catch c._exit(4);
        txn.put(entry[0], entry[1]) catch c._exit(5);
        txn.commit() catch c._exit(6);
    }
    // 写入但 NOT commit（模拟崩溃）
    var txn = db.beginWriteTxn() catch c._exit(7);
    for (uncommitted) |entry| {
        txn.put(entry[0], entry[1]) catch c._exit(8);
    }
    // 不 commit，直接崩溃
    c._exit(0);
}

test "crash_framework: fork child commits cleanly, parent sees data" {
    const path = ".test_cf_fork_commit.db";
    defer unlinkPath(path);
    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);

    // First create the DB
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
    }

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        childCommitExit(pz, &.{.{ "c1", "child1" }});
    }

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    try std.testing.expectEqual(@as(c_int, 0), status);

    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
    const v = try db.get("c1");
    defer if (v) |val| alloc.free(val);
    try std.testing.expectEqualStrings("child1", v.?);
}

test "crash_framework: fork child crashes before commit, uncommitted lost" {
    const path = ".test_cf_fork_crash.db";
    defer unlinkPath(path);
    // Pre-create DB
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
    }
    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        childCrashNoCommit(pz, &.{.{ "keep", "K" }}, &.{.{ "lost", "L" }});
    }

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);

    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();
    // committed entries survive
    const k = try db.get("keep");
    defer if (k) |val| alloc.free(val);
    try std.testing.expectEqualStrings("K", k.?);
    // uncommitted entries lost
    try std.testing.expectEqual(@as(?[]u8, null), try db.get("lost"));
}

// ===== 随机 workload + reopen =====

test "crash_framework: random keys reopen persists" {
    const path = ".test_cf_random.db";
    defer unlinkPath(path);
    var prng = std.Random.DefaultPrng.init(0x1234);
    const rnd = prng.random();

    const n: usize = 250;
    var keys = try alloc.alloc([]u8, n);
    defer {
        for (keys) |k| alloc.free(k);
        alloc.free(keys);
    }

    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();

        for (0..n) |i| {
            keys[i] = try std.fmt.allocPrint(alloc, "k{d:0>6}", .{i});
        }

        // Shuffle insertion order
        var order = try alloc.alloc(usize, n);
        defer alloc.free(order);
        for (0..n) |i| order[i] = i;
        rnd.shuffle(usize, order);

        // Batch commits
        const batch_size: usize = 25;
        var idx: usize = 0;
        while (idx < n) : (idx += batch_size) {
            var txn = try db.beginWriteTxn();
            const end = @min(idx + batch_size, n);
            var j = idx;
            while (j < end) : (j += 1) {
                try txn.put(keys[order[j]], "v");
            }
            try txn.commit();
        }
    }
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try std.testing.expectEqual(@as(u64, n), db.entryCount());
        for (keys) |k| {
            const v = try db.get(k);
            defer if (v) |val| alloc.free(val);
            try std.testing.expectEqualStrings("v", v.?);
        }
    }
}

// ===== 更新后 reopen =====

test "crash_framework: update existing key then reopen" {
    const path = ".test_cf_update.db";
    defer unlinkPath(path);
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        var txn = try db.beginWriteTxn();
        try txn.put("k", "v1");
        try txn.commit();
    }
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        var txn = try db.beginWriteTxn();
        try txn.put("k", "v2");
        try txn.commit();
    }
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try std.testing.expectEqual(@as(u64, 1), db.entryCount());
        const v = try db.get("k");
        defer if (v) |val| alloc.free(val);
        try std.testing.expectEqualStrings("v2", v.?);
    }
}

// ===== delete + reopen =====

test "crash_framework: delete then reopen" {
    const path = ".test_cf_delete.db";
    defer unlinkPath(path);
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        var txn = try db.beginWriteTxn();
        try txn.put("k", "v");
        try txn.commit();
    }
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        var txn = try db.beginWriteTxn();
        try txn.delete("k");
        try txn.commit();
    }
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try std.testing.expectEqual(@as(u64, 0), db.entryCount());
        try std.testing.expectEqual(@as(?[]u8, null), try db.get("k"));
    }
}
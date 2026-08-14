//! crash_recovery_test.zig — P3 TDD: 崩溃恢复
//! COW + 原子 meta 切换已崩溃安全（LMDB 无 WAL）。本测试验证恢复路径：
//! - commit 后 reopen → 已提交数据在（双 meta 选较新有效页）
//! - 多次交替提交 reopen → 最新版本可见
//! - 单 meta 页损坏 → 另一页兜底恢复（双 meta 容错）

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const FilePageStore = cube.file_page_store.FilePageStore;
const Db = cube.Db;

const alloc = std.testing.allocator;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

test "recovery: commit then reopen persists" {
    const path = ".test_crash_commit.db";
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
        const v = try db.get("a");
        defer if (v) |val| alloc.free(val);
        try std.testing.expectEqualStrings("1", v.?);
    }
}

test "recovery: multiple alternating commits, reopen sees latest" {
    const path = ".test_crash_alt.db";
    defer unlinkPath(path);
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        // 多次提交（触发 meta0/meta1 交替）
        var i: u8 = 0;
        while (i < 6) : (i += 1) {
            var txn = try db.beginWriteTxn();
            var kb: [4]u8 = undefined;
            const k = std.fmt.bufPrint(&kb, "k{d}", .{i}) catch unreachable;
            var vb: [4]u8 = undefined;
            const v = std.fmt.bufPrint(&vb, "v{d}", .{i}) catch unreachable;
            try txn.put(k, v);
            try txn.commit();
        }
    }
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        var i: u8 = 0;
        while (i < 6) : (i += 1) {
            var kb: [4]u8 = undefined;
            const k = std.fmt.bufPrint(&kb, "k{d}", .{i}) catch unreachable;
            const v = try db.get(k);
            defer if (v) |val| alloc.free(val);
            var vb: [4]u8 = undefined;
            const exp = std.fmt.bufPrint(&vb, "v{d}", .{i}) catch unreachable;
            try std.testing.expectEqualStrings(exp, v.?);
        }
    }
}

test "recovery: one meta page corrupted, other meta recovers" {
    const path = ".test_crash_corrupt.db";
    defer unlinkPath(path);
    // 两次提交：meta0/meta1 均有效（提交1→meta0, 提交2→meta1 为最新）
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        var t1 = try db.beginWriteTxn();
        try t1.put("survivor", "yes");
        try t1.commit();
        var t2 = try db.beginWriteTxn();
        try t2.put("k1", "v1");
        try t2.commit();
    }
    // 损坏 meta0（旧/非活动页），meta1 仍有效 → 恢复用 meta1
    {
        const pathz = try toZ(alloc, path);
        defer alloc.free(pathz);
        const fd = c.open(pathz, @as(c_int, c.O_RDWR));
        if (fd < 0) return error.OpenFailed;
        defer _ = c.close(fd);
        const off: i64 = @intCast(f2.PAGE_SIZE); // meta0 = page 1
        const zero: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
        _ = c.pwrite(fd, @ptrCast(&zero), zero.len, off);
    }
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        // meta1（最新）在 → survivor 与 k1 均在
        const s = try db.get("survivor");
        defer if (s) |val| alloc.free(val);
        try std.testing.expectEqualStrings("yes", s.?);
        const k = try db.get("k1");
        defer if (k) |val| alloc.free(val);
        try std.testing.expectEqualStrings("v1", k.?);
    }
}

fn toZ(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return try allocator.dupeZ(u8, path);
}

test "durability: async mode (fsync=false) + explicit sync() persists" {
    const path = ".test_crash_async.db";
    defer unlinkPath(path);
    // async 模式：commit 不自动 fsync
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{ .fsync = false });
        defer db.close();
        var txn = try db.beginWriteTxn();
        try txn.put("a1", "b1");
        try txn.commit();
        // async：commit 未 fsync；显式 sync 后才 durable
        try db.sync();
    }
    // 重开：显式 sync 过的数据应在
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        const v = try db.get("a1");
        defer if (v) |val| alloc.free(val);
        try std.testing.expectEqualStrings("b1", v.?);
    }
}

test "durability: default (fsync=true) commit is durable on reopen" {
    const path = ".test_crash_sync.db";
    defer unlinkPath(path);
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{}); // fsync 默认 true
        defer db.close();
        var txn = try db.beginWriteTxn();
        try txn.put("s1", "t1");
        try txn.commit();
        // 默认 sync on commit，无需显式 sync
    }
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        const v = try db.get("s1");
        defer if (v) |val| alloc.free(val);
        try std.testing.expectEqualStrings("t1", v.?);
    }
}

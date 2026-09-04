//! crash_recovery_test.zig - P3 TDD: crash recovery
//! COW + atomic meta switching is already crash-safe (LMDB-style, no WAL). These tests verify the recovery paths:
//! - commit then reopen -> committed data present (dual meta, picking the newer valid page)
//! - multiple alternating commits then reopen -> latest version visible
//! - one meta page corrupted -> the other page recovers (dual-meta fault tolerance)

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
        // multiple commits (triggering meta0/meta1 alternation)
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
    // two commits: both meta0/meta1 valid (commit 1 -> meta0, commit 2 -> meta1 as latest)
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
    // corrupt meta0 (old/inactive page), meta1 still valid -> recovery uses meta1
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
        // meta1 (latest) is present -> both survivor and k1 are there
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
    // async mode: commit does not fsync automatically
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{ .fsync = false });
        defer db.close();
        var txn = try db.beginWriteTxn();
        try txn.put("a1", "b1");
        try txn.commit();
        // async: commit did not fsync; durable only after explicit sync
        try db.sync();
    }
    // reopen: data explicitly synced should be present
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
        var db = try Db.open(alloc, fps.store(), .{}); // fsync defaults to true
        defer db.close();
        var txn = try db.beginWriteTxn();
        try txn.put("s1", "t1");
        try txn.commit();
        // sync on commit by default, no explicit sync needed
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

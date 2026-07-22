//! db 集成测试：open→写→读→select→close 全链路，纯同步 API
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");

const Db = cube.Db;

fn withDb(comptime body: fn (db: *Db) anyerror!void) !void {
    const path = "cube_db_itest.db";
    zio.Dir.cwd().deleteFile(path) catch {};
    defer zio.Dir.cwd().deleteFile(path) catch {};

    const db = try Db.open(std.testing.allocator, path, .{});
    defer db.close() catch {};
    try body(db);
}

test "db: put then get" {
    const B = struct {
        fn body(db: *Db) !void {
            try db.put("k", "v");
            const v = try db.get("k");
            try std.testing.expect(v != null);
            try std.testing.expectEqualStrings("v", v.?);
            std.testing.allocator.free(v.?);
        }
    }.body;
    try withDb(B);
}

test "db: overwrite" {
    const B = struct {
        fn body(db: *Db) !void {
            try db.put("k", "v1");
            try db.put("k", "v2");
            const v = try db.get("k");
            try std.testing.expectEqualStrings("v2", v.?);
            std.testing.allocator.free(v.?);
        }
    }.body;
    try withDb(B);
}

test "db: delete" {
    const B = struct {
        fn body(db: *Db) !void {
            try db.put("k", "v");
            try db.delete("k");
            const v = try db.get("k");
            try std.testing.expectEqual(@as(?[]u8, null), v);
        }
    }.body;
    try withDb(B);
}

test "db: reopen reads persisted data" {
    const path = "cube_db_reopen.db";
    zio.Dir.cwd().deleteFile(path) catch {};
    defer zio.Dir.cwd().deleteFile(path) catch {};

    {
        const db = try Db.open(std.testing.allocator, path, .{});
        defer db.close() catch {};
        try db.put("persisted", "yes");
    }
    {
        const db = try Db.open(std.testing.allocator, path, .{});
        defer db.close() catch {};
        const v = try db.get("persisted");
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings("yes", v.?);
        std.testing.allocator.free(v.?);
    }
}

test "db: select range" {
    const B = struct {
        fn body(db: *Db) !void {
            const keys = [_][]const u8{ "a", "b", "c", "d" };
            for (keys) |k| try db.put(k, "v");
            var it = try db.select("b", "d");
            defer it.deinit();
            var got = std.ArrayList([]const u8).empty;
            defer got.deinit(std.testing.allocator);
            while (try it.next()) |e| {
                try got.append(std.testing.allocator, try std.testing.allocator.dupe(u8, e.key));
            }
            try std.testing.expectEqual(@as(usize, 2), got.items.len);
            try std.testing.expectEqualStrings("b", got.items[0]);
            try std.testing.expectEqualStrings("c", got.items[1]);
            for (got.items) |g| std.testing.allocator.free(g);
        }
    }.body;
    try withDb(B);
}

test "db: concurrent puts all visible" {
    const path = "cube_db_concurrent.db";
    zio.Dir.cwd().deleteFile(path) catch {};
    defer zio.Dir.cwd().deleteFile(path) catch {};
    zio.Dir.cwd().deleteFile(path ++ ".compact") catch {};
    defer zio.Dir.cwd().deleteFile(path ++ ".compact") catch {};

    const db = try Db.open(std.testing.allocator, path, .{});
    defer db.close() catch {};

    const putter = struct {
        fn run(pdb: *Db, base: u32) !void {
            var i: u32 = 0;
            while (i < 100) : (i += 1) {
                var kbuf: [16]u8 = undefined;
                const klen = (try std.fmt.bufPrint(&kbuf, "{d}", .{base * 1000 + i})).len;
                try pdb.put(kbuf[0..klen], "v");
            }
        }
    }.run;

    var threads: [10]std.Thread = undefined;
    for (0..10) |i| {
        threads[i] = try std.Thread.spawn(.{}, putter, .{ db, @as(u32, @intCast(i)) });
    }
    for (threads) |t| t.join();

    // verify
    var ok: u32 = 0;
    var b: u32 = 0;
    while (b < 10) : (b += 1) {
        var i: u32 = 0;
        while (i < 100) : (i += 1) {
            var kbuf: [16]u8 = undefined;
            const klen = (try std.fmt.bufPrint(&kbuf, "{d}", .{b * 1000 + i})).len;
            const v = try db.get(kbuf[0..klen]);
            if (v != null) {
                ok += 1;
                std.testing.allocator.free(v.?);
            }
        }
    }
    try std.testing.expectEqual(@as(u32, 1000), ok);
}

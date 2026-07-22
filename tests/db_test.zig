//! db 集成测试：open→写→读→select→close 全链路，需 zio runtime
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");

const Db = cube.Db;

fn withDb(comptime body: fn (db: *Db) anyerror!void) !void {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const cwd = zio.Dir.cwd();
    const path = "cube_db_itest.db";
    cwd.deleteFile(path) catch {};
    defer cwd.deleteFile(path) catch {};

    const Runner = struct {
        fn run(p: []const u8, r: *zio.Runtime) !void {
            const db = try Db.open(std.testing.allocator, r, p, .{});
            defer db.close() catch {};
            try body(db);
        }
    };
    var h = try rt.spawn(Runner.run, .{ path, rt });
    h.join() catch {};
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
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const cwd = zio.Dir.cwd();
    const path = "cube_db_reopen.db";
    cwd.deleteFile(path) catch {};
    defer cwd.deleteFile(path) catch {};

    const Runner = struct {
        fn run(p: []const u8, r: *zio.Runtime) !void {
            // 第一次：写并关闭
            {
                const db = try Db.open(std.testing.allocator, r, p, .{});
                defer db.close() catch {};
                try db.put("persisted", "yes");
            }
            // 第二次：重开读
            {
                const db = try Db.open(std.testing.allocator, r, p, .{});
                defer db.close() catch {};
                const v = try db.get("persisted");
                try std.testing.expect(v != null);
                try std.testing.expectEqualStrings("yes", v.?);
                std.testing.allocator.free(v.?);
            }
        }
    };
    var h = try rt.spawn(Runner.run, .{ path, rt });
    h.join() catch {};
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
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const cwd = zio.Dir.cwd();
    const path = "cube_db_concurrent.db";
    cwd.deleteFile(path) catch {};
    defer cwd.deleteFile(path) catch {};

    const Setup = struct {
        fn run(p: []const u8, r: *zio.Runtime) !void {
            const db = try Db.open(std.testing.allocator, r, p, .{});
            defer db.close() catch {};
            var group: zio.Group = .init;
            defer group.cancel();
            for (0..10) |i| {
                try group.spawn(putter, .{ db, @as(u32, @intCast(i)) });
            }
            try group.wait();
        }
        fn putter(db: *Db, base: u32) !void {
            var i: u32 = 0;
            while (i < 100) : (i += 1) {
                var kbuf: [16]u8 = undefined;
                const klen = (try std.fmt.bufPrint(&kbuf, "{d}", .{base * 1000 + i})).len;
                try db.put(kbuf[0..klen], "v");
            }
        }
    };
    var sh = try rt.spawn(Setup.run, .{ path, rt });
    sh.join() catch {};

    // verify
            const V = struct {
        fn run(p: []const u8, r: *zio.Runtime) !void {
            const db = try Db.open(std.testing.allocator, r, p, .{});
            defer db.close() catch {};
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
    };
    var vh = try rt.spawn(V.run, .{ path, rt });
    vh.join() catch {};
}

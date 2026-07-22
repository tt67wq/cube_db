const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const Db = cube.Db;

test "db: manual compact keeps data" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const cwd = zio.Dir.cwd();
    const path = "cube_db_compact_test.db";
    cwd.deleteFile(path) catch {};
    defer cwd.deleteFile(path) catch {};
    cwd.deleteFile("cube_db_compact_test.db.compact") catch {};

    const T = struct {
        fn run(p: []const u8, r: *zio.Runtime) !void {
            const db = try Db.open(std.testing.allocator, r, p, .{});
            defer db.close() catch {};
            for (0..50) |i| {
                var kbuf: [16]u8 = undefined;
                const k = try std.fmt.bufPrint(&kbuf, "{d}", .{i});
                try db.put(k, "v");
            }
            try db.compact();
            // verify all
            for (0..50) |i| {
                var kbuf: [16]u8 = undefined;
                const k = try std.fmt.bufPrint(&kbuf, "{d}", .{i});
                const v = try db.get(k);
                if (v == null) return error.TestUnexpectedResult;
                std.testing.allocator.free(v.?);
            }
        }
    };
    var h = try rt.spawn(T.run, .{ path, rt });
    h.join() catch {};
}

test "db: compact then reopen" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const cwd = zio.Dir.cwd();
    const path = "cube_db_compact_reopen.db";
    cwd.deleteFile(path) catch {};
    defer cwd.deleteFile(path) catch {};
    cwd.deleteFile("cube_db_compact_reopen.db.compact") catch {};

    const T = struct {
        fn run(p: []const u8, r: *zio.Runtime) !void {
            const db = try Db.open(std.testing.allocator, r, p, .{});
            try db.put("keep1", "v1");
            try db.put("keep2", "v2");
            try db.compact();
            try db.close();
        }
    };
    var h = try rt.spawn(T.run, .{ path, rt });
    h.join() catch {};

    const R = struct {
        fn run(p: []const u8, r: *zio.Runtime) !void {
            const db = try Db.open(std.testing.allocator, r, p, .{});
            defer db.close() catch {};
            const v1 = try db.get("keep1");
            try std.testing.expectEqualStrings("v1", v1.?);
            std.testing.allocator.free(v1.?);
            const v2 = try db.get("keep2");
            try std.testing.expectEqualStrings("v2", v2.?);
            std.testing.allocator.free(v2.?);
        }
    };
    var rh = try rt.spawn(R.run, .{ path, rt });
    rh.join() catch {};
}

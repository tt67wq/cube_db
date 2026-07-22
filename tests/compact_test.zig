const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const Db = cube.Db;

test "db: manual compact keeps data" {
    const path = "cube_db_compact_test.db";
    zio.Dir.cwd().deleteFile(path) catch {};
    defer zio.Dir.cwd().deleteFile(path) catch {};
    zio.Dir.cwd().deleteFile(path ++ ".compact") catch {};
    defer zio.Dir.cwd().deleteFile(path ++ ".compact") catch {};

    const db = try Db.open(std.testing.allocator, path, .{});
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

test "db: compact then reopen" {
    const path = "cube_db_compact_reopen.db";
    zio.Dir.cwd().deleteFile(path) catch {};
    defer zio.Dir.cwd().deleteFile(path) catch {};
    zio.Dir.cwd().deleteFile(path ++ ".compact") catch {};
    defer zio.Dir.cwd().deleteFile(path ++ ".compact") catch {};

    {
        const db = try Db.open(std.testing.allocator, path, .{});
        try db.put("keep1", "v1");
        try db.put("keep2", "v2");
        try db.compact();
        try db.close();
    }
    {
        const db = try Db.open(std.testing.allocator, path, .{});
        defer db.close() catch {};
        const v1 = try db.get("keep1");
        try std.testing.expectEqualStrings("v1", v1.?);
        std.testing.allocator.free(v1.?);
        const v2 = try db.get("keep2");
        try std.testing.expectEqualStrings("v2", v2.?);
        std.testing.allocator.free(v2.?);
    }
}

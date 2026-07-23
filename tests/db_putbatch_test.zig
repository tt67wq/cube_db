//! db_putbatch_test.zig — TDD for Db.putBatch (lever 1)
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const Db = cube.Db;
const Entry = cube.Entry;

fn withDb(comptime body: fn (db: *Db) anyerror!void) !void {
    const path = "cube_db_putbatch_test.db";
    zio.Dir.cwd().deleteFile(path) catch {};
    defer zio.Dir.cwd().deleteFile(path) catch {};
    zio.Dir.cwd().deleteFile(path ++ ".compact") catch {};
    defer zio.Dir.cwd().deleteFile(path ++ ".compact") catch {};
    const db = try Db.open(std.testing.allocator, path, .{});
    defer db.close() catch {};
    try body(db);
}

test "db: putBatch 3 keys then get all" {
    const B = struct {
        fn body(db: *Db) !void {
            const entries = [_]Entry{
                .{ .key = "a", .value = "va" },
                .{ .key = "b", .value = "vb" },
                .{ .key = "c", .value = "vc" },
            };
            try db.putBatch(&entries);
            const va = try db.get("a");
            try std.testing.expectEqualStrings("va", va.?);
            std.testing.allocator.free(va.?);
            const vb = try db.get("b");
            try std.testing.expectEqualStrings("vb", vb.?);
            std.testing.allocator.free(vb.?);
            const vc = try db.get("c");
            try std.testing.expectEqualStrings("vc", vc.?);
            std.testing.allocator.free(vc.?);
        }
    }.body;
    try withDb(B);
}

test "db: putBatch dedup same key last wins" {
    const B = struct {
        fn body(db: *Db) !void {
            const entries = [_]Entry{
                .{ .key = "k", .value = "v1" },
                .{ .key = "k", .value = "v2" },
            };
            try db.putBatch(&entries);
            const v = try db.get("k");
            try std.testing.expectEqualStrings("v2", v.?);
            std.testing.allocator.free(v.?);
        }
    }.body;
    try withDb(B);
}

test "db: putBatch with tombstone deletes" {
    const B = struct {
        fn body(db: *Db) !void {
            const put_entries = [_]Entry{ .{ .key = "k", .value = "v" } };
            try db.putBatch(&put_entries);
            const del_entries = [_]Entry{ .{ .key = "k", .value = "", .tombstone = true } };
            try db.putBatch(&del_entries);
            const v = try db.get("k");
            try std.testing.expectEqual(@as(?[]u8, null), v);
        }
    }.body;
    try withDb(B);
}

test "db: putBatch >32 keys triggers splits, all readable" {
    const B = struct {
        fn body(db: *Db) !void {
            const allocator = std.testing.allocator;
            const entries = try allocator.alloc(Entry, 100);
            defer allocator.free(entries);
            for (entries, 0..) |*e, i| {
                var kbuf: [16]u8 = undefined;
                const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{i});
                e.* = .{ .key = k, .value = "v" };
            }
            try db.putBatch(entries);
            for (entries) |e| {
                const v = try db.get(e.key);
                try std.testing.expectEqualStrings("v", v.?);
                allocator.free(v.?);
            }
        }
    }.body;
    try withDb(B);
}

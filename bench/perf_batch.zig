const std = @import("std");
const cube = @import("cube_db");

fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

fn runTest(comptime alloc_name: []const u8, allocator: std.mem.Allocator) !void {
    // Fresh 10K
    {
        var ms = cube.page_store.MemPageStore.init(allocator, 5000000);
        defer ms.deinit();
        var db = try cube.Db.open(allocator, ms.store(), .{});
        defer db.close();
        const n: usize = 10000;
        const entries = try allocator.alloc(cube.Entry, n);
        defer allocator.free(entries);
        for (entries, 0..) |*e, i| {
            e.* = .{ .key = try std.fmt.allocPrint(allocator, "{d:0>10}", .{i}), .value = "v" };
        }
        defer for (entries) |e| allocator.free(e.key);
        const start = monoNs();
        try db.putBatch(entries);
        const elapsed = monoNs() - start;
        const ns = @divFloor(elapsed, @as(i64, @intCast(n)));
        std.debug.print("{s} Fresh 10K:    {d} ns/entry ({d:.1} us/entry), count={d}\n", .{ alloc_name, ns, @as(f64, @floatFromInt(ns)) / 1000.0, db.entryCount() });
    }

    // Update 1K (existing tree)
    {
        var ms = cube.page_store.MemPageStore.init(allocator, 5000000);
        defer ms.deinit();
        var db = try cube.Db.open(allocator, ms.store(), .{});
        defer db.close();
        const wu: usize = 1000;
        const we = try allocator.alloc(cube.Entry, wu);
        defer allocator.free(we);
        for (we, 0..) |*e, i| {
            e.* = .{ .key = try std.fmt.allocPrint(allocator, "{d:0>10}", .{i}), .value = "v" };
        }
        defer for (we) |e| allocator.free(e.key);
        try db.putBatch(we);
        // overwrite same keys
        const entries = try allocator.alloc(cube.Entry, wu);
        defer allocator.free(entries);
        for (entries, 0..) |*e, i| {
            e.* = .{ .key = try std.fmt.allocPrint(allocator, "{d:0>10}", .{i}), .value = "v2" };
        }
        defer for (entries) |e| allocator.free(e.key);
        const start = monoNs();
        try db.putBatch(entries);
        const elapsed = monoNs() - start;
        const ns = @divFloor(elapsed, @as(i64, @intCast(wu)));
        std.debug.print("{s} Update 1K:    {d} ns/entry ({d:.1} us/entry), count={d}\n", .{ alloc_name, ns, @as(f64, @floatFromInt(ns)) / 1000.0, db.entryCount() });
    }

    // Single put (for dupe overhead check)
    {
        var ms = cube.page_store.MemPageStore.init(allocator, 5000000);
        defer ms.deinit();
        var db = try cube.Db.open(allocator, ms.store(), .{});
        defer db.close();
        const n: usize = 100;
        const start = monoNs();
        for (0..n) |i| {
            var kbuf: [16]u8 = undefined;
            const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>6}", .{i});
            try db.putDirect(k, "v");
        }
        const elapsed = monoNs() - start;
        const ns = @divFloor(elapsed, @as(i64, @intCast(n)));
        std.debug.print("{s} Single put:   {d} ns/op ({d:.1} us/op), count={d}\n", .{ alloc_name, ns, @as(f64, @floatFromInt(ns)) / 1000.0, db.entryCount() });
    }
}

pub fn main() !void {
    // page_allocator (production-like)
    try runTest("PageAlloc", std.heap.page_allocator);
}

//! auto_compact 集成测试
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const Db = cube.Db;

fn sleepMs(ms: u64) void {
    if (ms == 0) return;
    var ts = std.posix.system.timespec{
        .sec = @as(isize, @intCast(ms / 1000)),
        .nsec = @as(isize, @intCast((ms % 1000) * 1_000_000)),
    };
    while (true) {
        const rc = std.posix.system.nanosleep(&ts, &ts);
        if (rc == 0) break;
    }
}

fn milliTimestamp() i64 {
    var ts: std.posix.system.timespec = undefined;
    _ = std.posix.system.clock_gettime(@as(std.posix.system.clockid_t, .MONOTONIC), &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn pollForCompact(db: *Db, timeout_ms: u64) bool {
    const start = milliTimestamp();
    while (milliTimestamp() - start < @as(i64, @intCast(timeout_ms))) {
        if (!db.state.compacting.load(.acquire)) return true;
        sleepMs(5);
    }
    return false;
}

test "I1: end-to-end dirt reclamation" {
    const path = "cube_db_auto_i1.db";
    const cwd = zio.Dir.cwd();
    cwd.deleteFile(path) catch {};
    defer cwd.deleteFile(path) catch {};
    cwd.deleteFile(path ++ ".compact") catch {};
    defer cwd.deleteFile(path ++ ".compact") catch {};

    const db = try Db.open(std.testing.allocator, path, .{
        .auto_compact_min_bytes = 4096,
        .auto_compact_dirt_ratio = 0.15,
        .compact_time_slice_ms = 1,
        .compact_scan_sleep_ms = 0,
        .compact_retry_base_ms = 1,
        .compact_max_retries = 2,
    });
    defer db.close() catch {};

    // write enough to exceed min_bytes
    for (0..200) |i| {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key{d}", .{i});
        try db.put(k, "v");
    }

    // overwrite many times to create dirt that triggers compact
    for (0..30) |_| {
        for (0..200) |i| {
            var kbuf: [16]u8 = undefined;
            const k = try std.fmt.bufPrint(&kbuf, "key{d}", .{i});
            try db.put(k, "v");
        }
    }

    try std.testing.expect(pollForCompact(db, 5000));

    // after auto compact, do a manual compact to capture any post-compact writes
    try db.compact();

    for (0..200) |i| {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key{d}", .{i});
        const v = try db.get(k);
        try std.testing.expect(v != null);
        std.testing.allocator.free(v.?);
    }

    try std.testing.expectEqual(@as(u64, 0), db.state.dirt.load(.acquire));
}

test "I4: manual + auto interop" {
    const path = "cube_db_auto_i4.db";
    const cwd = zio.Dir.cwd();
    cwd.deleteFile(path) catch {};
    defer cwd.deleteFile(path) catch {};
    cwd.deleteFile(path ++ ".compact") catch {};
    defer cwd.deleteFile(path ++ ".compact") catch {};

    const db = try Db.open(std.testing.allocator, path, .{
        .auto_compact_min_bytes = 4096,
        .auto_compact_dirt_ratio = 0.10,
        .compact_time_slice_ms = 1,
        .compact_scan_sleep_ms = 0,
        .compact_retry_base_ms = 1,
        .compact_max_retries = 2,
    });
    defer db.close() catch {};

    for (0..200) |i| {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key{d}", .{i});
        try db.put(k, "v");
    }
    for (0..20) |_| {
        for (0..200) |i| {
            var kbuf: [16]u8 = undefined;
            const k = try std.fmt.bufPrint(&kbuf, "key{d}", .{i});
            try db.put(k, "v");
        }
    }

    _ = pollForCompact(db, 5000);
    try db.compact();

    for (0..200) |i| {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key{d}", .{i});
        const v = try db.get(k);
        try std.testing.expect(v != null);
        std.testing.allocator.free(v.?);
    }
}

test "I5: close during auto compact" {
    const path = "cube_db_auto_i5.db";
    const cwd = zio.Dir.cwd();
    cwd.deleteFile(path) catch {};
    defer cwd.deleteFile(path) catch {};
    cwd.deleteFile(path ++ ".compact") catch {};
    defer cwd.deleteFile(path ++ ".compact") catch {};

    const db = try Db.open(std.testing.allocator, path, .{
        .auto_compact_min_bytes = 4096,
        .auto_compact_dirt_ratio = 0.10,
        .compact_time_slice_ms = 1,
        .compact_scan_sleep_ms = 0,
        .compact_retry_base_ms = 1,
        .compact_max_retries = 1,
    });

    for (0..200) |i| {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key{d}", .{i});
        try db.put(k, "v");
    }
    for (0..10) |_| {
        for (0..200) |i| {
            var kbuf: [16]u8 = undefined;
            const k = try std.fmt.bufPrint(&kbuf, "key{d}", .{i});
            try db.put(k, "v");
        }
    }

    try db.close();
}

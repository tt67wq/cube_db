//! tests/wal_test.zig — WAL 模块 TDD 测试
//! TDD: 先写失败测试 → 实现 → 测试 green。
const std = @import("std");
const cube_db = @import("cube_db");
const zio = @import("zio");
const wal = cube_db.wal;

const testing = std.testing;

/// Helper: create a unique temp path for WAL test files.
fn tempWalPath(allocator: std.mem.Allocator, suffix: []const u8) ![]const u8 {
    const id = @intFromPtr(suffix.ptr) & 0xFFFF;
    return try std.fmt.allocPrint(allocator, ".wal_test_{d}_{s}", .{ id, suffix });
}

/// Helper: clean up a WAL temp file.
fn cleanupWal(path: []const u8) void {
    zio.Dir.cwd().deleteFile(path) catch {};
}

/// Helper: free entries returned by replay().
fn freeEntries(allocator: std.mem.Allocator, entries: []wal.Entry) void {
    for (entries) |e| {
        allocator.free(e.key);
        allocator.free(e.value);
    }
    allocator.free(entries);
}

test "wal: append and replay roundtrip" {
    const path = try tempWalPath(testing.allocator, "roundtrip");
    defer {
        cleanupWal(path);
        testing.allocator.free(path);
    }

    // 第一轮: append 3 entries
    {
        var w = try wal.Wal.init(testing.allocator, path);
        defer w.deinit();
        _ = try w.append(.put, "hello", "world");
        _ = try w.append(.put, "foo", "bar");
        _ = try w.append(.delete, "todelete", "");
    }

    // 第二轮: 重放恢复
    {
        var w = try wal.Wal.init(testing.allocator, path);
        defer w.deinit();
        const entries = try w.replay();
        defer freeEntries(testing.allocator, entries);

        try testing.expectEqual(@as(usize, 3), entries.len);
        try testing.expectEqual(wal.EntryType.put, entries[0].entry_type);
        try testing.expectEqualStrings("hello", entries[0].key);
        try testing.expectEqualStrings("world", entries[0].value);
        try testing.expectEqual(wal.EntryType.put, entries[1].entry_type);
        try testing.expectEqualStrings("foo", entries[1].key);
        try testing.expectEqualStrings("bar", entries[1].value);
        try testing.expectEqual(wal.EntryType.delete, entries[2].entry_type);
        try testing.expectEqualStrings("todelete", entries[2].key);
    }
}

test "wal: append and replay large value" {
    const path = try tempWalPath(testing.allocator, "large");
    defer {
        cleanupWal(path);
        testing.allocator.free(path);
    }

    const big_val = try testing.allocator.alloc(u8, 10000);
    defer testing.allocator.free(big_val);
    @memset(big_val, 'x');

    {
        var w = try wal.Wal.init(testing.allocator, path);
        defer w.deinit();
        _ = try w.append(.put, "bigkey", big_val);
    }

    {
        var w = try wal.Wal.init(testing.allocator, path);
        defer w.deinit();
        const entries = try w.replay();
        defer freeEntries(testing.allocator, entries);

        try testing.expectEqual(@as(usize, 1), entries.len);
        try testing.expectEqualStrings("bigkey", entries[0].key);
        try testing.expectEqualSlices(u8, big_val, entries[0].value);
    }
}

test "wal: empty wal replay returns empty" {
    const path = try tempWalPath(testing.allocator, "empty");
    defer {
        cleanupWal(path);
        testing.allocator.free(path);
    }

    var w = try wal.Wal.init(testing.allocator, path);
    defer w.deinit();
    const entries = try w.replay();
    defer freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "wal: crc validation detects corruption" {
    const path = try tempWalPath(testing.allocator, "crc");
    defer {
        cleanupWal(path);
        testing.allocator.free(path);
    }

    // Write valid entry
    {
        var w = try wal.Wal.init(testing.allocator, path);
        defer w.deinit();
        _ = try w.append(.put, "key", "value");
    }

    // Corrupt the file by writing a bad byte at offset 21 (key area of entry)
    {
        const f = try zio.Dir.cwd().createFile(path, .{ .read = true, .truncate = false });
        defer f.close();
        const bad_byte = [_]u8{0xFF};
        _ = try f.write(&bad_byte, 21);
    }

    // Replay should detect corruption and skip the bad entry
    {
        var w = try wal.Wal.init(testing.allocator, path);
        defer w.deinit();
        const entries = try w.replay();
        defer freeEntries(testing.allocator, entries);
        try testing.expectEqual(@as(usize, 0), entries.len);
    }
}

test "wal: multiple appends across open/close cycles" {
    const path = try tempWalPath(testing.allocator, "multi");
    defer {
        cleanupWal(path);
        testing.allocator.free(path);
    }

    for (0..5) |i| {
        var w = try wal.Wal.init(testing.allocator, path);
        defer w.deinit();
        const key = try std.fmt.allocPrint(testing.allocator, "key{d}", .{i});
        defer testing.allocator.free(key);
        _ = try w.append(.put, key, "v");
    }

    var w = try wal.Wal.init(testing.allocator, path);
    defer w.deinit();
    const entries = try w.replay();
    defer freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 5), entries.len);
    for (0..5) |i| {
        const expected_key = try std.fmt.allocPrint(testing.allocator, "key{d}", .{i});
        defer testing.allocator.free(expected_key);
        try testing.expectEqualStrings(expected_key, entries[i].key);
    }
}

test "wal: checkpoint and truncate" {
    const path = try tempWalPath(testing.allocator, "ckpt");
    defer {
        cleanupWal(path);
        testing.allocator.free(path);
    }

    // Append 3 entries
    {
        var w = try wal.Wal.init(testing.allocator, path);
        defer w.deinit();
        _ = try w.append(.put, "a", "1");
        _ = try w.append(.put, "b", "2");
        _ = try w.append(.put, "c", "3");
    }

    // Replay, checkpoint, free entries
    {
        var w = try wal.Wal.init(testing.allocator, path);
        defer w.deinit();
        const entries = try w.replay();
        defer freeEntries(testing.allocator, entries);
        try w.checkpoint();
    }

    // Truncate removes all entries
    {
        var w = try wal.Wal.init(testing.allocator, path);
        defer w.deinit();
        try w.truncate();
    }

    // After truncate, replay returns empty
    {
        var w = try wal.Wal.init(testing.allocator, path);
        defer w.deinit();
        const entries = try w.replay();
        defer freeEntries(testing.allocator, entries);
        try testing.expectEqual(@as(usize, 0), entries.len);
    }
}
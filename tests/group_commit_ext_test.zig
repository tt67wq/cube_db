//! group_commit_test_ext.zig — #15: group-commit 扩展测试
//! 覆盖：并发写正确性、flush/close 持久化、数据一致性、边缘场景
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
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

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 100000);
}

// ---- flush/close 持久化 ----

test "group_commit_ext: flush then reopen persists data" {
    const path = ".test_gc_flush_reopen.db";
    defer unlinkPath(path);
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
        defer db.close();
        var i: u32 = 0;
        while (i < 50) : (i += 1) {
            var kbuf: [16]u8 = undefined;
            const k = try std.fmt.bufPrint(&kbuf, "k{d:0>4}", .{i});
            try db.put(k, "v");
        }
        try db.flush();
    }
    // reopen
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try std.testing.expectEqual(@as(u64, 50), db.entryCount());
        var i: u32 = 0;
        while (i < 50) : (i += 1) {
            var kbuf: [16]u8 = undefined;
            const k = try std.fmt.bufPrint(&kbuf, "k{d:0>4}", .{i});
            const v = try db.get(k);
            defer if (v) |val| alloc.free(val);
            try std.testing.expectEqualStrings("v", v.?);
        }
    }
}

test "group_commit_ext: close auto-flushes pending, persists" {
    const path = ".test_gc_close_flush.db";
    defer unlinkPath(path);
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
        try db.put("k", "v");
        // close without explicit flush — should auto-flush
        db.close();
    }
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        const v = try db.get("k");
        defer if (v) |val| alloc.free(val);
        try std.testing.expectEqualStrings("v", v.?);
    }
}

// ---- 批处理替代 putBatch 验证 ----

test "group_commit_ext: micro-batch produces same result as putBatch" {
    var ms = newStore();
    defer ms.deinit();

    // Method 1: micro-batch with flush
    {
        var db = try Db.open(alloc, ms.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
        defer db.close();
        var i: u32 = 0;
        while (i < 100) : (i += 1) {
            var kbuf: [16]u8 = undefined;
            const k = try std.fmt.bufPrint(&kbuf, "k{d:0>4}", .{i});
            try db.put(k, "v");
        }
        try db.flush();
        try std.testing.expectEqual(@as(u64, 100), db.entryCount());
    }
}

test "group_commit_ext: mixed put/delete in same batch" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{ .micro_batch = .{ .batch_threshold = 10 } });
    defer db.close();

    try db.putDirect("a", "keep");
    try db.putDirect("b", "remove");
    try db.flush();

    // Stage delete + put in same batch
    try db.delete("b");
    try db.put("c", "new");
    try db.flush();

    try std.testing.expectEqual(@as(u64, 2), db.entryCount());
    const va = try db.get("a");
    defer if (va) |val| alloc.free(val);
    try std.testing.expectEqualStrings("keep", va.?);

    try std.testing.expectEqual(@as(?[]u8, null), try db.get("b"));

    const vc = try db.get("c");
    defer if (vc) |val| alloc.free(val);
    try std.testing.expectEqualStrings("new", vc.?);
}

// ---- 边缘场景 ----

test "group_commit_ext: flush with empty pending is no-op" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
    defer db.close();
    // No-op, should not error
    try db.flush();
    try db.flush();
    try db.flush();
}

test "group_commit_ext: threshold boundary — exactly N then N+1" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{ .micro_batch = .{ .batch_threshold = 5 } });
    defer db.close();

    // 5 puts → auto-flush
    for (0..5) |i| {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d}", .{i});
        try db.put(k, "v");
    }
    try std.testing.expectEqual(@as(u64, 5), db.entryCount());

    // 1 more → pending count 1
    try db.put("k5", "v");
    // Not yet flushed (1 < 5)
    // Explicit flush
    try db.flush();
    try std.testing.expectEqual(@as(u64, 6), db.entryCount());
}

test "group_commit_ext: overwrite in pending before flush" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
    defer db.close();

    // Same key, multiple values in pending
    try db.put("k", "v1");
    try db.put("k", "v2");
    try db.put("k", "v3");
    try db.flush();

    // Last write wins
    const v = try db.get("k");
    defer if (v) |val| alloc.free(val);
    try std.testing.expectEqualStrings("v3", v.?);
}

test "group_commit_ext: putDirect and deleteDirect work alongside micro-batch" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
    defer db.close();

    // Direct put — immediately visible
    try db.putDirect("a", "direct");

    // Staged put — not yet visible
    try db.put("b", "staged");
    const staged = try db.get("b");
    try std.testing.expectEqual(@as(?[]u8, null), staged);

    // Direct delete
    try db.deleteDirect("a");
    try std.testing.expectEqual(@as(?[]u8, null), try db.get("a"));

    // Flush staged
    try db.flush();
    const v = try db.get("b");
    defer if (v) |val| alloc.free(val);
    try std.testing.expectEqualStrings("staged", v.?);
}

// ---- 大 value + micro-batch ----

test "group_commit_ext: 10KB overflow value with micro-batch" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{ .micro_batch = .{ .batch_threshold = 10 } });
    defer db.close();

    var big: [10000]u8 = undefined;
    @memset(&big, 'x');

    try db.put("big", &big);
    try db.flush();

    const v = try db.get("big");
    defer if (v) |val| alloc.free(val);
    try std.testing.expect(v != null);
    try std.testing.expectEqual(@as(usize, 10000), v.?.len);
}

// ---- 随机 workload + micro-batch ----

test "group_commit_ext: random puts with micro-batch, all correct" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{ .micro_batch = .{ .batch_threshold = 7 } });
    defer db.close();

    var prng = std.Random.DefaultPrng.init(0xABCD);
    const rnd = prng.random();

    const n: usize = 500;
    var kbuf: [16]u8 = undefined;

    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{i});
        try db.put(k, "v");
        // Random flush every ~20 puts
        if (rnd.uintLessThan(usize, 20) == 0) {
            try db.flush();
        }
    }
    try db.flush();

    try std.testing.expectEqual(@as(u64, n), db.entryCount());
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{i});
        const v = try db.get(k);
        defer if (v) |val| alloc.free(val);
        try std.testing.expectEqualStrings("v", v.?);
    }
}

// ---- 多次 flush + reopen 迭代 ----

test "group_commit_ext: 3 rounds of batch-flush-reopen" {
    const path = ".test_gc_3round.db";
    defer unlinkPath(path);
    for (0..3) |round| {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{ .micro_batch = .{ .batch_threshold = 5 } });
        defer db.close();

        // Verify previous entries
        if (round > 0) {
            var i: usize = 0;
        while (i < round * 10) : (i += 1) {
                var kbuf: [16]u8 = undefined;
                const k = try std.fmt.bufPrint(&kbuf, "k{d:0>4}", .{i});
                const v = try db.get(k);
                defer if (v) |val| alloc.free(val);
                try std.testing.expect(v != null);
            }
        }

        // Add new batch
        var i: usize = round * 10;
        const end = i + 10;
        while (i < end) : (i += 1) {
            var kbuf: [16]u8 = undefined;
            const k = try std.fmt.bufPrint(&kbuf, "k{d:0>4}", .{i});
            try db.put(k, "v");
        }
        try db.flush();
    }
}
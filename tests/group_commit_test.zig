//! group_commit_test.zig — TDD: micro-batching / group-commit
//! 测试 db.put/delete 暂存后批量提交的行为。
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const Db = cube.Db;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(std.testing.allocator, 100000);
}

// ---- Test 1: put without flush — data not yet visible ----
test "group_commit: put staged, not visible until flush" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
    defer db.close();

    try db.put("k1", "v1");
    try db.put("k2", "v2");

    // Not yet committed — get should not see staged data
    const v = try db.get("k1");
    try std.testing.expectEqual(@as(?[]u8, null), v);

    // After flush, data is visible
    try db.flush();
    const v1 = try db.get("k1");
    try std.testing.expectEqualStrings("v1", v1.?);
    std.testing.allocator.free(v1.?);
}

// ---- Test 2: auto-flush at threshold ----
test "group_commit: auto-flush at threshold" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 3 } });
    defer db.close();

    // Put 3 entries — should auto-flush on the 3rd
    try db.put("a", "1");
    try db.put("b", "2");
    try db.put("c", "3"); // threshold reached → auto-flush

    // All should be visible
    for ([_][]const u8{ "a", "b", "c" }) |k| {
        const v = try db.get(k);
        try std.testing.expect(v != null);
        std.testing.allocator.free(v.?);
    }
}

// ---- Test 3: flush then put more ----
test "group_commit: flush then stage more, flush again" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
    defer db.close();

    try db.put("a", "1");
    try db.flush();

    try db.put("b", "2");
    try db.flush();

    const v1 = try db.get("a");
    try std.testing.expectEqualStrings("1", v1.?);
    std.testing.allocator.free(v1.?);

    const v2 = try db.get("b");
    try std.testing.expectEqualStrings("2", v2.?);
    std.testing.allocator.free(v2.?);
}

// ---- Test 4: close auto-flushes pending ----
test "group_commit: close flushes pending entries" {
    var ms = newStore();
    defer ms.deinit();
    {
        var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
        try db.put("k", "v");
        // close without explicit flush — should auto-flush
        db.close();
    }
    {
        var db = try Db.open(std.testing.allocator, ms.store(), .{});
        defer db.close();
        const v = try db.get("k");
        try std.testing.expectEqualStrings("v", v.?);
        std.testing.allocator.free(v.?);
    }
}

// ---- Test 5: delete is also staged ----
test "group_commit: delete staged then flushed" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
    defer db.close();

    // First put directly (no micro-batch)
    try db.putDirect("k", "v");
    try db.flush();

    // Stage a delete
    try db.delete("k");
    // Still visible before flush
    const v1 = try db.get("k");
    try std.testing.expectEqualStrings("v", v1.?);
    std.testing.allocator.free(v1.?);

    try db.flush();
    // Gone after flush
    const v2 = try db.get("k");
    try std.testing.expectEqual(@as(?[]u8, null), v2);
}

// ---- Test 6: overwrite in same batch — last write wins ----
test "group_commit: overwrite within batch, last write wins" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
    defer db.close();

    try db.put("k", "v1");
    try db.put("k", "v2");
    try db.put("k", "v3");
    try db.flush();

    const v = try db.get("k");
    try std.testing.expectEqualStrings("v3", v.?);
    std.testing.allocator.free(v.?);
}

// ---- Test 7: micro_batch disabled (batch_threshold=1) behaves like direct ----
test "group_commit: threshold=1 auto-flushes each put" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 1 } });
    defer db.close();

    try db.put("a", "1");
    // Immediately visible (threshold=1 auto-flushed)
    const v = try db.get("a");
    try std.testing.expectEqualStrings("1", v.?);
    std.testing.allocator.free(v.?);
}

// ---- Test 8: entryCount reflects committed state ----
test "group_commit: entryCount only counts committed entries" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
    defer db.close();

    try db.put("a", "1");
    try db.put("b", "2");
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());

    try db.flush();
    try std.testing.expectEqual(@as(u64, 2), db.entryCount());
}

// ---- Test 9: putBatch bypasses micro-batch (already a batch) ----
test "group_commit: putBatch is direct, not staged" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
    defer db.close();

    const entries = [_]cube.Entry{
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "2" },
    };
    try db.putBatch(&entries);

    // Immediately visible
    const v = try db.get("a");
    try std.testing.expectEqualStrings("1", v.?);
    std.testing.allocator.free(v.?);
}

// ---- Test 10: 1000 sequential puts with threshold=10 ----
test "group_commit: 1000 puts with threshold=10, all readable after flush" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 10 } });
    defer db.close();

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        try db.put(k, "val");
    }
    try db.flush();

    i = 0;
    while (i < 1000) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        const v = try db.get(k);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings("val", v.?);
        std.testing.allocator.free(v.?);
    }
}

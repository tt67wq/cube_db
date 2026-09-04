//! txn_arena_test.zig — TDD: WriteTxn staging arena
//! Verify correctness after arena-ization: put/delete/commit/abort semantics unchanged,
//! with no leaks and no dangling references when the arena is released.
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const Db = cube.Db;

fn newStore(comptime n: usize) ps.MemPageStore {
    return ps.MemPageStore.init(std.testing.allocator, n);
}

// Test 1: put/commit roundtrip — staged entries applied correctly
test "txn arena: put/commit roundtrip" {
    var ms = newStore(100000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var txn = try db.beginWriteTxn();
    defer txn.deinit();
    try txn.put("key1", "value1");
    try txn.put("key2", "value2");
    try txn.delete("key1");
    try txn.commit();

    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
    try std.testing.expectEqual(@as(?[]u8, null), try db.get("key1"));
    const v2 = try db.get("key2");
    defer if (v2) |v| std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("value2", v2.?);
}

// Test 2: no dirty data after abort (@archon risk point: no dangling references after arena release)
test "txn arena: abort discards staged, no dirty data" {
    var ms = newStore(100000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    // First write one committed entry
    try db.putDirect("base", "keep");

    // Stage in the txn, then abort
    var txn = try db.beginWriteTxn();
    defer txn.deinit();
    try txn.put("aborted1", "x");
    try txn.put("aborted2", "y");
    try txn.delete("base");
    try txn.abort();

    // After abort: the committed data survives, the aborted data does not exist
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
    const v = try db.get("base");
    defer if (v) |val| std.testing.allocator.free(val);
    try std.testing.expectEqualStrings("keep", v.?);
    try std.testing.expectEqual(@as(?[]u8, null), try db.get("aborted1"));
    try std.testing.expectEqual(@as(?[]u8, null), try db.get("aborted2"));
}

// Test 3: stack-buffer keys — txn.put dupes immediately; keys need not live until commit
test "txn arena: stack buffer keys survive until commit" {
    var ms = newStore(100000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var txn = try db.beginWriteTxn();
    defer txn.deinit();
    // Shared stack buffer: simulates a caller reusing one buffer
    var kbuf: [16]u8 = undefined;
    {
        const k1 = try std.fmt.bufPrint(&kbuf, "key_{d}", .{1});
        try txn.put(k1, "v1");
    }
    {
        const k2 = try std.fmt.bufPrint(&kbuf, "key_{d}", .{2});
        try txn.put(k2, "v2");
    }
    try txn.commit();

    try std.testing.expectEqual(@as(u64, 2), db.entryCount());
    const v1 = try db.get("key_1");
    defer if (v1) |v| std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("v1", v1.?);
    const v2 = try db.get("key_2");
    defer if (v2) |v| std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("v2", v2.?);
}

// Test 4: entryCount is correct after a large batch of puts (1000 entries)
test "txn arena: large batch put count correct" {
    var ms = newStore(500000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 1000;
    var txn = try db.beginWriteTxn();
    defer txn.deinit();
    var kbuf: [16]u8 = undefined;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>6}", .{i});
        try txn.put(k, "v");
    }
    try txn.commit();

    try std.testing.expectEqual(@as(u64, n), db.entryCount());
    var kbuf2: [16]u8 = undefined;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf2, "key_{d:0>6}", .{i});
        const v = try db.get(k);
        try std.testing.expectEqualStrings("v", v.?);
        std.testing.allocator.free(v.?);
    }
}

// Test 5: alternating commit/abort — arena lifetime correct, no leaks
test "txn arena: alternating commit and abort" {
    var ms = newStore(500000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var kbuf: [16]u8 = undefined;
    for (0..20) |round| {
        var txn = try db.beginWriteTxn();
        defer txn.deinit();
        for (0..50) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "r{d}_{d:0>4}", .{ round, i });
            try txn.put(k, "v");
        }
        if (round % 2 == 0) {
            try txn.commit();
        } else {
            try txn.abort();
        }
    }
    // 10 rounds of commit x 50 = 500 entries
    try std.testing.expectEqual(@as(u64, 500), db.entryCount());
}

// Test 6: putBatch with a shared stack buffer — semantics preserved (value semantics are the caller's)
test "txn arena: putBatch with shared buffer collapses (caller semantics)" {
    var ms = newStore(100000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    // Simulates bench_baseline's former shared-buffer pattern: all entries' keys point at the same buffer
    var kbuf: [12]u8 = undefined;
    const entries = try std.testing.allocator.alloc(cube.Entry, 10);
    defer std.testing.allocator.free(entries);
    for (entries) |*e| {
        const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{7});
        e.* = .{ .key = k, .value = "v" };
    }
    try db.putBatch(entries);
    // All keys identical -> collapses to 1 entry (that is caller semantics, not a putBatch bug)
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
}

// Test 7: deinit of an uncommitted txn — no leaks, no crash
test "txn arena: deinit without commit or abort" {
    var ms = newStore(100000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var kbuf: [16]u8 = undefined;
    {
        var txn = try db.beginWriteTxn();
        defer txn.deinit();
        for (0..10) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "tmp_{d}", .{i});
            try txn.put(k, "v");
        }
        // Neither commit nor abort; just leave the scope (deinit triggers abort)
    }
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
    // The mutex should be released — a new txn can be opened
    var txn2 = try db.beginWriteTxn();
    defer txn2.deinit();
    try txn2.put("after", "ok");
    try txn2.commit();
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
}

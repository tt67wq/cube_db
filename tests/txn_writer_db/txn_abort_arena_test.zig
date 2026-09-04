//! txn_abort_arena_test.zig — #32 acceptance: WriteTxn abort-path correctness
//! @archon's requirement: stage entries, abort, then read back and verify no dirty data.
//! Covers WriteTxn arena lifetime risk points.
const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const MemPageStore = cube.page_store.MemPageStore;
const testing = std.testing;

// Basic abort: put then abort; verify the data was not applied
test "abort: put then abort, no data applied" {
    var ms = MemPageStore.init(testing.allocator, 100000);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    {
        var txn = try db.beginWriteTxn();
        try txn.put("k1", "v1");
        try txn.put("k2", "v2");
        try txn.abort();
    }

    try testing.expectEqual(@as(u64, 0), db.entryCount());
    const v1 = try db.get("k1");
    defer if (v1) |val| testing.allocator.free(val);
    try testing.expectEqual(@as(?[]u8, null), v1);
}

// Continue writing normally after an abort; verify no interference
test "abort: then commit another txn works" {
    var ms = MemPageStore.init(testing.allocator, 100000);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    {
        var txn = try db.beginWriteTxn();
        try txn.put("aborted", "no");
        try txn.abort();
    }
    {
        var txn = try db.beginWriteTxn();
        try txn.put("committed", "yes");
        try txn.commit();
    }

    try testing.expectEqual(@as(u64, 1), db.entryCount());
    const v = try db.get("committed");
    defer if (v) |val| testing.allocator.free(val);
    try testing.expectEqualStrings("yes", v.?);
    const av = try db.get("aborted");
    defer if (av) |val| testing.allocator.free(val);
    try testing.expectEqual(@as(?[]u8, null), av);
}

// Abort after a large batch put (lots of staged data); verify no leftovers after arena release
test "abort: large staging then abort, clean state" {
    var ms = MemPageStore.init(testing.allocator, 100000);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 10000;
    {
        var txn = try db.beginWriteTxn();
        var kbuf: [16]u8 = undefined;
        for (0..n) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{i});
            try txn.put(k, "value");
        }
        try txn.abort();
    }

    try testing.expectEqual(@as(u64, 0), db.entryCount());
    // Spot-check several keys to confirm no leftovers
    var vkbuf: [16]u8 = undefined;
    for ([_]usize{ 0, 1, 100, 5000, 9999 }) |i| {
        const k = try std.fmt.bufPrint(&vkbuf, "k{d:0>6}", .{i});
        const v = try db.get(k);
        defer if (v) |val| testing.allocator.free(val);
        try testing.expectEqual(@as(?[]u8, null), v);
    }
}

// Abort after a large putBatch (via WriteTxn to simulate db.putBatch's abort path)
// Note: db.putBatch commits internally and exposes no abort — here we abort manually via WriteTxn
test "abort: mixed put/delete staging then abort" {
    var ms = MemPageStore.init(testing.allocator, 100000);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    // First commit one batch
    {
        var txn = try db.beginWriteTxn();
        try txn.put("base1", "v");
        try txn.put("base2", "v");
        try txn.commit();
    }
    const count_before = db.entryCount();

    // Stage a mix of puts/deletes, then abort
    {
        var txn = try db.beginWriteTxn();
        try txn.put("base1", "changed"); // update existing
        try txn.delete("base2"); // delete existing
        try txn.put("new1", "v"); // insert new
        try txn.abort();
    }

    // After the abort everything is unchanged
    try testing.expectEqual(count_before, db.entryCount());
    const v1 = try db.get("base1");
    defer if (v1) |val| testing.allocator.free(val);
    try testing.expectEqualStrings("v", v1.?);
    const v2 = try db.get("base2");
    defer if (v2) |val| testing.allocator.free(val);
    try testing.expectEqualStrings("v", v2.?);
    const vn = try db.get("new1");
    defer if (vn) |val| testing.allocator.free(val);
    try testing.expectEqual(@as(?[]u8, null), vn);
}

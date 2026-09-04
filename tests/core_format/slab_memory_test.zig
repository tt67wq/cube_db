//! slab_memory_test.zig - #34 acceptance: MemPageStore slab page-pool memory semantics
//! Requested by @archon: memory usage verification after a large batch + delete (slab free path returns pages correctly, no leak)
const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const MemPageStore = cube.page_store.MemPageStore;
const testing = std.testing;

// large batch insert then delete all; verify memory usage falls back (slab pages returned)
test "slab: large batch then delete all, memory returns" {
    const n: usize = 100000;
    var ms = MemPageStore.init(testing.allocator, @as(u32, @intCast(3 + n * 10 + 10000)));
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    var v100: [100]u8 = undefined;
    @memset(&v100, 'x');

    // insert a large batch
    {
        var entries = try testing.allocator.alloc(cube.Entry, n);
        defer testing.allocator.free(entries);
        for (0..n) |i| entries[i] = .{ .key = try std.fmt.allocPrint(testing.allocator, "{d:0>10}", .{i}), .value = &v100 };
        defer for (entries) |e| testing.allocator.free(e.key);
        try db.putBatch(entries);
        try testing.expectEqual(@as(u64, n), db.entryCount());
    }

    const pages_after_insert = ms.pages.items.len;
    const free_after_insert = ms.freelist.items.len;
    std.debug.print("pages after insert: {d} (freelist={d}, active={d})\n", .{ pages_after_insert, free_after_insert, pages_after_insert - free_after_insert });

    // delete all
    {
        var txn = try db.beginWriteTxn();
        var kbuf: [12]u8 = undefined;
        for (0..n) |i| {
            const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{i});
            try txn.delete(k);
        }
        try txn.commit();
        try testing.expectEqual(@as(u64, 0), db.entryCount());
    }

    const pages_after_delete = ms.pages.items.len;
    const free_after_delete = ms.freelist.items.len;
    std.debug.print("pages after delete: {d} (freelist={d}, active={d})\n", .{ pages_after_delete, free_after_delete, pages_after_delete - free_after_delete });

    // slab free path: after delete, the active page count (items.len - freelist.len) should fall back
    // under COW, delete writes new pages (tombstones) and old pages go to the freelist, so items.len may grow
    // but the freelist accumulates the freed pages, so active pages should be <= the active count at insert time
    const active_after_insert = pages_after_insert - free_after_insert;
    const active_after_delete = pages_after_delete - free_after_delete;
    try testing.expect(active_after_delete <= active_after_insert);
    std.debug.print("active pages: {d} -> {d} ({s})\n", .{ active_after_insert, active_after_delete, if (active_after_delete <= active_after_insert) "OK" else "FAIL" });
}

// alternating insert/delete cycles, verifying slab pool reuse (no leak growth)
test "slab: repeated insert/delete cycles, no leak" {
    const n: usize = 10000;
    var ms = MemPageStore.init(testing.allocator, @as(u32, @intCast(3 + n * 10 + 10000)));
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    var v100: [100]u8 = undefined;
    @memset(&v100, 'x');
    var kbuf: [12]u8 = undefined;

    var peak_pages: usize = 0;
    for (0..5) |cycle| {
        // insert batch
        {
            var entries = try testing.allocator.alloc(cube.Entry, n);
            defer testing.allocator.free(entries);
            for (0..n) |i| entries[i] = .{ .key = try std.fmt.allocPrint(testing.allocator, "{d:0>10}", .{cycle * n + i}), .value = &v100 };
            defer for (entries) |e| testing.allocator.free(e.key);
            try db.putBatch(entries);
        }
        peak_pages = @max(peak_pages, ms.pages.items.len - ms.freelist.items.len);

        // delete batch
        {
            var txn = try db.beginWriteTxn();
            for (0..n) |i| {
                const k = try std.fmt.bufPrint(&kbuf, "{d:0>10}", .{cycle * n + i});
                try txn.delete(k);
            }
            try txn.commit();
        }
    }

    try testing.expectEqual(@as(u64, 0), db.entryCount());
    const final_pages = ms.pages.items.len - ms.freelist.items.len;
    std.debug.print("peak active: {d}, final active: {d}\n", .{ peak_pages, final_pages });
    // with slab pool reuse, the final active page count must not exceed the peak (no leak growth)
    try testing.expect(final_pages <= peak_pages);
}

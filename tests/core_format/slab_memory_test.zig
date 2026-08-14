//! slab_memory_test.zig — #34 验收：MemPageStore slab 页池内存语义
//! @archon 要求：大 batch + delete 后的内存占用验证（slab 释放路径正确归还，无泄漏）
const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const MemPageStore = cube.page_store.MemPageStore;
const testing = std.testing;

// 大 batch 插入后 delete 全部，验证内存占用回落（slab 页归还）
test "slab: large batch then delete all, memory returns" {
    const n: usize = 100000;
    var ms = MemPageStore.init(testing.allocator, @as(u32, @intCast(3 + n * 10 + 10000)));
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    var v100: [100]u8 = undefined;
    @memset(&v100, 'x');

    // 插入大 batch
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

    // delete 全部
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

    // slab 释放路径：delete 后活跃页数（items.len - freelist.len）应回落
    // COW 下 delete 会写新页（tombstone），旧页进 freelist，所以 items.len 可能增长
    // 但 freelist 应积累已释放页，活跃页数应 <= insert 时的活跃页数
    const active_after_insert = pages_after_insert - free_after_insert;
    const active_after_delete = pages_after_delete - free_after_delete;
    try testing.expect(active_after_delete <= active_after_insert);
    std.debug.print("active pages: {d} -> {d} ({s})\n", .{ active_after_insert, active_after_delete, if (active_after_delete <= active_after_insert) "OK" else "FAIL" });
}

// 交替插入/删除多轮，验证 slab 池复用（不泄漏增长）
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
    // slab 池复用后，final 活跃页数不应超过峰值（无泄漏增长）
    try testing.expect(final_pages <= peak_pages);
}

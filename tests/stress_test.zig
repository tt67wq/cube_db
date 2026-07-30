//! stress_test.zig — P4 TDD: 大数据集 + 长时运行稳定性
//! 插入大量 key（堆分配，避免栈缓冲别名），验证全部可读、reopen 持久、无内存泄漏。

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const Db = cube.Db;

const alloc = std.testing.allocator;

test "stress: 1000 sequential keys all readable, heap-allocated" {
    var ms = ps.MemPageStore.init(alloc, 10000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    // 堆分配 key（避免 bufPrint 复用栈缓冲）
    const keys = try alloc.alloc([]u8, 1000);
    defer {
        for (keys) |k| alloc.free(k);
        alloc.free(keys);
    }
    // 批量提交：每个 WriteTxn 提交多个 key（group commit）
    const batch_size: usize = 100;
    var i: usize = 0;
    while (i < 1000) : (i += batch_size) {
        var txn = try db.beginWriteTxn();
        const end = @min(i + batch_size, 1000);
        var j = i;
        while (j < end) : (j += 1) {
            keys[j] = try std.fmt.allocPrint(alloc, "k{d:0>6}", .{j});
            try txn.put(keys[j], "v");
        }
        try txn.commit();
    }

    try std.testing.expectEqual(@as(u64, 1000), db.entryCount());

    // 全部可读
    for (keys) |k| {
        const v = try db.get(k);
        defer if (v) |val| alloc.free(val);
        try std.testing.expectEqualStrings("v", v.?);
    }
}

test "stress: 1000 keys reopen persists (FilePageStore 1TB region)" {
    const c = @cImport({ @cInclude("unistd.h"); });
    const path = ".test_stress_reopen.db";
    defer {
        var buf: [64]u8 = undefined;
        if (path.len < buf.len) {
            @memcpy(buf[0..path.len], path);
            buf[path.len] = 0;
            _ = c.unlink(@ptrCast(&buf));
        }
    }
    const FilePageStore = cube.file_page_store.FilePageStore;

    const keys = try alloc.alloc([]u8, 1000);
    defer {
        for (keys) |k| alloc.free(k);
        alloc.free(keys);
    }
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        const batch_size: usize = 100;
        var i: usize = 0;
        while (i < 1000) : (i += batch_size) {
            var txn = try db.beginWriteTxn();
            const end = @min(i + batch_size, 1000);
            var j = i;
            while (j < end) : (j += 1) {
                keys[j] = try std.fmt.allocPrint(alloc, "k{d:0>6}", .{j});
                try txn.put(keys[j], "v");
            }
            try txn.commit();
        }
    }
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try std.testing.expectEqual(@as(u64, 1000), db.entryCount());
        for (keys) |k| {
            const v = try db.get(k);
            defer if (v) |val| alloc.free(val);
            try std.testing.expectEqualStrings("v", v.?);
        }
    }
}

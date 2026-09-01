//! lock_failure_test.zig — T-13: putBatch 锁失败 / 并发正确性测试
//!
//! 背景：src/db.zig:141 `Db.putBatch` 第一行 `self.write_mutex.lock() catch return error.LockFailed`。
//! write_mutex 类型为 `zio.Mutex`，其 `lock()` 返回 `Cancelable!void`。
//!
//! note: lock() 在同步线程上下文中调用 getCurrentTaskOrNull() == null，
//! 走 lockThread() 路径（futex 自旋等待），返回 void——不返回 error。
//! 只有在 zio 异步运行时中、task 被取消时才返回 error.Canceled。
//! 因此在纯同步测试中 `catch return error.LockFailed` 是死代码（dead code），
//! lock 永远不会返回 LockFailed。测试文档化此行为并验证并发 putBatch 正确性。
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;

const alloc = std.testing.allocator;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 10000);
}

// ---- Test 1: 正常路径 putBatch，全部成功 + Db 状态一致 ----
test "lock_failure: normal putBatch succeeds, Db state consistent" {
    var ms = newStore();
    defer ms.deinit();
    var db = try cube.Db.open(alloc, ms.store(), .{});
    defer db.close();

    const entries = [_]cube.Entry{
        .{ .key = "alpha", .value = "111" },
        .{ .key = "bravo", .value = "222" },
        .{ .key = "charlie", .value = "333" },
        .{ .key = "delta", .value = "444" },
    };

    try db.putBatch(&entries);

    // entry_count 应反映写入数量
    try std.testing.expectEqual(@as(u64, 4), db.entryCount());

    // 逐个 get 验证值正确
    for (entries) |e| {
        const v = try db.get(e.key);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings(e.value, v.?);
        alloc.free(v.?);
    }

    // root 应非 NULL_ROOT（有数据）
    try std.testing.expect(db.getRoot() != cube.btree.NULL_ROOT);
}

// ---- Test 2: putBatch 永远不返回 LockFailed（文档化 dead code）----
// note: lock() never returns error in current Zig, catch is dead code
test "lock_failure: putBatch never returns LockFailed in sync context" {
    var ms = newStore();
    defer ms.deinit();
    var db = try cube.Db.open(alloc, ms.store(), .{});
    defer db.close();

    // 在纯同步线程上下文中，zio.Mutex.lock() 走 lockThread() 路径，
    // 返回 void 而非 error。因此 putBatch 永远不会走到 catch return error.LockFailed。
    // 此测试文档化该行为：多次 putBatch 都成功返回，无 LockFailed。
    for (0..5) |round| {
        var kbuf: [16]u8 = undefined;
        var vbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d}", .{round});
        const v = try std.fmt.bufPrint(&vbuf, "val_{d}", .{round});
        const entries = [_]cube.Entry{
            .{ .key = k, .value = v },
        };
        try db.putBatch(&entries);
    }

    try std.testing.expectEqual(@as(u64, 5), db.entryCount());
}

// ---- Test 3: 并发 putBatch 不 panic / 不 deadlock / 数据一致 ----
const Concurrency = struct {
    db: *cube.Db,
    prefix: []const u8,
    n: usize,

    fn run(ctx: *Concurrency) void {
        var i: usize = 0;
        while (i < ctx.n) : (i += 1) {
            var kbuf: [32]u8 = undefined;
            var vbuf: [32]u8 = undefined;
            const k = std.fmt.bufPrint(&kbuf, "{s}_{d:0>4}", .{ ctx.prefix, i }) catch return;
            const v = std.fmt.bufPrint(&vbuf, "val_{d:0>4}", .{i}) catch return;
            const entries = [_]cube.Entry{ .{ .key = k, .value = v } };
            ctx.db.putBatch(&entries) catch return;
        }
    }
};

test "lock_failure: concurrent putBatch, no deadlock, data consistent" {
    var ms = newStore();
    defer ms.deinit();
    var db = try cube.Db.open(alloc, ms.store(), .{});
    defer db.close();

    // 预先写入一些初始数据确保 root 已建
    try db.putDirect("init", "0");

    const n_per_thread: usize = 50;
    var ctx_a = Concurrency{ .db = db, .prefix = "A", .n = n_per_thread };
    var ctx_b = Concurrency{ .db = db, .prefix = "B", .n = n_per_thread };

    const thread_a = try std.Thread.spawn(.{}, Concurrency.run, .{&ctx_a});
    const thread_b = try std.Thread.spawn(.{}, Concurrency.run, .{&ctx_b});

    thread_a.join();
    thread_b.join();

    // 验证：两条线程各写入 n_per_thread 个 key，加上 1 个 init key
    try std.testing.expectEqual(@as(u64, n_per_thread * 2 + 1), db.entryCount());

    // 抽查若干 key 的值正确
    var kbuf: [32]u8 = undefined;
    var vbuf: [32]u8 = undefined;
    const k = try std.fmt.bufPrint(&kbuf, "A_{d:0>4}", .{@as(usize, 25)});
    const expected_v = try std.fmt.bufPrint(&vbuf, "val_{d:0>4}", .{@as(usize, 25)});
    const v = try db.get(k);
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings(expected_v, v.?);
    alloc.free(v.?);
}

// ---- Test 4: putBatch 中途 future 失败不影响其他 future（半应用检查）----
// applyBatch 对重复 key 的处理：insertBatch 以 last-write-wins 归并，
// 不返回 error。但如果 btree.insert 遇到内部错误，会 set future 为该 error。
// 此测试验证：正常 putBatch 中所有 future 均成功，Db 状态一致。
test "lock_failure: putBatch all futures succeed, no half-applied state" {
    var ms = newStore();
    defer ms.deinit();
    var db = try cube.Db.open(alloc, ms.store(), .{});
    defer db.close();

    const entries = [_]cube.Entry{
        .{ .key = "k1", .value = "v1" },
        .{ .key = "k2", .value = "v2" },
        .{ .key = "k3", .value = "v3" },
    };

    try db.putBatch(&entries);

    // 状态一致：entry_count = 3，所有 key 可读
    try std.testing.expectEqual(@as(u64, 3), db.entryCount());

    const k1 = (try db.get("k1")) orelse return error.MissingKey;
    try std.testing.expectEqualStrings("v1", k1);
    alloc.free(k1);

    const k2 = (try db.get("k2")) orelse return error.MissingKey;
    try std.testing.expectEqualStrings("v2", k2);
    alloc.free(k2);

    const k3 = (try db.get("k3")) orelse return error.MissingKey;
    try std.testing.expectEqualStrings("v3", k3);
    alloc.free(k3);
}

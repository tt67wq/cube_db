//! lock_failure_test.zig — T-13: putBatch lock-failure / concurrency correctness tests
//!
//! Background: src/db.zig:141 `Db.putBatch` starts with `self.write_mutex.lock() catch return error.LockFailed`.
//! write_mutex is a `zio.Mutex`; its `lock()` returns `Cancelable!void`.
//!
//! note: lock() called in a synchronous thread context has getCurrentTaskOrNull() == null,
//! takes the lockThread() path (futex spin-wait), and returns void — no error.
//! Only in a zio async runtime, when the task is canceled, does it return error.Canceled.
//! So in purely synchronous tests `catch return error.LockFailed` is dead code —
//! lock never returns LockFailed. These tests document that behavior and verify concurrent putBatch correctness.
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;

const alloc = std.testing.allocator;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 10000);
}

// ---- Test 1: normal-path putBatch, all succeed + Db state consistent ----
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

    // entry_count should reflect the number of writes
    try std.testing.expectEqual(@as(u64, 4), db.entryCount());

    // Verify each value via get
    for (entries) |e| {
        const v = try db.get(e.key);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings(e.value, v.?);
        alloc.free(v.?);
    }

    // root should not be NULL_ROOT (there is data)
    try std.testing.expect(db.getRoot() != cube.btree.NULL_ROOT);
}

// ---- Test 2: putBatch never returns LockFailed (documents the dead code) ----
// note: lock() never returns error in current Zig, catch is dead code
test "lock_failure: putBatch never returns LockFailed in sync context" {
    var ms = newStore();
    defer ms.deinit();
    var db = try cube.Db.open(alloc, ms.store(), .{});
    defer db.close();

    // In a purely synchronous thread context, zio.Mutex.lock() takes the lockThread() path
    // and returns void, not an error. So putBatch can never reach `catch return error.LockFailed`.
    // This test documents that behavior: many putBatch calls all return successfully, no LockFailed.
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

// ---- Test 3: concurrent putBatch — no panic / no deadlock / data consistent ----
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

    // Pre-write some initial data to make sure the root exists
    try db.putDirect("init", "0");

    const n_per_thread: usize = 50;
    var ctx_a = Concurrency{ .db = db, .prefix = "A", .n = n_per_thread };
    var ctx_b = Concurrency{ .db = db, .prefix = "B", .n = n_per_thread };

    const thread_a = try std.Thread.spawn(.{}, Concurrency.run, .{&ctx_a});
    const thread_b = try std.Thread.spawn(.{}, Concurrency.run, .{&ctx_b});

    thread_a.join();
    thread_b.join();

    // Verify: each thread wrote n_per_thread keys, plus 1 init key
    try std.testing.expectEqual(@as(u64, n_per_thread * 2 + 1), db.entryCount());

    // Spot-check several keys' values
    var kbuf: [32]u8 = undefined;
    var vbuf: [32]u8 = undefined;
    const k = try std.fmt.bufPrint(&kbuf, "A_{d:0>4}", .{@as(usize, 25)});
    const expected_v = try std.fmt.bufPrint(&vbuf, "val_{d:0>4}", .{@as(usize, 25)});
    const v = try db.get(k);
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings(expected_v, v.?);
    alloc.free(v.?);
}

// ---- Test 4: a failing future mid-putBatch must not affect other futures (partial-application check) ----
// applyBatch merges duplicate keys via insertBatch last-write-wins and does not
// return an error. But if btree.insert hits an internal error, it sets that entry's future to the error.
// This test verifies: in a normal putBatch all futures succeed and the Db state is consistent.
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

    // State consistent: entry_count = 3, all keys readable
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

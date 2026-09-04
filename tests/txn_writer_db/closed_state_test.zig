//! closed_state_test.zig — T-4: applyBatch closed-branch tests
//! Verify that calling applyBatch after State.deinit() delivers error.Closed to all futures with no segfault.
//! Covers the closed guard branch at src/writer.zig:261-264.
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;
const wrt = cube.writer;

const alloc = std.testing.allocator;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 10000);
}

// ---- Test 1: applyBatch after close — all futures receive error.Closed ----
test "closed: applyBatch after deinit sets error.Closed on all futures" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(alloc, s, .{});
    // deinit marks closed=true and frees pending_free
    state.deinit();
    // state.deinit was already called; do not call it twice (ms.deinit in the defer frees the page store)

    // Build the batch: 3 requests
    var futures: [3]zio.Future(wrt.OpResult) = .{ .{}, .{}, .{} };
    const reqs = [_]wrt.Request{
        .{ .key = "a", .value = "1", .tombstone = false, .future = &futures[0] },
        .{ .key = "b", .value = "2", .tombstone = false, .future = &futures[1] },
        .{ .key = "c", .value = "3", .tombstone = false, .future = &futures[2] },
    };

    // applyBatch does not return an error (the closed branch just sets futures and returns)
    try state.applyBatch(&reqs);

    // Each future should receive error.Closed
    for (&futures) |*f| {
        const result = try f.wait();
        try std.testing.expectError(error.Closed, result.value);
    }

    // State untouched: root is still NULL_ROOT; sequence/dirt/entry_count still 0
    try std.testing.expectEqual(btree.NULL_ROOT, state.root.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.sequence.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.entry_count.load(.acquire));
}

// ---- Test 2: normal putBatch, then close, then applyBatch — state must not change ----
test "closed: normal applyBatch then deinit then applyBatch — state unchanged" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(alloc, s, .{});

    // Normal path: applyBatch with 3 puts
    var f1: [3]zio.Future(wrt.OpResult) = .{ .{}, .{}, .{} };
    const reqs1 = [_]wrt.Request{
        .{ .key = "x", .value = "1", .tombstone = false, .future = &f1[0] },
        .{ .key = "y", .value = "2", .tombstone = false, .future = &f1[1] },
        .{ .key = "z", .value = "3", .tombstone = false, .future = &f1[2] },
    };
    try state.applyBatch(&reqs1);
    for (&f1) |*f| _ = try f.wait();

    // Record the state before close
    const root_before = state.root.load(.acquire);
    const seq_before = state.sequence.load(.acquire);
    const count_before = state.entry_count.load(.acquire);

    // close
    state.deinit();

    // applyBatch again after close
    var f2: [2]zio.Future(wrt.OpResult) = .{ .{}, .{} };
    const reqs2 = [_]wrt.Request{
        .{ .key = "new1", .value = "v", .tombstone = false, .future = &f2[0] },
        .{ .key = "new2", .value = "v", .tombstone = false, .future = &f2[1] },
    };
    try state.applyBatch(&reqs2);

    // All futures receive error.Closed
    for (&f2) |*f| {
        const result = try f.wait();
        try std.testing.expectError(error.Closed, result.value);
    }

    // State unchanged by the post-close applyBatch
    try std.testing.expectEqual(root_before, state.root.load(.acquire));
    try std.testing.expectEqual(seq_before, state.sequence.load(.acquire));
    try std.testing.expectEqual(count_before, state.entry_count.load(.acquire));

    // The pre-close data is indeed in the btree (verified via root)
    const v = try btree.get(alloc, s, root_before, "x");
    try std.testing.expectEqualStrings("1", v.?);
    alloc.free(v.?);
}

// ---- Test 3: a single request after close also receives error.Closed ----
test "closed: single request after deinit gets error.Closed" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(alloc, s, .{});
    state.deinit();

    var future: zio.Future(wrt.OpResult) = .{};
    const req = wrt.Request{
        .key = "solo",
        .value = "val",
        .tombstone = false,
        .future = &future,
    };
    try state.applyBatch(&.{req});

    const result = try future.wait();
    try std.testing.expectError(error.Closed, result.value);

    try std.testing.expectEqual(btree.NULL_ROOT, state.root.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.sequence.load(.acquire));
}

// ---- Test 4: an empty batch after close does not crash ----
test "closed: empty batch after deinit is no-op, no crash" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(alloc, s, .{});
    state.deinit();

    // Empty batch: the closed branch's for loop does not execute; it just returns
    try state.applyBatch(&.{});

    try std.testing.expectEqual(btree.NULL_ROOT, state.root.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.sequence.load(.acquire));
}

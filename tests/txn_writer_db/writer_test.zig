//! writer_test.zig — wrt applyBatch tests (TDD RED)
//! Covers: single put, batched put, delete, meta alternation, atomic root update, dirt accounting.
//! Uses MemPageStore to simulate storage; written to fail first (wrt.zig does not exist).
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const fmt2 = cube.format;
const ps = cube.page_store;
const btree = cube.btree;
const wrt = cube.writer;

// ---- Helpers ----

const MAPSIZE_PAGES = 10000;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(std.testing.allocator, MAPSIZE_PAGES);
}

test "writer: applyBatch with single put" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    var future: zio.Future(wrt.OpResult) = .{};
    const req = wrt.Request{
        .key = "hello",
        .value = "world",
        .tombstone = false,
        .future = &future,
    };
    try state.applyBatch(&.{req});
    _ = try future.wait();

    // Verify the data is in the tree
    const root = state.root.load(.acquire);
    try std.testing.expect(root != btree.NULL_ROOT);
    const v = try btree.get(std.testing.allocator, s, root, "hello");
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("world", v.?);
    std.testing.allocator.free(v.?);
}

test "writer: applyBatch with multiple puts" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    var futures: [3]zio.Future(wrt.OpResult) = .{ .{}, .{}, .{} };
    const reqs = [_]wrt.Request{
        .{ .key = "a", .value = "1", .tombstone = false, .future = &futures[0] },
        .{ .key = "b", .value = "2", .tombstone = false, .future = &futures[1] },
        .{ .key = "c", .value = "3", .tombstone = false, .future = &futures[2] },
    };
    try state.applyBatch(&reqs);
    for (&futures) |*f| _ = try f.wait();

    const root = state.root.load(.acquire);
    for (reqs) |r| {
        const v = try btree.get(std.testing.allocator, s, root, r.key);
        try std.testing.expect(v != null);
        std.testing.allocator.free(v.?);
    }
}

test "writer: applyBatch with delete" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    // First put
    var f1: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{
        .key = "x", .value = "y", .tombstone = false, .future = &f1,
    }});
    _ = try f1.wait();

    // Then delete
    var f2: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{
        .key = "x", .value = "", .tombstone = true, .future = &f2,
    }});
    _ = try f2.wait();

    const root = state.root.load(.acquire);
    const v = try btree.get(std.testing.allocator, s, root, "x");
    try std.testing.expectEqual(@as(?[]u8, null), v);
}

test "writer: meta page alternates after each applyBatch" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    // First applyBatch -> meta page 0
    var f1: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k1", .value = "v1", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();
    const meta_after_1 = try s.readMeta();
    try std.testing.expect(meta_after_1 != null);
    try std.testing.expectEqual(@as(u64, 1), meta_after_1.?.sequence);
    try std.testing.expect(meta_after_1.?.root_page != fmt2.NULL_PAGE);

    // Second applyBatch -> meta page 1 (sequence=2)
    var f2: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k2", .value = "v2", .tombstone = false, .future = &f2 }});
    _ = try f2.wait();
    const meta_after_2 = try s.readMeta();
    try std.testing.expect(meta_after_2 != null);
    try std.testing.expectEqual(@as(u64, 2), meta_after_2.?.sequence);

    // Third -> meta page 0 (sequence=3)
    var f3: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k3", .value = "v3", .tombstone = false, .future = &f3 }});
    _ = try f3.wait();
    const meta_after_3 = try s.readMeta();
    try std.testing.expect(meta_after_3 != null);
    try std.testing.expectEqual(@as(u64, 3), meta_after_3.?.sequence);
}

test "writer: root atomically updated after each batch" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    try std.testing.expectEqual(btree.NULL_ROOT, state.root.load(.acquire));

    var f1: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "a", .value = "1", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();
    const r1 = state.root.load(.acquire);
    try std.testing.expect(r1 != btree.NULL_ROOT);

    var f2: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "b", .value = "2", .tombstone = false, .future = &f2 }});
    _ = try f2.wait();
    const r2 = state.root.load(.acquire);
    try std.testing.expect(r2 != r1); // COW → new root
}

test "writer: dirt count reflects pending free pages" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    // First put: creates a new leaf -> dirt should be 0 (no old page to reclaim)
    var f1: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v1", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();
    try std.testing.expectEqual(@as(u64, 0), state.dirt.load(.acquire));

    // Second overwrite: start a read txn; dirty pages must not be reclaimed immediately
    const r = state.beginRead();
    var f2: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v2", .tombstone = false, .future = &f2 }});
    _ = try f2.wait();
    // With a reader -> pending_free > 0, dirt = pending_free
    try std.testing.expect(state.pendingFreeCount() > 0);
    try std.testing.expectEqual(state.pendingFreeCount(), state.dirt.load(.acquire));
    // End the read -> dirty pages released -> dirt = 0
    state.endRead(r);
    try std.testing.expectEqual(@as(u64, 0), state.dirt.load(.acquire));
}

test "writer: entry_count and byte_size updated correctly" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    try std.testing.expectEqual(@as(u64, 0), state.entry_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.byte_size.load(.acquire));

    // put "hello"="world" (5+5+10=20 bytes; the 10-byte overhead matches leafPayloadSize, T-26)
    var f1: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "hello", .value = "world", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();
    try std.testing.expectEqual(@as(u64, 1), state.entry_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 20), state.byte_size.load(.acquire));

    // delete "hello" (tombstone, but entry count should go to 0)
    var f2: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "hello", .value = "", .tombstone = true, .future = &f2 }});
    _ = try f2.wait();
    try std.testing.expectEqual(@as(u64, 0), state.entry_count.load(.acquire));
}

test "writer: batch with mixed ops" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    var futures: [4]zio.Future(wrt.OpResult) = .{ .{}, .{}, .{}, .{} };
    const reqs = [_]wrt.Request{
        .{ .key = "a", .value = "1", .tombstone = false, .future = &futures[0] },
        .{ .key = "b", .value = "2", .tombstone = false, .future = &futures[1] },
        .{ .key = "a", .value = "", .tombstone = true, .future = &futures[2] }, // delete a
        .{ .key = "c", .value = "3", .tombstone = false, .future = &futures[3] },
    };
    try state.applyBatch(&reqs);
    for (&futures) |*f| _ = try f.wait();

    const root = state.root.load(.acquire);
    // "a" was deleted
    try std.testing.expectEqual(@as(?[]u8, null), try btree.get(std.testing.allocator, s, root, "a"));
    // "b" and "c" should still exist
    const vb = try btree.get(std.testing.allocator, s, root, "b");
    try std.testing.expectEqualStrings("2", vb.?);
    std.testing.allocator.free(vb.?);
    const vc = try btree.get(std.testing.allocator, s, root, "c");
    try std.testing.expectEqualStrings("3", vc.?);
    std.testing.allocator.free(vc.?);
    // entry_count = 2 (b, c)
    try std.testing.expectEqual(@as(u64, 2), state.entry_count.load(.acquire));
}
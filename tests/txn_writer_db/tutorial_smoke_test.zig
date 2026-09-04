//! tutorial_smoke_test.zig — verify that every runnable snippet in docs/tutorial/ compiles
//! A reader can copy any snippet into a standalone test file and it will run independently.
const std = @import("std");
const cube = @import("cube_db");
const zio = @import("zio");

const format = cube.format;
const MemPageStore = cube.page_store.MemPageStore;
const btree = cube.btree;

// ---- Chapter 01: page format ----
test "T01 page header encode/decode and CRC" {
    const h = format.PageHeader{
        .page_no = 42,
        .page_type = format.PAGE_TYPE_LEAF,
        .gen = 1000,
        .nkeys = 16,
        .free_next = 0,
    };

    var buf: [format.PAGE_HEADER_SIZE]u8 = undefined;
    format.encodePageHeader(&buf, &h);
    const got = format.decodePageHeader(&buf);
    try std.testing.expectEqual(h.page_no, got.page_no);
    try std.testing.expectEqual(h.page_type, got.page_type);
    try std.testing.expectEqual(h.gen, got.gen);

    var page: [format.PAGE_SIZE]u8 = undefined;
    @memset(&page, 0);
    format.encodePageHeader(&page, &h);
    @memset(page[format.PAGE_HEADER_SIZE .. format.PAGE_SIZE - 4], 0xbb);

    const cs = format.computePageChecksum(&page);
    format.setPageChecksum(&page, cs);
    try std.testing.expect(format.verifyPageChecksum(&page));

    page[100] ^= 0xff;
    try std.testing.expect(!format.verifyPageChecksum(&page));
}

// ---- Chapter 02: B-tree ----
test "T02 B-tree insert and lookup" {
    const allocator = std.testing.allocator;
    var ms = MemPageStore.init(allocator, 1 << 10);
    defer ms.deinit();
    const store = ms.store();

    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    var root: u32 = 0;

    for ([_][]const u8{ "alice", "bob", "carol" }, 0..) |k, i| {
        var buf: [8]u8 = undefined;
        const v = try std.fmt.bufPrint(&buf, "val_{d}", .{i});
        const result = try btree.insert(allocator, store, root, k, v, false, &dirty);
        root = result.new_root;
    }

    const v = try btree.get(allocator, store, root, "bob");
    defer if (v) |val| allocator.free(val);
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("val_1", v.?);

    const nv = try btree.get(allocator, store, root, "zoe");
    try std.testing.expect(nv == null);
}

// ---- Chapter 03: COW writes ----
test "T03 applyBatch batch write + compact" {
    const allocator = std.testing.allocator;
    var ms = MemPageStore.init(allocator, 1 << 10);
    defer ms.deinit();
    const store = ms.store();

    const wrt = cube.writer;
    var state = wrt.State.init(allocator, store, .{ .fsync = false });
    defer state.deinit();

    var f1: zio.Future(wrt.OpResult) = .{};
    var f2: zio.Future(wrt.OpResult) = .{};
    var f3: zio.Future(wrt.OpResult) = .{};

    const batch = [_]wrt.Request{
        .{ .key = "alpha", .value = "100", .tombstone = false, .future = &f1 },
        .{ .key = "beta", .value = "200", .tombstone = false, .future = &f2 },
        .{ .key = "gamma", .value = "300", .tombstone = false, .future = &f3 },
    };

    try state.applyBatch(&batch);
    _ = try f1.wait();
    _ = try f2.wait();
    _ = try f3.wait();

    try state.compact();
    try std.testing.expectEqual(@as(u64, 0), state.dirtCount());
}

// ---- Chapter 04: MVCC ----
test "T04 MVCC reader deferred reclamation" {
    const allocator = std.testing.allocator;
    var ms = MemPageStore.init(allocator, 1 << 10);
    defer ms.deinit();
    const store = ms.store();

    const wrt = cube.writer;
    var state = wrt.State.init(allocator, store, .{ .fsync = false });
    defer state.deinit();

    // Write one entry first so the tree has data (later inserts will produce dirty pages)
    {
        var f0: zio.Future(wrt.OpResult) = .{};
        try state.applyBatch(&.{.{ .key = "seed", .value = "x",
            .tombstone = false, .future = &f0 }});
        _ = try f0.wait();
    }

    // Start the reader
    const reader = state.beginRead();
    defer state.endRead(reader);

    try std.testing.expect(reader.seq > 0);
    try std.testing.expectEqual(@as(u32, 1), state.reader_count.load(.acquire));

    var future: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "mvcc", .value = "test",
        .tombstone = false, .future = &future }});
    _ = try future.wait();
    try std.testing.expect(state.dirtCount() > 0);
    try std.testing.expect(state.pendingFreeCount() > 0);
}

// ---- Chapter 05: overflow pages ----
test "T05 large-value overflow page chain" {
    const allocator = std.testing.allocator;
    var ms = MemPageStore.init(allocator, 1 << 12);
    defer ms.deinit();
    const store = ms.store();

    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    var root: u32 = 0;

    const big_value = try allocator.alloc(u8, 5000);
    defer allocator.free(big_value);
    @memset(big_value, 0xAB);

    const result = try btree.insert(allocator, store, root, "bigkey", big_value, false, &dirty);
    root = result.new_root;

    const v = try btree.get(allocator, store, root, "bigkey");
    defer if (v) |val| allocator.free(val);

    try std.testing.expect(v != null);
    try std.testing.expectEqual(@as(usize, 5000), v.?.len);
    try std.testing.expectEqual(@as(u8, 0xAB), v.?[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), v.?[4999]);
}

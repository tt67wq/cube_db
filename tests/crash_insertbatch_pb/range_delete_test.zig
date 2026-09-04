//! range_delete_test.zig - Db.deleteRange contract tests
//! Contract points covered:
//!   1. [min, max) half-open range delete (byte-order comparison, same as select)
//!   2. null min/max = unbounded; (null, null) clears the whole store
//!   3. keys outside the range are untouched (existence + value preserved)
//!   4. inverted/empty range (min >= max) -> successful no-op
//!   5. only missing/already-deleted keys -> successful no-op (idempotent)
//!   6. under micro_batch, pending puts inside the range must also be deleted
//!   7. entryCount() reflects deletions (same accounting as delete)
//!   8. MemPageStore + FilePageStore behave identically
//!   9. no new public types (compiler-enforced; deleteRange returns !void)
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const FilePageStore = cube.file_page_store.FilePageStore;
const Db = cube.Db;

const alloc = std.testing.allocator;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

fn expectGet(db: *Db, key: []const u8, expected: ?[]const u8) !void {
    const v = try db.get(key);
    defer if (v) |val| alloc.free(val);
    if (expected) |exp| {
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings(exp, v.?);
    } else {
        try std.testing.expect(v == null);
    }
}

// ---- common seed data: covering in-range/boundary/outside-range (committed directly, bypassing micro-batching) ----
fn seedDirect(db: *Db) !void {
    try db.putDirect("a", "1");
    try db.putDirect("b", "2");
    try db.putDirect("c", "3");
    try db.putDirect("d", "4");
    try db.putDirect("e", "5");
}

test "deleteRange: basic range delete [b, d)" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);

    try db.deleteRange("b", "d"); // deletes b, c

    try expectGet(db, "a", "1");
    try expectGet(db, "b", null);
    try expectGet(db, "c", null);
    try expectGet(db, "d", "4");
    try expectGet(db, "e", "5");
}

test "deleteRange: boundary [min, max) excludes max" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);

    // [b, c): only b deleted; c is the upper bound and must be kept
    try db.deleteRange("b", "c");
    try expectGet(db, "a", "1");
    try expectGet(db, "b", null);
    try expectGet(db, "c", "3");
    try expectGet(db, "d", "4");
}

test "deleteRange: (null, null) clears whole store" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);

    try db.deleteRange(null, null);
    try expectGet(db, "a", null);
    try expectGet(db, "c", null);
    try expectGet(db, "e", null);
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

test "deleteRange: null min unbounded below" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);

    try db.deleteRange(null, "c"); // deletes a, b
    try expectGet(db, "a", null);
    try expectGet(db, "b", null);
    try expectGet(db, "c", "3");
    try expectGet(db, "e", "5");
}

test "deleteRange: null max unbounded above" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);

    try db.deleteRange("c", null); // deletes c, d, e
    try expectGet(db, "a", "1");
    try expectGet(db, "b", "2");
    try expectGet(db, "c", null);
    try expectGet(db, "e", null);
}

test "deleteRange: inverted range (min >= max) is no-op" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);
    const count_before = db.entryCount();

    try db.deleteRange("d", "b"); // inverted
    try db.deleteRange("c", "c"); // empty range [c, c)

    try expectGet(db, "b", "2");
    try expectGet(db, "c", "3");
    try expectGet(db, "d", "4");
    try std.testing.expectEqual(count_before, db.entryCount());
}

test "deleteRange: keys outside range untouched (existence + value)" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);

    try db.deleteRange("a", "b"); // only deletes a
    try expectGet(db, "b", "2");
    try expectGet(db, "e", "5");
    // verify with a full scan as well: the remaining key set is correct
    var it = try db.select(null, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |e| {
        n += 1;
        try std.testing.expect(!std.mem.eql(u8, e.key, "a"));
    }
    try std.testing.expectEqual(@as(usize, 4), n);
}

test "deleteRange: micro_batch pending puts inside range are deleted" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
    defer db.close();
    // Committed baseline (bypasses micro-batching so the tree is non-empty):
    try db.putDirect("a", "1");
    try db.putDirect("e", "5");

    // pending (not flushed): m1/m2 inside the range, m3 outside
    try db.put("m1", "pending-1");
    try db.put("m2", "pending-2");
    try db.put("m3", "pending-3");
    try std.testing.expectEqual(@as(usize, 3), db.pending.items.len);

    try db.deleteRange("m1", "m3"); // should delete m1, m2; m3 kept

    // pending entries consumed by deleteRange (flushed), nothing left over
    try std.testing.expectEqual(@as(usize, 0), db.pending.items.len);
    try expectGet(db, "m1", null);
    try expectGet(db, "m2", null);
    try expectGet(db, "m3", "pending-3");
    // committed keys outside the range untouched
    try expectGet(db, "a", "1");
    try expectGet(db, "e", "5");
}

test "deleteRange: micro_batch pending deletes + staged put outside range" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
    defer db.close();
    // Committed baseline (bypasses micro-batching):
    try db.putDirect("a", "1");
    try db.putDirect("b", "2");
    try db.putDirect("c", "3");
    try db.putDirect("d", "4");
    try db.putDirect("e", "5");

    try db.delete("c"); // pending tombstone (inside the range)
    try db.put("x", "9"); // pending put, outside the range
    try db.deleteRange("b", "d"); // [b,d) half-open: delete b; c already has a pending tombstone; d is the upper bound, kept

    try expectGet(db, "a", "1");
    try expectGet(db, "b", null);
    try expectGet(db, "c", null);
    try expectGet(db, "d", "4"); // upper bound, kept
    try expectGet(db, "x", "9");
}

test "deleteRange: idempotent on already-missing keys" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);

    try db.deleteRange("f", "z"); // all missing keys
    try std.testing.expectEqual(@as(u64, 5), db.entryCount());
    try expectGet(db, "e", "5");

    // deleting the same range again after deletion -> still succeeds
    try db.deleteRange("b", "d");
    try db.deleteRange("b", "d");
    try expectGet(db, "b", null);
    try expectGet(db, "c", null);
    try expectGet(db, "d", "4");
    // deleteRange on an empty store also succeeds
    try db.deleteRange(null, null);
    try db.deleteRange(null, null);
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

test "deleteRange: entryCount reflects deletions" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try seedDirect(db);
    try std.testing.expectEqual(@as(u64, 5), db.entryCount());

    try db.deleteRange("b", "d"); // deletes b, c
    try std.testing.expectEqual(@as(u64, 3), db.entryCount());

    try db.deleteRange("a", "b"); // deletes a
    try std.testing.expectEqual(@as(u64, 2), db.entryCount());

    try db.deleteRange(null, null); // clear all
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

test "deleteRange: FilePageStore identical behavior" {
    const path = ".test_range_delete.db";
    defer unlinkPath(path);
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();
    try seedDirect(db);

    try db.deleteRange("b", "d");
    try expectGet(db, "a", "1");
    try expectGet(db, "b", null);
    try expectGet(db, "c", null);
    try expectGet(db, "d", "4");
    try expectGet(db, "e", "5");
    try std.testing.expectEqual(@as(u64, 3), db.entryCount());

    // (null, null) clearing works the same way
    try db.deleteRange(null, null);
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

test "deleteRange: byte-order comparison matches select" {
    var ms = ps.MemPageStore.init(alloc, 100000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    // lexicographic order of numeric keys: "10" < "2"
    try db.putDirect("1", "v1");
    try db.putDirect("10", "v10");
    try db.putDirect("2", "v2");
    try db.putDirect("20", "v20");

    try db.deleteRange("10", "2"); // in byte order [10, 2) = {10} ("10" < "2")
    try expectGet(db, "1", "v1");
    try expectGet(db, "10", null);
    try expectGet(db, "2", "v2");
    try expectGet(db, "20", "v20");
}

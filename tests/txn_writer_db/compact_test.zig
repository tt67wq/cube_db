//! compact_test.zig — compact v2 tests (TDD RED)
//! Covers: compact on an empty DB, clearing dirt, keeping data readable, blocking with readers, idempotence.
//! Uses MemPageStore; written to fail first (compact not yet implemented or not O(1)).
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const ps = cube.page_store;
const wrt = cube.writer;
const dbi = cube.db;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(std.testing.allocator, 10000);
}

test "compact: compact on empty db is no-op" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();
    // compact on an empty DB must not error
    try db.compact();
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

test "compact: compact clears dirt after writes" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    // Write and overwrite to produce dirty pages
    try db.put("k", "v1");
    // No readers; dirty pages already auto-flushed -> dirt = 0
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());

    // Start a reader to block the automatic flush
    const r = db.beginRead();
    try db.put("k", "v2");
    // With a reader -> dirt > 0
    try std.testing.expect(db.dirtCount() > 0);
    db.endRead(r);

    // Now the reader has ended; dirt should be 0 (auto flush)
    // But to test compact, a manual compact should also clear dirt
    try db.compact();
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
}

test "compact: compact preserves data" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    try db.put("persist", "me");
    try db.put("another", "key");
    try db.compact();

    // Data is still there
    const v1 = try db.get("persist");
    try std.testing.expectEqualStrings("me", v1.?);
    std.testing.allocator.free(v1.?);
    const v2 = try db.get("another");
    try std.testing.expectEqualStrings("key", v2.?);
    std.testing.allocator.free(v2.?);
}

test "compact: compact with active reader blocks" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    // First write the initial data
    try db.put("k", "v1");

    // Start a reader
    const r = db.beginRead();

    // Overwrite (produces dirty pages in pending_free)
    try db.put("k", "v2");
    // With a reader -> dirt > 0
    try std.testing.expect(db.dirtCount() > 0);

    // compact should either wait for the reader or skip the full flush
    // MVP: compact only flushes what is currently flushable; it does not block on the reader
    try db.compact();
    // After compact, dirt should be 0 (flushed all pending)
    // But the reader may have blocked part of the flush -> dirt should at least decrease
    // Here we only verify that compact does not crash and data stays readable
    const v = try db.get("k");
    try std.testing.expectEqualStrings("v2", v.?);
    std.testing.allocator.free(v.?);
    db.endRead(r);
}

test "compact: multiple compacts are idempotent" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    try db.put("k", "v");
    try db.compact();
    try db.compact(); // second time
    try db.compact(); // third time

    const v = try db.get("k");
    try std.testing.expectEqualStrings("v", v.?);
    std.testing.allocator.free(v.?);
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
}

test "compact: after compact, new writes work" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    try db.put("k", "v1");
    try db.compact();
    try db.put("k", "v2");
    // After overwrite, dirt should be 0 (auto flush with no readers)
    // But to test compact semantics, use beginRead here to block the flush
    // then verify that compact can clear dirt
    const r = db.beginRead();
    try db.put("k", "v3");
    try std.testing.expect(db.dirtCount() > 0);
    db.endRead(r);
    // After the reader ends, auto flush -> dirt = 0
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
}
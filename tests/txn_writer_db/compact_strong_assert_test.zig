//! compact_strong_assert_test.zig — T-22: compact strong-assertion tests
//!
//! Supplements compact_test.zig with strong assertions: not just "data readable", but also
//! exact dirt / pendingFreeCount values, verifying compact's actual semantics.
//!
//! Core semantics (src/writer.zig State.compact, revised by T-30):
//! - No readers: compact -> full reclamation -> pending_free emptied, dirt=0
//! - With readers: compact -> reclaims the subset allowed by the oldest-reader watermark;
//!   when nothing is reclaimable, pending_free is unchanged and dirt is no longer silently zeroed —
//!   it reflects the true number of still-pinned pages (the old MVP "counter-only reset" was removed in T-30)
//! - Reader ends (the last one) -> full reclamation -> pending_free emptied
//!
//! Does not modify src/ or the existing compact_test.zig.

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const wrt = cube.writer;

const alloc = std.testing.allocator;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 10000);
}

// ---- Test 1: with a reader, compact reclaims by watermark and dirt reflects the truly pinned page count (T-30 semantics) ----
// put(k, v1) → beginRead → put(k, v2) → dirt > 0, pendingFree > 0
// compact() -> nothing reclaimable (release_seq=2 !< watermark=1) -> pendingFree unchanged,
//             dirt not zeroed (still reflects the pinned page count; the old MVP silent reset to 0 was removed)
// endRead -> pendingFreeCount == 0 (full reclamation by the last reader)
test "compact_strong: with reader — compact keeps dirt truthful, pages pinned until reader ends" {
    var ms = newStore();
    defer ms.deinit();
    var db = try cube.Db.open(alloc, ms.store(), .{});
    defer db.close();

    // Initial write (no readers -> auto flush -> dirt=0)
    try db.put("k", "v1");
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
    try std.testing.expectEqual(@as(usize, 0), db.state.pendingFreeCount());

    // Start a reader to block the automatic flush
    const r = db.beginRead();

    // Overwrite to produce dirty pages -> pending_free accumulates, dirt > 0
    try db.put("k", "v2");
    try std.testing.expect(db.dirtCount() > 0);
    try std.testing.expect(db.state.pendingFreeCount() > 0);

    // compact: with a reader -> no safely reclaimable page -> pendingFree unchanged, dirt still > 0
    // (T-30: no more silent counter reset — dirt reflects the true number of still-pinned pages)
    try db.compact();
    try std.testing.expect(db.dirtCount() > 0);
    // Key assertion: pendingFreeCount is still > 0 (pages not reclaimed)
    try std.testing.expect(db.state.pendingFreeCount() > 0);
    try std.testing.expectEqual(db.state.pendingFreeCount(), @as(usize, @intCast(db.dirtCount())));

    // Data still readable (compact does not affect data visibility)
    const v = try db.get("k");
    try std.testing.expectEqualStrings("v2", v.?);
    alloc.free(v.?);

    // Reader ends -> the last reader triggers flushPendingFree
    db.endRead(r);

    // Key assertion: after the reader ends, pendingFreeCount is 0
    try std.testing.expectEqual(@as(usize, 0), db.state.pendingFreeCount());
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
}

// ---- Test 2: compact with no readers flushes everything ----
// put(k, v1) -> put(k, v2) -> dirt == 0 (auto flush with no readers)
// compact() → dirt == 0, pendingFreeCount == 0
test "compact_strong: no reader — compact flushes all pending pages" {
    var ms = newStore();
    defer ms.deinit();
    var db = try cube.Db.open(alloc, ms.store(), .{});
    defer db.close();

    // Write and overwrite (no readers -> auto flush)
    try db.put("k", "v1");
    try db.put("k", "v2");

    // With no readers, put already auto-flushed -> dirt=0, pendingFree=0
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
    try std.testing.expectEqual(@as(usize, 0), db.state.pendingFreeCount());

    // compact with no readers -> flushPendingFree (nothing left to flush)
    try db.compact();

    // Key assertion: dirt=0 and pendingFreeCount=0
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
    try std.testing.expectEqual(@as(usize, 0), db.state.pendingFreeCount());

    // Data readable
    const v = try db.get("k");
    try std.testing.expectEqualStrings("v2", v.?);
    alloc.free(v.?);
}

// ---- Test 3: entry_count / byte_size unchanged after compact ----
// compact is a metadata operation (flush dirty + write meta); it does not change logical data.
test "compact_strong: entry_count and byte_size unchanged after compact" {
    var ms = newStore();
    defer ms.deinit();
    var db = try cube.Db.open(alloc, ms.store(), .{});
    defer db.close();

    // Write several keys
    try db.put("a", "11111");
    try db.put("b", "22222");
    try db.put("c", "33333");

    const entry_count_before = db.entryCount();
    const byte_size_before = db.state.byte_size.load(.acquire);

    try std.testing.expect(entry_count_before == 3);
    try std.testing.expect(byte_size_before > 0);

    try db.compact();

    // Key assertion: compact does not change the logical data volume
    try std.testing.expectEqual(entry_count_before, db.entryCount());
    try std.testing.expectEqual(byte_size_before, db.state.byte_size.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
}

// ---- Test 4: meta written after compact — data readable on reopen ----
// compact writes a new meta (dirt=0); on reopen, the correct state is restored from meta.
test "compact_strong: after compact, reopen — meta restored, data readable" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    {
        var db = try cube.Db.open(alloc, s, .{});
        // Write + overwrite to produce dirty pages
        try db.put("k1", "v1");
        try db.put("k2", "v2");
        try db.put("k1", "override"); // overwrite produces dirty pages
        try db.compact();
        try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
        db.close();
    }

    // Reopen — meta should restore the correct root/sequence/entry_count
    var db2 = try cube.Db.open(alloc, s, .{});
    defer db2.close();

    try std.testing.expectEqual(@as(u64, 2), db2.entryCount());
    try std.testing.expectEqual(@as(u64, 0), db2.dirtCount());

    // k1 should be the overwritten value
    const v1 = try db2.get("k1");
    try std.testing.expectEqualStrings("override", v1.?);
    alloc.free(v1.?);

    // k2 is unaffected by the overwrite
    const v2 = try db2.get("k2");
    try std.testing.expectEqualStrings("v2", v2.?);
    alloc.free(v2.?);
}

// ---- Test 5: pendingFree accumulates after multiple overwrites -> compact with a reader keeps dirt truthful -> endRead clears ----
// A more complex scenario: multiple overwrites produce several batches of pendingFree while a reader is active
// T-30: compact with a reader no longer clears the dirt counter; dirt == pendingFreeCount (the truly pinned count)
test "compact_strong: multiple overwrites during reader — compact keeps dirt truthful, endRead clears pages" {
    var ms = newStore();
    defer ms.deinit();
    var db = try cube.Db.open(alloc, ms.store(), .{});
    defer db.close();

    try db.put("k", "v0");
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());

    const r = db.beginRead();

    // Multiple overwrites (each produces dirty pages; pending_free accumulates)
    try db.put("k", "v1");
    const dirt_after_v1 = db.dirtCount();
    const pending_after_v1 = db.state.pendingFreeCount();
    try std.testing.expect(dirt_after_v1 > 0);
    try std.testing.expect(pending_after_v1 > 0);

    try db.put("k", "v2");
    try std.testing.expect(db.dirtCount() > 0);
    try std.testing.expect(db.state.pendingFreeCount() > pending_after_v1);

    // compact: with a reader -> nothing reclaimable (watermark=1, all release_seq >= 2) -> unchanged
    try db.compact();
    try std.testing.expect(db.dirtCount() > 0);
    try std.testing.expect(db.state.pendingFreeCount() > 0);
    try std.testing.expectEqual(db.state.pendingFreeCount(), @as(usize, @intCast(db.dirtCount())));

    // Overwrite again -> pinned pages keep growing (dirt grows with pendingFree)
    try db.put("k", "v3");
    try std.testing.expect(db.dirtCount() > 0);

    // Second compact
    try db.compact();
    try std.testing.expect(db.dirtCount() > 0);
    try std.testing.expect(db.state.pendingFreeCount() > 0);

    // Data correct
    const v = try db.get("k");
    try std.testing.expectEqualStrings("v3", v.?);
    alloc.free(v.?);

    // Reader ends -> flush all accumulated pages
    db.endRead(r);
    try std.testing.expectEqual(@as(usize, 0), db.state.pendingFreeCount());
    try std.testing.expectEqual(@as(u64, 0), db.dirtCount());
}

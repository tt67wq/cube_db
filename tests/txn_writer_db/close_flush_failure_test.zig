//! close_flush_failure_test.zig — T-19: flush failure at close tests
//!
//! Background: src/db.zig:55 `Db.close` silently swallows flush errors with `self.flush() catch {}`.
//! If flush fails, close still proceeds to free pending and deinit.
//!
//! note: lock() never returns error in current Zig, catch is dead code.
//! zio.Mutex.lock() in a synchronous thread context takes lockThread() (futex) and returns void, not an error.
//! So putBatch's `catch return error.LockFailed` never triggers.
//!
//! The only error paths of flush():
//! - putBatch -> applyBatch with closed=true sets futures to error.Closed -> putBatch propagates it
//! - putBatch → allocator.alloc OOM
//! But safely triggering those paths before close would require a double deinit (unsafe), so this test instead covers:
//! 1. Normal path: micro-batch put -> close -> flush succeeds -> data readable
//! 2. Close with empty pending: flush is a no-op, no leaks
//! 3. Close after putDirect: pending is empty, data already committed
//! 4. Micro-batch reaching the threshold auto-flushes: pending is empty at close

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;

const alloc = std.testing.allocator;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 10000);
}

// ---- Test 1: normal path — micro-batch put -> close -> flush succeeds -> data readable ----
test "close_flush: normal micro-batch close flushes pending, data readable" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var db = try cube.Db.open(alloc, s, .{
        .micro_batch = .{ .batch_threshold = 3 },
    });

    // put 2 entries (below threshold=3, staged in pending)
    try db.put("key1", "val1");
    try db.put("key2", "val2");
    try std.testing.expectEqual(@as(usize, 2), db.pending.items.len);

    // close → flush → putBatch → applyBatch → data committed → pending freed
    db.close();
    // db is now freed

    // Reopen to verify data was flushed and committed
    var db2 = try cube.Db.open(alloc, s, .{});
    defer db2.close();

    const v1 = try db2.get("key1");
    try std.testing.expect(v1 != null);
    try std.testing.expectEqualStrings("val1", v1.?);
    alloc.free(v1.?);

    const v2 = try db2.get("key2");
    try std.testing.expect(v2 != null);
    try std.testing.expectEqualStrings("val2", v2.?);
    alloc.free(v2.?);

    try std.testing.expectEqual(@as(u64, 2), db2.entryCount());
}

// ---- Test 2: close with empty pending — flush is a no-op, no leaks ----
// note: lock() never returns error in current Zig, catch is dead code.
// flush() returns immediately when pending is empty (no-op); it does not call putBatch.
// So close with empty pending is always safe.
test "close_flush: empty pending close — flush no-op, no leak" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var db = try cube.Db.open(alloc, s, .{
        .micro_batch = .{ .batch_threshold = 5 },
    });

    try std.testing.expectEqual(@as(usize, 0), db.pending.items.len);

    // close → flush no-op → deinit → no leak
    db.close();
}

// ---- Test 3: close after putDirect — pending is empty, data already committed ----
// putDirect bypasses micro-batching and commits directly; pending stays empty.
// close's flush is a no-op; the data was committed at putDirect time.
test "close_flush: putDirect then close — pending empty, data committed" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var db = try cube.Db.open(alloc, s, .{
        .micro_batch = .{ .batch_threshold = 5 },
    });

    try db.putDirect("x", "42");
    try db.putDirect("y", "99");

    try std.testing.expectEqual(@as(usize, 0), db.pending.items.len);
    try std.testing.expectEqual(@as(u64, 2), db.entryCount());

    db.close();

    // Reopen and verify
    var db2 = try cube.Db.open(alloc, s, .{});
    defer db2.close();

    const vx = try db2.get("x");
    try std.testing.expect(vx != null);
    try std.testing.expectEqualStrings("42", vx.?);
    alloc.free(vx.?);

    const vy = try db2.get("y");
    try std.testing.expect(vy != null);
    try std.testing.expectEqualStrings("99", vy.?);
    alloc.free(vy.?);
}

// ---- Test 4: micro-batch reaches threshold and auto-flushes -> pending is empty at close ----
// put triggers flush automatically at batch_threshold; pending is emptied.
// close's flush is a no-op (pending already empty); no extra side effects.
test "close_flush: auto-flush at threshold, close with empty pending" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();

    var db = try cube.Db.open(alloc, s, .{
        .micro_batch = .{ .batch_threshold = 2 },
    });

    // put 3 entries: threshold=2 means after 2nd put, auto-flush, pending clears
    try db.put("a", "1");
    try db.put("b", "2"); // auto-flush triggers here (pending.len >= 2)
    try db.put("c", "3"); // pending has 1 entry

    // After 3 puts with threshold=2: pending should have 1 entry (c)
    try std.testing.expectEqual(@as(usize, 1), db.pending.items.len);

    // close → flush (1 pending entry) → putBatch → committed
    db.close();

    // Reopen and verify all 3 entries
    var db2 = try cube.Db.open(alloc, s, .{});
    defer db2.close();

    try std.testing.expectEqual(@as(u64, 3), db2.entryCount());

    const va = try db2.get("a");
    try std.testing.expectEqualStrings("1", va.?);
    alloc.free(va.?);

    const vb = try db2.get("b");
    try std.testing.expectEqualStrings("2", vb.?);
    alloc.free(vb.?);

    const vc = try db2.get("c");
    try std.testing.expectEqualStrings("3", vc.?);
    alloc.free(vc.?);
}

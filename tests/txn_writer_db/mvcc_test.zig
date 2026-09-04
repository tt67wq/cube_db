//! mvcc_test.zig — MVCC reader safe-reclamation tests (TDD RED)
//! Covers: dirty pages reclaimed immediately with no readers, deferred while a reader is active, reclaimed after the reader ends.
//! Uses MemPageStore; written to fail first (MVCC not yet implemented).
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;
const wrt = cube.writer;

test "mvcc: no active readers — dirty pages freed immediately" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    // Write one key (creates a new leaf, no dirty pages)
    var f1: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v1", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();
    const dirt1 = state.dirt.load(.acquire);
    try std.testing.expectEqual(@as(u64, 0), dirt1); // first insert produces no dirty page

    // Overwrite the key (old page enters pending_free; with no readers it must be freed immediately)
    var f2: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v2", .tombstone = false, .future = &f2 }});
    _ = try f2.wait();
    // No readers -> pending_free flushed -> dirt = 0 (reclaimed)
    const dirt2 = state.dirt.load(.acquire);
    try std.testing.expectEqual(@as(u64, 0), dirt2);
    try std.testing.expectEqual(@as(usize, 0), state.pendingFreeCount());
    // The pending_free list should be empty
    try std.testing.expectEqual(@as(usize, 0), state.pendingFreeCount());
}

test "mvcc: active reader prevents dirty page recycling" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    // Write one key to establish the initial pages
    var f1: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v1", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();

    // Before overwriting, record the current page count (page number reached by bump allocation)
    // At this point leaf 1 is at page FIRST_DATA_PAGE

    // Begin a read txn (simulating a reader holding a snapshot of the old root)
    const reader_seq = state.beginRead();
    try std.testing.expect(reader_seq > 0);

    // Overwrite the key (COW creates new leaf 2, frees old leaf 1)
    var f2: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v2", .tombstone = false, .future = &f2 }});
    _ = try f2.wait();

    // Active reader -> pending_free should be > 0 (old page not freed)
    try std.testing.expect(state.pendingFreeCount() > 0);

    // End the read txn
    state.endRead();

    // Now pending_free should be fully released
    try std.testing.expectEqual(@as(usize, 0), state.pendingFreeCount());
}

test "mvcc: multiple readers all release before pages freed" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    var f1: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v1", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();

    // Two readers active at the same time
    const r1 = state.beginRead();
    const r2 = state.beginRead();
    _ = r1;
    _ = r2;

    // Overwrite
    var f2: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v2", .tombstone = false, .future = &f2 }});
    _ = try f2.wait();
    try std.testing.expect(state.pendingFreeCount() > 0);

    // Release one reader -> pages must still not be freed (the other reader remains)
    state.endRead();
    try std.testing.expect(state.pendingFreeCount() > 0);

    // Release the second reader -> pages should be freed
    state.endRead();
    try std.testing.expectEqual(@as(usize, 0), state.pendingFreeCount());
}

test "mvcc: dirt counter reflects pending pages" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    var f1: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v1", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();

    _ = state.beginRead();

    var f2: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v2", .tombstone = false, .future = &f2 }});
    _ = try f2.wait();

    // dirt should equal the pending_free count (not yet freed)
    try std.testing.expectEqual(state.pendingFreeCount(), state.dirt.load(.acquire));

    state.endRead();
    // After the reader ends, dirt should be 0 (freed)
    try std.testing.expectEqual(@as(u64, 0), state.dirt.load(.acquire));
}

test "mvcc: old root still readable during concurrent write" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    // Write key="k"="v1"
    var f1: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v1", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();
    const root_v1 = state.getRoot();

    // Begin a read (simulating a reader holding a snapshot of the old root)
    _ = state.beginRead();

    // Write key="k"="v2" (COW produces a new root; the old root's page must not be reclaimed)
    var f2: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v2", .tombstone = false, .future = &f2 }});
    _ = try f2.wait();

    // The old root should still be readable (its page was not reclaimed)
    const oldv = try btree.get(std.testing.allocator, s, root_v1, "k");
    try std.testing.expectEqualStrings("v1", oldv.?);
    std.testing.allocator.free(oldv.?);

    // The new root reads the new value
    const root_v2 = state.getRoot();
    try std.testing.expect(root_v2 != root_v1);
    const newv = try btree.get(std.testing.allocator, s, root_v2, "k");
    try std.testing.expectEqualStrings("v2", newv.?);
    std.testing.allocator.free(newv.?);

    state.endRead();
}

test "mvcc: beginRead/endRead nesting" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    // Nested beginRead/endRead must count correctly
    // First write one key; subsequent overwrites produce dirty pages
    var f0: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "initial", .tombstone = false, .future = &f0 }});
    _ = try f0.wait();

    const r1 = state.beginRead();
    const r2 = state.beginRead();
    _ = r1;
    _ = r2;
    state.endRead(); // release the second one
    var f1: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "k", .value = "v", .tombstone = false, .future = &f1 }});
    _ = try f1.wait();
    // A reader is still active (the first one); pages must not be freed
    try std.testing.expect(state.pendingFreeCount() > 0);
    state.endRead(); // release the first one
    try std.testing.expectEqual(@as(usize, 0), state.pendingFreeCount());
}
// ---- T-30: per-reader sequence registration + oldest-reader watermark precise reclamation ----
//
// Old-model defect: single reader_count + last-reader flush — while any reader is active, every commit's
// COW'd-out dirty pages pile up in pending_free; a short-lived reader's exit reclaims nothing; pending/dirt
// grow unboundedly while a long-lived reader stays alive; compact() with readers silently cleared the dirt counter.
//
// New semantics (T-30 expectations):
// - Each pending page carries its release sequence release_seq (the new_sequence of the commit that freed it);
// - Each active reader registers its snapshot sequence; watermark = min snapshot over active readers;
// - A page with release_seq < watermark is safe to reclaim (no active reader can still reference it);
//   release_seq >= watermark must be retained (an old snapshot may still be valid — correctness bottom line);
// - Any reader exit triggers incremental reclamation by watermark; no need to wait for the last reader;
//   the last reader's exit (reader_count==0) still reclaims everything (existing fast path kept);
// - compact() no longer silently clears the counter: dirt reflects the true number of still-pinned (unreclaimable) pages.

fn applyPut(state: *wrt.State, key: []const u8, value: []const u8) !void {
    var fut: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = key, .value = value, .tombstone = false, .future = &fut }});
    _ = try fut.wait();
}

// Short-lived reader thread context: begin -> signal started -> wait for exit command -> end -> signal exited.
// B runs on its own thread: its begin/end occupy its own thread-local registration stack, so endRead
// pairs precisely (B's exit unregisters B's snapshot slot — the real shape of concurrent readers; see
// the thread pattern in mvcc_concurrent_flush_test. endRead takes no identity argument, so same-thread
// out-of-order ends can only pair conservatively; cross-thread is the precise pairing.)
const ShortReaderCtx = struct {
    state: *wrt.State,
    snapshot: u64 = 0,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    may_exit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn shortReaderThread(ctx: *ShortReaderCtx) void {
    ctx.snapshot = ctx.state.beginRead();
    ctx.started.store(true, .release);
    while (!ctx.may_exit.load(.acquire)) {
        std.Thread.yield() catch {};
    }
    ctx.state.endRead();
    ctx.exited.store(true, .release);
}

test "mvcc watermark: short-lived reader exit reclaims pages while long-lived reader active" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    // Build the tree: 3 commits -> sequence=3 (single-leaf tree: root is the leaf; each overwrite COWs and frees exactly 1 page)
    try applyPut(&state, "a", "1"); // seq 1
    try applyPut(&state, "b", "1"); // seq 2
    try applyPut(&state, "c", "1"); // seq 3

    // B: short-lived reader, own thread, starts early (oldest snapshot 3)
    var bctx = ShortReaderCtx{ .state = &state };
    const tb = try std.Thread.spawn(.{}, shortReaderThread, .{&bctx});
    while (!bctx.started.load(.acquire)) {
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(u64, 3), bctx.snapshot);

    // Overwrite a -> seq 4, old leaf freed (release_seq=4)
    try applyPut(&state, "a", "2");
    // Overwrite b -> seq 5, old leaf freed (release_seq=5)
    try applyPut(&state, "b", "2");
    const pending_before = state.pendingFreeCount();
    try std.testing.expectEqual(@as(usize, 2), pending_before);

    // A: long-lived reader, starts late (snapshot 5), captures its snapshot root
    const seq_a = state.beginRead();
    try std.testing.expectEqual(@as(u64, 5), seq_a);
    const root_a = state.getRoot();

    // B exits (A still active): tell thread B to end and wait for completion.
    // Old model: reclamation waits for the last reader (A) -> pending unchanged (RED fails here).
    // New model: B unregisters its snapshot slot -> watermark = A's snapshot (5) -> the page with
    //         release_seq=4 is reclaimed (4<5); the page with release_seq=5 is conservatively retained (5 !< 5, boundary page).
    bctx.may_exit.store(true, .release);
    while (!bctx.exited.load(.acquire)) {
        std.Thread.yield() catch {};
    }
    tb.join();

    const pending_after = state.pendingFreeCount();
    try std.testing.expect(pending_after < pending_before); // incremental reclamation happened
    try std.testing.expect(pending_after >= 1); // the conservative boundary page (release_seq==watermark) stays pinned
    // dirt reflects the true number of still-pinned (unreclaimable) pages
    try std.testing.expectEqual(pending_after, @as(usize, @intCast(state.dirt.load(.acquire))));

    // A's snapshot tree is still readable (retained pages unchanged)
    const va = try btree.get(std.testing.allocator, s, root_a, "a");
    try std.testing.expectEqualStrings("2", va.?);
    std.testing.allocator.free(va.?);
    const vc = try btree.get(std.testing.allocator, s, root_a, "c");
    try std.testing.expectEqualStrings("1", vc.?);
    std.testing.allocator.free(vc.?);

    // Reverse correctness: pages released after A's snapshot (release_seq=6) must not be reclaimed while A is active
    try applyPut(&state, "c", "2"); // seq 6, frees the leaf of R5 (release_seq=6)
    try std.testing.expect(state.pendingFreeCount() > pending_after);
    // A can still read its own snapshot (c is still the old value 1)
    const vc2 = try btree.get(std.testing.allocator, s, root_a, "c");
    try std.testing.expectEqualStrings("1", vc2.?);
    std.testing.allocator.free(vc2.?);

    // A exits (last reader) -> full reclamation (existing fast path)
    state.endRead();
    try std.testing.expectEqual(@as(usize, 0), state.pendingFreeCount());
    try std.testing.expectEqual(@as(u64, 0), state.dirt.load(.acquire));
}

test "mvcc watermark: compact keeps dirt truthful with active reader" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(std.testing.allocator, s, .{});
    defer state.deinit();

    try applyPut(&state, "k", "v1"); // seq 1

    // A: long-lived reader (snapshot 1)
    const seq_a = state.beginRead();
    try std.testing.expectEqual(@as(u64, 1), seq_a);

    try applyPut(&state, "k", "v2"); // seq 2, old leaf freed (release_seq=2)
    try std.testing.expect(state.pendingFreeCount() > 0);
    try std.testing.expect(state.dirt.load(.acquire) > 0);

    // compact: with a reader -> no reclaimable page (release_seq=2 !< watermark=1).
    // Old model: silently cleared the counter (false dirt=0 while pages stayed pinned) -> RED fails here.
    // New model: dirt reflects the true number of still-pinned pages; no silent reset.
    try state.compact();
    try std.testing.expect(state.pendingFreeCount() > 0);
    try std.testing.expect(state.dirt.load(.acquire) > 0);
    try std.testing.expectEqual(state.pendingFreeCount(), @as(usize, @intCast(state.dirt.load(.acquire))));

    // Data still readable (compact does not affect visibility)
    const root = state.getRoot();
    const v = try btree.get(std.testing.allocator, s, root, "k");
    try std.testing.expectEqualStrings("v2", v.?);
    std.testing.allocator.free(v.?);

    // A exits (last reader) -> full reclamation, dirt back to 0
    state.endRead();
    try std.testing.expectEqual(@as(usize, 0), state.pendingFreeCount());
    try std.testing.expectEqual(@as(u64, 0), state.dirt.load(.acquire));
}

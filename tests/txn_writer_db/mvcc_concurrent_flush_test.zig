//! mvcc_concurrent_flush_test.zig — T-16: MVCC concurrent flush stress test (#10)
//!
//! src/writer.zig:169 State.endRead: the last reader (prev==1) runs flushPendingFree(),
//! taking pending_free_mu, mutually exclusive with applyBatch's grace-period flush. This is the
//! core race point of MVCC reclamation (once an ArrayList concurrent-mutate SEGV, fixed in commit 7f4805c).
//!
//! The existing mvcc_test.zig is entirely single-threaded and sequential; the last-reader vs writer
//! flush mutual exclusion has never been exercised under real multithreading. This file: 1 writer + N readers
//! concurrently for 2-3 seconds, asserting no panic + pendingFreeCount eventually 0 + dirt eventually 0 + no leaks.
//!
//! Design:
//! - Writer thread: loop overwriting a fixed set of 100 keys (k0..k99), one applyBatch of 1 entry per
//!   iteration -> COW produces a new leaf, the old leaf enters pending_free. The fixed key set guarantees
//!   the page pool never grows without bound (flushed pending_free pages return to the freelist LIFO for reuse, never exceeding max_pages).
//! - Reader threads: loop beginRead(handle) -> brief sleep -> endRead(handle); the last reader triggers flushPendingFree,
//!   serialized with the writer's grace-period flush via pending_free_mu.
//! - Stop: atomic stop_flag + time limit (~2.5s).
//!
//! Allocator safety: only the writer thread touches state.allocator via the arena
//! (ArenaAllocator.init(state.allocator)) — single-threaded; reader threads' endRead->flushPendingFree->store.freePage
//! only mutates MemPageStore.freelist (whose allocator is separate and protected by MemPageStore.freelist_mu),
//! never touching state.allocator. So std.testing.allocator can safely detect leaks.
//!
//! Wiring: registered in build.zig under the test-db step.

const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;
const wrt = cube.writer;

const alloc = std.testing.allocator;

/// Monotonic nanoseconds (MONOTONIC clock), used for the time-limit stop
fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

/// Sleep ns nanoseconds (std.Thread.sleep moved to Io in 0.16; use libc nanosleep directly)
fn sleepNs(ns: u64) void {
    var req: std.c.timespec = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
    _ = std.c.nanosleep(&req, null);
}

const WriterCtx = struct {
    state: *wrt.State,
    stop: *std.atomic.Value(bool),
    err: ?anyerror = null,
    /// Number of writes (used to assert the writer actually ran)
    writes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

const ReaderCtx = struct {
    state: *wrt.State,
    stop: *std.atomic.Value(bool),
    err: ?anyerror = null,
    reads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn writerThread(ctx: *WriterCtx) void {
    // Overwrite the fixed 100-key set (k0..k99), one applyBatch of 1 entry each time.
    // Fixed key set -> COW'd old pages enter pending_free, return to the freelist after flush for reuse; never exceeds max_pages.
    var i: u64 = 0;
    while (!ctx.stop.load(.acquire)) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = std.fmt.bufPrint(&kbuf, "k{d:0>3}", .{i % 100}) catch {
            ctx.err = error.FormatFailed;
            return;
        };
        var vbuf: [16]u8 = undefined;
        const v = std.fmt.bufPrint(&vbuf, "v{d}", .{i}) catch {
            ctx.err = error.FormatFailed;
            return;
        };
        var fut: zio.Future(wrt.OpResult) = .{};
        const reqs = [_]wrt.Request{.{ .key = k, .value = v, .tombstone = false, .future = &fut }};
        ctx.state.applyBatch(&reqs) catch |err| {
            ctx.err = err;
            return;
        };
        // Wait for the future (applyBatch already set it internally; wait takes the result)
        _ = fut.wait() catch |err| {
            ctx.err = err;
            return;
        };
        _ = ctx.writes.fetchAdd(1, .monotonic);
    }
}

fn readerThread(ctx: *ReaderCtx) void {
    while (!ctx.stop.load(.acquire)) {
        const reader = ctx.state.beginRead();
        _ = reader;
        // Hold the read txn briefly to widen the last-reader flush race window
        std.Thread.yield() catch {};
        // Occasionally sleep a bit so multiple readers interleave
        if (ctx.reads.load(.monotonic) % 7 == 0) {
            sleepNs(1_000_000); // 1ms
        }
        ctx.state.endRead(reader); // the last reader triggers flushPendingFree
        _ = ctx.reads.fetchAdd(1, .monotonic);
    }
}

test "mvcc_concurrent_flush: 1 writer + 3 readers, no panic, pending/dirt zero" {
    var ms = ps.MemPageStore.init(alloc, 2000);
    defer ms.deinit();
    const s = ms.store();

    var state = wrt.State.init(alloc, s, .{ .fsync = false });
    defer state.deinit();

    // Warm-up: write the 100 keys first to build the initial tree (so later overwrites produce COW dirty pages)
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>3}", .{i});
        var fut: zio.Future(wrt.OpResult) = .{};
        const reqs = [_]wrt.Request{.{ .key = k, .value = "init", .tombstone = false, .future = &fut }};
        try state.applyBatch(&reqs);
        _ = try fut.wait();
    }

    // Stress for 2.5 seconds
    const duration_ns: i64 = 2_500_000_000;
    var stop = std.atomic.Value(bool).init(false);

    var wctx = WriterCtx{ .state = &state, .stop = &stop };
    var rctx0 = ReaderCtx{ .state = &state, .stop = &stop };
    var rctx1 = ReaderCtx{ .state = &state, .stop = &stop };
    var rctx2 = ReaderCtx{ .state = &state, .stop = &stop };

    const t_start = monoNs();

    const tw = try std.Thread.spawn(.{}, writerThread, .{&wctx});
    const tr0 = try std.Thread.spawn(.{}, readerThread, .{&rctx0});
    const tr1 = try std.Thread.spawn(.{}, readerThread, .{&rctx1});
    const tr2 = try std.Thread.spawn(.{}, readerThread, .{&rctx2});

    // Main thread waits for the time limit
    while (monoNs() - t_start < duration_ns) {
        sleepNs(10_000_000); // 10ms polling
    }
    stop.store(true, .release);

    tw.join();
    tr0.join();
    tr1.join();
    tr2.join();

    const elapsed_ns = monoNs() - t_start;

    // 1. No panic / no segfault (threads joining normally means no crash; additionally check no thread recorded an error)
    try std.testing.expect(wctx.err == null);
    try std.testing.expect(rctx0.err == null);
    try std.testing.expect(rctx1.err == null);
    try std.testing.expect(rctx2.err == null);

    // 2. Runtime > 1 second (proves this is a stress test, not a smoke test)
    try std.testing.expect(elapsed_ns > 1_000_000_000);

    // 3. The writer actually ran many iterations + readers actually ran many iterations
    try std.testing.expect(wctx.writes.load(.monotonic) > 100);
    const total_reads = rctx0.reads.load(.monotonic) + rctx1.reads.load(.monotonic) + rctx2.reads.load(.monotonic);
    try std.testing.expect(total_reads > 100);

    // 4. All readers have exited -> reader_count == 0. Do one final applyBatch to trigger the
    //    grace-period flush (reader_count==0 branch), ensuring pending_free is emptied.
    try std.testing.expectEqual(@as(u32, 0), state.reader_count.load(.acquire));
    var fut_final: zio.Future(wrt.OpResult) = .{};
    const final_reqs = [_]wrt.Request{.{ .key = "k_final", .value = "done", .tombstone = false, .future = &fut_final }};
    try state.applyBatch(&final_reqs);
    _ = try fut_final.wait();

    // 5. Assert pendingFreeCount eventually reaches 0 (all dirty pages reclaimed)
    try std.testing.expectEqual(@as(usize, 0), state.pendingFreeCount());

    // 6. Assert dirt eventually reaches 0
    try std.testing.expectEqual(@as(u64, 0), state.dirt.load(.acquire));

    // 7. Data correctness spot check: k000 must be readable (its last overwrite happened during the race)
    //    Old root snapshots have been reclaimed, but the current root's k000 is readable
    const root = state.getRoot();
    try std.testing.expect(root != btree.NULL_ROOT);
    const v = try btree.get(alloc, s, root, "k000");
    try std.testing.expect(v != null);
    alloc.free(v.?);

    // std.testing.allocator detects leaks when the test ends: a leak would mean pending_free
    // lost page numbers under concurrency (a missing freePage) or the arena was not released.
    // state.deinit() frees the remaining pending_free; the arena is deinit'd via defer inside applyBatch. No leaks expected.
}

//! freelist_concurrent_test.zig - T-33 RED (P0): FilePageStore's freelist has no lock
//!
//! The bug: MemPageStore guards its freelist with `freelist_mu` (page_store.zig: vtAllocPage /
//! vtFreePage / vtReadPage / vtWritePage all take it). FilePageStore has the same `freelist:
//! ArrayList(u32)` and no lock at all — while a reader thread runs
//! `endRead -> reclaimPendingFree -> store.freePage` (append), the writer thread runs
//! `applyBatch -> btree.insert -> store.allocPage` (pop). Two threads mutating one ArrayList:
//! items pointer, length and capacity are all raced, so pages can be lost (leak) or handed out
//! twice (corruption).
//!
//! This test is the regression net for step 0 (the lock must land *before* chain persistence, or the
//! persisted chain is a record of whatever the race produced).
//!
//! RED status on main: the deterministic signal is the `freelist_mu` field contract below. The race
//! itself is probabilistic — a run may also die with SIGSEGV inside the ArrayList, which is the same
//! bug wearing a different hat; either outcome is RED. The pool-duplicate scan is gated on the lock
//! existing, because scanning a raced ArrayList on main can read a garbage length and take the
//! process down for an unattributable reason instead of failing an assertion.
//!
//! Allocator discipline: FilePageStore gets `std.heap.page_allocator` (thread-safe) so that on main
//! the race is confined to the ArrayList's own fields rather than also corrupting the leak-checking
//! allocator; `Db` keeps `std.testing.allocator` and is only touched by the writer thread (its arena
//! lives in applyBatch). Reader threads allocate nothing: they use `getInto` (caller buffer) and
//! `select` (borrowed iterator, no overflow values in this workload).
//!
//! Hookup: comptime @import at the end of tests/core_format/format_test.zig.

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const ps = cube.page_store;
const Db = cube.Db;
const FilePageStore = cube.file_page_store.FilePageStore;
const part = @import("page_partition.zig");

const c = @cImport({
    @cInclude("unistd.h");
});

const alloc = std.testing.allocator;

const n_keys: usize = 200;
const n_readers: usize = 3;
const duration_ns: i64 = 1_200_000_000;

fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

/// std.Thread.sleep moved to Io in 0.16; libc nanosleep, same as mvcc_concurrent_flush_test.zig.
fn sleepNs(ns: u64) void {
    var req: std.c.timespec = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
    _ = std.c.nanosleep(&req, null);
}

fn fmtKey(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "k{d:0>6}", .{i}) catch unreachable;
}

/// Fixed value per key (not per iteration): any successful read must return exactly this, so a page
/// handed out twice shows up as a wrong or missing value rather than an unpredictable one.
fn fmtVal(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "v{d:0>6}", .{i}) catch unreachable;
}

const WriterCtx = struct {
    db: *Db,
    stop: *std.atomic.Value(bool),
    err: ?anyerror = null,
    writes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

const ReaderCtx = struct {
    db: *Db,
    stop: *std.atomic.Value(bool),
    err: ?anyerror = null,
    reads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

/// One commit per iteration: COW victims go to pending_free, and step 9 (or a reader's endRead)
/// pushes them into the store's freelist while the next iteration's allocPage pops from it.
fn writerThread(ctx: *WriterCtx) void {
    var kbuf: [16]u8 = undefined;
    var vbuf: [16]u8 = undefined;
    var i: usize = 0;
    while (!ctx.stop.load(.acquire)) : (i += 1) {
        const k = fmtKey(&kbuf, i % n_keys);
        const v = fmtVal(&vbuf, i % n_keys);
        ctx.db.putDirect(k, v) catch |err| {
            ctx.err = err;
            return;
        };
        _ = ctx.writes.fetchAdd(1, .monotonic);
    }
}

/// beginReadTxn/end is what reaches `store.freePage` from a non-writer thread (endRead reclaims by
/// watermark). Every 8th iteration holds a borrowed range iterator instead, to widen the window.
fn readerThread(ctx: *ReaderCtx) void {
    var kbuf: [16]u8 = undefined;
    var vbuf: [16]u8 = undefined;
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (!ctx.stop.load(.acquire)) : (i += 1) {
        const n = ctx.reads.load(.monotonic);
        if (n % 8 == 0) {
            var it = ctx.db.select(null, null) catch |err| {
                ctx.err = err;
                return;
            };
            while (it.next() catch |err| {
                ctx.err = err;
                it.deinit();
                return;
            }) |_| {}
            it.deinit(); // releases the reader pin -> may trigger reclamation
        } else {
            var txn = ctx.db.beginReadTxn() catch |err| {
                ctx.err = err;
                return;
            };
            const k = fmtKey(&kbuf, i % n_keys);
            const want = fmtVal(&vbuf, i % n_keys);
            const got = txn.getInto(k, &buf) catch |err| {
                ctx.err = err;
                txn.end();
                return;
            };
            if (got) |len| {
                if (len != want.len or !std.mem.eql(u8, buf[0..len], want)) {
                    ctx.err = error.ValueCorrupted;
                    txn.end();
                    return;
                }
            }
            txn.end(); // endRead -> reclaimPendingFree -> store.freePage (the raced append)
        }
        std.Thread.yield() catch {};
        _ = ctx.reads.fetchAdd(1, .monotonic);
    }
}

test "P0: 1 writer + 3 readers churn on FilePageStore — no lost or double-allocated page" {
    const path = ".test_fl_concurrent.db";
    defer {
        var buf: [256]u8 = undefined;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        _ = c.unlink(@ptrCast(&buf));
    }

    var meta_before: f2.MetaPage = undefined;

    // ---- phase 1: the concurrent churn ----
    {
        // page_allocator for the store: see the allocator-discipline note in the header
        var fps = try FilePageStore.init(std.heap.page_allocator, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{ .fsync = false });
        defer db.close();

        // warm-up: build the tree so later overwrites actually produce COW victims
        {
            var kbuf: [16]u8 = undefined;
            var vbuf: [16]u8 = undefined;
            for (0..n_keys) |i| try db.putDirect(fmtKey(&kbuf, i), fmtVal(&vbuf, i));
        }

        var stop = std.atomic.Value(bool).init(false);
        var wctx = WriterCtx{ .db = db, .stop = &stop };
        var rctx: [n_readers]ReaderCtx = undefined;
        for (&rctx) |*r| r.* = .{ .db = db, .stop = &stop };

        const t0 = monoNs();
        const tw = try std.Thread.spawn(.{}, writerThread, .{&wctx});
        var trs: [n_readers]std.Thread = undefined;
        for (&trs, &rctx) |*t, *r| t.* = try std.Thread.spawn(.{}, readerThread, .{r});

        while (monoNs() - t0 < duration_ns) sleepNs(10_000_000);
        stop.store(true, .release);
        tw.join();
        for (&trs) |*t| t.join();
        const elapsed = monoNs() - t0;

        // 1. it was a stress run, not a smoke run
        try std.testing.expect(elapsed > 1_000_000_000);
        try std.testing.expect(wctx.writes.load(.monotonic) > 200);
        var total_reads: u64 = 0;
        for (&rctx) |*r| total_reads += r.reads.load(.monotonic);
        try std.testing.expect(total_reads > 200);

        // 2. no thread hit an error (a page handed out twice surfaces as ValueCorrupted in a reader)
        try std.testing.expect(wctx.err == null);
        for (&rctx) |*r| try std.testing.expect(r.err == null);

        // 3. every reader is gone, so one more commit must drain pending_free completely
        try db.putDirect("k_final", "done");
        try std.testing.expectEqual(@as(u64, 0), db.dirtCount());

        // 4. the whole key set still reads back byte-exact
        {
            var kbuf: [16]u8 = undefined;
            var vbuf: [16]u8 = undefined;
            var rbuf: [64]u8 = undefined;
            for (0..n_keys) |i| {
                const want = fmtVal(&vbuf, i);
                const got = try db.getInto(fmtKey(&kbuf, i), &rbuf) orelse return error.KeyMissing;
                try std.testing.expectEqualSlices(u8, want, rbuf[0..got]);
            }
        }

        // persist the pool so phase 2 can inspect the durable state
        try db.compact();
        meta_before = (try fps.store().readMeta()) orelse return error.NoMeta;
    }

    // ---- phase 2: reopen and inspect the durable state ----
    var fps2 = try FilePageStore.init(std.heap.page_allocator, path);
    defer fps2.deinit();
    const meta = (try fps2.store().readMeta()) orelse return error.NoMeta;
    try std.testing.expectEqual(meta_before.last_page, meta.last_page);

    var rep = try part.classify(alloc, fps2.store(), meta);
    defer rep.deinit();
    part.dump(&rep, "P0 concurrent");
    try part.expectDisjoint(&rep); // no page in two classes => nothing was double-allocated

    // 5. the restored pool must not list any page twice (a raced append can duplicate an entry,
    //    which later becomes a double allocation). Gated on the lock existing: on main the ArrayList
    //    itself may be corrupt, and scanning it could take the process down for the wrong reason.
    if (@hasField(FilePageStore, "freelist_mu")) {
        if (@hasDecl(FilePageStore, "freePagesSnapshot")) {
            const snap = try fps2.freePagesSnapshot(alloc);
            defer alloc.free(snap);
            const sorted = try alloc.dupe(u32, snap);
            defer alloc.free(sorted);
            std.mem.sort(u32, sorted, {}, std.sort.asc(u32));
            for (sorted, 0..) |p, i| {
                try std.testing.expect(p >= ps.FIRST_DATA_PAGE and p <= meta.last_page);
                if (i > 0 and sorted[i - 1] == p) {
                    std.debug.print("P0: page {d} listed twice in the freelist\n", .{p});
                    return error.DuplicateFreePage;
                }
            }
        }
    }

    // 6. the contract this whole test exists for: FilePageStore must guard its freelist the way
    //    MemPageStore does. RED on main — this is the deterministic signal.
    try std.testing.expect(@hasField(FilePageStore, "freelist_mu"));
}

//! reader_handle_test.zig — T-32 RED: failing tests for the explicit Reader handle API.
//!
//! API under test (per .agents/tasks/reader-handle/task.md):
//!   pub const Reader = struct { state: *State, seq: u64, active: bool };
//!   pub fn beginRead(self: *State) *Reader;
//!   pub fn endRead(self: *State, reader: *Reader) void;
//!
//! These tests are RED: they do not compile against main (no wrt.Reader,
//! beginRead returns u64). GREEN implements the handle API and migrates
//! callers; these tests must then pass unchanged.
//!
//! Misuse design choice (red.md item 7 — chosen and documented here):
//! endRead(state, reader) with reader.state != state must NOT silently
//! corrupt state. We encode PREVENTED BY DESIGN: endRead guards on
//! reader.state == self and returns early on mismatch (a documented no-op;
//! neither State's registry nor reader_count is touched).

const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const ps = cube.page_store;
const wrt = cube.writer;

/// Test harness: MemPageStore + writer State, mirroring the setup of the
/// existing mvcc tests.
const TestDb = struct {
    ms: ps.MemPageStore,
    state: wrt.State,

    fn init() TestDb {
        return .{
            .ms = ps.MemPageStore.init(std.testing.allocator, 1000),
            .state = undefined,
        };
    }

    fn setup(self: *TestDb) void {
        self.state = wrt.State.init(std.testing.allocator, self.ms.store(), .{});
    }

    fn deinit(self: *TestDb) void {
        self.state.deinit();
        self.ms.deinit();
    }
};

/// One single-key write commit (fresh future per call, as in mvcc_test).
fn write(state: *wrt.State, key: []const u8, value: []const u8) !void {
    var f: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = key, .value = value, .tombstone = false, .future = &f }});
    _ = try f.wait();
}

fn readerCount(state: *wrt.State) u32 {
    return state.reader_count.load(.acquire);
}

// ---- 1. single reader ----

test "reader handle: single reader — begin/end, handle identity, watermark while active" {
    var db = TestDb.init();
    db.setup();
    defer db.deinit();
    const st = &db.state;

    try write(st, "k", "v1");

    const r = st.beginRead();
    // Handle identity: owns this State, captured a live snapshot, is active.
    try std.testing.expect(r.state == st);
    try std.testing.expect(r.active);
    try std.testing.expect(r.seq == st.sequence.load(.acquire));
    try std.testing.expect(r.seq > 0);
    try std.testing.expectEqual(@as(u32, 1), readerCount(st));

    // While the reader is active, COW'd old pages are pinned (the reader's
    // snapshot is the watermark).
    try write(st, "k", "v2");
    try std.testing.expect(st.pendingFreeCount() > 0);

    st.endRead(r);
    try std.testing.expectEqual(@as(u32, 0), readerCount(st));
    try std.testing.expect(!r.active);
    // Reader gone -> watermark lifted -> pages reclaimed.
    try std.testing.expectEqual(@as(usize, 0), st.pendingFreeCount());
}

// ---- 2. nested readers ----

test "reader handle: nested readers — independent handles, non-LIFO release, min watermark" {
    var db = TestDb.init();
    db.setup();
    defer db.deinit();
    const st = &db.state;

    try write(st, "k", "v1"); // establish the tree
    const r1 = st.beginRead();
    try std.testing.expectEqual(@as(u32, 1), readerCount(st));

    // Two commits while only r1 is active: their old pages have
    // release_seq < any snapshot taken after them.
    try write(st, "k", "v2");
    try write(st, "k", "v3");

    const r2 = st.beginRead(); // snapshot strictly newer than r1's
    try std.testing.expectEqual(@as(u32, 2), readerCount(st));
    try std.testing.expect(r2.seq > r1.seq);
    try std.testing.expect(r2.state == st);

    // A third commit while both readers are active.
    try write(st, "k", "v4");
    const pending_both = st.pendingFreeCount();
    try std.testing.expect(pending_both > 0);
    try std.testing.expectEqual(st.pendingFreeCount(), @as(usize, @intCast(st.dirtCount())));

    // Release the FIRST-begun handle FIRST (FIFO, not LIFO). A TLS-stack
    // pairing design mis-pairs here; each handle must unregister itself.
    st.endRead(r1);
    try std.testing.expectEqual(@as(u32, 1), readerCount(st));

    // Watermark is now r2's snapshot: pages from commits older than r2's
    // snapshot are reclaimed, r2's own pinned pages are kept.
    const pending_after = st.pendingFreeCount();
    try std.testing.expect(pending_after > 0);
    try std.testing.expect(pending_after < pending_both);

    st.endRead(r2);
    try std.testing.expectEqual(@as(u32, 0), readerCount(st));
    try std.testing.expectEqual(@as(usize, 0), st.pendingFreeCount());
    try std.testing.expectEqual(@as(u64, 0), st.dirtCount());
}

// ---- 3. many readers / pool reuse ----

test "reader handle: many readers — 100 sequential and 100 overlapping, no leak" {
    var db = TestDb.init();
    db.setup();
    defer db.deinit();
    const st = &db.state;

    try write(st, "k", "v0");

    // Sequential churn: the pool must hand out and take back handles
    // without leaking registrations or breaking reclamation.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const r = st.beginRead();
        try std.testing.expectEqual(@as(u32, 1), readerCount(st));
        if (i % 10 == 0) {
            // A write under an active reader pins pages...
            try write(st, "k", "v");
            try std.testing.expect(st.pendingFreeCount() > 0);
        }
        st.endRead(r);
        try std.testing.expectEqual(@as(u32, 0), readerCount(st));
        // ...and the exit of each short-lived reader reclaims them.
        try std.testing.expectEqual(@as(usize, 0), st.pendingFreeCount());
    }

    // Overlapping storm: 100 concurrent handles on one State (beyond the
    // old 64-slot design), released in reverse order.
    var handles: [100]*wrt.Reader = undefined;
    for (&handles) |*h| h.* = st.beginRead();
    try std.testing.expectEqual(@as(u32, 100), readerCount(st));

    try write(st, "k", "v");
    try std.testing.expect(st.pendingFreeCount() > 0);

    var j: usize = handles.len;
    while (j > 0) {
        j -= 1;
        st.endRead(handles[j]);
        // reader_count must track exactly (no double-decrement, no leak).
        try std.testing.expectEqual(@as(u32, @intCast(j)), readerCount(st));
    }
    try std.testing.expectEqual(@as(usize, 0), st.pendingFreeCount());

    // The pool is still functional after the storm.
    const r = st.beginRead();
    try std.testing.expectEqual(@as(u32, 1), readerCount(st));
    st.endRead(r);
    try std.testing.expectEqual(@as(u32, 0), readerCount(st));
}

// ---- 4. active reader holds watermark ----

test "reader handle: active reader holds watermark — pending kept, then reclaimed" {
    var db = TestDb.init();
    db.setup();
    defer db.deinit();
    const st = &db.state;

    try write(st, "k", "v1");

    const r = st.beginRead();
    try write(st, "k", "v2");
    // Old page is in pending_free: pinned by the active reader.
    try std.testing.expect(st.pendingFreeCount() > 0);
    try std.testing.expect(st.dirtCount() > 0);

    st.endRead(r);
    // Reader done: everything is reclaimable and reclaimed.
    try std.testing.expectEqual(@as(usize, 0), st.pendingFreeCount());
    try std.testing.expectEqual(@as(u64, 0), st.dirtCount());
}

// ---- 5. no readers fast path ----

test "reader handle: no readers — write reclaims old pages immediately (fast path)" {
    var db = TestDb.init();
    db.setup();
    defer db.deinit();
    const st = &db.state;

    try write(st, "k", "v1");
    try std.testing.expectEqual(@as(u32, 0), readerCount(st));

    // Overwrite with no active reader: the COW'd old page must be
    // reclaimed by the time applyBatch returns.
    try write(st, "k", "v2");
    try std.testing.expectEqual(@as(usize, 0), st.pendingFreeCount());
    try std.testing.expectEqual(@as(u64, 0), st.dirtCount());

    try write(st, "k", "v3");
    try std.testing.expectEqual(@as(usize, 0), st.pendingFreeCount());
}

// ---- 6. double-end no-op ----

test "reader handle: double endRead is a safe no-op" {
    var db = TestDb.init();
    db.setup();
    defer db.deinit();
    const st = &db.state;

    try write(st, "k", "v1");

    const r = st.beginRead();
    try std.testing.expectEqual(@as(u32, 1), readerCount(st));

    st.endRead(r);
    try std.testing.expectEqual(@as(u32, 0), readerCount(st));
    try std.testing.expect(!r.active);

    // Second end on the same handle (no intervening beginRead): guarded by
    // .active — must not underflow reader_count or corrupt the pool.
    // (A stale end AFTER the pool recycled the handle for a new reader is
    // use-after-recycle, outside the contract — not encoded here.)
    st.endRead(r);
    try std.testing.expectEqual(@as(u32, 0), readerCount(st));
    try std.testing.expectEqual(@as(usize, 0), st.pendingFreeCount());
}

// ---- 7. misuse: cross-state endRead (documented choice: guarded no-op) ----

test "reader handle: cross-state endRead is a guarded no-op, never corrupts" {
    // Design choice (red.md item 7, "prevented by design"): endRead checks
    // reader.state == self and returns early on mismatch. Releasing a
    // foreign State's reader is therefore impossible: neither State's
    // registry nor reader_count is touched. (Chosen over a panic because
    // Zig 0.16 has no in-process expectPanics and no test-accessible argv
    // for a child-process harness; the guard is testable directly.)
    var db1 = TestDb.init();
    db1.setup();
    defer db1.deinit();
    var db2 = TestDb.init();
    db2.setup();
    defer db2.deinit();

    try write(&db1.state, "k", "v1");
    const r1 = db1.state.beginRead();
    try std.testing.expectEqual(@as(u32, 1), readerCount(&db1.state));
    try std.testing.expectEqual(@as(u32, 0), readerCount(&db2.state));

    // Misuse: release db1's reader through db2 — must be a no-op.
    db2.state.endRead(r1);
    try std.testing.expectEqual(@as(u32, 1), readerCount(&db1.state));
    try std.testing.expectEqual(@as(u32, 0), readerCount(&db2.state));
    try std.testing.expect(r1.active); // db1's reader is untouched

    // The correct release still works and reclaims normally.
    db1.state.endRead(r1);
    try std.testing.expectEqual(@as(u32, 0), readerCount(&db1.state));
    try std.testing.expectEqual(@as(u32, 0), readerCount(&db2.state));
    try std.testing.expect(!r1.active);
}

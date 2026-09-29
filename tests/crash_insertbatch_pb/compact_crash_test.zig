//! compact_crash_test.zig — U5-7: compactFull crash matrix (design `bb4d489`
//! §7 step 6 / §4). Fork-harness family, sibling of tomb_chain_crash_test.zig.
//!
//! Convention (U5-8, T-70 long-term item — no script gate by design): every
//! NEW matrix cell must (1) appear as a row in the report's tag×window table
//! and (2) print that cell's stdout verbatim into the report.
//!
//! Windows covered (design §4.2):
//!   - COPY window (§4.1 "拷贝期磁盘零新状态"): the child drives the kernel
//!     (compact.run) directly and aborts the process from the test-owned
//!     progress callback at a deterministic batch point. No engine code is
//!     touched: the progress callback is the injection seam the kernel
//!     already exposes (design §2.1 ⑥/§2.5), and abort() from test code is
//!     a real process crash at exactly that point.
//!       * compact_crash mid_copy(k=1): crash after the first batch landed
//!         (800 survivors / budget 64 → 12 loop batches + tail 32);
//!       * compact_crash mid_copy(k=12 late): same workload, crash after the
//!         LAST loop batch — tail 32 still unwritten (late-stage cell);
//!       * compact_crash mid_copy(k=12 exact-multiple): 768 survivors = 12×64
//!         → EMPTY tail, so the last loop flush completes the entire copy —
//!         per design §4.2 this disk state is indistinguishable from the
//!         before_retire window (retire enqueue is pure memory).
//!   - PUBLISH window (N+2 rows): the child runs the REAL Db.compactFull
//!     (publish commit = N+1), then arms an EXISTING CrashTag and does one
//!     small putBatch (the N+2 commit) — abort fires inside vtWriteMeta at
//!     the tagged point, exactly like the T-38-5 family. Both §4.2 N+2
//!     mutex cases are covered:
//!       * no reader at compactFull close → old tree pages drained into the
//!         pool → persisted by the N+2 big chain (freePageCount ≥ old tree);
//!       * reader held ACROSS compactFull and the N+2 commit → old tree
//!         pages are orphans (leak direction; freePageCount stays small).
//!   - unarmed baseline: child completes the whole compactFull normally →
//!     parent asserts the published state (harness honesty control).
//!
//! Leak accounting (task §3): every case asserts the orphan/pool numbers are
//! derivable from the operation sequence — not just "the db still opens".

const std = @import("std");
const cube = @import("cube_db");
const btree = cube.btree;
const compact = cube.compact;
const FilePageStore = cube.file_page_store.FilePageStore;
const Db = cube.Db;
const tdiag = @import("test_diag.zig");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
});

const alloc = std.testing.allocator;

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

fn pathZ(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return try allocator.dupeZ(u8, path);
}

fn armCrashHook(comptime tag_name: []const u8) void {
    const Tag = FilePageStore.CrashTag;
    if (@hasField(Tag, tag_name)) {
        FilePageStore.test_crash_hook = @field(Tag, tag_name);
    }
}

// ===== shared workload =====

const N_PUT: usize = 800; // pre-state entries
const N_SURV: u64 = 200; // after deleteRange [key200, inf)
const VAL_LEN: usize = 64;

fn fmtKey(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>10}", .{i}) catch unreachable;
}

/// Parent-side pre-state builder (runs in the parent BEFORE fork).
const PreInfo = struct { old_tree_pages: usize, old_root: u32 };

fn buildPreState(path: []const u8, churn_rounds: usize) !PreInfo {
    return buildPreStateN(path, churn_rounds, 200);
}

/// `survivors` = keys 0..survivors kept (deleteRange [survivors, ∞)).
fn buildPreStateN(path: []const u8, churn_rounds: usize, survivors: usize) !PreInfo {
    var fps = try tdiag.initStoreWithRetry(FilePageStore, alloc, path, 10);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{ .fsync = false });
    defer db.close();
    var value: [VAL_LEN]u8 = undefined;
    @memset(&value, 'v');
    var batch: std.ArrayList(cube.Entry) = .empty;
    defer batch.deinit(alloc);
    defer for (batch.items) |e| alloc.free(e.key);
    var k: usize = 0;
    while (k < N_PUT) : (k += 250) {
        for (batch.items) |e| alloc.free(e.key);
        batch.clearRetainingCapacity();
        for (0..250) |j| {
            var kb: [10]u8 = undefined;
            try batch.append(alloc, .{ .key = try alloc.dupe(u8, fmtKey(&kb, k + j)), .value = &value });
        }
        try db.putBatch(batch.items);
    }
    // churn: re-put the first 250 keys (COW victims grow the pool)
    var round: usize = 0;
    while (round < churn_rounds) : (round += 1) {
        for (batch.items) |e| alloc.free(e.key);
        batch.clearRetainingCapacity();
        for (0..250) |j| {
            var kb: [10]u8 = undefined;
            try batch.append(alloc, .{ .key = try alloc.dupe(u8, fmtKey(&kb, j)), .value = &value });
        }
        try db.putBatch(batch.items);
    }
    // range-delete [survivors, ∞)
    var kmin: [10]u8 = undefined;
    _ = fmtKey(&kmin, survivors);
    try db.deleteRange(&kmin, null);
    try std.testing.expectEqual(@as(u64, survivors), db.entryCount());

    var pages: std.ArrayList(u32) = .empty;
    defer pages.deinit(alloc);
    try btree.collectTreePages(alloc, db.store, db.getRoot(), &pages);
    return .{ .old_tree_pages = pages.items.len, .old_root = db.getRoot() };
}

fn buildPreStateFile(path: []const u8, churn_rounds: usize) !usize {
    const info = try buildPreState(path, churn_rounds);
    return info.old_tree_pages;
}

fn buildPreStateFileN(path: []const u8, churn_rounds: usize, survivors: usize) !usize {
    const info = try buildPreStateN(path, churn_rounds, survivors);
    return info.old_tree_pages;
}

/// Parent-side post-crash verification: reopen, assert the recovered root is
/// the OLD (root, tomb_head) — per-key reads identical to the pre-state
/// visible set — and scrub is all-green (§4.1/§4.2 shared invariant).
fn verifyRecoveredOldRoot(path: []const u8, survivors: u64) !void {
    return verifyRecoveredOldRootN(path, survivors, 800);
}

fn verifyRecoveredOldRootN(path: []const u8, survivors: u64, n_put: usize) !void {
    var fps = try tdiag.initStoreWithRetry(FilePageStore, alloc, path, 10);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();
    try std.testing.expectEqual(survivors, db.entryCount());
    // per-key reads
    var kbuf: [10]u8 = undefined;
    var got: usize = 0;
    for (0..n_put) |i| {
        const k = fmtKey(&kbuf, i);
        const v = try db.get(k);
        defer if (v) |val| alloc.free(val);
        if (i < survivors) {
            try std.testing.expect(v != null);
            got += 1;
        } else {
            try std.testing.expect(v == null); // still shadowed (tomb_head intact)
        }
    }
    try std.testing.expectEqual(@as(usize, @intCast(survivors)), got);
    // whole-file scrub: every data page CRC-valid
    var sink: [256]u8 = undefined;
    var dw = std.Io.Writer.Discarding.init(&sink);
    var report = try cube_check_mod.scrub(alloc, fps.store(), &dw.writer);
    defer report.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), report.failed.len);
}

const cube_check_mod = @import("cube_check");

// ===== COPY-window children (kernel + progress abort; no engine changes) =====

// F1 (review 501e7aa): the copy-window cells are honest only if the progress
// callback ACTUALLY fires — the workload must span several kernel batches
// (visible set > batch budget), the child must die by SIGABRT (not any
// non-zero exit), and the parent must reconcile the recorded fire count.
// The child records "fires=<n>/batches=<b>" into a sidecar file right before
// abort; the parent asserts fires >= 1 and batches == the targeted k.

var crash_after_batches: u64 = 0;
var fire_count: u64 = 0;
var last_copied: u64 = 0;
var fires_path: [:0]const u8 = "";

fn progressAbortAtBatch(copied: u64, batches: u64, user: ?*anyopaque) bool {
    _ = user;
    fire_count += 1;
    last_copied = copied;
    if (batches >= crash_after_batches) {
        // record the reconciliation evidence, then crash for real
        var buf: [128]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "fires={d}\nbatches={d}\ncopied={d}\n", .{ fire_count, batches, last_copied }) catch unreachable;
        {
            var f = std.Io.Dir.cwd().createFile(std.testing.io, fires_path, .{}) catch std.process.abort();
            f.writeStreamingAll(std.testing.io, content) catch {
                f.close(std.testing.io);
                std.process.abort();
            };
            f.sync(std.testing.io) catch {};
            f.close(std.testing.io);
        }
        std.process.abort(); // deterministic crash at this exact point
    }
    return true;
}

/// Child: kernel copy with a deterministic mid-copy abort. The workload is
/// sized by the caller (visible entries MUST exceed batch_max_entries so
/// mid-loop flushes — and therefore progress calls — really happen).
fn childCopyCrash(path_z: [:0]const u8, comptime power_fail: bool, abort_at: u64, batch_max: usize, n_fires: [:0]const u8) noreturn {
    tdiag.closeInheritedFds(&.{});
    fires_path = n_fires;
    var fps = FilePageStore.init(alloc, path_z) catch c._exit(2);
    const db = Db.open(alloc, fps.store(), .{
        .fsync = !power_fail,
        .durability = if (power_fail) .power_fail else .process_crash,
    }) catch c._exit(3);
    crash_after_batches = abort_at;
    // kernel-only run: NO publish (compactFull is not called) — the copy
    // window under test. Progress aborts the process at batch `abort_at`.
    _ = compact.run(db, alloc, .{ .progress = progressAbortAtBatch, .batch_max_entries = batch_max }) catch {
        c._exit(9); // graceful abort must NOT happen (we crash instead)
    };
    // unreachable when the workload spans multiple batches
    c._exit(7);
}

/// Parent-side reconciliation: the child must have died by SIGABRT (a real
/// abort at the injection point, never a normal exit or arbitrary code) and
/// its fire-count record must show the callback actually ran.
fn expectSigAbort(status: c_int, fires_file: []const u8, want_batches: u64) !void {
    // WTERMSIG: low 7 bits hold the fatal signal when the child was killed
    // by one (WIFSIGNALED); 0x7f would mean stopped (WIFSTOPPED) — reject.
    const termsig: u8 = @intCast(status & 0x7f);
    const signaled = termsig != 0 and termsig != 0x7f;
    if (!signaled or termsig != c.SIGABRT) {
        std.debug.print("expected SIGABRT death, status={d} (termsig={d})\n", .{ status, termsig });
        return error.NotASignalDeath;
    }
    // reconcile fire count
    const content = std.Io.Dir.cwd().readFileAlloc(std.testing.io, fires_file, alloc, .limited(4096)) catch |e| {
        std.debug.print("fires sidecar missing — progress never fired\n", .{});
        return e;
    };
    defer alloc.free(content);
    var fired: u64 = 0;
    var batches_at_abort: u64 = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "fires=")) fired = std.fmt.parseInt(u64, line[6..], 10) catch 0;
        if (std.mem.startsWith(u8, line, "batches=")) batches_at_abort = std.fmt.parseInt(u64, line[8..], 10) catch 0;
    }
    if (fired == 0) return error.ProgressNeverFired;
    if (batches_at_abort != want_batches) return error.WrongAbortBatch;
    tdiag.print("reconcile: fires={d} batches_at_abort={d} (want {d})", .{ fired, batches_at_abort, want_batches });
}

/// SIGABRT-only death check for PUBLISH-window tag cells (the armed tag
/// aborts inside vtWriteMeta — same signal semantics, no fires sidecar).
fn expectSigAbortNoFires(status: c_int) !void {
    const signaled = (status & 0x7f) != 0;
    const termsig: u8 = @intCast(status & 0x7f);
    if (!signaled or termsig != c.SIGABRT) {
        std.debug.print("expected SIGABRT death, status={d} (termsig={d})\n", .{ status, termsig });
        return error.NotASignalDeath;
    }
}

fn expectCleanExit(status: c_int) !void {
    if (status != 0) return error.ChildDidNotExitCleanly;
}

test "compact_crash: mid_copy k=1 (sync) — multi-batch workload, SIGABRT, prefix orphans" {
    const path = ".test_compact_crash_mid1.db";
    const fires = ".test_compact_crash_mid1.fires";
    defer unlinkPath(path);
    defer unlinkPath(fires);
    const old_tree = try buildPreStateFileN(path, 0, 800);
    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);
    const fz = try pathZ(alloc, fires);
    defer alloc.free(fz);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    // 800 survivors / batch_max 64 → 12 loop batches (768) + tail 32; abort
    // after batch 1 → orphan prefix ≈ one 64-entry batch.
    if (pid == 0) childCopyCrash(pz, false, 1, 64, fz);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    try expectSigAbort(status, fires, 1);

    // §4.1: recovery root == old (root, tomb_head); new pages are orphans.
    try verifyRecoveredOldRootN(path, 800, 1000);
    // leak accounting: k=1 prefix — orphans ≈ one 64-entry batch (2 leaves +
    // branch/chain overhead), strictly smaller than the full new tree.
    {
        var fps = try tdiag.initStoreWithRetry(FilePageStore, alloc, path, 10);
        defer fps.deinit();
        const meta = (try fps.store().readMeta()).?;
        const file_pages = (try std.Io.Dir.cwd().statFile(std.testing.io, path, .{})).size / cube.format.PAGE_SIZE;
        var reach: std.ArrayList(u32) = .empty;
        defer reach.deinit(alloc);
        try btree.collectTreePages(alloc, fps.store(), meta.root_page, &reach);
        const orphans = file_pages - 3 - reach.items.len;
        // Derivation (measured composition, batch_max=64, VAL_LEN=64 → ~84B/entry):
        //   new-tree prefix (≈6-8 leaf/branch pages) + pre-state persisted
        //   freelist chain page (FREE-typed, 1) + old tomb-chain page (1) —
        //   all unreachable from the recovered root, all leak-direction safe.
        tdiag.print("mid1: file_pages={d} reach={d} orphans={d} old_tree={d}", .{ file_pages, reach.items.len, orphans, old_tree });
        try std.testing.expect(orphans >= 4 and orphans <= 14);
    }
}

test "compact_crash: mid_copy k=12 late-stage (sync) — non-empty tail (800 survivors), NOT yet pre-retire equivalent" {
    const path = ".test_compact_crash_midlast.db";
    const fires = ".test_compact_crash_midlast.fires";
    defer unlinkPath(path);
    defer unlinkPath(fires);
    const old_tree = try buildPreStateFileN(path, 0, 800);
    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);
    const fz = try pathZ(alloc, fires);
    defer alloc.free(fz);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    // k=12 = the LAST in-loop batch: all 768 loop entries written, tail 32
    // NOT yet on disk → this is a LATE mid_copy cell, NOT the before_retire
    // equivalence window (F5, review 24c3213 — equivalence needs an exact
    // budget multiple → empty tail; see the 768-survivor cell below).
    if (pid == 0) childCopyCrash(pz, false, 12, 64, fz);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    try expectSigAbort(status, fires, 12);

    // design §4.2: disk state identical to before_retire — recovery root old,
    // all new pages orphaned.
    try verifyRecoveredOldRootN(path, 800, 1000);
    {
        var fps = try tdiag.initStoreWithRetry(FilePageStore, alloc, path, 10);
        defer fps.deinit();
        const meta = (try fps.store().readMeta()).?;
        const file_pages = (try std.Io.Dir.cwd().statFile(std.testing.io, path, .{})).size / cube.format.PAGE_SIZE;
        var reach: std.ArrayList(u32) = .empty;
        defer reach.deinit(alloc);
        try btree.collectTreePages(alloc, fps.store(), meta.root_page, &reach);
        const orphans = file_pages - 3 - reach.items.len;
        // Derivation: full new tree (~25) + per-batch COW victims (11 batches
        // re-writing the growing rightmost path, ~4 pages/batch) + 2 chain
        // pages (persisted freelist + tomb) — all unreachable, leak-safe.
        // MUST strictly exceed the k=1 prefix (F1 distinction: prefix < full).
        tdiag.print("midlast: file_pages={d} reach={d} orphans={d}", .{ file_pages, reach.items.len, orphans });
        try std.testing.expect(orphans >= 40 and orphans <= 90);
        tdiag.print("midlast(sync, tail=32): orphans={d} (late stage, [40,90]), old_tree={d}", .{ orphans, old_tree });
    }
}

test "compact_crash: mid_copy k=12 exact-multiple (sync) — 768=12×64, empty tail, before_retire equivalence window" {
    const path = ".test_compact_crash_equi.db";
    const fires = ".test_compact_crash_equi.fires";
    defer unlinkPath(path);
    defer unlinkPath(fires);
    const old_tree = try buildPreStateFileN(path, 0, 768);
    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);
    const fz = try pathZ(alloc, fires);
    defer alloc.free(fz);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    // 768 survivors = exact budget multiple (12×64) → NO tail: the 12th
    // loop flush completes the ENTIRE copy. The abort lands after the last
    // data page is written and before any retire/publish step — design §4.2
    // before_retire equivalence: disk state indistinguishable from "copy
    // complete, enqueue pending" (enqueue is pure memory).
    if (pid == 0) childCopyCrash(pz, false, 12, 64, fz);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    try expectSigAbort(status, fires, 12);

    // equivalence assertions: recovery root old, FULL new tree orphaned
    try verifyRecoveredOldRootN(path, 768, 1000);
    {
        var fps = try tdiag.initStoreWithRetry(FilePageStore, alloc, path, 10);
        defer fps.deinit();
        const meta = (try fps.store().readMeta()).?;
        const file_pages = (try std.Io.Dir.cwd().statFile(std.testing.io, path, .{})).size / cube.format.PAGE_SIZE;
        var reach: std.ArrayList(u32) = .empty;
        defer reach.deinit(alloc);
        try btree.collectTreePages(alloc, fps.store(), meta.root_page, &reach);
        const orphans = file_pages - 3 - reach.items.len;
        // Derivation: complete new tree for 768 entries (~24 leaves + 1
        // branch) + 11 batches of COW victims (~4/batch) + 2 chain pages
        // (persisted freelist + tomb). All unreachable — leak-safe.
        tdiag.print("equi: file_pages={d} reach={d} orphans={d} old_tree={d}", .{ file_pages, reach.items.len, orphans, old_tree });
        try std.testing.expect(orphans >= 40 and orphans <= 90);
    }
}

test "compact_crash: mid_copy k=1 (power_fail) — same recovery contract" {
    const path = ".test_compact_crash_mid1_pf.db";
    const fires = ".test_compact_crash_mid1_pf.fires";
    defer unlinkPath(path);
    defer unlinkPath(fires);
    _ = try buildPreStateFileN(path, 0, 800);
    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);
    const fz = try pathZ(alloc, fires);
    defer alloc.free(fz);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childCopyCrash(pz, true, 1, 64, fz);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    try expectSigAbort(status, fires, 1);
    // no meta write happens in the copy window regardless of durability mode
    try verifyRecoveredOldRootN(path, 800, 1000);
}

// ===== PUBLISH-window children (real compactFull + existing CrashTags) =====

/// Child: run the real Db.compactFull, then (optionally with a reader held)
/// arm an existing tag and do the N+2 small commit — abort inside vtWriteMeta.
fn childPublishCrash(path_z: [:0]const u8, comptime tag_name: ?[]const u8, comptime hold_reader: bool) noreturn {
    tdiag.closeInheritedFds(&.{});
    var fps = FilePageStore.init(alloc, path_z) catch c._exit(2);
    var db = Db.open(alloc, fps.store(), .{ .fsync = false }) catch c._exit(3);

    // long reader pin (for the reader-case variants)
    var txn: ?cube.db.ReadTxn = if (hold_reader) db.beginReadTxn() catch c._exit(4) else null;

    _ = db.compactFull(.{}) catch c._exit(5); // publish commit (N+1)

    // N+2: one small commit with the tag armed (if any) → abort inside vtWriteMeta
    if (comptime tag_name) |tn| armCrashHook(tn);
    var upd = [_]cube.Entry{.{ .key = "zz-last", .value = "v" }};
    db.putBatch(&upd) catch c._exit(6);
    // unreachable when the tag fired
    if (txn) |*t| t.end();
    db.close();
    fps.deinit();
    c._exit(0);
}

/// Parent-side: reopen and check the §4.2 shared invariant — recovered root
/// re-opens with the post-compact visible set, key-by-key.
fn verifyPostCompactVisible(path: []const u8, with_zz: bool) !void {
    _ = c.usleep(300_000); // U5-7-T: child lock release settle (T-62 family)
    var fps = try tdiag.initStoreWithRetry(FilePageStore, alloc, path, 10);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();
    const want: u64 = if (with_zz) N_SURV + 1 else N_SURV;
    if (db.entryCount() != want) {
        tdiag.print("verify: entryCount={d} want={d} with_zz={} tomb_head={d}", .{ db.entryCount(), want, with_zz, db.state.getTombHead() });
    }
    try std.testing.expectEqual(want, db.entryCount());
    var kbuf: [10]u8 = undefined;
    for (0..N_PUT) |i| {
        const k = fmtKey(&kbuf, i);
        const v = try db.get(k);
        defer if (v) |val| alloc.free(val);
        if (i < 200) try std.testing.expect(v != null) else try std.testing.expect(v == null);
    }
    const zz = try db.get("zz-last");
    defer if (zz) |val| alloc.free(val);
    if (with_zz) {
        try std.testing.expect(zz != null);
    } else {
        try std.testing.expect(zz == null); // N+2 never landed
    }
    var sink: [256]u8 = undefined;
    var dw = std.Io.Writer.Discarding.init(&sink);
    var report = try cube_check_mod.scrub(alloc, fps.store(), &dw.writer);
    defer report.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), report.failed.len);
}

test "compact_crash: N+2 after_chain_before_meta, NO reader — recovery = N+1; old tree orphaned (⑪ reclaim was in-memory only)" {
    const path = ".test_compact_crash_n2_chain.db";
    defer unlinkPath(path);
    _ = try buildPreState(path, 3); // churn grows the pool
    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childPublishCrash(pz, "after_chain_before_meta", false);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    try expectSigAbortNoFires(status); // tag aborted inside the N+2 commit

    // Recovery root = N+1's (new_root, 0). The old tree entered the pool at
    // step ⑪ — AFTER N+1's meta landed — so the N+1-persisted chain does NOT
    // contain it: restore gives a small pool and the old tree pages are
    // orphans (leak direction). The already-written N+2 big chain is orphaned
    // too (its meta never landed). freePageCount < old_tree proves the
    // restored pool did not absorb the old tree at this window.
    {
        var fps = try tdiag.initStoreWithRetry(FilePageStore, alloc, path, 10);
        defer fps.deinit();
        const pool = fps.freePageCount();
        // F3 tightened (review 501e7aa §3): the restored pool is EMPTY — the
        // N+1-persisted chain covers only the pre-compact pool, which
        // persistChainLocked emptied into its own chain pages at N+1 (those
        // pages are the orphaned N+1 chain, not pool entries).
        try std.testing.expectEqual(@as(usize, 0), pool);
        tdiag.print("N+2 acbm(no-reader): freePageCount={d} == 0 — orphan direction", .{pool});
    }
    try verifyPostCompactVisible(path, false); // zz-last never landed
}

test "compact_crash: N+2 after_meta, READER held — N+2 landed; old tree NOT in pool (orphans)" {
    const path = ".test_compact_crash_n2_aftermeta_reader.db";
    defer unlinkPath(path);
    const info = try buildPreState(path, 3);
    _ = info; // pool==0 assertion no longer needs old_tree
    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childPublishCrash(pz, "after_meta", true);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);

    // reader pinned at compactFull close → step ⑪ reclaim skipped → the old
    // tree never entered the pool → N+2's persisted chain does NOT contain
    // it: freePageCount stays small; the old tree is orphaned (leak dir).
    {
        var fps = try tdiag.initStoreWithRetry(FilePageStore, alloc, path, 10);
        defer fps.deinit();
        const pool = fps.freePageCount();
        // F3 tightened: reader held → ⑪ skipped → old tree never pooled; the
        // N+2 persisted chain holds only the pre-existing pool (empty for this
        // fixture's drain pattern).
        try std.testing.expectEqual(@as(usize, 0), pool);
        tdiag.print("N+2 after_meta(reader): freePageCount={d} == 0 — orphan direction", .{pool});
    }
    try verifyPostCompactVisible(path, true); // N+2 landed (a held reader does not block N+2's commit)
}

test "compact_crash: N+2 after_meta, NO reader — old tree lands in the persisted big chain (pool-positive)" {
    const path = ".test_compact_crash_n2_aftermeta_noreader.db";
    defer unlinkPath(path);
    const info = try buildPreState(path, 3); // churn grows the pool
    const old_tree = info.old_tree_pages;
    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childPublishCrash(pz, "after_meta", false);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    try expectSigAbortNoFires(status);

    // No reader at compactFull close → step ⑪ reclaim ran BEFORE N+2's
    // vtWriteMeta → the old tree pages entered the pool → N+2's persisted
    // big chain contains them. Design §4.2 row① "pool" branch: this is the
    // MASS-RETIRE PAYOFF case — restoring must give a pool >= old_tree with
    // zero duplicates.
    try verifyPostCompactVisible(path, true); // N+2 landed
    {
        var fps = try tdiag.initStoreWithRetry(FilePageStore, alloc, path, 10);
        defer fps.deinit();
        const meta = (try fps.store().readMeta()).?;
        const pool = fps.freePageCount();
        // F2 (review 24c3213): the pool must absorb the old tree.
        // Design §4.2 row①: ⑪ enqueued the old tree (old_tree pages) BEFORE
        // N+2's vtWriteMeta, so the persisted big chain = old tree MINUS the
        // pages N+2's own zz-last put popped from the freshly reclaimed pool.
        // A 1-entry put nets [0, 4] pops (leaf COW ± split, branch path COW):
        // measured net pop = 1 (33 → 32). The mass-retire payoff is proven by
        // pool ≈ old_tree — vs pool == 0 in the reader-held cell (⑪ skipped).
        try std.testing.expect(pool + 4 >= old_tree);
        try std.testing.expect(pool > 0);
        // F2: the persisted big chain must restore a DEDUP pool — a duplicate
        // entry would double-allocate a live page later.
        const snap = try fps.freePagesSnapshot(alloc);
        defer alloc.free(snap);
        var seen = std.AutoHashMap(u32, void).init(alloc);
        defer seen.deinit();
        var dup: usize = 0;
        for (snap) |pn| {
            const gop = try seen.getOrPut(pn);
            if (gop.found_existing) dup += 1;
        }
        try std.testing.expectEqual(@as(usize, 0), dup);
        tdiag.print("N+2 after_meta(no-reader): freePageCount={d} >= old_tree={d} (last_page={d}) dups={d} — pool-positive", .{ pool, old_tree, meta.last_page, dup });
    }
}

test "compact_crash: N+2 before_chain, NO reader — retire enqueue is pure memory, recovery = N+1" {
    const path = ".test_compact_crash_n2_beforechain.db";
    defer unlinkPath(path);
    _ = try buildPreState(path, 3);
    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childPublishCrash(pz, "before_chain", false);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    try expectSigAbortNoFires(status);
    // retire enqueue happened in memory only; chain never persisted →
    // recovery = N+1 published state (post-compact, no zz-last)
    try verifyPostCompactVisible(path, false);
}

test "compact_crash: unarmed baseline — compactFull completes, published state visible" {
    const path = ".test_compact_crash_baseline.db";
    defer unlinkPath(path);
    _ = try buildPreState(path, 0);
    const pz = try pathZ(alloc, path);
    defer alloc.free(pz);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childPublishCrash(pz, null, false);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    // unarmed hook → no abort → child completes normally (status 0)
    try std.testing.expectEqual(@as(c_int, 0), status);
    try verifyPostCompactVisible(path, true);
}

test "compact_crash: contract — existing CrashTag surface covers the publish window" {
    try std.testing.expect(@hasDecl(FilePageStore, "CrashTag"));
    try std.testing.expect(@hasDecl(FilePageStore, "test_crash_hook"));
    // the tags exercised by this matrix (no new variants required)
    inline for (.{ "before_chain", "mid_chain", "after_chain_before_meta", "after_meta" }) |t| {
        try std.testing.expect(@hasField(FilePageStore.CrashTag, t));
    }
}

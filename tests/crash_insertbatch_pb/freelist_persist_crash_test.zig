//! freelist_persist_crash_test.zig - T-33 RED (T5): crash injection at the freelist-chain write points
//!
//! Injection uses the GREEN-provided hook (task.md, 崩溃注入 hook):
//!
//!   FilePageStore.CrashTag = .before_chain | .mid_chain | .after_chain_before_meta | .after_meta
//!   FilePageStore.test_crash_hook  (static, null in production)
//!
//! which correspond to the write-order matrix in design.md §2 (wf-red @ 4f2d9cd):
//!
//!   tag                       | durable meta after the crash | what is on disk
//!   --------------------------|------------------------------|------------------------------------
//!   before_chain              | S-1                          | nothing of commit S
//!   mid_chain                 | S-1                          | part of S's chain pages (orphans)
//!   after_chain_before_meta   | S-1                          | all of S's chain pages, meta not switched
//!   after_meta                | S                            | S fully written, sync not reached
//!
//! Matrix row 4 (power loss *during* the single sync, meta landed but chain pages did not) is NOT
//! testable with fork()+_exit: the process-crash model keeps the page cache intact, so everything
//! written before _exit is visible to the reopen. That row lives in freelist_persist_test.zig as
//! fixture T6 v10 instead — no idle test here.
//!
//! Assertions per injection point (task.md T5 规格修正, data lattice):
//!   ① every key committed *before* the armed commit is present (durable prefix)
//!   ② a commit after the armed one may only exist if the armed one does (causality: no S+1 without S)
//!   ③ the armed commit's own keys are all-present or all-absent (batch atomicity)
//!   ④ T7 partition invariant on the recovered state, and freeListDiscarded() == false — under the
//!      process-crash model a crash must never *damage* the chain, only leave an older one in charge
//!   ⑤ write one more round, reopen, re-run T7 and re-verify every durable key: this is the
//!      double-allocation recheck (a wrongly-freed live page shows up as clobbered old data)
//!
//! Plus T5-b (kill between two commits, no hook: the baseline) and T5-r (reopen idempotence: restore
//! is read-only, so crashing during it must change nothing).
//!
//! RED against main (93ec9fc): CrashTag/test_crash_hook do not exist, so the child simply completes
//! every commit; the lattice/T7 machinery still runs and must hold, and the final contract assertion
//! fails. Hook names are reached through @hasDecl/@hasField guards so this file compiles on main.
//!
//! Hookup: comptime @import in tests/crash_insertbatch_pb_test.zig.

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const Db = cube.Db;
const FilePageStore = cube.file_page_store.FilePageStore;
const part = @import("../core_format/page_partition.zig");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
});

const alloc = std.testing.allocator;

// ===== crash-hook bridge (GREEN contract) =====

fn crashHookAvailable() bool {
    if (!@hasDecl(FilePageStore, "CrashTag")) return false;
    return @hasDecl(FilePageStore, "test_crash_hook") or @hasField(FilePageStore, "test_crash_hook");
}

/// Arm the injection point. Accepts the hook as either a file-static decl or an instance field so
/// the RED tests do not over-constrain GREEN's choice; the tag name must exist verbatim.
fn armCrashHook(fps: *FilePageStore, comptime tag_name: []const u8) void {
    if (@hasDecl(FilePageStore, "CrashTag")) {
        const Tag = FilePageStore.CrashTag;
        if (@hasField(Tag, tag_name)) {
            const tag = @field(Tag, tag_name);
            if (@hasDecl(FilePageStore, "test_crash_hook")) {
                FilePageStore.test_crash_hook = tag;
            } else if (@hasField(FilePageStore, "test_crash_hook")) {
                fps.test_crash_hook = tag;
            }
        }
    }
}

fn discardedOf(fps: *const FilePageStore) bool {
    if (@hasDecl(FilePageStore, "freeListDiscarded")) return fps.freeListDiscarded();
    return false;
}

fn poolLenOf(fps: *const FilePageStore) usize {
    if (@hasDecl(FilePageStore, "freePageCount")) return fps.freePageCount();
    if (@hasField(FilePageStore, "freelist")) return fps.freelist.items.len;
    return 0;
}

// ===== workload =====
//
// Commit sequence (the armed one is C3):
//   C1  put 0..149        durable prefix
//   C2  delete 30..99     makes COW victims
//   C2b compact           load-bearing: pushes those victims into the persisted chain, so the armed
//                         commit has a real chain to retire/rewrite (see freelist_persist_test T3)
//   --- child process starts here ---
//   C3  put 150..249      the armed commit (S)
//   C4  put 250..349      the commit after it (S+1)

const val_len: usize = 24;

fn fmtKey(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "k{d:0>6}", .{i}) catch unreachable;
}

fn fmtVal(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "v{d:0>6}", .{i}) catch unreachable;
}

fn putRange(db: *Db, from: usize, to: usize) !void {
    var entries = std.ArrayList(cube.Entry).empty;
    defer {
        for (entries.items) |e| {
            alloc.free(e.key);
            alloc.free(e.value);
        }
        entries.deinit(alloc);
    }
    for (from..to) |i| {
        const k = try std.fmt.allocPrint(alloc, "k{d:0>6}", .{i});
        errdefer alloc.free(k);
        const v = try alloc.alloc(u8, val_len);
        errdefer alloc.free(v);
        @memset(v, '.');
        _ = try std.fmt.bufPrint(v, "v{d:0>6}", .{i});
        try entries.append(alloc, .{ .key = k, .value = v, .tombstone = false });
    }
    try db.putBatch(entries.items);
}

fn deleteRange(db: *Db, from: usize, to: usize) !void {
    var entries = std.ArrayList(cube.Entry).empty;
    defer {
        for (entries.items) |e| alloc.free(e.key);
        entries.deinit(alloc);
    }
    for (from..to) |i| {
        const k = try std.fmt.allocPrint(alloc, "k{d:0>6}", .{i});
        errdefer alloc.free(k);
        try entries.append(alloc, .{ .key = k, .value = "", .tombstone = true });
    }
    try db.putBatch(entries.items);
}

fn expectRangePresent(db: *Db, from: usize, to: usize) !void {
    var kbuf: [16]u8 = undefined;
    var vbuf: [16]u8 = undefined;
    for (from..to) |i| {
        const k = fmtKey(&kbuf, i);
        const got = try db.get(k) orelse {
            std.debug.print("expected key {s} present\n", .{k});
            return error.KeyMissing;
        };
        defer alloc.free(got);
        const want = fmtVal(&vbuf, i);
        if (got.len < want.len or !std.mem.eql(u8, got[0..want.len], want)) return error.ValueMismatch;
    }
}

fn expectRangeAbsent(db: *Db, from: usize, to: usize) !void {
    var kbuf: [16]u8 = undefined;
    for (from..to) |i| {
        const k = fmtKey(&kbuf, i);
        if (try db.get(k)) |v| {
            alloc.free(v);
            std.debug.print("expected key {s} absent\n", .{k});
            return error.KeyPresent;
        }
    }
}

/// Batch atomicity: the range is fully present or fully absent. Returns which.
fn allOrNone(db: *Db, from: usize, to: usize) !bool {
    var kbuf: [16]u8 = undefined;
    var present: usize = 0;
    for (from..to) |i| {
        const k = fmtKey(&kbuf, i);
        if (try db.get(k)) |v| {
            alloc.free(v);
            present += 1;
        }
    }
    if (present != 0 and present != to - from) {
        std.debug.print("torn batch: {d}/{d} keys present\n", .{ present, to - from });
        return error.TornBatch;
    }
    return present != 0;
}

// ===== fixture: the durable prefix =====

fn buildPreState(path: []const u8) !void {
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();
    try putRange(db, 0, 150); // C1
    try deleteRange(db, 30, 100); // C2
    try db.compact(); // C2b: persist the freed pages (chain non-empty before the armed commit)
}

// ===== child =====

fn childCrashAt(
    comptime tag_name: []const u8,
    comptime armed: bool,
    comptime do_c4: bool,
    path_z: [:0]const u8,
) noreturn {
    var fps = FilePageStore.init(alloc, path_z) catch c._exit(2);
    var db = Db.open(alloc, fps.store(), .{}) catch c._exit(3);
    if (armed) armCrashHook(&fps, tag_name);
    putRange(db, 150, 250) catch c._exit(4); // C3 = commit S, dies inside writeMeta when armed
    if (do_c4) putRange(db, 250, 350) catch c._exit(5); // C4 = commit S+1
    db.close();
    fps.deinit();
    c._exit(0);
}

// ===== parent-side verification =====

const Landed = struct { c3: bool, c4: bool };

/// ①②③④: durable prefix, causality, batch atomicity, partition + no discard.
fn checkAfterCrash(path: []const u8, label: []const u8) !Landed {
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try Db.open(alloc, fps.store(), .{});
    defer db.close();

    // ① everything committed before the armed commit survived
    try expectRangePresent(db, 0, 30);
    try expectRangePresent(db, 100, 150);
    try expectRangeAbsent(db, 30, 100);

    // ③ the armed commit is atomic; ② the next one may not exist without it
    const c3 = try allOrNone(db, 150, 250);
    const c4 = try allOrNone(db, 250, 350);
    if (c4 and !c3) {
        std.debug.print("{s}: causality violation — S+1 landed without S\n", .{label});
        return error.CausalityViolation;
    }

    // ④ a process crash must never damage the chain: the recovered state partitions cleanly and the
    //    freelist is either the new one or the previous generation's, never discarded
    const meta = (try fps.store().readMeta()) orelse return error.NoMeta;
    var rep = try part.classify(alloc, fps.store(), meta);
    defer rep.deinit();
    part.dump(&rep, label);
    try part.expectDisjoint(&rep);
    try std.testing.expectEqual(false, discardedOf(&fps));

    std.debug.print("{s}: c3={s} c4={s} free_count={d} pool={d}\n", .{
        label,
        if (c3) "landed" else "lost",
        if (c4) "landed" else "lost",
        meta.free_count,
        poolLenOf(&fps),
    });
    return .{ .c3 = c3, .c4 = c4 };
}

/// ⑤: one more write round, then reopen and re-verify. If the recovered freelist had handed out a
/// live page, the new round's COW would clobber data that was durable before the crash.
fn writeRoundAndRecheck(path: []const u8, landed: Landed, label: []const u8) !void {
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try putRange(db, 350, 400);
    }
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try expectRangePresent(db, 0, 30);
        try expectRangePresent(db, 100, 150);
        try expectRangeAbsent(db, 30, 100);
        if (landed.c3) try expectRangePresent(db, 150, 250) else try expectRangeAbsent(db, 150, 250);
        if (landed.c4) try expectRangePresent(db, 250, 350) else try expectRangeAbsent(db, 250, 350);
        try expectRangePresent(db, 350, 400);
        const meta = (try fps.store().readMeta()) orelse return error.NoMeta;
        var rep = try part.classify(alloc, fps.store(), meta);
        defer rep.deinit();
        try part.expectDisjoint(&rep); // no page in two classes => no double allocation
        std.debug.print("{s}: post-write recheck OK (last_page={d})\n", .{ label, meta.last_page });
    }
}

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

/// One injection point: build the durable prefix, fork the armed child, verify the lattice.
fn runCrashCase(comptime tag_name: []const u8, comptime armed: bool, comptime do_c4: bool, path: []const u8) !void {
    defer unlinkPath(path);
    try buildPreState(path);

    const pz = try alloc.dupeZ(u8, path);
    defer alloc.free(pz);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childCrashAt(tag_name, armed, do_c4, pz);

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    if (armed and crashHookAvailable()) {
        // the hook must take the process down deliberately: a non-zero exit (_exit) or SIGABRT
        // (@panic/abort). SIGSEGV/SIGBUS here would mean the injection point is a real crash, not a
        // simulated one.
        const sig: c_int = status & 0x7f;
        try std.testing.expect(status != 0);
        try std.testing.expect(sig == 0 or sig == c.SIGABRT);
    }

    const label = if (armed) tag_name else "between-commits";
    const landed = try checkAfterCrash(path, label);
    try writeRoundAndRecheck(path, landed, label);

    // contract last: on main the lattice above still runs (and must hold), then this fails
    if (armed) try std.testing.expect(crashHookAvailable());
}

test "T5 before_chain: crash before any chain page is written" {
    try runCrashCase("before_chain", true, true, ".test_fl_crash_before_chain.db");
}

test "T5 mid_chain: crash halfway through writing the chain pages" {
    try runCrashCase("mid_chain", true, true, ".test_fl_crash_mid_chain.db");
}

test "T5 after_chain_before_meta: crash with the new chain written but meta not switched" {
    // The sharpest case for two-generation retirement: the previous meta is still in charge and its
    // chain pages must not have been recycled by this commit, or recovery would read a chain that
    // lists live pages.
    try runCrashCase("after_chain_before_meta", true, true, ".test_fl_crash_after_chain.db");
}

test "T5 after_meta: crash after the meta switch, before sync" {
    try runCrashCase("after_meta", true, true, ".test_fl_crash_after_meta.db");
}

test "T5-b: kill between two commits (no hook) — baseline" {
    // C3 completes and is durable, C4 never starts. Same lattice, no injection: this is the control
    // case that keeps the harness honest (if the lattice only passed with a hook, it proved nothing).
    try runCrashCase("after_meta", false, false, ".test_fl_crash_between.db");
}

test "T5-r: reopen is idempotent — restoreFreeList is read-only" {
    const path = ".test_fl_crash_reopen_idem.db";
    defer unlinkPath(path);
    try buildPreState(path);

    // state as it is before the child touches anything
    var before: f2.MetaPage = undefined;
    var before_pool: usize = undefined;
    var before_discarded: bool = undefined;
    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        before = (try fps.store().readMeta()) orelse return error.NoMeta;
        before_pool = poolLenOf(&fps);
        before_discarded = discardedOf(&fps);
    }

    // child: open (runs restore) and die right there — restore must not have written anything.
    // CrashTag has no restore-phase tag, so this is the observable equivalent: a crash during a
    // read-only phase leaves the file byte-identical.
    {
        const pz = try alloc.dupeZ(u8, path);
        defer alloc.free(pz);
        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            var fps = FilePageStore.init(alloc, pz) catch c._exit(2);
            var db = Db.open(alloc, fps.store(), .{}) catch c._exit(3);
            var kbuf: [16]u8 = undefined;
            if (db.get(fmtKey(&kbuf, 5)) catch null) |v| alloc.free(v);
            c._exit(0); // no close, no commit: die with the store open
        }
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
        try std.testing.expectEqual(@as(c_int, 0), status);
    }

    // reopen twice more: identical observable state every time, data intact, partition clean
    for (0..2) |round| {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        const meta = (try fps.store().readMeta()) orelse return error.NoMeta;
        try std.testing.expectEqual(before.sequence, meta.sequence);
        try std.testing.expectEqual(before.root_page, meta.root_page);
        try std.testing.expectEqual(before.free_head, meta.free_head);
        try std.testing.expectEqual(before.free_count, meta.free_count);
        try std.testing.expectEqual(before.last_page, meta.last_page);
        try std.testing.expectEqual(before_discarded, discardedOf(&fps));
        try std.testing.expectEqual(before_pool, poolLenOf(&fps));

        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try expectRangePresent(db, 0, 30);
        try expectRangePresent(db, 100, 150);
        try expectRangeAbsent(db, 30, 100);

        var rep = try part.classify(alloc, fps.store(), meta);
        defer rep.deinit();
        try part.expectDisjoint(&rep);
        _ = round;
    }
}

test "T5 contract: FilePageStore exposes CrashTag and test_crash_hook" {
    // Fixed names from task.md. On main neither exists, so no injection point can be armed.
    try std.testing.expect(@hasDecl(FilePageStore, "CrashTag"));
    if (@hasDecl(FilePageStore, "CrashTag")) {
        const Tag = FilePageStore.CrashTag;
        try std.testing.expect(@hasField(Tag, "before_chain"));
        try std.testing.expect(@hasField(Tag, "mid_chain"));
        try std.testing.expect(@hasField(Tag, "after_chain_before_meta"));
        try std.testing.expect(@hasField(Tag, "after_meta"));
    }
    try std.testing.expect(crashHookAvailable());
}

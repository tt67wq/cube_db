//! cube_check.zig — offline integrity tool (T-35 Part B; U5-4 adds vacuum).
//!
//! Usage:
//!   cube_check scrub <db-path>
//!   cube_check vacuum <src-db-path> <dst-db-path>
//!
//! Exit codes (also printed by --help):
//!   0 (EXIT_OK)      all pages passed CRC verification / vacuum succeeded
//!   1 (EXIT_USAGE)   usage error: bad arguments, cannot open the DB file,
//!                    no valid meta page, dst exists, or src is flocked
//!   2 (EXIT_CORRUPT) corruption found: at least one data page failed CRC
//!
//! The scrub/vacuum decision logic lives in the library functions `scrub` and
//! `vacuumCopy` (unit-tested in tests/cube_check_test.zig and
//! tests/cube_check_vacuum_test.zig); `main` only does argv parsing and
//! exit-code mapping. The DB must not be held open by a writer process —
//! FilePageStore takes an exclusive flock on open (vacuum reports the held
//! lock as EXIT_USAGE, never crashes).

const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;

pub const EXIT_OK: u8 = 0;
pub const EXIT_USAGE: u8 = 1;
pub const EXIT_CORRUPT: u8 = 2;

/// One page that failed whole-page CRC verification.
pub const FailedPage = struct {
    page_no: u32,
    /// From format.decodePageHeader — best-effort diagnostic on a corrupt page.
    page_type: u8,
};

pub const ScrubReport = struct {
    total: u64,
    passed: u64,
    failed: []FailedPage,

    pub fn deinit(self: *ScrubReport, alloc: std.mem.Allocator) void {
        alloc.free(self.failed);
    }
};

fn pageTypeName(t: u8) ?[]const u8 {
    return switch (t) {
        cube.format.PAGE_TYPE_FREE => "FREE",
        cube.format.PAGE_TYPE_META => "META",
        cube.format.PAGE_TYPE_BRANCH => "BRANCH",
        cube.format.PAGE_TYPE_LEAF => "LEAF",
        cube.format.PAGE_TYPE_OVERFLOW => "OVERFLOW",
        else => null,
    };
}

/// Verify the whole-page CRC of every data page in
/// [FIRST_DATA_PAGE ..= meta.last_page] (inclusive: last_page is the highest
/// allocated page). Reads each page via the store and runs
/// format.verifyPageChecksum on it. Prints one line per failed page plus a
/// summary (total/passed/failed and the failed page-number list) to `writer`.
///
/// Errors: error.NoMeta when the store has no valid meta page; store read
/// errors propagate unchanged. Caller owns `report.failed` (free via
/// ScrubReport.deinit).
pub fn scrub(
    alloc: std.mem.Allocator,
    store: cube.page_store.PageStore,
    writer: *std.Io.Writer,
) !ScrubReport {
    const meta = (try store.readMeta()) orelse return error.NoMeta;

    var failed: std.ArrayList(FailedPage) = .empty;
    errdefer failed.deinit(alloc);
    var total: u64 = 0;
    var passed: u64 = 0;

    var page_no: u64 = cube.page_store.FIRST_DATA_PAGE;
    while (page_no <= meta.last_page) : (page_no += 1) {
        const no: u32 = @intCast(page_no);
        const page = try store.readPage(no);
        total += 1;
        const arr: *const [cube.format.PAGE_SIZE]u8 = page[0..cube.format.PAGE_SIZE];
        if (cube.format.verifyPageChecksum(arr)) {
            passed += 1;
            continue;
        }
        const hdr = cube.format.decodePageHeader(page[0..cube.format.PAGE_HEADER_SIZE]);
        try failed.append(alloc, .{ .page_no = no, .page_type = hdr.page_type });
        if (pageTypeName(hdr.page_type)) |name| {
            try writer.print("page {d}: CRC FAILED (type {s})\n", .{ no, name });
        } else {
            try writer.print("page {d}: CRC FAILED (type {d}, unknown)\n", .{ no, hdr.page_type });
        }
    }

    try writer.print("scrub: total={d} passed={d} failed={d}\n", .{ total, passed, failed.items.len });
    if (failed.items.len > 0) {
        try writer.writeAll("failed pages:");
        for (failed.items) |f| try writer.print(" {d}", .{f.page_no});
        try writer.writeAll("\n");
    }

    return .{
        .total = total,
        .passed = passed,
        .failed = try failed.toOwnedSlice(alloc),
    };
}

// ===== U5-4: vacuum (offline space reclamation) =====

/// True if `path` exists (any file type). Used by the vacuum CLI to reject an
/// existing dst BEFORE any work starts (no silent overwrite, no half-written
/// replacement of a valid db).
pub fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Outcome of one vacuumCopy run (counters only; the caller prints them).
pub const VacuumReport = struct {
    /// Live entries streamed out of src and put into dst (what src's
    /// entryCount reported; shadowed/tombstoned entries are never seen).
    entries_copied: u64,
    /// Pages the dst store allocated (leaf/branch/overflow/meta data pages,
    /// i.e. the dst file's high-water mark in pages).
    pages_written: u32,

    pub fn deinit(self: *const VacuumReport, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc; // counters only — nothing owned (future-proof shape)
    }
};

/// Stream every live entry from the db at `src_path` into a fresh db at
/// `dst_path`. U-5 step 1 (offline): the old file is never modified — the
/// documented swap is `mv dst src` AFTER the tool exits OK (see task U5-4).
///
/// Guarantees:
///   - dst must not exist (error.DstExists) — no silent overwrite;
///   - src must not be flocked by a writer (error.FileLocked from the store;
///     the CLI maps it to EXIT_USAGE) — vacuum never opens a live db;
///   - entries are read with a FULL-CRC ReadTxn select (crc_check = .full):
///     a corrupt page anywhere in the scan aborts with the store's error
///     (e.g. error.CorruptCrc) before dst can be mistaken for a good copy;
///   - src is opened read-only BY INTENT: no put/delete/commit is ever issued
///     on it, and no page is written through its store;
///   - tombstones and range-tombstone shadowing need no special handling:
///     select only yields visible (live) entries, which is exactly the live
///     set vacuum must carry over; entry_count of the dst equals src's.
///
/// Failure semantics: on any error the dst store is deinit'd and its file is
/// deleted — vacuum never leaves a half-valid dst behind.
pub fn vacuumCopy(
    alloc: std.mem.Allocator,
    io: std.Io,
    src_path: []const u8,
    dst_path: []const u8,
    writer: *std.Io.Writer,
) !VacuumReport {
    // Reject a missing src BEFORE touching dst: FilePageStore.init is O_CREAT,
    // so without this gate a typo'd src silently vacuums an empty db into dst.
    if (!fileExists(io, src_path)) return error.OpenFailed;
    if (fileExists(io, dst_path)) return error.DstExists;

    var src_fps = try cube.file_page_store.FilePageStore.init(alloc, src_path);
    defer src_fps.deinit();

    var dst_fps = try cube.file_page_store.FilePageStore.init(alloc, dst_path);
    defer dst_fps.deinit();
    // U5-4-C (T-67): marker path known only after success-critical work, but
    // the cleanup must cover the whole failure surface — precompute it here.
    const marker_path = try std.fmt.allocPrint(alloc, "{s}.done", .{dst_path});
    defer alloc.free(marker_path);
    errdefer {
        // No half-valid dst: remove the file AND any completion marker —
        // a failed vacuum must not leave trust artifacts behind.
        std.Io.Dir.cwd().deleteFile(io, dst_path) catch {};
        std.Io.Dir.cwd().deleteFile(io, marker_path) catch {};
    }

    var src_db = try Db.open(alloc, src_fps.store(), .{ .crc_check = .full });
    defer src_db.close();
    // U5-4-C (E-1 note): a 0-commit src has zeroed meta slots — "vacuuming"
    // it would produce a meta-less dst that scrub can only reject (NoMeta).
    // Refuse up front (EXIT_USAGE via the CLI) instead of fake-success.
    if ((try src_fps.store().readMeta()) == null) return error.NoMeta;
    var dst_db = try Db.open(alloc, dst_fps.store(), .{ .fsync = false });
    defer dst_db.close();

    // Stream the full visible key space. ReadTxn pins the snapshot; entries
    // are borrowed until next(), so each key/value is duped into the batch
    // buffer before it advances.
    var txn = try src_db.beginReadTxn();
    defer txn.end();
    var it = try txn.select(null, null);
    defer it.deinit();

    var entries_copied: u64 = 0;
    const BATCH = 512;
    var last_page: u32 = 0;
    // Staging byte budgets: capacity is a FLOOR sized for the common shape,
    // never a ceiling — the loader below flushes before exceeding capacity and
    // grows (n==0 only, so already-staged slices cannot dangle) for entries
    // larger than the budget itself (F1: legal keys reach MAX_KEY_SIZE=4051B
    // and overflow values are unbounded; hardcoding averages panics on legal
    // input — same lesson as T-40's count-only chunking).
    var batch_keys = try std.ArrayList(u8).initCapacity(alloc, BATCH * 48);
    defer batch_keys.deinit(alloc);
    var batch_vals = try std.ArrayList(u8).initCapacity(alloc, BATCH * 80);
    defer batch_vals.deinit(alloc);
    var batch = try alloc.alloc(cube.Entry, BATCH);
    defer alloc.free(batch);
    var n: usize = 0;

    while (try it.next()) |e| {
        // Byte-budget gate: flush BEFORE appending if either buffer would
        // exceed capacity (appendSliceAssumeCapacity asserts new_len <=
        // capacity — exceeding it is a panic/OOB, never a realloc).
        if (n == BATCH or
            batch_keys.items.len + e.key.len > batch_keys.capacity or
            batch_vals.items.len + e.value.len > batch_vals.capacity)
        {
            try dst_db.putBatch(batch[0..n]);
            entries_copied += n;
            n = 0;
            batch_keys.clearRetainingCapacity();
            batch_vals.clearRetainingCapacity();
            // ftruncate ceiling so a churned src never bloats dst: dst file
            // covers only what THIS vacuum actually wrote.
            const m = (try dst_fps.store().readMeta()).?;
            if (m.last_page > last_page) {
                try dst_fps.compactFileTo(m.last_page);
                last_page = m.last_page;
            }
        }
        // Oversized single entry (larger than the whole buffer): with n==0
        // there are no staged slices referencing buffer memory, so growing is
        // safe (a realloc here would dangle batch[0..n]'s key/value slices).
        if (batch_keys.capacity < e.key.len) try batch_keys.ensureTotalCapacity(alloc, e.key.len);
        if (batch_vals.capacity < e.value.len) try batch_vals.ensureTotalCapacity(alloc, e.value.len);
        batch_keys.appendSliceAssumeCapacity(e.key);
        batch_vals.appendSliceAssumeCapacity(e.value);
        const base_k = batch_keys.items.len - e.key.len;
        const base_v = batch_vals.items.len - e.value.len;
        batch[n] = .{ .key = batch_keys.items[base_k..], .value = batch_vals.items[base_v..] };
        n += 1;
    }
    if (n > 0) {
        try dst_db.putBatch(batch[0..n]);
        entries_copied += n;
        const m = (try dst_fps.store().readMeta()).?;
        if (m.last_page > last_page) {
            try dst_fps.compactFileTo(m.last_page);
            last_page = m.last_page;
        }
    }

    const dst_count = dst_db.entryCount();
    if (dst_count != entries_copied or dst_count != src_db.entryCount()) {
        // Counter invariant broken — refuse to bless the copy.
        return error.VacuumCountMismatch;
    }

    try dst_db.sync();

    // U5-4-C (T-67): completion marker — the ONLY thing distinguishing a
    // finished vacuum from a kill -9 prefix snapshot (batch commits leave a
    // scrub-clean, openable PARTIAL dst). Written AFTER the final dst sync;
    // any failure here propagates (marker write failure must never surface
    // as success) and the errdefer above removes it.
    {
        const content = try std.fmt.allocPrint(alloc, "vacuum-complete entries={d}\n", .{entries_copied});
        defer alloc.free(content);
        var mf = try std.Io.Dir.cwd().createFile(io, marker_path, .{});
        errdefer mf.close(io);
        try mf.writeStreamingAll(io, content);
        try mf.sync(io);
        mf.close(io);
    }

    try writer.print("vacuum: copied {d} live entries (dst last_page={d}); completion marker: {s}\n", .{ entries_copied, last_page, marker_path });
    return .{
        .entries_copied = entries_copied,
        .pages_written = last_page,
    };
}

const usage_text =
    \\Usage: cube_check scrub <db-path>
    \\       cube_check vacuum <src-db-path> <dst-db-path>
    \\
    \\scrub: offline integrity check — verifies the whole-page CRC of every data
    \\page in [FIRST_DATA_PAGE ..= meta.last_page].
    \\
    \\vacuum: offline space reclamation — rewrites all LIVE entries from src into
    \\a fresh dst (dead/shadowed pages are not copied); src is opened read-only
    \\by intent and left byte-identical. The dst path must not exist. src must
    \\not be flocked by a writer.
    \\
    \\Exit codes:
    \\  0  all pages passed / vacuum succeeded
    \\  1  usage error (bad args, open failure, no valid meta page, dst exists,
    \\     src locked by a writer)
    \\  2  corruption found (at least one page failed CRC)
    \\
;

fn usageError() u8 {
    std.debug.print("{s}", .{usage_text});
    return EXIT_USAGE;
}

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;

    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_it.next(); // argv[0]
    const sub = args_it.next() orelse return usageError();
    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        var out_buf: [2048]u8 = undefined;
        var w: std.Io.File.Writer = .init(.stdout(), init.io, &out_buf);
        try w.interface.writeAll(usage_text);
        try w.interface.flush();
        return EXIT_OK;
    }

    var out_buf: [4096]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stdout(), init.io, &out_buf);

    if (std.mem.eql(u8, sub, "scrub")) {
        const path = args_it.next() orelse return usageError();
        if (args_it.next() != null) return usageError();
        var fps = cube.file_page_store.FilePageStore.init(alloc, path) catch |err| {
            std.debug.print("cube_check: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
            return EXIT_USAGE;
        };
        defer fps.deinit();
        var report = scrub(alloc, fps.store(), &w.interface) catch |err| {
            try w.interface.flush();
            std.debug.print("cube_check: scrub failed: {s}\n", .{@errorName(err)});
            return EXIT_USAGE;
        };
        defer report.deinit(alloc);
        try w.interface.flush();
        return if (report.failed.len == 0) EXIT_OK else EXIT_CORRUPT;
    }

    if (std.mem.eql(u8, sub, "vacuum")) {
        const src = args_it.next() orelse return usageError();
        const dst = args_it.next() orelse return usageError();
        if (args_it.next() != null) return usageError();
        var report = vacuumCopy(alloc, init.io, src, dst, &w.interface) catch |err| switch (err) {
            error.FileLocked => {
                std.debug.print("cube_check: vacuum: src '{s}' is locked by a writer\n", .{src});
                return EXIT_USAGE;
            },
            error.DstExists => {
                std.debug.print("cube_check: vacuum: dst '{s}' already exists (refusing to overwrite)\n", .{dst});
                return EXIT_USAGE;
            },
            error.CorruptCrc => {
                // F5 (U5-4-P): a corrupt src is CORRUPTION (the 0/1/2 convention's
                // whole reason for the third code — scrub maps CRC failures here
                // too), not a usage error. Same class as `scrub`'s failed>0 exit.
                std.debug.print("cube_check: vacuum: src '{s}' has corrupt pages (run scrub for details)\n", .{src});
                return EXIT_CORRUPT;
            },
            error.NoMeta => {
                // U5-4-C (E-1 note): a 0-commit src has no meta — the result
                // could never pass scrub, so refuse as a usage error.
                std.debug.print("cube_check: vacuum: src '{s}' has no committed meta (empty db)\n", .{src});
                return EXIT_USAGE;
            },
            else => {
                std.debug.print("cube_check: vacuum failed: {s}\n", .{@errorName(err)});
                return EXIT_USAGE;
            },
        };
        defer report.deinit(alloc);
        // U5-4-C (T-67): success output MUST declare the completion marker —
        // dst is only a finished vacuum when <dst>.done exists (kill -9
        // leaves scrub-clean prefix snapshots without it).
        try w.interface.print("vacuum: OK entries={d} pages_written={d} completion_marker={s}.done\n", .{ report.entries_copied, report.pages_written, dst });
        try w.interface.flush();
        return EXIT_OK;
    }

    return usageError();
}

//! tests/cube_check_vacuum_test.zig — U5-4: cube_check vacuum (offline space
//! reclamation) library-function tests, mirroring the cube_check_test.zig
//! pattern (the CLI is a thin argv shell; the decision logic lives in
//! src/cube_check.zig and is tested directly).
//!
//! vacuum contract under test:
//!   - streams live entries out of src (shadowed entries are invisible to
//!     select, so only live data is rewritten) into a FRESH dst store;
//!   - dst byte-size semantics match src per-key (entryCount + get equal);
//!   - dst file page high-water mark is far below a churned src (dead pages
//!     gone);
//!   - src is treated read-only: vacuumCopy aborts when the src path is
//!     already flocked by a writer (error.FileLocked), and does not modify
//!     src content (byte-identical pre/post, scrubbed OK);
//!   - existing dst is refused (error.DstExists) — no silent overwrite;
//!   - failure mid-vacuum surfaces as an error (no half-valid dst content);
//!   - scrub passes on the vacuumed dst (whole-file CRC integrity).

const std = @import("std");
const cube = @import("cube_db");
const cube_check = @import("cube_check");
const Db = cube.Db;
const FilePageStore = cube.file_page_store.FilePageStore;
const ps = cube.page_store;

const c = @cImport({
    @cInclude("unistd.h");
});

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

/// Highest page number backing the db file (file size in pages - 1).
/// FilePageStore grows the file via ftruncate on write; after close the
/// mmap region does NOT shrink, so stat() sees the final high-water mark.
fn lastPageOf(path: []const u8) !u64 {
    const st = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
    const pages = st.size / cube.format.PAGE_SIZE;
    if (pages < ps.FIRST_DATA_PAGE) return 0;
    return pages - 1;
}

/// Fill a db with `n` 64B-value entries ("key%06d"), one putBatch commit.
fn writeSampleDb(allocator: std.mem.Allocator, path: []const u8, n: usize) !void {
    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    var db = try Db.open(allocator, fps.store(), .{});
    defer db.close();

    var value: [64]u8 = undefined;
    @memset(&value, 'v');
    const entries = try allocator.alloc(cube.Entry, n);
    defer allocator.free(entries);
    for (entries, 0..) |*e, i| e.* = .{
        .key = try std.fmt.allocPrint(allocator, "key{d:0>6}", .{i}),
        .value = &value,
    };
    defer for (entries) |e| allocator.free(e.key);
    try db.putBatch(entries);
}

/// Duplicate every key 20x (same key+value re-put), then range-delete half
/// the keyspace. Churn leaves: per-key overwrite versions in leaf pages,
/// overflow/branch garbage, and a wide free pool — all dead weight vacuum
/// must shed. Returns nothing; the caller reopens and measures.
///
/// F3 (U5-4-P): values are DETERMINISTIC PER-KEY (mixed shapes incl. one
/// >1-page overflow value), not a fixed fill — the main contract test then
/// verifies dst vs src per-key against a recomputed oracle instead of the
/// old constant-64B-pattern equality (which couldn't catch a value swap).
/// Value oracle (shared with the main contract test below): for key i,
///   len = 2*4096+7 (overflow, 2 pages) when i == 42, else 17 + 13*(i % 5);
///   byte j = (i * 31 + j) % 251.
fn churnDb(allocator: std.mem.Allocator, path: []const u8, n: usize) !void {
    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    var db = try Db.open(allocator, fps.store(), .{});
    defer db.close();

    for (0..20) |_| {
        const entries = try allocator.alloc(cube.Entry, n);
        defer allocator.free(entries);
        // Values must live until putBatch returns — allocated per round into
        // `round_values` (freed after the commit), NOT per-iteration defer
        // (which would free each buffer while `entries` still borrows it).
        var round_values: std.ArrayList([]u8) = .empty;
        defer {
            for (round_values.items) |v| allocator.free(v);
            round_values.deinit(allocator);
        }
        for (entries, 0..) |*e, i| {
            const vlen: usize = if (i == 42) 2 * 4096 + 7 else 17 + 13 * (i % 5);
            const v = try allocator.alloc(u8, vlen);
            for (v, 0..) |*b, j| b.* = @truncate((i * 31 + j) % 251);
            try round_values.append(allocator, v);
            e.* = .{
                .key = try std.fmt.allocPrint(allocator, "key{d:0>6}", .{i}),
                .value = v,
            };
        }
        defer for (entries) |e| allocator.free(e.key);
        try db.putBatch(entries);
    }
    // delete [key000200, inf): range tombstones shadow half the live set
    // (physical entries stay — that dead weight is exactly what vacuum removes).
    try db.deleteRange("key000200", null);
}

test "cube_check vacuum: fileExists and lastPageOf helpers" {
    const allocator = std.heap.page_allocator;
    const path = ".vacuum_helper_probe.db";
    defer unlinkPath(path);
    try std.testing.expect(!cube_check.fileExists(std.testing.io, path));
    try writeSampleDb(allocator, path, 50);
    try std.testing.expect(cube_check.fileExists(std.testing.io, path));
    const lp = try lastPageOf(path);
    try std.testing.expect(lp >= 3); // at least one leaf beyond meta pages
}

test "cube_check vacuum: live data survives byte-identical, dst shrinks, scrub OK" {
    const allocator = std.heap.page_allocator;
    const src = ".vacuum_src.db";
    const dst = ".vacuum_dst.db";
    defer unlinkPath(src);
    defer unlinkDstAndMarker(dst);
    try churnDb(allocator, src, 800);

    // pre: src is big (churn), entries shadowed by the range tombstone
    const src_last = try lastPageOf(src);
    try std.testing.expect(src_last >= 40); // churn wrote many pages (observed ~54)
    {
        var src_fps = try FilePageStore.init(allocator, src);
        defer src_fps.deinit();
        var src_db = try Db.open(allocator, src_fps.store(), .{});
        defer src_db.close();
        try std.testing.expect(src_db.entryCount() == 200);
    }

    var out: [256]u8 = undefined;
    var fw = std.Io.Writer.fixed(&out);
    const report = try cube_check.vacuumCopy(std.testing.allocator, std.testing.io, src, dst, &fw);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 200), report.entries_copied);

    // dst opens, entryCount matches, every visible key byte-identical
    // (sequentially: flock is exclusive per path, src closed before dst opens)
    var src_count: u64 = 0;
    {
        var src_fps = try FilePageStore.init(allocator, src);
        defer src_fps.deinit();
        var src_db = try Db.open(allocator, src_fps.store(), .{});
        defer src_db.close();
        src_count = src_db.entryCount();
    }
    var dst_fps = try FilePageStore.init(allocator, dst);
    defer dst_fps.deinit();
    var dst_db = try Db.open(allocator, dst_fps.store(), .{});
    defer dst_db.close();
    try std.testing.expectEqual(src_count, dst_db.entryCount());

    var it = try dst_db.select(null, null);
    defer it.deinit();
    var checked: usize = 0;
    // F3 (U5-4-P): per-key TRUE-VALUE comparison against the churnDb oracle
    // (same formula: len = 2*4096+7 if i==42 else 17+13*(i%5); byte j =
    // (i*31+j) % 251). Replaces the old constant-pattern check, which could
    // not distinguish a swapped/misattributed value from the real one.
    // The i==42 entry exercises a >1-page overflow value round-trip.
    while (try it.next()) |e| {
        const i = try std.fmt.parseInt(usize, e.key[3..], 10);
        const vlen: usize = if (i == 42) 2 * 4096 + 7 else 17 + 13 * (i % 5);
        try std.testing.expectEqual(vlen, e.value.len);
        for (e.value, 0..) |b, j| {
            try std.testing.expectEqual(@as(u8, @truncate((i * 31 + j) % 251)), b);
        }
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 200), checked);

    // dst page high-water is far below churned src (dead pages shed)
    const dst_last = try lastPageOf(dst);
    try std.testing.expect(dst_last < src_last / 2);

    // whole-file CRC integrity on dst
    var sink: [64]u8 = undefined;
    var dw = std.Io.Writer.Discarding.init(&sink);
    var scrub_report = try cube_check.scrub(std.testing.allocator, dst_fps.store(), &dw.writer);
    defer scrub_report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), scrub_report.failed.len);
}

test "cube_check vacuum: empty-key entry and tombstone-only ranges round-trip" {
    const allocator = std.heap.page_allocator;
    const src = ".vacuum_edge_src.db";
    const dst = ".vacuum_edge_dst.db";
    defer unlinkPath(src);
    defer unlinkDstAndMarker(dst);
    {
        var fps = try FilePageStore.init(allocator, src);
        defer fps.deinit();
        var db = try Db.open(allocator, fps.store(), .{});
        defer db.close();
        try db.put("", "empty-key-value"); // smallest key
        try db.put("aaa", "1");
        try db.put("zzz", "2");
        try db.delete("aaa"); // tree tombstone on a live key
    }

    var out: [256]u8 = undefined;
    var fw = std.Io.Writer.fixed(&out);
    const report = try cube_check.vacuumCopy(std.testing.allocator, std.testing.io, src, dst, &fw);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), report.entries_copied);

    var dst_fps = try FilePageStore.init(allocator, dst);
    defer dst_fps.deinit();
    var dst_db = try Db.open(allocator, dst_fps.store(), .{});
    defer dst_db.close();
    try std.testing.expectEqualStrings("empty-key-value", (try dst_db.get("")).?);
    try std.testing.expectEqual(@as(u64, 2), dst_db.entryCount());
    try std.testing.expect((try dst_db.get("aaa")) == null); // deletion preserved
    try std.testing.expectEqualStrings("2", (try dst_db.get("zzz")).?);
}

test "cube_check vacuum: existing dst refused, no overwrite" {
    const allocator = std.heap.page_allocator;
    const src = ".vacuum_refuse_src.db";
    const dst = ".vacuum_refuse_dst.db";
    defer unlinkPath(src);
    defer unlinkDstAndMarker(dst);
    try writeSampleDb(allocator, src, 100);
    // pre-existing dst must survive untouched
    {
        var fps = try FilePageStore.init(allocator, dst);
        defer fps.deinit();
        var db = try Db.open(allocator, fps.store(), .{});
        defer db.close();
        try db.put("sentinel", "do-not-touch");
    }

    var sink: [64]u8 = undefined;
    var dw = std.Io.Writer.Discarding.init(&sink);
    const result = cube_check.vacuumCopy(std.testing.allocator, std.testing.io, src, dst, &dw.writer);
    try std.testing.expectError(error.DstExists, result);

    var fps = try FilePageStore.init(allocator, dst);
    defer fps.deinit();
    var db = try Db.open(allocator, fps.store(), .{});
    defer db.close();
    try std.testing.expectEqualStrings("do-not-touch", (try db.get("sentinel")).?);
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
}

test "cube_check vacuum: flocked src (active writer) -> error.FileLocked, EXIT_USAGE direction" {
    const allocator = std.heap.page_allocator;
    const src = ".vacuum_locked_src.db";
    defer unlinkPath(src);
    try writeSampleDb(allocator, src, 50);
    // Hold the flock the way a real writer would (exclusive, held by fps).
    var holder = try FilePageStore.init(allocator, src);
    defer holder.deinit();
    var sink: [64]u8 = undefined;
    var dw = std.Io.Writer.Discarding.init(&sink);
    const result = cube_check.vacuumCopy(std.testing.allocator, std.testing.io, src, ".vacuum_locked_dst.db", &dw.writer);
    try std.testing.expectError(error.FileLocked, result);
    defer unlinkPath(".vacuum_locked_dst.db");
    // No dst file may have been created by the failed attempt.
    try std.testing.expect(!cube_check.fileExists(std.testing.io, ".vacuum_locked_dst.db"));
}

test "cube_check vacuum: missing src fails, no dst residue" {
    var sink: [64]u8 = undefined;
    var dw = std.Io.Writer.Discarding.init(&sink);
    // FilePageStore.init creates-missing-files (O_CREAT), so the precise
    // error for a missing src is store-internal; the CONTRACT is: no dst is
    // produced and nothing can be mistaken for a good copy. Assert dst's
    // absence both before (path never existed) and after the failed call.
    const result = cube_check.vacuumCopy(std.testing.allocator, std.testing.io, ".vacuum_nonexistent.db", ".vacuum_ne_dst.db", &dw.writer);
    try std.testing.expectError(error.OpenFailed, result);
    defer unlinkPath(".vacuum_ne_dst.db");
    defer unlinkPath(".vacuum_nonexistent.db");
    try std.testing.expect(!cube_check.fileExists(std.testing.io, ".vacuum_ne_dst.db"));
}

test "cube_check vacuum: mid-vacuum corrupt page surfaces as error, no valid dst" {
    const allocator = std.heap.page_allocator;
    const src = ".vacuum_bad_src.db";
    const dst = ".vacuum_bad_dst.db";
    defer unlinkPath(src);
    defer unlinkDstAndMarker(dst);
    try writeSampleDb(allocator, src, 3000); // multi-page leaf chain
    // Corrupt a high-numbered data page (readable via mmap, CRC invalid —
    // hot-path reads skip CRC by default, so the tree still opens fine; the
    // full-CRC select used by vacuum must trip on it).
    // mmap pages are PROT_READ|PROT_WRITE; corruption via the PageStore
    // slice (no CRC recompute — same injection as cube_check_test.corruptOneByte).
    {
        var fps = try FilePageStore.init(allocator, src);
        defer fps.deinit();
        const meta = (try fps.store().readMeta()).?;
        try std.testing.expect(meta.last_page > 10);
        const page = try fps.store().readPage(@intCast(meta.last_page));
        const raw: [*]u8 = @constCast(page.ptr);
        raw[64] ^= 0xFF;
    }

    var sink: [64]u8 = undefined;
    var dw = std.Io.Writer.Discarding.init(&sink);
    const result = cube_check.vacuumCopy(std.testing.allocator, std.testing.io, src, dst, &dw.writer);
    try std.testing.expectError(error.CorruptCrc, result);
    // dst must not exist as a valid (openable) db
    try std.testing.expect(!cube_check.fileExists(std.testing.io, dst));
}

test "cube_check vacuum: src content unchanged by a successful vacuum" {
    const allocator = std.heap.page_allocator;
    const src = ".vacuum_ro_src.db";
    const dst = ".vacuum_ro_dst.db";
    defer unlinkPath(src);
    defer unlinkDstAndMarker(dst);
    try writeSampleDb(allocator, src, 400);

    const before_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, src, allocator, .limited(64 << 20));
    defer allocator.free(before_bytes);

    var out: [256]u8 = undefined;
    var fw = std.Io.Writer.fixed(&out);
    const report = try cube_check.vacuumCopy(std.testing.allocator, std.testing.io, src, dst, &fw);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 400), report.entries_copied);

    const after_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, src, allocator, .limited(64 << 20));
    defer allocator.free(after_bytes);
    const after = try std.Io.Dir.cwd().statFile(std.testing.io, src, .{});
    try std.testing.expectEqual(before_bytes.len, after.size);
    try std.testing.expectEqualSlices(u8, before_bytes, after_bytes);
}

// ===== U5-4-F: batch-loader input-shape boundaries (review F1) =====
// The batch staging buffers were sized from hardcoded average key/value
// bytes (512×48 / 512×80) and filled with appendSliceAssumeCapacity — legal
// input shapes (64B keys; 1MB overflow values) overflow the capacity assert
// (panic in Debug/ReleaseSafe, OOB in ReleaseFast). These two tests pin the
// contract: ANY legal db content must vacuum without tripping the loader.

/// Churn a db with 64-byte keys ("K" + 63 chars) so a full 512-entry batch
/// carries 512×64 = 32,768 key bytes > the old 512×48 = 24,576 capacity.
fn churn64BKeys(allocator: std.mem.Allocator, path: []const u8, n: usize) !void {
    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    var db = try Db.open(allocator, fps.store(), .{});
    defer db.close();
    var value: [64]u8 = undefined;
    @memset(&value, 'v');
    const entries = try allocator.alloc(cube.Entry, n);
    defer allocator.free(entries);
    for (entries, 0..) |*e, i| {
        // 64-byte key: "K" + 63 zero-padded digits
        e.* = .{ .key = try std.fmt.allocPrint(allocator, "K{d:0>63}", .{i}), .value = &value };
    }
    defer for (entries) |e| allocator.free(e.key);
    try db.putBatch(entries);
}

test "cube_check vacuum F1: 64-byte keys × 600 entries (batch byte-budget overflow)" {
    const allocator = std.heap.page_allocator;
    const src = ".vacuum_f1k_src.db";
    const dst = ".vacuum_f1k_dst.db";
    defer unlinkPath(src);
    defer unlinkDstAndMarker(dst);
    try churn64BKeys(allocator, src, 600); // > BATCH=512 → full batch + tail

    var out: [256]u8 = undefined;
    var fw = std.Io.Writer.fixed(&out);
    const report = try cube_check.vacuumCopy(std.testing.allocator, std.testing.io, src, dst, &fw);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 600), report.entries_copied);

    var dst_fps = try FilePageStore.init(allocator, dst);
    defer dst_fps.deinit();
    var dst_db = try Db.open(allocator, dst_fps.store(), .{});
    defer dst_db.close();
    try std.testing.expectEqual(@as(u64, 600), dst_db.entryCount());
    // spot-check first/last keys byte-identical (64B keys round-trip)
    const first_key = try std.fmt.allocPrint(allocator, "K{d:0>63}", .{0});
    defer allocator.free(first_key);
    const first = (try dst_db.get(first_key)).?;
    defer allocator.free(first);
    try std.testing.expectEqual(@as(usize, 64), first.len);
    const last_key = try std.fmt.allocPrint(allocator, "K{d:0>63}", .{599});
    defer allocator.free(last_key);
    const last = (try dst_db.get(last_key)).?;
    defer allocator.free(last);
    try std.testing.expectEqual(@as(usize, 64), last.len);
}

test "cube_check vacuum F1: single 1MB value (oversized entry exceeds val buffer)" {
    const allocator = std.heap.page_allocator;
    const src = ".vacuum_f1v_src.db";
    const dst = ".vacuum_f1v_dst.db";
    defer unlinkPath(src);
    defer unlinkDstAndMarker(dst);
    {
        var fps = try FilePageStore.init(allocator, src);
        defer fps.deinit();
        var db = try Db.open(allocator, fps.store(), .{});
        defer db.close();
        const big = try allocator.alloc(u8, 1 << 20); // 1MB, single entry
        defer allocator.free(big);
        @memset(big, 'B');
        try db.put("big", big);
        try db.put("small", "s");
    }

    var out: [256]u8 = undefined;
    var fw = std.Io.Writer.fixed(&out);
    const report = try cube_check.vacuumCopy(std.testing.allocator, std.testing.io, src, dst, &fw);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), report.entries_copied);

    var dst_fps = try FilePageStore.init(allocator, dst);
    defer dst_fps.deinit();
    var dst_db = try Db.open(allocator, dst_fps.store(), .{});
    defer dst_db.close();
    try std.testing.expectEqual(@as(u64, 2), dst_db.entryCount());
    const got = (try dst_db.get("big")).?;
    defer allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1 << 20), got.len);
    try std.testing.expectEqual(@as(u8, 'B'), got[0]);
    try std.testing.expectEqual(@as(u8, 'B'), got[got.len - 1]);
    try std.testing.expectEqualStrings("s", (try dst_db.get("small")).?);
}

// ===== U5-4-P: F5 exit-code semantics (review round 1 follow-up) =====
// `error.CorruptCrc` from a corrupted src must map to EXIT_CORRUPT (2), the
// existing cube_check convention (scrub maps corruption to 2), NOT the
// generic `else => EXIT_USAGE` catch-all. Library-level: vacuumCopy's error
// set is the source of truth; CLI-level: asserted via subprocess below
// (same skip-if-unbuilt pattern as cube_check_test M15).

test "cube_check vacuum F5: corrupted src maps to EXIT_CORRUPT (2) via CLI subprocess" {
    const allocator = std.heap.page_allocator;
    const exe = blk: {
        const candidates = [_][]const u8{
            "zig-out/bin/cube_check",
            "../zig-out/bin/cube_check",
            "../../zig-out/bin/cube_check",
        };
        for (candidates) |p| {
            std.Io.Dir.cwd().access(std.testing.io, p, .{}) catch continue;
            break :blk p;
        }
        return error.SkipZigTest; // no installed binary: exit-code mapping not testable here
    };
    const src = ".vacuum_f5_src.db";
    const dst = ".vacuum_f5_dst.db";
    defer unlinkPath(src);
    defer unlinkPath(dst);
    try writeSampleDb(allocator, src, 3000); // multi-page leaf chain
    {
        var fps = try FilePageStore.init(allocator, src);
        defer fps.deinit();
        const meta = (try fps.store().readMeta()).?;
        const page = try fps.store().readPage(@intCast(meta.last_page));
        const raw: [*]u8 = @constCast(page.ptr);
        raw[64] ^= 0xFF; // same injection as the corrupt-src library test above
    }

    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ exe, "vacuum", src, dst },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(std.testing.io);
    const code = switch (term) {
        .exited => |exit_code| exit_code,
        else => return error.UnexpectedChildTermination,
    };
    try std.testing.expectEqual(@as(u8, cube_check.EXIT_CORRUPT), code);
    // And no dst residue (F5 asserts the mapping only; no-half-dst is test 7's job).
    try std.testing.expect(!cube_check.fileExists(std.testing.io, dst));
}

// ===== U5-4-C (T-67): dst completion marker + empty-src gate =====
// Contract: a dst produced by vacuumCopy is only a COMPLETED vacuum if the
// sidecar completion marker (`<dst>.done`) exists and names the copied entry
// count. kill -9 / mid-vacuum errors leave batch-committed prefix snapshots
// (T-67: scrub-clean, openable, PARTIAL) — the marker is what separates a
// finished vacuum from a prefix. Marker write failure must never surface as
// success. Empty (0-commit) src is refused (error.NoMeta → EXIT_USAGE): a
// meta-less dst could never pass scrub, so "vacuuming nothing" was a
// fake-success (E-1 note from U5-4-T #16).

fn markerPathFor(dst: []const u8) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, "{s}.done", .{dst});
}

/// Cleanup helper for tests that produce a dst: removes both the dst and its
/// completion sidecar (U5-4-C: every successful vacuumCopy leaves <dst>.done).
fn unlinkDstAndMarker(dst: []const u8) void {
    unlinkPath(dst);
    const m = std.fmt.allocPrint(std.testing.allocator, "{s}.done", .{dst}) catch return;
    defer std.testing.allocator.free(m);
    unlinkPath(m);
}

test "cube_check vacuum T-67: success writes completion marker with entry count" {
    const allocator = std.heap.page_allocator;
    const src = ".vacuum_m_src.db";
    const dst = ".vacuum_m_dst.db";
    const marker = try markerPathFor(dst);
    defer std.testing.allocator.free(marker);
    defer unlinkPath(src);
    defer unlinkDstAndMarker(dst);
    defer unlinkPath(marker);
    try writeSampleDb(allocator, src, 200);

    var out: [256]u8 = undefined;
    var fw = std.Io.Writer.fixed(&out);
    const report = try cube_check.vacuumCopy(std.testing.allocator, std.testing.io, src, dst, &fw);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 200), report.entries_copied);

    // marker exists and names the entry count
    try std.testing.expect(cube_check.fileExists(std.testing.io, marker));
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, marker, allocator, .limited(4096));
    defer allocator.free(content);
    const want = try std.fmt.allocPrint(allocator, "vacuum-complete entries=200\n", .{});
    defer allocator.free(want);
    try std.testing.expectEqualSlices(u8, want, content);
}

test "cube_check vacuum T-67: mid-vacuum failure (error AFTER batches landed) → no marker" {
    const allocator = std.heap.page_allocator;
    const src = ".vacuum_mfail_src.db";
    const dst = ".vacuum_mfail_dst.db";
    const marker = try markerPathFor(dst);
    defer std.testing.allocator.free(marker);
    defer unlinkPath(src);
    defer unlinkDstAndMarker(dst);
    defer unlinkPath(marker);
    // 3000 entries → multi-batch walk (512/batch); corrupt a HIGH leaf so the
    // failure lands AFTER several successful batches (the T-67 shape: prefix
    // snapshot exists, then the walk dies).
    try writeSampleDb(allocator, src, 3000);
    {
        var fps = try FilePageStore.init(allocator, src);
        defer fps.deinit();
        const meta = (try fps.store().readMeta()).?;
        const page = try fps.store().readPage(@intCast(meta.last_page));
        const raw: [*]u8 = @constCast(page.ptr);
        raw[64] ^= 0xFF;
    }

    var sink: [64]u8 = undefined;
    var dw = std.Io.Writer.Discarding.init(&sink);
    const result = cube_check.vacuumCopy(std.testing.allocator, std.testing.io, src, dst, &dw.writer);
    try std.testing.expectError(error.CorruptCrc, result);
    // dst prefix file may exist (batch commits) but NO completion marker
    try std.testing.expect(!cube_check.fileExists(std.testing.io, marker));
}

test "cube_check vacuum T-67: empty src (0 commits) → error.NoMeta, no dst, no marker" {
    const allocator = std.heap.page_allocator;
    const src = ".vacuum_empty_src.db";
    const dst = ".vacuum_empty_dst.db";
    const marker = try markerPathFor(dst);
    defer std.testing.allocator.free(marker);
    defer unlinkPath(src);
    defer unlinkDstAndMarker(dst);
    defer unlinkPath(marker);
    {
        var fps = try FilePageStore.init(allocator, src); // creates, never commits
        defer fps.deinit();
    }
    var sink: [64]u8 = undefined;
    var dw = std.Io.Writer.Discarding.init(&sink);
    const result = cube_check.vacuumCopy(std.testing.allocator, std.testing.io, src, dst, &dw.writer);
    try std.testing.expectError(error.NoMeta, result);
    try std.testing.expect(!cube_check.fileExists(std.testing.io, dst));
    try std.testing.expect(!cube_check.fileExists(std.testing.io, marker));
}

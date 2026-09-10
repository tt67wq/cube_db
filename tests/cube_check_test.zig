//! tests/cube_check_test.zig — T-35 Part B: cube_check.scrub library-function
//! tests. The scrub decision logic lives in src/cube_check.zig and is tested
//! directly (no subprocess); the CLI argv parsing is a thin shell over it.
//!
//! Corruption injection (test-only): write a normal DB, then flip one byte of
//! a data page directly through FilePageStore's writePage (bypassing CRC
//! recompute), reopen, and scrub must report that page as corrupt.

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

/// Write a normal DB with `n` entries (several data pages) at `path`.
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

/// Flip one payload byte of `page_no` directly in the mmap region (no CRC
/// recompute). Test-only corruption helper — lives here, not in production code.
fn corruptOneByte(allocator: std.mem.Allocator, path: []const u8, page_no: u32) !void {
    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    const s = fps.store();
    const page = try s.writePage(page_no);
    page[cube.format.PAGE_HEADER_SIZE + 8] ^= 0xAA;
}

/// Read the on-disk page_type of `page_no` (header bytes, untouched by
/// corruptOneByte, so pre- and post-corruption reads agree).
fn readPageType(allocator: std.mem.Allocator, path: []const u8, page_no: u32) !u8 {
    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    const page = try fps.store().readPage(page_no);
    const hdr = cube.format.decodePageHeader(page[0..cube.format.PAGE_HEADER_SIZE]);
    return hdr.page_type;
}

test "cube_check: scrub clean DB — all pages pass" {
    const allocator = std.heap.page_allocator;
    const path = ".cube_check_clean.db";
    defer unlinkPath(path);
    try writeSampleDb(allocator, path, 200);

    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();

    var out: [8192]u8 = undefined;
    @memset(&out, 0);
    var fw = std.Io.Writer.fixed(&out);
    var report = try cube_check.scrub(std.testing.allocator, fps.store(), &fw);
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(report.total > 0);
    try std.testing.expectEqual(report.total, report.passed);
    try std.testing.expectEqual(@as(usize, 0), report.failed.len);
    try std.testing.expect(std.mem.indexOf(u8, &out, "failed=0") != null);
}

test "cube_check: scrub detects a corrupted page" {
    const allocator = std.heap.page_allocator;
    const path = ".cube_check_corrupt.db";
    defer unlinkPath(path);
    try writeSampleDb(allocator, path, 200);
    try corruptOneByte(allocator, path, ps.FIRST_DATA_PAGE);
    // capture the expected header page_type BEFORE opening the scrub store
    // (FilePageStore takes an exclusive flock — no second concurrent open)
    const want_type = try readPageType(allocator, path, ps.FIRST_DATA_PAGE);

    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();

    var sink: [64]u8 = undefined;
    var dw = std.Io.Writer.Discarding.init(&sink);
    var report = try cube_check.scrub(std.testing.allocator, fps.store(), &dw.writer);
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), report.failed.len);
    try std.testing.expectEqual(ps.FIRST_DATA_PAGE, report.failed[0].page_no);
    try std.testing.expectEqual(report.total - 1, report.passed);
    // page_type diagnostic: header region is untouched by corruptOneByte, so
    // the reported type must equal the pre-corruption on-disk header type.
    try std.testing.expectEqual(want_type, report.failed[0].page_type);
}

test "cube_check: scrub reports no valid meta" {
    const allocator = std.heap.page_allocator;
    const path = ".cube_check_nometa.db";
    defer unlinkPath(path);
    var fps = try FilePageStore.init(allocator, path); // fresh file, no meta written
    defer fps.deinit();

    var sink: [64]u8 = undefined;
    var dw = std.Io.Writer.Discarding.init(&sink);
    const result = cube_check.scrub(std.testing.allocator, fps.store(), &dw.writer);
    try std.testing.expectError(error.NoMeta, result);
}

test "cube_check: exit code constants (documented in --help)" {
    try std.testing.expectEqual(@as(u8, 0), cube_check.EXIT_OK);
    try std.testing.expectEqual(@as(u8, 1), cube_check.EXIT_USAGE);
    try std.testing.expectEqual(@as(u8, 2), cube_check.EXIT_CORRUPT);
}

// ===== wf-pi-3 (test worker) strengthening — plan M13/M14/M15 =====

test "cube_check: scrub lists every corrupted page — multi-page injection (M13/M14)" {
    const allocator = std.heap.page_allocator;
    const path = ".cube_check_multi.db";
    defer unlinkPath(path);
    // 3000 entries x ~87B -> ~70+ pages, so pages 33 and 64 both exist as
    // live data pages; 64 % 64 == 0 and 33/3 are not (scrub is tier-blind,
    // it verifies every page regardless of any sampling rule).
    try writeSampleDb(allocator, path, 3000);

    {
        var fps = try FilePageStore.init(allocator, path);
        defer fps.deinit();
        const meta = (try fps.store().readMeta()).?;
        try std.testing.expect(meta.last_page >= 64); // page 64 is allocated
    }

    const corrupted = [_]u32{ ps.FIRST_DATA_PAGE, 33, 64 };
    var want_types: [corrupted.len]u8 = undefined;
    for (corrupted, 0..) |pn, i| {
        want_types[i] = try readPageType(allocator, path, pn);
        try corruptOneByte(allocator, path, pn);
    }

    var fps2 = try FilePageStore.init(allocator, path);
    defer fps2.deinit();
    var sink: [64]u8 = undefined;
    var dw = std.Io.Writer.Discarding.init(&sink);
    var report = try cube_check.scrub(std.testing.allocator, fps2.store(), &dw.writer);
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), report.failed.len);
    try std.testing.expectEqual(report.total - 3, report.passed);
    // order-independent set comparison on page numbers
    for (corrupted) |pn| {
        var found = false;
        for (report.failed) |f| {
            if (f.page_no == pn) {
                found = true;
                // page_type diagnostic must match the intact on-disk header
                const idx = for (corrupted, 0..) |cp, j| {
                    if (cp == pn) break j;
                } else unreachable;
                try std.testing.expectEqual(want_types[idx], f.page_type);
            }
        }
        try std.testing.expect(found);
    }
}

/// Locate the installed cube_check executable (built by `zig build`).
/// Skips the CLI test when absent (e.g. bare `zig build test` without a prior
/// `zig build`) — the exit-code mapping is then covered only by the constants
/// test above; run `zig build` first for full coverage.
fn findCubeCheckExe() ?[]const u8 {
    const candidates = [_][]const u8{
        "zig-out/bin/cube_check",
        "../zig-out/bin/cube_check",
        "../../zig-out/bin/cube_check",
    };
    for (candidates) |p| {
        std.Io.Dir.cwd().access(std.testing.io, p, .{}) catch continue;
        return p;
    }
    return null;
}

fn runCli(exe: []const u8, path: []const u8) !u8 {
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ exe, "scrub", path },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(std.testing.io);
    return switch (term) {
        .exited => |code| code,
        else => error.UnexpectedChildTermination,
    };
}

test "cube_check CLI: exit codes via subprocess (M15)" {
    const allocator = std.heap.page_allocator;
    const exe = findCubeCheckExe() orelse return error.SkipZigTest;

    // clean DB -> EXIT_OK (0)
    {
        const path = ".cube_check_cli_clean.db";
        defer unlinkPath(path);
        try writeSampleDb(allocator, path, 200);
        try std.testing.expectEqual(@as(u8, 0), try runCli(exe, path));
    }
    // corrupted DB -> EXIT_CORRUPT (2)
    {
        const path = ".cube_check_cli_corrupt.db";
        defer unlinkPath(path);
        try writeSampleDb(allocator, path, 200);
        try corruptOneByte(allocator, path, ps.FIRST_DATA_PAGE);
        try std.testing.expectEqual(@as(u8, 2), try runCli(exe, path));
    }
    // nonexistent path -> EXIT_USAGE (1)
    {
        const path = ".cube_check_cli_missing.db"; // never created
        defer unlinkPath(path);
        try std.testing.expectEqual(@as(u8, 1), try runCli(exe, path));
    }
    // empty file, no valid meta -> EXIT_USAGE (1)
    {
        const path = ".cube_check_cli_nometa.db";
        defer unlinkPath(path);
        {
            const f = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
            f.close(std.testing.io);
        }
        try std.testing.expectEqual(@as(u8, 1), try runCli(exe, path));
    }
}

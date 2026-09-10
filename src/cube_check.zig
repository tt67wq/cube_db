//! cube_check.zig — offline integrity tool (T-35 Part B).
//!
//! Usage:
//!   cube_check scrub <db-path>
//!
//! Exit codes (also printed by --help):
//!   0 (EXIT_OK)      all pages passed CRC verification
//!   1 (EXIT_USAGE)   usage error: bad arguments, cannot open the DB file,
//!                    or no valid meta page
//!   2 (EXIT_CORRUPT) corruption found: at least one data page failed CRC
//!
//! The scrub decision logic is the library function `scrub` (unit-tested in
//! tests/cube_check_test.zig); `main` only does argv parsing and exit-code
//! mapping. The DB must not be held open by a writer process — FilePageStore
//! takes an exclusive flock on open.

const std = @import("std");
const cube = @import("cube_db");

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

const usage_text =
    \\Usage: cube_check scrub <db-path>
    \\
    \\Offline integrity check: verifies the whole-page CRC of every data page
    \\in [FIRST_DATA_PAGE ..= meta.last_page]. The DB must not be open by any
    \\writer process (FilePageStore takes an exclusive flock).
    \\
    \\Exit codes:
    \\  0  all pages passed
    \\  1  usage error (bad args, open failure, no valid meta page)
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
    const path = args_it.next() orelse return usageError();
    if (!std.mem.eql(u8, sub, "scrub")) return usageError();
    if (args_it.next() != null) return usageError();

    var fps = cube.file_page_store.FilePageStore.init(alloc, path) catch |err| {
        std.debug.print("cube_check: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
        return EXIT_USAGE;
    };
    defer fps.deinit();

    var out_buf: [4096]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    var report = scrub(alloc, fps.store(), &w.interface) catch |err| {
        try w.interface.flush();
        std.debug.print("cube_check: scrub failed: {s}\n", .{@errorName(err)});
        return EXIT_USAGE;
    };
    defer report.deinit(alloc);
    try w.interface.flush();

    return if (report.failed.len == 0) EXIT_OK else EXIT_CORRUPT;
}

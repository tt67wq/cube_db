//! mmap_region_test.zig - P1 TDD: 1TB reserved virtual region + file growth visible to readers (growth-vis)
//! Verifies LMDB-style plan I: open mmaps a 1TB MAP_SHARED reserved region; after the file grows via ftruncate,
//! readers see new data through the same mmap pointer - no SIGBUS, no re-mmap needed.
//! Inspired by spike_mmap.zig (already proven viable on macOS); here we exercise the real FilePageStore interface.

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const FilePageStore = cube.file_page_store.FilePageStore;
const f2 = cube.format;
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

/// 1 TB reserved virtual region
const REGION: u64 = 1 << 40;

test "FilePageStore: open reserves 1TB virtual region" {
    const allocator = std.testing.allocator;
    const path = ".test_mmap_region_open.db";
    defer unlinkPath(path);
    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    // reserved region >= 1TB (LMDB-style placeholder)
    try std.testing.expect(fps.regionSize() >= REGION);
}

test "FilePageStore: file growth visible via same mmap (no SIGBUS)" {
    const allocator = std.testing.allocator;
    const path = ".test_mmap_region_growth.db";
    defer unlinkPath(path);
    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    const s = fps.store();

    // allocate one data page (triggers file ftruncate growth)
    const pn = try s.allocPage();
    try std.testing.expect(pn >= ps.FIRST_DATA_PAGE);

    // write known bytes
    const wbuf = try s.writePage(pn);
    const magic = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    @memcpy(wbuf[0..4], &magic);

    // read back through the same mmap pointer; the just-written bytes must be visible, no SIGBUS
    const rbuf = try s.readPage(pn);
    try std.testing.expectEqual(@as(u8, 0xDE), rbuf[0]);
    try std.testing.expectEqual(@as(u8, 0xAD), rbuf[1]);
    try std.testing.expectEqual(@as(u8, 0xBE), rbuf[2]);
    try std.testing.expectEqual(@as(u8, 0xEF), rbuf[3]);
}

test "FilePageStore: growth at high page number needs no remmap" {
    const allocator = std.testing.allocator;
    const path = ".test_mmap_region_high.db";
    defer unlinkPath(path);
    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    const s = fps.store();

    // allocate several pages in a row; the file grows accordingly, no re-open/re-mmap needed
    var last: u32 = 0;
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        last = try s.allocPage();
        const w = try s.writePage(last);
        w[0] = @intCast(i & 0xFF);
    }
    // read back the last page to confirm the grown region is visible
    const r = try s.readPage(last);
    try std.testing.expectEqual(@as(u8, 15), r[0]);
}

test "FilePageStore: Db COW put/get persists across reopen" {
    const allocator = std.testing.allocator;
    const path = ".test_mmap_region_e2e.db";
    defer unlinkPath(path);
    // first open: write a few keys, then close
    {
        var fps = try FilePageStore.init(allocator, path);
        defer fps.deinit();
        var db = try cube.Db.open(allocator, fps.store(), .{});
        defer db.close();
        try db.put("alpha", "one");
        try db.put("beta", "two");
        try db.compact();
        const v = try db.get("alpha");
        defer if (v) |val| allocator.free(val);
        try std.testing.expectEqualStrings("one", v.?);
    }
    // reopen: data must be present
    {
        var fps = try FilePageStore.init(allocator, path);
        defer fps.deinit();
        var db = try cube.Db.open(allocator, fps.store(), .{});
        defer db.close();
        const a = try db.get("alpha");
        defer if (a) |val| allocator.free(val);
        try std.testing.expectEqualStrings("one", a.?);
        const b = try db.get("beta");
        defer if (b) |val| allocator.free(val);
        try std.testing.expectEqualStrings("two", b.?);
    }
}

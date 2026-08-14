//! mmap_region_test.zig — P1 TDD: 1TB 预留虚拟区 + 文件增长 reader 可见（growth-vis）
//! 验证 LMDB 式方案 I：open mmap 1TB MAP_SHARED 预留区，文件 ftruncate 增长后
//! reader 经同一 mmap 指针读新数据，无 SIGBUS、无需重 mmap。
//! 灵感来自 spike_mmap.zig（已验证 macOS 可行），此处走 FilePageStore 真实接口。

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

/// 1 TB 预留虚拟区
const REGION: u64 = 1 << 40;

test "FilePageStore: open reserves 1TB virtual region" {
    const allocator = std.testing.allocator;
    const path = ".test_mmap_region_open.db";
    defer unlinkPath(path);
    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    // 预留区 >= 1TB（LMDB 式占位）
    try std.testing.expect(fps.regionSize() >= REGION);
}

test "FilePageStore: file growth visible via same mmap (no SIGBUS)" {
    const allocator = std.testing.allocator;
    const path = ".test_mmap_region_growth.db";
    defer unlinkPath(path);
    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    const s = fps.store();

    // 分配一个数据页（触发文件 ftruncate 增长）
    const pn = try s.allocPage();
    try std.testing.expect(pn >= ps.FIRST_DATA_PAGE);

    // 写已知字节
    const wbuf = try s.writePage(pn);
    const magic = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    @memcpy(wbuf[0..4], &magic);

    // 经同一 mmap 指针读回，应可见刚写字节，无 SIGBUS
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

    // 连续分配多页，文件随之增长，无需重新 open/mmap
    var last: u32 = 0;
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        last = try s.allocPage();
        const w = try s.writePage(last);
        w[0] = @intCast(i & 0xFF);
    }
    // 读回最后一页确认增长区可见
    const r = try s.readPage(last);
    try std.testing.expectEqual(@as(u8, 15), r[0]);
}

test "FilePageStore: Db COW put/get persists across reopen" {
    const allocator = std.testing.allocator;
    const path = ".test_mmap_region_e2e.db";
    defer unlinkPath(path);
    // 第一次开：写几个 key，关
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
    // 重开：数据应在
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

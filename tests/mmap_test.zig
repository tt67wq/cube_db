//! mmap wrapper TDD 测试（T1）。RED: stub 返回 NotImplemented → GREEN: 真 mmap。
const std = @import("std");
const cube = @import("cube_db");
const mmap = cube.mmap;

const c = @cImport({
    @cInclude("sys/mman.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

test "mmap: mapReadOnly + read back written bytes (roundtrip)" {
    const path = "mmap_wrapper_test.db";
    const fd = c.open(path, @as(c_int, c.O_RDWR | c.O_CREAT | c.O_TRUNC), @as(c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    defer _ = c.unlink(path);

    // 写 4KB + 已知字节
    try std.testing.expectEqual(@as(c_int, 0), c.ftruncate(fd, 4096));
    const magic: [4]u8 = .{ 0xCA, 0xFE, 0xBA, 0xBE };
    try std.testing.expectEqual(@as(isize, 4), c.pwrite(fd, @ptrCast(&magic[0]), 4, 100));

    const region = mmap.pageAlignUp(4096);
    const ptr = try mmap.mapReadOnly(fd, region);
    defer mmap.unmap(ptr, region);

    // 读回
    try std.testing.expectEqual(@as(u8, 0xCA), ptr[100]);
    try std.testing.expectEqual(@as(u8, 0xFE), ptr[101]);
    try std.testing.expectEqual(@as(u8, 0xBA), ptr[102]);
    try std.testing.expectEqual(@as(u8, 0xBE), ptr[103]);
}

test "mmap: mapReadOnly grows visible (pwrite after map)" {
    const path = "mmap_wrapper_grow_test.db";
    const fd = c.open(path, @as(c_int, c.O_RDWR | c.O_CREAT | c.O_TRUNC), @as(c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    defer _ = c.unlink(path);
    try std.testing.expectEqual(@as(c_int, 0), c.ftruncate(fd, 4096));

    const region: usize = 1 << 30; // 1GB 预留区
    const ptr = try mmap.mapReadOnly(fd, region);
    defer mmap.unmap(ptr, region);

    // 映射后再增长 + 写
    try std.testing.expectEqual(@as(c_int, 0), c.ftruncate(fd, 8192));
    const v: [4]u8 = .{ 1, 2, 3, 4 };
    try std.testing.expectEqual(@as(isize, 4), c.pwrite(fd, @ptrCast(&v[0]), 4, 6000));

    try std.testing.expectEqual(@as(u8, 1), ptr[6000]);
    try std.testing.expectEqual(@as(u8, 4), ptr[6003]);
}

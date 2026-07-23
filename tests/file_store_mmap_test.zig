//! T2/T3 测试：FileStore mmap 预留大区 + vtRead 走 mmap memcpy+跳 marker。
//! RED：旧 vtRead 用 pread；新字段 mmap_base 不存在。
//! GREEN：create 时 mmap 预留区，vtRead 改 mmap memcpy+跳 marker。
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const FileStore = cube.file_store.FileStore;
const f = cube.format;

// T2: create 后 mmap_base 已设（非 null）
test "T2: FileStore.create maps a reserved region (mmap_base set)" {
    const path = "t2_mmap_base_test.db";
    const cwd = zio.Dir.cwd();
    cwd.deleteFile(path) catch {};
    defer cwd.deleteFile(path) catch {};

    var fs = try FileStore.create(std.testing.allocator, path);
    defer fs.close();
    try std.testing.expect(fs.mmap_base != null);
    try std.testing.expect(fs.mmap_region_len > 0);
}

// T3 roundtrip: append 写 → read 读回一致（小数据，单块内）
test "T3: roundtrip small data within one block" {
    const path = "t3_roundtrip_small.db";
    const cwd = zio.Dir.cwd();
    cwd.deleteFile(path) catch {};
    defer cwd.deleteFile(path) catch {};

    var fs = try FileStore.create(std.testing.allocator, path);
    defer fs.close();
    const s = fs.store();
    const data = "hello-mmap-read-path";
    const off = try s.append(data);
    try std.testing.expectEqual(@as(u64, 0), off);
    var buf: [32]u8 = undefined;
    const n = try s.read(&buf, off);
    try std.testing.expectEqual(@as(usize, data.len), n);
    try std.testing.expectEqualStrings(data, buf[0..n]);
}

// T3: 跨 marker 边界（写 >4095 字节，读跨边界处 marker 被跳过）
test "T3: cross marker boundary (write >BLOCK_SIZE-1, marker skipped on read)" {
    const path = "t3_cross_marker.db";
    const cwd = zio.Dir.cwd();
    cwd.deleteFile(path) catch {};
    defer cwd.deleteFile(path) catch {};

    var fs = try FileStore.create(std.testing.allocator, path);
    defer fs.close();
    const s = fs.store();
    // 写跨边界：BLOCK_SIZE-1=4095 逻辑字节/块。写 8192 逻辑字节 → 跨 1 块 + 部分。
    const N: usize = 8192;
    const data = try std.testing.allocator.alloc(u8, N);
    defer std.testing.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @intCast(i % 251); // 伪随机模式
    const off = try s.append(data);
    try std.testing.expectEqual(@as(u64, 0), off);

    // 读回全部
    const got = try std.testing.allocator.alloc(u8, N);
    defer std.testing.allocator.free(got);
    var read_total: usize = 0;
    while (read_total < N) {
        const n = try s.read(got[read_total..], @as(u64, @intCast(read_total)));
        try std.testing.expect(n > 0);
        read_total += n;
    }
    try std.testing.expectEqual(N, read_total);
    // 关键：跨边界处数据正确（marker 字节被跳过，不是数据）
    try std.testing.expectEqualSlices(u8, data, got);

    // 特别检查边界附近：offset 4094, 4095, 4096, 4097（跨 marker）
    try std.testing.expectEqual(data[4094], got[4094]);
    try std.testing.expectEqual(data[4095], got[4095]);
    try std.testing.expectEqual(data[4096], got[4096]);
}

// T3: bounds — offset == logical_len 返回 0；offset 超出不 panic
test "T3: bounds check — offset==size returns 0" {
    const path = "t3_bounds.db";
    const cwd = zio.Dir.cwd();
    cwd.deleteFile(path) catch {};
    defer cwd.deleteFile(path) catch {};

    var fs = try FileStore.create(std.testing.allocator, path);
    defer fs.close();
    const s = fs.store();
    _ = try s.append("abc");
    var buf: [8]u8 = undefined;
    const size = try s.size();
    const n = try s.read(&buf, size);
    try std.testing.expectEqual(@as(usize, 0), n);
}

// T3: reopen 后读旧数据（mmap 映射已存文件内容）
test "T3: reopen reads persisted data via mmap" {
    const path = "t3_reopen.db";
    const cwd = zio.Dir.cwd();
    cwd.deleteFile(path) catch {};

    {
        var fs = try FileStore.create(std.testing.allocator, path);
        const s = fs.store();
        _ = try s.append("persisted-data");
        try s.sync();
        fs.close();
    }
    defer cwd.deleteFile(path) catch {};

    var fs = try FileStore.create(std.testing.allocator, path);
    defer fs.close();
    const s = fs.store();
    var buf: [32]u8 = undefined;
    const n = try s.read(&buf, 0);
    try std.testing.expectEqual(@as(usize, "persisted-data".len), n);
    try std.testing.expectEqualStrings("persisted-data", buf[0..n]);
}

//! T1 RED: 去 marker——appendRaw 写连续逻辑字节，逻辑==物理。
//! 旧实现：每 4095 逻辑字节插 1 marker，物理>逻辑、读跨边界需跳 marker。
//! 期望：写 >4095 字节，物理长度==逻辑长度、读回全等（无 marker 间隙）。
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const f = cube.format;
const store_mod = cube.store;

test "T1 RED: MemStore appendRaw physical==logical (no marker)" {
    var ms = store_mod.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    // 写跨原 marker 边界（>4095 字节）
    const N: usize = 8192;
    const data = try std.testing.allocator.alloc(u8, N);
    defer std.testing.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @intCast(i % 251);
    _ = try s.append(data);
    // 物理长度应 == 逻辑长度（无 marker 字节插入）
    const logical = try s.size();
    const physical = try s.physicalSize();
    try std.testing.expectEqual(logical, physical);
    // 读回全等
    const got = try std.testing.allocator.alloc(u8, N);
    defer std.testing.allocator.free(got);
    var read_total: usize = 0;
    while (read_total < N) {
        const n = try s.read(got[read_total..], @intCast(read_total));
        try std.testing.expect(n > 0);
        read_total += n;
    }
    try std.testing.expectEqualSlices(u8, data, got);
}

test "T1 RED: FileStore appendRaw physical==logical (no marker)" {
    const path = "t1_marker_filestore.db";
    const cwd = zio.Dir.cwd();
    cwd.deleteFile(path) catch {};
    defer cwd.deleteFile(path) catch {};
    var fs = try cube.file_store.FileStore.create(std.testing.allocator, path);
    defer fs.close();
    const s = fs.store();
    const N: usize = 8192;
    const data = try std.testing.allocator.alloc(u8, N);
    defer std.testing.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @intCast(i % 251);
    _ = try s.append(data);
    const logical = try s.size();
    const physical = try s.physicalSize();
    try std.testing.expectEqual(logical, physical);
}

test "T1 RED: logicalToPhysical identity (logical==physical)" {
    // 去 marker 后逻辑偏移 == 物理偏移
    try std.testing.expectEqual(@as(u64, 0), store_mod.logicalToPhysical(0));
    try std.testing.expectEqual(@as(u64, 4096), store_mod.logicalToPhysical(4096));
    try std.testing.expectEqual(@as(u64, 0), store_mod.physicalToLogical(0));
    try std.testing.expectEqual(@as(u64, 4096), store_mod.physicalToLogical(4096));
}

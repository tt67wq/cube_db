//! profile_commit.zig — #35: commit 路径规模敏感项分解
//! 计时埋点：dupe / sort / dedup / insertBatch / pending_free / meta
//! 用法：zig build profile-commit -Doptimize=ReleaseFast
const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const Entry = cube.Entry;
const writer = cube.writer;

fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

fn runScale(allocator: std.mem.Allocator, n: usize, label: []const u8) !void {
    // 预分配页池容量（消除 resize 变量，专注 commit 路径本身）
    var ms = cube.page_store.MemPageStore.init(allocator, @as(u32, @intCast(3 + n * 10 + 10000)));
    defer ms.deinit();
    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();

    // 构建 entries（预构建，不计时）
    const entries = try allocator.alloc(Entry, n);
    defer allocator.free(entries);
    for (entries, 0..) |*e, i| {
        e.* = .{ .key = try std.fmt.allocPrint(allocator, "{d:0>10}", .{i}), .value = "v" };
    }
    defer for (entries) |e| allocator.free(e.key);

    writer.ProfileStats.reset();
    writer.ProfileStats.enable = true;
    defer writer.ProfileStats.enable = false;

    // 分段计时 putBatch 整体 vs applyBatch 内部
    const t_staging0 = monoNs();
    try db.putBatch(entries);
    const t_staging1 = monoNs();

    const elapsed = t_staging1 - t_staging0;
    const per_entry = @divFloor(elapsed, @as(i64, @intCast(n)));
    const apply_total = writer.ProfileStats.txn_total_ns;
    const gap = elapsed - @as(i64, @intCast(apply_total));

    std.debug.print("\n=== {s}: N={d}, 总耗时 {d} ms, {d} ns/entry ({d:.2} us/entry) ===\n", .{ label, n, @divFloor(elapsed, 1_000_000), per_entry, @as(f64, @floatFromInt(per_entry)) / 1000.0 });
    std.debug.print("entryCount = {d}\n", .{db.entryCount()});
    std.debug.print("  applyBatch 内部合计: {d} ns ({d:.1}%)  每 entry {d} ns\n", .{ apply_total, @as(f64, @floatFromInt(apply_total)) / @as(f64, @floatFromInt(elapsed)) * 100.0, @divFloor(@as(i64, @intCast(apply_total)), @as(i64, @intCast(n))) });
    std.debug.print("  未计量（staging+flushPendingFree+其他）: {d} ns ({d:.1}%)  每 entry {d} ns\n", .{ gap, @as(f64, @floatFromInt(@max(gap, 0))) / @as(f64, @floatFromInt(elapsed)) * 100.0, @divFloor(@max(gap, 0), @as(i64, @intCast(n))) });
    writer.ProfileStats.print();
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    // 拐点扫描：100K → 500K
    try runScale(alloc, 100_000, "100K");
    try runScale(alloc, 200_000, "200K");
    try runScale(alloc, 300_000, "300K");
    try runScale(alloc, 400_000, "400K");
    try runScale(alloc, 500_000, "500K");

    // 1M
    try runScale(alloc, 1_000_000, "1M");
}

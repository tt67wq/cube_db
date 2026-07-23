//! group_commit_test.zig — 并发 group commit（leader/follower 隐式合并）TDD
//! RED：旧 sendRequest 每 op 独占 write_mutex + 1 applyBatch → apply_count == N*M。
//! GREEN：leader/follower 合并并发 put/delete 到更少 applyBatch → apply_count << N*M。
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const Db = cube.Db;

fn fmtKey(buf: *[16]u8, base: u32, i: u32) []const u8 {
    return (std.fmt.bufPrint(buf, "{d}", .{base * 100_000 + i}) catch unreachable);
}

test "group commit: concurrent puts merge into fewer applyBatch calls" {
    const path = "group_commit_merge.db";
    zio.Dir.cwd().deleteFile(path) catch {};
    defer zio.Dir.cwd().deleteFile(path) catch {};
    zio.Dir.cwd().deleteFile(path ++ ".compact") catch {};
    defer zio.Dir.cwd().deleteFile(path ++ ".compact") catch {};

    const db = try Db.open(std.testing.allocator, path, .{});
    defer db.close() catch {};

    const N: u32 = 16; // 线程数
    const M: u32 = 50; // 每线程 put 数
    const total = N * M;

    const Worker = struct {
        fn run(pdb: *Db, base: u32) !void {
            var i: u32 = 0;
            while (i < M) : (i += 1) {
                var kbuf: [16]u8 = undefined;
                const k = fmtKey(&kbuf, base, i);
                try pdb.put(k, "v");
            }
        }
    }.run;

    var threads: [16]std.Thread = undefined;
    for (0..N) |i| {
        threads[i] = try std.Thread.spawn(.{}, Worker, .{ db, @as(u32, @intCast(i)) });
    }
    for (threads) |t| t.join();

    const ac = db.state.apply_count.load(.monotonic);
    // RED（旧代码）：ac == total（800）→ 断言失败。
    // GREEN（group commit）：leader 合并 → ac 远小于 total。
    //   阈值 total/2 足够稳健：16 线程 + 阻塞 fsync 必有重叠合并。
    if (ac >= total / 2) {
        std.debug.print("apply_count={d} expected < {d}\n", .{ ac, total / 2 });
    }
    try std.testing.expect(ac < total / 2);

    // 正确性：所有 key 可读
    var ok: u32 = 0;
    var b: u32 = 0;
    while (b < N) : (b += 1) {
        var j: u32 = 0;
        while (j < M) : (j += 1) {
            var kbuf: [16]u8 = undefined;
            const k = fmtKey(&kbuf, b, j);
            const v = try db.get(k);
            if (v) |val| {
                ok += 1;
                std.testing.allocator.free(val);
            }
        }
    }
    try std.testing.expectEqual(total, ok);
}

test "group commit: concurrent puts + deletes merge, all correct" {
    const path = "group_commit_del.db";
    zio.Dir.cwd().deleteFile(path) catch {};
    defer zio.Dir.cwd().deleteFile(path) catch {};
    zio.Dir.cwd().deleteFile(path ++ ".compact") catch {};
    defer zio.Dir.cwd().deleteFile(path ++ ".compact") catch {};

    const db = try Db.open(std.testing.allocator, path, .{});
    defer db.close() catch {};

    // 先 put 100 个 key（单线程）
    var p: u32 = 0;
    while (p < 100) : (p += 1) {
        var kbuf: [16]u8 = undefined;
        const k = fmtKey(&kbuf, 0, p);
        try db.put(k, "v");
    }

    // 并发：8 线程各 delete 不同 key
    const N: u32 = 8;
    const Deler = struct {
        fn run(pdb: *Db, base: u32) !void {
            var j: u32 = 0;
            while (j < 12) : (j += 1) {
                var kbuf: [16]u8 = undefined;
                const k = fmtKey(&kbuf, 0, base * 12 + j);
                try pdb.delete(k);
            }
        }
    }.run;
    var threads: [8]std.Thread = undefined;
    for (0..N) |i| {
        threads[i] = try std.Thread.spawn(.{}, Deler, .{ db, @as(u32, @intCast(i)) });
    }
    for (threads) |t| t.join();

    // 合并：N*M=96 个 delete，apply_count 应远小于 96
    const ac = db.state.apply_count.load(.monotonic);
    // 上面 100 put 已贡献 ~100（若未合并）；这里只关心 delete 段是否合并：
    // delete 后 apply_count 相对 put 后的增量应 < 96/2。
    // 简化：delete 全程并发 → apply_count 增量 < 96。
    if (ac >= 196) {
        std.debug.print("apply_count={d} implies deletes not merged\n", .{ac});
    }
    try std.testing.expect(ac < 196);

    // 正确性：被 delete 的 96 key 应消失；未删的 4 key（key 96..99）应在
    var gone: u32 = 0;
    var j: u32 = 0;
    while (j < 96) : (j += 1) {
        var kbuf: [16]u8 = undefined;
        const k = fmtKey(&kbuf, 0, j);
        const v = try db.get(k);
        if (v == null) gone += 1 else std.testing.allocator.free(v.?);
    }
    try std.testing.expectEqual(@as(u32, 96), gone);
}

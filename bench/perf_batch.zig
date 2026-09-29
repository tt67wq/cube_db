const std = @import("std");
const cube = @import("cube_db");

fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const n: usize = 100000;

    var ms = cube.page_store.MemPageStore.init(alloc, 5000000);
    defer ms.deinit();
    var db = try cube.Db.open(alloc, ms.store(), .{});
    defer db.close();

    const entries = try alloc.alloc(cube.Entry, n);
    defer alloc.free(entries);
    for (entries, 0..) |*e, i| {
        e.* = .{ .key = try std.fmt.allocPrint(alloc, "{d:0>10}", .{i}), .value = "v" };
    }
    defer for (entries) |e| alloc.free(e.key);

    const t0 = monoNs();
    try db.putBatch(entries);
    const t1 = monoNs();
    const per_entry = @divFloor(t1 - t0, @as(i64, @intCast(n)));

    std.debug.print("100K putBatch: {d} ms, {d} ns/entry ({d:.2} us/entry), count={d}\n", 
        .{ @divFloor(t1 - t0, 1_000_000), per_entry, @as(f64, @floatFromInt(per_entry)) / 1000.0, db.entryCount() });

    // ===== U5-8 cell: delete-churn -> compactFull (U-65 closing measurement) =====
    // Shape aligned with the U5-1 baseline (put 100k -> delete 90% -> metrics),
    // but with compactFull instead of the O(1) compact(). Machine-readable
    // key=value lines; `file_pages` is the MemPageStore page high-water
    // (`next_free`) — the same file-size proxy the U5-1 baseline used (§3.3:
    // the online path never shrinks the file, so it must NOT go down).
    const sample: usize = 400;
    var keys: [sample][]const u8 = undefined;
    for (&keys, 0..) |*k, i| k.* = entries[90000 + (i * 25) % 10000].key; // survivors live in [90000,100000)

    const getAvg = struct {
        fn run(db_: *cube.Db, ks: []const []const u8) !f64 {
            var total: i64 = 0;
            var hits: usize = 0;
            for (ks) |k| {
                const s = monoNs();
                const v = try db_.get(k);
                const e = monoNs();
                if (v) |vv| {
                    hits += 1;
                    std.heap.page_allocator.free(vv);
                }
                total += e - s;
            }
            std.debug.print("get_hits={d}\n", .{hits});
            return @as(f64, @floatFromInt(@divFloor(total, @as(i64, @intCast(ks.len))))) / 1000.0;
        }
    }.run;

    // delete 90% via one deleteRange over [0, 90000) (the U5-1 range variant)
    const t2 = monoNs();
    try db.deleteRange(entries[0].key, entries[90000].key);
    const t3 = monoNs();
    const ms_stale = ms.next_free;
    const get_tax = try getAvg(db, &keys);
    const sel_stale: usize = blk: {
        var it = try db.select(null, null);
        var cnt: usize = 0;
        while (try it.next()) |_| cnt += 1;
        break :blk cnt;
    };

    const t4 = monoNs();
    const stats = try db.compactFull(.{});
    const t5 = monoNs();
    const ms_after = ms.next_free;
    const get_clean = try getAvg(db, &keys);
    const sel_clean: usize = blk: {
        var it = try db.select(null, null);
        var cnt: usize = 0;
        while (try it.next()) |_| cnt += 1;
        break :blk cnt;
    };

    std.debug.print("churn_compactfull n={d} deleteRange_ms={d:.1}\n", .{ n, @as(f64, @floatFromInt(t3 - t2)) / 1e6 });
    std.debug.print("churn_compactfull before file_pages={d} visible={d} get_avg_us={d:.3}\n", .{ ms_stale, sel_stale, get_tax });
    std.debug.print("churn_compactfull stats entries_copied={d} live_bytes={d} old_pages_retired={d} batches={d} chain_dropped={} compactFull_ms={d:.1}\n", .{ stats.entries_copied, stats.live_bytes, stats.old_pages_retired, stats.batches, stats.chain_dropped, @as(f64, @floatFromInt(t5 - t4)) / 1e6 });
    std.debug.print("churn_compactfull after reclaimed_pages={d} file_pages={d} visible={d} get_avg_us={d:.3}\n", .{ stats.old_pages_retired, ms_after, sel_clean, get_clean });
}

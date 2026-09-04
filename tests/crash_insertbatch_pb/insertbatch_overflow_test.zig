//! insertbatch_overflow_test.zig - #26 regression tests
//! Acceptance tests for the insertBatch leaf-capacity overflow fix
//! Covers: large batches in one leaf range, random distribution, reverse order, duplicate keys
const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const MemPageStore = cube.page_store.MemPageStore;
const testing = std.testing;

fn newStore(mapsize: u32) MemPageStore {
    return MemPageStore.init(testing.allocator, mapsize);
}

// core scenario 1: many keys landing in the same leaf range (contiguous keys, beyond the 32-entries/leaf limit)
test "insertbatch_overflow: 10K sequential keys (dense leaf range)" {
    var ms = newStore(50003);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 10000;
    var keys = try testing.allocator.alloc([]u8, n);
    defer {
        for (keys) |k| testing.allocator.free(k);
        testing.allocator.free(keys);
    }
    for (0..n) |i| {
        keys[i] = try std.fmt.allocPrint(testing.allocator, "{d:0>10}", .{i});
    }

    var entries = try testing.allocator.alloc(cube.Entry, n);
    defer testing.allocator.free(entries);
    for (0..n) |i| {
        entries[i] = .{ .key = keys[i], .value = "v" };
    }

    try db.putBatch(entries);
    try testing.expectEqual(@as(u64, n), db.entryCount());

    for (keys) |k| {
        const v = try db.get(k);
        defer if (v) |val| testing.allocator.free(val);
        try testing.expect(v != null);
    }
}

// core scenario 2: randomly distributed keys (spanning multiple leaves, but one big batch)
test "insertbatch_overflow: 10K random keys in one batch" {
    var ms = newStore(50003);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 10000;
    var prng = std.Random.DefaultPrng.init(0xABCD);
    const rnd = prng.random();

    var keys = try testing.allocator.alloc([]u8, n);
    defer {
        for (keys) |k| testing.allocator.free(k);
        testing.allocator.free(keys);
    }
    for (0..n) |i| {
        keys[i] = try std.fmt.allocPrint(testing.allocator, "k{d:0>10}-{d:0>6}", .{ rnd.uintLessThan(usize, 100000), i });
    }

    var entries = try testing.allocator.alloc(cube.Entry, n);
    defer testing.allocator.free(entries);
    for (0..n) |i| {
        entries[i] = .{ .key = keys[i], .value = "v" };
    }

    try db.putBatch(entries);
    try testing.expectEqual(@as(u64, n), db.entryCount());

    for (keys) |k| {
        const v = try db.get(k);
        defer if (v) |val| testing.allocator.free(val);
        try testing.expect(v != null);
    }
}

// core scenario 3: reverse-ordered keys (key order opposite to insertion order)
test "insertbatch_overflow: 10K reverse-ordered keys" {
    var ms = newStore(50003);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 10000;
    var keys = try testing.allocator.alloc([]u8, n);
    defer {
        for (keys) |k| testing.allocator.free(k);
        testing.allocator.free(keys);
    }
    for (0..n) |i| {
        keys[i] = try std.fmt.allocPrint(testing.allocator, "{d:0>10}", .{n - 1 - i});
    }

    var entries = try testing.allocator.alloc(cube.Entry, n);
    defer testing.allocator.free(entries);
    for (0..n) |i| {
        entries[i] = .{ .key = keys[i], .value = "v" };
    }

    try db.putBatch(entries);
    try testing.expectEqual(@as(u64, n), db.entryCount());

    for (keys) |k| {
        const v = try db.get(k);
        defer if (v) |val| testing.allocator.free(val);
        try testing.expect(v != null);
    }
}

// scenario 4: duplicate keys within one leaf (last write wins)
test "insertbatch_overflow: duplicate keys in batch, last wins" {
    var ms = newStore(50003);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 100;
    const dup: usize = 3;
    var entries = try testing.allocator.alloc(cube.Entry, n * dup);
    defer testing.allocator.free(entries);
    for (0..n) |i| {
        for (0..dup) |d| {
            const idx = i * dup + d;
            entries[idx] = .{
                .key = try std.fmt.allocPrint(testing.allocator, "{d:0>10}", .{i}),
                .value = try std.fmt.allocPrint(testing.allocator, "v{d}", .{d}),
            };
        }
    }
    defer {
        for (entries) |e| {
            testing.allocator.free(e.key);
            testing.allocator.free(e.value);
        }
    }

    try db.putBatch(entries);
    try testing.expectEqual(@as(u64, n), db.entryCount());

    for (0..n) |i| {
        const k = try std.fmt.allocPrint(testing.allocator, "{d:0>10}", .{i});
        defer testing.allocator.free(k);
        const v = try db.get(k);
        defer if (v) |val| testing.allocator.free(val);
        try testing.expect(v != null);
        try testing.expectEqualStrings("v2", v.?);
    }
}

// scenario 5: large batch of sequential keys (10KB values, triggering overflow pages + splits)
test "insertbatch_overflow: 10K sequential keys with 10KB values" {
    // 10KB x 10000 ~ 100MB of data, mapsize must be large enough
    var ms = newStore(300000000);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 10000;
    var big: [10000]u8 = undefined;
    @memset(&big, 'x');

    var keys = try testing.allocator.alloc([]u8, n);
    defer {
        for (keys) |k| testing.allocator.free(k);
        testing.allocator.free(keys);
    }
    var entries = try testing.allocator.alloc(cube.Entry, n);
    defer testing.allocator.free(entries);
    for (0..n) |i| {
        keys[i] = try std.fmt.allocPrint(testing.allocator, "{d:0>10}", .{i});
        entries[i] = .{ .key = keys[i], .value = &big };
    }

    try db.putBatch(entries);
    try testing.expectEqual(@as(u64, n), db.entryCount());

    for (keys[0..100]) |k| {
        const v = try db.get(k);
        defer if (v) |val| testing.allocator.free(val);
        try testing.expect(v != null);
        try testing.expectEqual(@as(usize, 10000), v.?.len);
    }
}

// Adversarial scenario (requested by @archon, closing condition for guard removal):
// 10K entries all in a dense leaf range + a random sequence of mixed tombstones,
// proving multi-split stays correct under the worst-case distribution.
test "insertbatch_overflow: adversarial 10K dense range + mixed tombstones" {
    var ms = newStore(1000000);
    defer ms.deinit();
    var db = try Db.open(testing.allocator, ms.store(), .{});
    defer db.close();

    const n: usize = 10000;
    var keys = try testing.allocator.alloc([]u8, n);
    defer {
        for (keys) |k| testing.allocator.free(k);
        testing.allocator.free(keys);
    }
    // dense range: common prefix + 5-digit suffix, all keys in a very narrow sort interval
    for (0..n) |i| {
        keys[i] = try std.fmt.allocPrint(testing.allocator, "k{d:0>5}", .{i});
    }

    // first batch: all puts
    {
        var entries = try testing.allocator.alloc(cube.Entry, n);
        defer testing.allocator.free(entries);
        for (0..n) |i| {
            entries[i] = .{ .key = keys[i], .value = "v1" };
        }
        try db.putBatch(entries);
        try testing.expectEqual(@as(u64, n), db.entryCount());
    }

    // second batch: random mix of put/delete (50% tombstones), shuffled
    {
        var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
        const rnd = prng.random();

        // shuffled indices
        var idx = try testing.allocator.alloc(usize, n);
        defer testing.allocator.free(idx);
        for (0..n) |i| idx[i] = i;
        rnd.shuffle(usize, idx);

        var entries = try testing.allocator.alloc(cube.Entry, n);
        defer testing.allocator.free(entries);
        for (0..n) |i| {
            const k = idx[i];
            const tombstone = (rnd.uintLessThan(usize, 100) < 50);
            entries[i] = .{
                .key = keys[k],
                .value = if (tombstone) "" else "v2",
                .tombstone = tombstone,
            };
        }
        try db.putBatch(entries);
    }

    // verify: 50% deletes -> ~5000 survivors expected (statistically close, needs exact accounting)
    // more precise approach: replay the same random sequence to compute the expectation
    // use deterministic verification: per-key get, counting survivors
    var live_count: u64 = 0;
    for (keys) |k| {
        const v = try db.get(k);
        defer if (v) |val| testing.allocator.free(val);
        if (v != null) live_count += 1;
    }
    // 50% tombstones -> ~5000 expected; allow a small random deviation (+/-5%)
    const expected: u64 = n / 2;
    try testing.expect(live_count > expected * 95 / 100);
    try testing.expect(live_count < expected * 105 / 100);
    // entryCount must agree with per-key gets
    try testing.expectEqual(live_count, db.entryCount());

    // spot-check: surviving keys' values must be v2 (overwritten by the second batch) or v1 (not overwritten)
    var checked: usize = 0;
    for (keys) |k| {
        const v = try db.get(k);
        defer if (v) |val| testing.allocator.free(val);
        if (v != null) {
            checked += 1;
            try testing.expect(std.mem.eql(u8, v.?, "v1") or std.mem.eql(u8, v.?, "v2"));
        }
    }
    try testing.expectEqual(live_count, checked);
}
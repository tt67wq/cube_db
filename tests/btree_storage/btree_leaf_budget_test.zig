//! btree_leaf_budget_test.zig - T-26: insertIntoLeaf byte-budget overflow (TDD)
//! issues/insert-into-leaf-fast-path-stack-overflow.md:
//! The fast path only checks entry count (LEAF_MAX_ENTRIES=32), not byte size (payload capacity 4068B).
//! 31 legal ~130B full-leaf entries + 1 oversized entry (new_count=32 does not trigger a count split)
//! would @memcpy out of bounds on the fixed 4068B stack buffer. After the fix it should fall back to
//! insertIntoLeafSplit with data intact.
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;
const Db = cube.Db;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(std.testing.allocator, 10000);
}

test "leaf budget: 31x130B full leaf + oversized entry -> split fallback, data intact" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);

    // 31 entries x (10 fixed overhead + 4B key + 116B value) = 130B each,
    // payload = 3 header + 4030 = 4033B <= 4068B -- a legal full leaf.
    var small: [116]u8 = undefined;
    @memset(&small, 'x');
    var i: usize = 0;
    while (i < 31) : (i += 1) {
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>3}", .{i});
        dirty.clearRetainingCapacity();
        root = (try btree.insert(std.testing.allocator, s, root, k, &small, false, &dirty)).new_root;
    }

    // 32nd entry: new_count=32 <= LEAF_MAX_ENTRIES (no count split),
    // but 4033 + (10+4+400) = 4447 > 4068 -> stack overflow when unfixed; takes the split path after the fix.
    var big: [400]u8 = undefined;
    @memset(&big, 'y');
    dirty.clearRetainingCapacity();
    root = (try btree.insert(std.testing.allocator, s, root, "k031", &big, false, &dirty)).new_root;

    // data intact: all 32 keys readable, values correct
    i = 0;
    while (i < 32) : (i += 1) {
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>3}", .{i});
        const v = try btree.get(std.testing.allocator, s, root, k);
        try std.testing.expect(v != null);
        const want: []const u8 = if (i < 31) small[0..] else big[0..];
        try std.testing.expectEqualSlices(u8, want, v.?);
        std.testing.allocator.free(v.?);
    }
}

test "leaf budget: live_delta accounting overhead = 10 (byte_size consistency)" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);
    var acc: i64 = 0;

    // 10 keys (4B), variable-length values
    for (0..10) |i| {
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key{d}", .{i});
        var vbuf: [64]u8 = undefined;
        const vlen = 8 + i * 5;
        @memset(vbuf[0..vlen], 'v');
        dirty.clearRetainingCapacity();
        const wr = try btree.insert(std.testing.allocator, s, root, k, vbuf[0..vlen], false, &dirty);
        root = wr.new_root;
        acc += wr.live_delta;
    }
    // overwrite key3 (value 100B)
    {
        var vbuf: [128]u8 = undefined;
        @memset(vbuf[0..100], 'w');
        dirty.clearRetainingCapacity();
        const wr = try btree.insert(std.testing.allocator, s, root, "key3", vbuf[0..100], false, &dirty);
        root = wr.new_root;
        acc += wr.live_delta;
    }
    // delete key5 (tombstone: value counted as 0, key kept in the leaf)
    {
        dirty.clearRetainingCapacity();
        const wr = try btree.insert(std.testing.allocator, s, root, "key5", "", true, &dirty);
        root = wr.new_root;
        acc += wr.live_delta;
    }

    // compute independently per entry: 10 + key.len + value.len each (tombstone value=0),
    // consistent with leafPayloadSize accounting (the original implementation used fixed overhead 9, undercounting 1B per entry).
    var expected: i64 = 0;
    for (0..10) |i| {
        const vlen: i64 = if (i == 3) 100 else if (i == 5) 0 else @intCast(8 + i * 5);
        expected += 10 + 4 + vlen;
    }
    try std.testing.expectEqual(expected, acc);

    // data integrity spot-check
    const v3 = try btree.get(std.testing.allocator, s, root, "key3");
    try std.testing.expectEqual(@as(usize, 100), v3.?.len);
    std.testing.allocator.free(v3.?);
    const v5 = try btree.get(std.testing.allocator, s, root, "key5");
    try std.testing.expect(v5 == null);
}

// ---- T-26 review finding 1: found + old_is_overflow + byte-budget fallback -> dirty double free ----

test "leaf budget: overwrite overflow entry hitting byte-budget fallback -> dirty no dup pages, no corruption" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);

    // 30 x (10+4+100)=114B inline + 1 5000B overflow entry (10+4+4=18B in the leaf)
    // payload = 3 + 3420 + 18 = 3441B <= 4068 -- a legal full leaf (31 entries)
    var v100: [100]u8 = undefined;
    @memset(&v100, 'x');
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>3}", .{i});
        dirty.clearRetainingCapacity();
        root = (try btree.insert(std.testing.allocator, s, root, k, &v100, false, &dirty)).new_root;
    }
    var ov: [5000]u8 = undefined;
    @memset(&ov, 'o');
    dirty.clearRetainingCapacity();
    root = (try btree.insert(std.testing.allocator, s, root, "k030", &ov, false, &dirty)).new_root;

    // overwrite the overflow entry with a 700B inline value: found=true, old_is_overflow=true,
    // 3 + 3420 + (10+4+700) = 4137 > 4068 -> byte-budget fallback to split.
    // Before the fix: insertIntoLeaf first called freeOverflowPages on the old chain, then split's
    // fromPayload freed again -> duplicate page numbers in dirty -> freelist double allocation -> page aliasing corruption.
    var v700: [700]u8 = undefined;
    @memset(&v700, 'y');
    dirty.clearRetainingCapacity();
    root = (try btree.insert(std.testing.allocator, s, root, "k030", &v700, false, &dirty)).new_root;

    // dirty has no duplicate page numbers
    for (dirty.items, 0..) |pn, idx| {
        for (dirty.items[idx + 1 ..]) |pn2| {
            try std.testing.expect(pn != pn2);
        }
    }

    // simulate the writer: freePage all of dirty, keep inserting 400 entries, assert no page aliasing corruption
    for (dirty.items) |pn| s.freePage(pn);
    i = 0;
    while (i < 400) : (i += 1) {
        var kbuf: [12]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "m{d:0>5}", .{i});
        dirty.clearRetainingCapacity();
        root = (try btree.insert(std.testing.allocator, s, root, k, "v", false, &dirty)).new_root;
    }

    // full verification: 30 old inline + overwritten value + 400 new keys
    i = 0;
    while (i < 30) : (i += 1) {
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>3}", .{i});
        const v = try btree.get(std.testing.allocator, s, root, k);
        try std.testing.expect(v != null);
        try std.testing.expectEqualSlices(u8, &v100, v.?);
        std.testing.allocator.free(v.?);
    }
    {
        const v = try btree.get(std.testing.allocator, s, root, "k030");
        try std.testing.expect(v != null);
        try std.testing.expectEqualSlices(u8, &v700, v.?);
        std.testing.allocator.free(v.?);
    }
    i = 0;
    while (i < 400) : (i += 1) {
        var kbuf: [12]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "m{d:0>5}", .{i});
        const v = try btree.get(std.testing.allocator, s, root, k);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings("v", v.?);
        std.testing.allocator.free(v.?);
    }
}


// ---- T-26 review finding 2: insertBatchIntoLeaf tail-append loop live_delta accounting ----

test "leaf budget: putBatch ordered append byte_size == per-entry sum (overhead 10)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var expected: u64 = 0;

    // first batch: empty tree (insertBatchFresh path)
    {
        var entries: [20]cube.Entry = undefined;
        var kbufs: [20][8]u8 = undefined;
        var vbufs: [20][64]u8 = undefined;
        for (0..20) |i| {
            const k = try std.fmt.bufPrint(&kbufs[i], "a{d:0>3}", .{i});
            const vlen = 10 + i;
            @memset(vbufs[i][0..vlen], 'v');
            entries[i] = .{ .key = k, .value = vbufs[i][0..vlen] };
            expected += 10 + k.len + vlen;
        }
        try db.putBatch(&entries);
    }

    // second batch: all keys greater than existing in-leaf keys ("b*" > "a*") and sorted within the batch ->
    // the "Remaining batch entries" tail loop of insertBatchIntoLeaf merge
    // (originally still +9, undercounting 1B per entry)
    {
        var entries: [30]cube.Entry = undefined;
        var kbufs: [30][8]u8 = undefined;
        var vbufs: [30][64]u8 = undefined;
        for (0..30) |i| {
            const k = try std.fmt.bufPrint(&kbufs[i], "b{d:0>3}", .{i});
            const vlen = 10 + i;
            @memset(vbufs[i][0..vlen], 'w');
            entries[i] = .{ .key = k, .value = vbufs[i][0..vlen] };
            expected += 10 + k.len + vlen;
        }
        try db.putBatch(&entries);
    }

    try std.testing.expectEqual(@as(u64, 50), db.entryCount());
    try std.testing.expectEqual(expected, db.state.byte_size.load(.acquire));

    // data spot-check
    const va = try db.get("a000");
    try std.testing.expectEqual(@as(usize, 10), va.?.len);
    std.testing.allocator.free(va.?);
    const vb = try db.get("b029");
    try std.testing.expectEqual(@as(usize, 39), vb.?.len);
    std.testing.allocator.free(vb.?);
}

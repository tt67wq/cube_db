//! binary_search_test.zig — TDD: binary search optimization for read path
//! Tests that get/getBorrowed return correct results after switching
//! from linear scan to binary search in leaf/branch lookup.
//! Also tests optional CRC skip for read path performance.
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;
const Db = cube.Db;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(std.testing.allocator, 100000);
}

// ---- Correctness: get works after binary search ----

test "bsearch: get on single-entry leaf" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);
    root = (try btree.insert(std.testing.allocator, s, root, "k", "v", false, &dirty)).new_root;
    const v = try btree.get(std.testing.allocator, s, root, "k");
    try std.testing.expectEqualStrings("v", v.?);
    std.testing.allocator.free(v.?);
}

test "bsearch: get on full leaf (32 entries)" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        dirty.clearRetainingCapacity();
        root = (try btree.insert(std.testing.allocator, s, root, k, "val", false, &dirty)).new_root;
    }
    // Read every key
    i = 0;
    while (i < 32) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        const v = try btree.get(std.testing.allocator, s, root, k);
        try std.testing.expectEqualStrings("val", v.?);
        std.testing.allocator.free(v.?);
    }
    // Misses
    const miss = try btree.get(std.testing.allocator, s, root, "key_0099");
    try std.testing.expectEqual(@as(?[]u8, null), miss);
    const miss2 = try btree.get(std.testing.allocator, s, root, "aaa");
    try std.testing.expectEqual(@as(?[]u8, null), miss2);
    const miss3 = try btree.get(std.testing.allocator, s, root, "zzz");
    try std.testing.expectEqual(@as(?[]u8, null), miss3);
}

test "bsearch: getBorrowed on multi-level tree (depth 3+)" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);
    var i: u32 = 0;
    while (i < 3000) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{i});
        dirty.clearRetainingCapacity();
        root = (try btree.insert(std.testing.allocator, s, root, k, "v", false, &dirty)).new_root;
    }
    // Spot check
    const checks = [_]u32{ 0, 1, 42, 999, 1500, 2999 };
    for (checks) |idx| {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{idx});
        const v = try btree.getBorrowed(s, root, k);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings("v", v.?);
    }
    // Misses
    const miss = try btree.getBorrowed(s, root, "k999999");
    try std.testing.expectEqual(@as(?[]const u8, null), miss);
    const miss2 = try btree.getBorrowed(s, root, "a");
    try std.testing.expectEqual(@as(?[]const u8, null), miss2);
}

test "bsearch: first and last key in leaf" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);
    const keys = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel" };
    for (keys) |k| {
        dirty.clearRetainingCapacity();
        root = (try btree.insert(std.testing.allocator, s, root, k, "v", false, &dirty)).new_root;
    }
    // First
    const v0 = try btree.get(std.testing.allocator, s, root, "alpha");
    try std.testing.expectEqualStrings("v", v0.?);
    std.testing.allocator.free(v0.?);
    // Last
    const v7 = try btree.get(std.testing.allocator, s, root, "hotel");
    try std.testing.expectEqualStrings("v", v7.?);
    std.testing.allocator.free(v7.?);
    // Just before first
    const miss_before = try btree.get(std.testing.allocator, s, root, "aaa");
    try std.testing.expectEqual(@as(?[]u8, null), miss_before);
    // Just after last
    const miss_after = try btree.get(std.testing.allocator, s, root, "india");
    try std.testing.expectEqual(@as(?[]u8, null), miss_after);
}

test "bsearch: random model test (1000 ops, seed 42)" {
    const allocator = std.testing.allocator;
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree.NULL_ROOT;
    var model = std.StringHashMap([]u8).init(allocator);
    defer {
        var it = model.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        model.deinit();
    }
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var kbuf: [8]u8 = undefined;
        const klen = 3 + rnd.uintLessThan(usize, 4);
        for (0..klen) |j| kbuf[j] = 'a' + rnd.uintLessThan(u8, 10);
        const key = kbuf[0..klen];
        dirty.clearRetainingCapacity();
        if (rnd.boolean()) {
            const wr = try btree.insert(allocator, s, root, key, "V", false, &dirty);
            root = wr.new_root;
            const gop = try model.getOrPut(key);
            if (gop.found_existing) {
                allocator.free(gop.value_ptr.*);
            } else {
                gop.key_ptr.* = try allocator.dupe(u8, key);
            }
            gop.value_ptr.* = try allocator.dupe(u8, "V");
        } else {
            const wr = try btree.insert(allocator, s, root, key, "", true, &dirty);
            root = wr.new_root;
            if (model.fetchRemove(key)) |kv| {
                allocator.free(kv.key);
                allocator.free(kv.value);
            }
        }
        // Verify
        const mv = model.get(key);
        const bv = try btree.get(allocator, s, root, key);
        if (mv == null) {
            try std.testing.expect(bv == null);
        } else {
            try std.testing.expect(bv != null);
            try std.testing.expectEqualStrings(mv.?, bv.?);
            allocator.free(bv.?);
        }
    }
}

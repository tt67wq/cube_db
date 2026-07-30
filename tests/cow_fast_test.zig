//! cow_fast_test.zig — Phase 2 TDD: in-place page COW fast path
//! Tests that the COW write path produces correct results when the
//! fast path (page copy + patch) is used for branch and leaf nodes
//! that don't split. These tests must pass both before and after the
//! optimization — they verify behavioral correctness, not impl details.
const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const ps = cube.page_store;
const btree = cube.btree;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(std.testing.allocator, 100000);
}

// ---- Test 1: multi-level B-tree, overwrite leaf without split ----
// Build a tree deep enough to have branch nodes (depth ≥ 2),
// then overwrite an existing key. The leaf won't split (entry count stays same).
// Verifies the in-place leaf COW path: new page has correct entry,
// old root still sees old value (COW).
test "cow_fast: overwrite in multi-level tree, no leaf split" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);

    // Insert enough keys to create at least 2 levels (LEAF_MAX_ENTRIES=32)
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        dirty.clearRetainingCapacity();
        root = (try btree.insert(std.testing.allocator, s, root, k, "val_old", false, &dirty)).new_root;
    }

    // Snapshot old root for COW verification
    const old_root = root;

    // Overwrite key_0025 (middle of tree, leaf won't split — entry count unchanged)
    dirty.clearRetainingCapacity();
    root = (try btree.insert(std.testing.allocator, s, root, "key_0025", "val_new", false, &dirty)).new_root;

    // New root must be different (COW created new pages)
    try std.testing.expect(old_root != root);

    // New root sees new value
    const newv = try btree.get(std.testing.allocator, s, root, "key_0025");
    try std.testing.expectEqualStrings("val_new", newv.?);
    std.testing.allocator.free(newv.?);

    // Old root still sees old value (COW)
    const oldv = try btree.get(std.testing.allocator, s, old_root, "key_0025");
    try std.testing.expectEqualStrings("val_old", oldv.?);
    std.testing.allocator.free(oldv.?);

    // All other keys still readable from new root
    i = 0;
    while (i < 50) : (i += 1) {
        if (i == 25) continue;
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        const v = try btree.get(std.testing.allocator, s, root, k);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings("val_old", v.?);
        std.testing.allocator.free(v.?);
    }
}

// ---- Test 2: multi-level B-tree, insert new key into full-ish leaf ----
// Insert keys that cause leaf split, then insert one more key into
// a non-full leaf. Verifies the in-place leaf insert path.
test "cow_fast: insert into non-full leaf in multi-level tree" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);

    // Insert 40 keys to create multiple leaves + branch level
    var i: u32 = 0;
    while (i < 40) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        dirty.clearRetainingCapacity();
        root = (try btree.insert(std.testing.allocator, s, root, k, "v", false, &dirty)).new_root;
    }

    // Insert a key that goes between existing keys (no split needed, leaf has room)
    dirty.clearRetainingCapacity();
    root = (try btree.insert(std.testing.allocator, s, root, "key_0000a", "inserted", false, &dirty)).new_root;

    // Verify the inserted key
    const v = try btree.get(std.testing.allocator, s, root, "key_0000a");
    try std.testing.expectEqualStrings("inserted", v.?);
    std.testing.allocator.free(v.?);

    // Verify all original keys still readable
    i = 0;
    while (i < 40) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        const v2 = try btree.get(std.testing.allocator, s, root, k);
        try std.testing.expect(v2 != null);
        try std.testing.expectEqualStrings("v", v2.?);
        std.testing.allocator.free(v2.?);
    }
}

// ---- Test 3: branch child pointer update (depth ≥ 3) ----
// Build a tree with depth ≥ 3 (root branch → mid branch → leaf),
// then overwrite a key. The branch nodes at all levels should get
// their child pointers updated correctly via the fast path.
test "cow_fast: branch child update at depth 3" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);

    // Need depth 3: root branch → mid branches → leaves
    // LEAF_MAX_ENTRIES=32, BRANCH_MAX_CHILDREN=64
    // 32 * 64 = 2048 keys minimum for depth 3
    // But with splits, ~2000 should suffice. Let's do 3000 for safety.
    var i: u32 = 0;
    while (i < 3000) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{i});
        dirty.clearRetainingCapacity();
        root = (try btree.insert(std.testing.allocator, s, root, k, "v", false, &dirty)).new_root;
    }

    // Overwrite a key in the middle
    const old_root = root;
    dirty.clearRetainingCapacity();
    root = (try btree.insert(std.testing.allocator, s, root, "k001500", "newval", false, &dirty)).new_root;

    // COW: old root sees old value
    const oldv = try btree.get(std.testing.allocator, s, old_root, "k001500");
    try std.testing.expectEqualStrings("v", oldv.?);
    std.testing.allocator.free(oldv.?);

    // New root sees new value
    const newv = try btree.get(std.testing.allocator, s, root, "k001500");
    try std.testing.expectEqualStrings("newval", newv.?);
    std.testing.allocator.free(newv.?);

    // Spot-check other keys
    const checks = [_]u32{ 0, 1, 42, 999, 1501, 2999 };
    for (checks) |idx| {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>6}", .{idx});
        const v = try btree.get(std.testing.allocator, s, root, k);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings("v", v.?);
        std.testing.allocator.free(v.?);
    }
}

// ---- Test 4: delete in multi-level tree (tombstone, no split) ----
test "cow_fast: delete (tombstone) in multi-level tree, no split" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    var root: u32 = btree.NULL_ROOT;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(std.testing.allocator);

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        dirty.clearRetainingCapacity();
        root = (try btree.insert(std.testing.allocator, s, root, k, "v", false, &dirty)).new_root;
    }

    // Delete key_0050
    dirty.clearRetainingCapacity();
    root = (try btree.insert(std.testing.allocator, s, root, "key_0050", "", true, &dirty)).new_root;

    // Deleted key returns null
    const v = try btree.get(std.testing.allocator, s, root, "key_0050");
    try std.testing.expectEqual(@as(?[]u8, null), v);

    // Other keys still readable
    i = 0;
    while (i < 100) : (i += 1) {
        if (i == 50) continue;
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key_{d:0>4}", .{i});
        const v2 = try btree.get(std.testing.allocator, s, root, k);
        try std.testing.expect(v2 != null);
        std.testing.allocator.free(v2.?);
    }
}

// ---- Test 5: model test with many overwrites (exercises fast path heavily) ----
test "cow_fast: 1000 random put/overwrite/delete vs model (seed 99)" {
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
    var prng = std.Random.DefaultPrng.init(99);
    const rnd = prng.random();
    const ops = 1000;
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);
    var i: usize = 0;
    while (i < ops) : (i += 1) {
        // Keys from a small space so we get many overwrites/deletes
        var kbuf: [8]u8 = undefined;
        const klen = 3 + rnd.uintLessThan(usize, 4);
        for (0..klen) |j| kbuf[j] = 'a' + rnd.uintLessThan(u8, 10);
        const key = kbuf[0..klen];
        dirty.clearRetainingCapacity();
        if (rnd.boolean()) {
            const val = try allocator.dupe(u8, "V");
            const wr = try btree.insert(allocator, s, root, key, val, false, &dirty);
            root = wr.new_root;
            allocator.free(val);
            const gop = try model.getOrPut(key);
            if (gop.found_existing) {
                allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = try allocator.dupe(u8, "V");
            } else {
                gop.key_ptr.* = try allocator.dupe(u8, key);
                gop.value_ptr.* = try allocator.dupe(u8, "V");
            }
        } else {
            const wr = try btree.insert(allocator, s, root, key, "", true, &dirty);
            root = wr.new_root;
            if (model.fetchRemove(key)) |kv| {
                allocator.free(kv.key);
                allocator.free(kv.value);
            }
        }
        // Verify this key
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
    // Full count comparison
    var it = try btree.select(allocator, s, root, null, null);
    defer it.deinit();
    var bcount: usize = 0;
    while (try it.next()) |_| bcount += 1;
    try std.testing.expectEqual(model.count(), bcount);
}

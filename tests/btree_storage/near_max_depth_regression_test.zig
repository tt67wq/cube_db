//! near_max_depth_regression_test.zig — T-44: near-MAX key depth ratchet regression.
//!
//! Issue T-44: with keys near MAX_KEY_SIZE (leaf holds 1 entry, branch holds ~2
//! children), the single-insert and one-by-one batch paths used to deepen the
//! tree by +1 per write (staircase ratchet via promote_orphan mixing page
//! heights into splices). After ~64 writes the depth passed Iterator.MAX_DEPTH
//! and select/deleteRange failed with error.Truncated (point get still worked).
//! The bulk batch-all path was always balanced.
//!
//! RED shape (deterministic, from the T-43 review probe): 4000B keys — a leaf
//! fits exactly 1 entry (4014B <= 4068 cap, 2 entries = 8025B > cap) and a
//! branch fits exactly 2 children (4015B <= cap, 3 = 8023B > cap).
//!
//! Assertions (GREEN): depth <= 2*ceil(log2(n)) + 4 for n > 64 near-MAX keys
//! written ONE AT A TIME via btree.insert AND via one-entry btree.insertBatch
//! (the putBatch micro-batch shape); select reads back every entry in order
//! with exact content; Db-level put + deleteRange + select stays readable.
//! Control: N=5000 small keys keep depth <= 4 (T-37-B invariant intact; the
//! fix must not disturb the normal-key shape).
//!
//! Wiring: comptime-imported from btree_test.zig into the test-btree step.

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;
const dbi = cube.db;

const alloc = std.testing.allocator;

const KLEN = 4000; // near-MAX: 1 entry/leaf, 2 children/branch
const N = 130; // > 64 (Iterator.MAX_DEPTH) — RED depth was exactly n

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 2_000_000);
}

/// 8-digit decimal prefix (lexicographic == numeric) + fixed pad: distinct,
/// deterministically ordered keys of exact byte length.
fn keyInto(buf: []u8, i: usize, len: usize) []const u8 {
    @memset(buf, 'x');
    _ = std.fmt.bufPrint(buf[0..8], "{d:0>8}", .{i}) catch unreachable;
    return buf[0..len];
}

fn depthBound(n: usize) usize {
    // O(log n) with constant slack: 2*ceil(log2 n) + 4.
    // For n=130: 20 (RED was 130; balanced batch-all is ~9).
    var ceil_log2: usize = 0;
    while ((@as(usize, 1) << @intCast(ceil_log2)) < n) ceil_log2 += 1;
    return 2 * ceil_log2 + 4;
}

/// Read back every entry, assert exact key content, ascending order, values.
fn expectFullReadback(root: u32, store: ps.PageStore, bufs: [][]const u8) !void {
    var it = try btree.select(alloc, store, root, null, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |e| {
        try std.testing.expect(n < bufs.len);
        try std.testing.expectEqualSlices(u8, bufs[n], e.key);
        try std.testing.expectEqualSlices(u8, "v", e.value);
        n += 1;
    }
    try std.testing.expectEqual(bufs.len, n);
}

// ===== 1. single-insert path (btree.insert) =====

test "T-44: single insert of near-MAX keys keeps depth O(log n) (n>64)" {
    var ms = newStore();
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(alloc);

    var root = btree.NULL_ROOT;
    const bufs = try alloc.alloc([KLEN]u8, N);
    defer alloc.free(bufs);
    const keys = try alloc.alloc([]const u8, N);
    defer alloc.free(keys);
    for (0..N) |i| {
        keys[i] = keyInto(&bufs[i], i, KLEN);
        const wr = try btree.insert(alloc, ms.store(), root, keys[i], "v", false, &dirty);
        root = wr.new_root;
    }

    // Depth bound: RED measured depth == n == 130 (linear ratchet).
    const depth = btree.treeDepth(ms.store(), root);
    if (depth > depthBound(N)) {
        std.debug.print("\n[T-44 RED] single-insert depth={d} > bound={d} (linear ratchet)\n", .{ depth, depthBound(N) });
        return error.DepthRatchet;
    }
    try expectFullReadback(root, ms.store(), keys);
}

// ===== 2. one-by-one batch path (putBatch micro-batch shape) =====

test "T-44: one-by-one batch insert of near-MAX keys keeps depth O(log n)" {
    var ms = newStore();
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(alloc);

    var root = btree.NULL_ROOT;
    const bufs = try alloc.alloc([KLEN]u8, N);
    defer alloc.free(bufs);
    const keys = try alloc.alloc([]const u8, N);
    defer alloc.free(keys);
    for (0..N) |i| {
        keys[i] = keyInto(&bufs[i], i, KLEN);
        var one: [1]btree.LeafEntry = .{.{ .tombstone = false, .key = keys[i], .value = "v" }};
        const wr = try btree.insertBatch(alloc, ms.store(), root, &one, &dirty);
        root = wr.new_root;
    }

    const depth = btree.treeDepth(ms.store(), root);
    if (depth > depthBound(N)) {
        std.debug.print("\n[T-44 RED] batch-1-by-1 depth={d} > bound={d} (linear ratchet)\n", .{ depth, depthBound(N) });
        return error.DepthRatchet;
    }
    try expectFullReadback(root, ms.store(), keys);
}

// ===== 3. small-key control: the fix must not disturb the normal-key shape =====

test "T-44: small-key control (N=5000) keeps depth bounded (T-37-B intact)" {
    var ms = newStore();
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(alloc);

    const N_SMALL = 5000;
    var root = btree.NULL_ROOT;
    var kbufs: [N_SMALL][10]u8 = undefined;
    for (0..N_SMALL) |i| {
        const k = std.fmt.bufPrint(&kbufs[i], "{d:0>10}", .{i}) catch unreachable;
        const wr = try btree.insert(alloc, ms.store(), root, k, "v", false, &dirty);
        root = wr.new_root;
    }
    // Pre-fix measured depth = 3 (fanout 64: ceil(log_64(157)) = 2 + slack).
    const depth = btree.treeDepth(ms.store(), root);
    try std.testing.expect(depth <= 4);

    var it = try btree.select(alloc, ms.store(), root, null, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, N_SMALL), n);
}

// ===== 4. Db-level: put + deleteRange + select stay readable after churn =====

test "T-44: Db put + deleteRange + select with near-MAX keys (n>64)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), .{});
    defer db.close();

    const N_DB = 80; // > 64
    const bufs = try alloc.alloc([KLEN]u8, N_DB);
    defer alloc.free(bufs);
    for (0..N_DB) |i| {
        try db.put(keyInto(&bufs[i], i, KLEN), "v");
    }

    // deleteRange over a middle band [10, 20)
    var lo: [KLEN]u8 = undefined;
    var hi: [KLEN]u8 = undefined;
    try db.deleteRange(keyInto(&lo, 10, KLEN), keyInto(&hi, 20, KLEN));

    var it = try db.select(null, null);
    defer it.deinit();
    var n: usize = 0;
    var last: ?[]const u8 = null;
    while (try it.next()) |e| {
        if (last) |p| try std.testing.expect(std.mem.order(u8, p, e.key) == .lt);
        last = e.key;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, N_DB - 10), n);

    // spot-check: a deleted key is gone, kept keys on both sides survive
    try std.testing.expectEqual(@as(?[]u8, null), try db.get(keyInto(&lo, 15, KLEN)));
    const v = try db.get(keyInto(&lo, 5, KLEN));
    try std.testing.expect(v != null);
    alloc.free(v.?);
    const v2 = try db.get(keyInto(&lo, 70, KLEN));
    try std.testing.expect(v2 != null);
    alloc.free(v2.?);
}
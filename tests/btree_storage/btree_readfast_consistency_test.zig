//! btree_readfast_consistency_test.zig - T-17: readNodePayloadFast vs readNodePayload consistency
//!
//! src/btree.zig:49 readNodePayloadFast skips CRC verification (hot read path); readNodePayload (:39) verifies CRC.
//! Comments claim COW guarantees make verification unnecessary, but no test proved fast and full reads agree.
//! This file builds leaf/branch/overflow/full-leaf pages and asserts both return byte-identical payloads (std.mem.eql).
//!
//! readNodePayload / readNodePayloadFast / writeNodePage are all pub; build pages directly and compare double reads.
//! Hookup: comptime block in tests/btree_storage/btree_test.zig.

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const ps = cube.page_store;
const btree = cube.btree;

const allocator = std.testing.allocator;

fn newStore(n: u32) ps.MemPageStore {
    return ps.MemPageStore.init(allocator, n);
}

/// Build a valid leaf payload (1 entry, inline value, no overflow) into buf, return the actual length
fn buildLeafPayload(buf: []u8, key: []const u8, value: []const u8) !usize {
    var ms = ps.MemPageStore.init(allocator, 64);
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);
    const entries = [_]btree.LeafEntry{
        .{ .tombstone = false, .key = key, .value = value },
    };
    return try btree.encodeLeafPayload(buf, &entries, ms.store(), &dirty);
}

/// Build a valid branch payload (n children) into buf, return the actual length
fn buildBranchPayload(buf: []u8, n_children: u32) usize {
    // n children, n-1 keys "m0","m1"...
    var keys: [8][]const u8 = .{ "k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7" };
    var children: [9]u32 = .{ 10, 20, 30, 40, 50, 60, 70, 80, 90 };
    return btree.encodeBranchPayload(buf, keys[0 .. n_children - 1], children[0..n_children]);
}

/// Double-read the same page, assert the payload slices are byte-identical
fn assertFastEqFull(store: ps.PageStore, page_no: u32) !void {
    const slow = try btree.readNodePayload(store, page_no);
    const fast = try btree.readNodePayloadFast(store, page_no);
    // the same page should return equal-length payloads (both [HEADER_SIZE..PAGE_SIZE-4])
    try std.testing.expectEqual(slow.len, fast.len);
    try std.testing.expect(std.mem.eql(u8, slow, fast));
}

test "readfast: leaf page payload consistent" {
    var ms = newStore(64);
    defer ms.deinit();
    const s = ms.store();

    var payload_buf: [f2.PAGE_SIZE]u8 = undefined;
    const pl = try buildLeafPayload(&payload_buf, "key1", "val1");
    const pn = try s.allocPage();
    try btree.writeNodePage(s, pn, f2.PAGE_TYPE_LEAF, 1, payload_buf[0..pl]);

    try assertFastEqFull(s, pn);
}

test "readfast: full-ish leaf page payload consistent" {
    // near-full leaf: multiple entries push the payload close to the limit. LEAF_MAX_ENTRIES=32,
    // fill with 32 short key/values (leafPayloadSize approaches PAGE_SIZE-28-4).
    var ms = newStore(64);
    defer ms.deinit();
    const s = ms.store();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    // build 32 entries (close to LEAF_MAX_ENTRIES)
    var entries: [32]btree.LeafEntry = undefined;
    var kbufs: [32][4]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const k = try std.fmt.bufPrint(&kbufs[i], "k{d:0>2}", .{i});
        entries[i] = .{ .tombstone = false, .key = k, .value = "v" };
    }
    var payload_buf: [f2.PAGE_SIZE]u8 = undefined;
    const pl = try btree.encodeLeafPayload(&payload_buf, &entries, s, &dirty);
    try std.testing.expect(pl > 100); // content really written

    const pn = try s.allocPage();
    try btree.writeNodePage(s, pn, f2.PAGE_TYPE_LEAF, @intCast(entries.len), payload_buf[0..pl]);

    try assertFastEqFull(s, pn);
}

test "readfast: branch page payload consistent" {
    var ms = newStore(64);
    defer ms.deinit();
    const s = ms.store();

    var payload_buf: [f2.PAGE_SIZE]u8 = undefined;
    const pl = buildBranchPayload(&payload_buf, 5); // 5 children, 4 keys
    const pn = try s.allocPage();
    try btree.writeNodePage(s, pn, f2.PAGE_TYPE_BRANCH, 5, payload_buf[0..pl]);

    try assertFastEqFull(s, pn);
}

test "readfast: overflow page payload consistent" {
    // overflow page: raw data chunk as payload, page_type=OVERFLOW
    var ms = newStore(64);
    defer ms.deinit();
    const s = ms.store();

    var chunk: [4068]u8 = undefined; // OVERFLOW_PAYLOAD = PAGE_SIZE-24-4 = 4068
    var i: usize = 0;
    while (i < chunk.len) : (i += 1) chunk[i] = @intCast(i % 251);

    const pn = try s.allocPage();
    try btree.writeNodePage(s, pn, f2.PAGE_TYPE_OVERFLOW, 0, &chunk);

    try assertFastEqFull(s, pn);

    // extra assertion: overflow payload content matches the written chunk (both fast and full agree)
    const fast = try btree.readNodePayloadFast(s, pn);
    try std.testing.expect(std.mem.eql(u8, &chunk, fast[0..chunk.len]));
}

test "readfast: multiple pages in a tree all consistent" {
    // Build a multi-page btree (inserting many keys triggers leaf split + branch), double-read the root
    // and several pages (verifying page consistency of a real COW tree, not just hand-built pages)
    var ms = newStore(10000);
    defer ms.deinit();
    const s = ms.store();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    var root: u32 = btree.NULL_ROOT;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key{d:0>3}", .{i});
        const wr = try btree.insert(allocator, s, root, k, "val", false, &dirty);
        root = wr.new_root;
    }
    try std.testing.expect(root != btree.NULL_ROOT);

    // root page (branch or leaf) double-read consistent
    try assertFastEqFull(s, root);

    // pages in the dirty list (COW old/new pages) should also double-read consistently
    for (dirty.items, 0..) |pn, idx| {
        if (idx >= 8) break; // spot-check the first 8 pages
        try assertFastEqFull(s, pn);
    }
}

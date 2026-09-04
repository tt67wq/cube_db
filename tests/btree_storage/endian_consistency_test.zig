//! endian_consistency_test.zig - T-8: btree payload endianness consistency (TDD red stage)
//!
//! src/btree.zig currently writes leaf/branch payload count/klen/vlen/children fields with
//! `.big` (37 sites) while overflow page numbers use `.little` (6 sites). The goal is to unify everything on `.little`.
//!
//! This is the TDD red stage: the tests assert these fields read correctly via `.little`. The source
//! has not been changed yet, so the first 3 categories (leaf count / leaf klen vlen / branch children) FAIL,
//! while the 4th category (overflow page number, already .little) PASSES as a control.
//!
//! T-9 (green stage) will change the 37 .big sites to .little, at which point everything goes green.
//! Hookup: comptime @import of this file at the end of tests/btree_storage/btree_test.zig.

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const ps = cube.page_store;
const btree = cube.btree;

const allocator = std.testing.allocator;

/// Build a payload with 1 inline leaf entry, return (buf, actual length)
fn buildLeafPayload(buf: []u8) !usize {
    var ms = ps.MemPageStore.init(allocator, 64);
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);
    const entries = [_]btree.LeafEntry{
        .{ .tombstone = false, .key = "key1", .value = "val1" },
    };
    return try btree.encodeLeafPayload(buf, &entries, ms.store(), &dirty);
}

/// Build a payload with 1 overflow leaf entry, return (buf, actual length)
fn buildOverflowLeafPayload(buf: []u8) !usize {
    var ms = ps.MemPageStore.init(allocator, 64);
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);
    // > MAX_INLINE_VALUE(3800) triggers an overflow page
    var big: [4000]u8 = undefined;
    @memset(&big, 0xAB);
    const entries = [_]btree.LeafEntry{
        .{ .tombstone = false, .key = "k", .value = &big },
    };
    return try btree.encodeLeafPayload(buf, &entries, ms.store(), &dirty);
}

/// Build a branch payload (3 children, 2 keys), return the actual length
fn buildBranchPayload(buf: []u8) usize {
    const keys = [_][]const u8{ "m", "q" };
    const children = [_]u32{ 10, 20, 30 };
    return btree.encodeBranchPayload(buf, &keys, &children);
}

test "endian: leaf count field is little-endian" {
    // Red stage: encodeLeafPayload currently writes count(=1) with .big.
    // .big -> bytes [0x00, 0x01]; reading .little -> 0x0100 = 256 != 1 -> FAIL (expected red)
    var buf: [f2.PAGE_SIZE]u8 = undefined;
    _ = try buildLeafPayload(&buf);
    // count is at offset 1 (byte[0]=LEAF_KIND)
    const got_little = std.mem.readInt(u16, buf[1..3], .little);
    try std.testing.expectEqual(@as(u16, 1), got_little);
}

test "endian: leaf klen field is little-endian" {
    // Red stage: klen(=4, "key1") written with .big -> bytes [0x00,0x00,0x00,0x04]
    // reading .little -> 0x04000000 != 4 -> FAIL (expected red)
    var buf: [f2.PAGE_SIZE]u8 = undefined;
    _ = try buildLeafPayload(&buf);
    // layout: kind(1) + count(2) + tombstone(1) + klen(4) -> klen at offset 4
    const got_little = std.mem.readInt(u32, buf[4..8], .little);
    try std.testing.expectEqual(@as(u32, 4), got_little); // "key1".len
}

test "endian: leaf vlen field is little-endian" {
    // Red stage: vlen(=4, "val1") written with .big -> reading .little gives 0x04000000 != 4 -> FAIL
    var buf: [f2.PAGE_SIZE]u8 = undefined;
    _ = try buildLeafPayload(&buf);
    // layout: kind(1)+count(2)+tombstone(1)+klen(4)+key(4)+vlen(4) -> vlen at offset 12
    const got_little = std.mem.readInt(u32, buf[12..16], .little);
    try std.testing.expectEqual(@as(u32, 4), got_little); // "val1".len
}

test "endian: branch children field is little-endian" {
    // Red stage: children written with .big. children=[10,20,30], 30=0x1E -> .big bytes
    // [0x00,0x00,0x00,0x1E]; reading .little -> 0x1E000000 != 30 -> FAIL (expected red)
    var buf: [f2.PAGE_SIZE]u8 = undefined;
    const pl_len = buildBranchPayload(&buf);
    // layout: kind(1)+count(2)+ [klen(4)+key(1)]x2 + children(3x4)
    // = 1+2 + (4+1)+(4+1) + 12 = 3+10+12 = 25; children region starts at offset 13
    const children_off: usize = pl_len - 3 * 4;
    // the 3rd child (=30) is at children_off + 8
    const got_little = std.mem.readInt(u32, buf[children_off + 8 ..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 30), got_little);
}

test "endian: overflow page_no field is little-endian (control, passes)" {
    // Control: overflow page numbers are already .little (one of the 6 sites), this test should PASS.
    // Build an overflow entry, read back the overflow page_no field, assert .little reads a non-zero (valid) page number.
    var buf: [f2.PAGE_SIZE]u8 = undefined;
    const pl_len = try buildOverflowLeafPayload(&buf);
    try std.testing.expect(pl_len > 0);
    // layout: kind(1)+count(2)+tombstone(1)+klen(4)+key(1)+vlen(4)+flags(1)+page_no(4)
    // flags=LEAF_FLAG_OVERFLOW, page_no at offset 1+2+1+4+1+4+1 = 14
    const page_no_little = std.mem.readInt(u32, buf[14..18], .little);
    // overflow page number should be >= FIRST_DATA_PAGE(3); .little reads the correct value (control green)
    try std.testing.expect(page_no_little >= 3);
    // confirm asymmetry: reading .big should give a different value (proving it really is .little)
    const page_no_big = std.mem.readInt(u32, buf[14..18], .big);
    try std.testing.expect(page_no_little != page_no_big);
}

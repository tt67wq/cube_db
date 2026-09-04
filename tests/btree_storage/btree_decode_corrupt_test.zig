//! btree_decode_corrupt_test.zig - T-5: btree page decode corrupt/truncated path tests
//!
//! The error.CorruptCrc / error.Truncated paths of src/btree.zig's deserialization trust
//! boundary (readNodePayload / decodeLeafPayload / decodeBranchPayload) previously had zero
//! direct tests, only indirect black-box coverage via put/get. This file constructs corrupted/
//! truncated payloads directly to pin down the errors.
//!
//! Strategy: use the pub encoding functions (encodeLeafPayload / encodeBranchPayload) to build
//! valid payloads, then flip bits / truncate / mismatch kinds, asserting the exact decode error.
//! LEAF_KIND/BRANCH_KIND are private, but encode* already embeds the correct kind byte; corrupt
//! tests never need those constants directly, and wrong-kind tests trigger kind != LEAF_KIND
//! naturally by "feeding a branch payload to decodeLeafPayload".
//!
//! Hookup: comptime @import of this file at the end of tests/btree_storage/btree_test.zig.

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const ps = cube.page_store;
const btree = cube.btree;

const allocator = std.testing.allocator;

/// Build a valid leaf payload (1 inline entry, no overflow page IO) into buf, return the actual length used
fn buildValidLeafPayload(buf: []u8) !usize {
    var ms = ps.MemPageStore.init(allocator, 64);
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);
    const entries = [_]btree.LeafEntry{
        .{ .tombstone = false, .key = "key1", .value = "val1" },
    };
    return try btree.encodeLeafPayload(buf, &entries, ms.store(), &dirty);
}

/// Build a valid branch payload (3 children, 2 keys) into buf, return the actual length used
fn buildValidBranchPayload(buf: []u8) usize {
    const keys = [_][]const u8{ "m", "q" };
    const children = [_]u32{ 10, 20, 30 };
    return btree.encodeBranchPayload(buf, &keys, &children);
}

// ===== readNodePayload CRC corruption =====

test "btree_decode_corrupt: readNodePayload on CRC-damaged leaf returns CorruptCrc" {
    var ms = ps.MemPageStore.init(allocator, 64);
    defer ms.deinit();
    const s = ms.store();

    // build a valid leaf payload
    var payload_buf: [f2.PAGE_SIZE]u8 = undefined;
    const pl_len = try buildValidLeafPayload(&payload_buf);

    // write it as a full page (header + payload + padding + CRC)
    const page_no = try s.allocPage();
    try btree.writeNodePage(s, page_no, f2.PAGE_TYPE_LEAF, 1, payload_buf[0..pl_len]);

    // valid page: readNodePayload should succeed
    const valid = try btree.readNodePayload(s, page_no);
    try std.testing.expect(valid.len > 0);

    // flip 1 byte in the payload region -> CRC mismatch
    const page = try s.writePage(page_no);
    page[f2.PAGE_HEADER_SIZE + 1] ^= 0xFF;

    // expect error.CorruptCrc
    try std.testing.expectError(error.CorruptCrc, btree.readNodePayload(s, page_no));
}

// ===== decodeLeafPayload truncation =====

test "btree_decode_corrupt: decodeLeafPayload < 3 bytes returns Truncated" {
    // 2-byte payload -> len < 3 -> error.Truncated
    const short = [_]u8{ 0x02, 0x00 };
    var entries_out: [4]btree.DecodedLeafEntry = undefined;
    try std.testing.expectError(error.Truncated, btree.decodeLeafPayload(&short, &entries_out));
}

test "btree_decode_corrupt: decodeLeafPayload on truncated valid leaf returns Truncated" {
    // valid leaf payload truncated to 3 bytes (kind + count=1), entries_out capacity is enough,
    // but the entry body data is missing -> in-loop pos+1+4 > payload.len -> error.Truncated
    var full: [f2.PAGE_SIZE]u8 = undefined;
    const pl_len = try buildValidLeafPayload(&full);
    try std.testing.expect(pl_len >= 3);

    var truncated: [3]u8 = undefined;
    @memcpy(&truncated, full[0..3]);
    var entries_out: [4]btree.DecodedLeafEntry = undefined;
    try std.testing.expectError(error.Truncated, btree.decodeLeafPayload(&truncated, &entries_out));
}

test "btree_decode_corrupt: decodeLeafPayload wrong kind (branch payload) returns CorruptCrc" {
    // feed a branch payload to decodeLeafPayload: BRANCH_KIND != LEAF_KIND -> error.CorruptCrc
    var branch_buf: [f2.PAGE_SIZE]u8 = undefined;
    _ = buildValidBranchPayload(&branch_buf);

    var entries_out: [4]btree.DecodedLeafEntry = undefined;
    try std.testing.expectError(error.CorruptCrc, btree.decodeLeafPayload(&branch_buf, &entries_out));
}

test "btree_decode_corrupt: decodeLeafPayload entries_out too small returns Truncated" {
    // valid leaf payload with 1 entry, but entries_out length 0 -> entries_out.len < count -> Truncated
    var full: [f2.PAGE_SIZE]u8 = undefined;
    _ = try buildValidLeafPayload(&full);
    var entries_out: [0]btree.DecodedLeafEntry = undefined;
    try std.testing.expectError(error.Truncated, btree.decodeLeafPayload(&full, &entries_out));
}

// ===== decodeBranchPayload truncation =====

test "btree_decode_corrupt: decodeBranchPayload < 3 bytes returns Truncated" {
    const short = [_]u8{ 0x01, 0x00 };
    var keys_out: [4][]const u8 = undefined;
    var children_out: [4]u32 = undefined;
    try std.testing.expectError(error.Truncated, btree.decodeBranchPayload(&short, &keys_out, &children_out));
}

test "btree_decode_corrupt: decodeBranchPayload on truncated valid branch returns Truncated" {
    // valid branch payload truncated to 3 bytes (kind + count=3), keys_out/children_out capacity is enough,
    // but key data is missing -> pos+4 > payload.len -> error.Truncated
    var full: [f2.PAGE_SIZE]u8 = undefined;
    const pl_len = buildValidBranchPayload(&full);
    try std.testing.expect(pl_len >= 3);

    var truncated: [3]u8 = undefined;
    @memcpy(&truncated, full[0..3]);
    var keys_out: [4][]const u8 = undefined;
    var children_out: [4]u32 = undefined;
    try std.testing.expectError(error.Truncated, btree.decodeBranchPayload(&truncated, &keys_out, &children_out));
}

test "btree_decode_corrupt: decodeBranchPayload wrong kind (leaf payload) returns CorruptCrc" {
    // feed a leaf payload to decodeBranchPayload: LEAF_KIND != BRANCH_KIND -> error.CorruptCrc
    var leaf_buf: [f2.PAGE_SIZE]u8 = undefined;
    _ = try buildValidLeafPayload(&leaf_buf);

    var keys_out: [4][]const u8 = undefined;
    var children_out: [4]u32 = undefined;
    try std.testing.expectError(error.CorruptCrc, btree.decodeBranchPayload(&leaf_buf, &keys_out, &children_out));
}

test "btree_decode_corrupt: decodeBranchPayload children_out too small returns Truncated" {
    // valid branch payload with 3 children, children_out length 2 -> children_out.len < count -> Truncated
    var full: [f2.PAGE_SIZE]u8 = undefined;
    _ = buildValidBranchPayload(&full);
    var keys_out: [4][]const u8 = undefined;
    var children_out: [2]u32 = undefined; // count=3, needs >=3
    try std.testing.expectError(error.Truncated, btree.decodeBranchPayload(&full, &keys_out, &children_out));
}

// ===== valid path regression (ensure encode->decode round-trip works; otherwise the corrupt tests are meaningless) =====

test "btree_decode_corrupt: valid leaf payload round-trips (sanity)" {
    var full: [f2.PAGE_SIZE]u8 = undefined;
    const pl_len = try buildValidLeafPayload(&full);
    var entries_out: [4]btree.DecodedLeafEntry = undefined;
    try btree.decodeLeafPayload(full[0..pl_len], &entries_out);
    try std.testing.expectEqualStrings("key1", entries_out[0].key);
    try std.testing.expectEqualStrings("val1", entries_out[0].value);
}

test "btree_decode_corrupt: valid branch payload round-trips (sanity)" {
    var full: [f2.PAGE_SIZE]u8 = undefined;
    const pl_len = buildValidBranchPayload(&full);
    var keys_out: [4][]const u8 = undefined;
    var children_out: [4]u32 = undefined;
    try btree.decodeBranchPayload(full[0..pl_len], &keys_out, &children_out);
    try std.testing.expectEqualStrings("m", keys_out[0]);
    try std.testing.expectEqualStrings("q", keys_out[1]);
    try std.testing.expectEqual(@as(u32, 10), children_out[0]);
    try std.testing.expectEqual(@as(u32, 30), children_out[2]);
}

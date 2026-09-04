//! freelist_overflow_test.zig - T-3: pin down writeFreelistEntries over-capacity behavior
//!
//! When src/format.zig:234 writeFreelistEntries writes entries exceeding a single page's capacity,
//! `if (pos + 4 > payload.len) break` silently drops the overflow entries, but the count field is
//! written as the original entries.len (not the number actually written). readFreelistEntries
//! (src/format.zig:255) clamps with `@min(count, max)`, masking the count != actually-written inconsistency.
//!
//! This file asserts the current actual behavior (entries read back), and marks the spots where count
//! mismatches the actually-written count with `// FIXME: known bug - write count mismatch`, keeping the
//! tests green without hiding the problem.
//!
//! Hookup: comptime @import of this file at the end of tests/core_format/format_test.zig.

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;

/// Max freelist entries per page: payload = PAGE_SIZE - PAGE_HEADER_SIZE(24) - CRC(4);
/// first 4 bytes hold count, the rest holds u32 entries -> max = (payload - 4) / 4 = (4096-24-4-4)/4 = 1016
const MAX_ENTRIES: u32 = @as(u32, @intCast((f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4 - 4) / 4));

/// Build a zeroed page + FREE page header, to test only the freelist payload behavior
fn newFreePage() [f2.PAGE_SIZE]u8 {
    var page: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page, 0);
    var h = f2.PageHeader{ .page_no = 1, .page_type = f2.PAGE_TYPE_FREE, .gen = 0, .nkeys = 0, .free_next = 0 };
    f2.encodePageHeader(&page, &h);
    return page;
}

test "freelist_overflow: max+1 entries — read-back clamped to max, count mismatch" {
    // max+1 entries: the write side's break drops the last 1, but the count field is written as max+1
    var page = newFreePage();
    const allocator = std.testing.allocator;
    var entries = std.ArrayList(u32).empty;
    defer entries.deinit(allocator);
    var i: u32 = 0;
    while (i < MAX_ENTRIES + 1) : (i += 1) {
        try entries.append(allocator, 1000 + i);
    }

    f2.writeFreelistEntries(&page, entries.items);
    const got = f2.readFreelistEntries(&page);

    // entries read back: readFreelistEntries @min(count=max+1, max) = max
    try std.testing.expectEqual(MAX_ENTRIES, @as(u32, @intCast(got.len)));

    // FIXME: known bug - write count mismatch
    // writeFreelistEntries writes count as entries.len (max+1), but only max entries were actually written.
    // The read returns max due to @min clamping; the count field (1017) is inconsistent with the actually-written count (1016).
    // verify the count field really was written as max+1 (i.e. the bug exists):
    const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    const stored_count = std.mem.readInt(u32, payload[0..4], .little);
    try std.testing.expectEqual(MAX_ENTRIES + 1, stored_count);

    // read-back content: the first max entries intact, the max+1-th (dropped by break) is unreachable
    try std.testing.expectEqual(@as(u32, 1000), got[0]);
    try std.testing.expectEqual(@as(u32, 1000 + MAX_ENTRIES - 1), got[got.len - 1]);
}

test "freelist_overflow: max+10 entries — read-back still clamped to max" {
    var page = newFreePage();
    const allocator = std.testing.allocator;
    var entries = std.ArrayList(u32).empty;
    defer entries.deinit(allocator);
    var i: u32 = 0;
    while (i < MAX_ENTRIES + 10) : (i += 1) {
        try entries.append(allocator, 2000 + i);
    }

    f2.writeFreelistEntries(&page, entries.items);
    const got = f2.readFreelistEntries(&page);

    // even with 10 more dropped, read-back is still = max (@min clamp)
    try std.testing.expectEqual(MAX_ENTRIES, @as(u32, @intCast(got.len)));

    // FIXME: known bug - write count mismatch
    const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    const stored_count = std.mem.readInt(u32, payload[0..4], .little);
    try std.testing.expectEqual(MAX_ENTRIES + 10, stored_count);
}

test "freelist_overflow: corrupt count 0xFFFFFFFF — no crash, clamped to max" {
    // build a page directly: count field = 0xFFFFFFFF (far beyond capacity), payload filled with valid entries
    var page = newFreePage();
    const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    std.mem.writeInt(u32, payload[0..4], 0xFFFFFFFF, .little);
    var pos: usize = 4;
    var i: u32 = 0;
    while (pos + 4 <= payload.len) : (i += 1) {
        std.mem.writeInt(u32, payload[pos..][0..4], 3000 + i, .little);
        pos += 4;
    }
    // do not call writeFreelistEntries (it would rewrite count); test readFreelistEntries' clamping directly
    f2.setPageChecksum(&page, f2.computePageChecksum(&page));

    const got = f2.readFreelistEntries(&page);
    // @min(0xFFFFFFFF, max) = max, no out-of-bounds, no crash
    try std.testing.expectEqual(MAX_ENTRIES, @as(u32, @intCast(got.len)));
    try std.testing.expectEqual(@as(u32, 3000), got[0]);
    try std.testing.expectEqual(@as(u32, 3000 + MAX_ENTRIES - 1), got[got.len - 1]);
}

test "freelist_overflow: exactly max entries — count and read-back consistent" {
    // exactly max entries: count == actually written, nothing dropped, no bug
    var page = newFreePage();
    const allocator = std.testing.allocator;
    var entries = std.ArrayList(u32).empty;
    defer entries.deinit(allocator);
    var i: u32 = 0;
    while (i < MAX_ENTRIES) : (i += 1) {
        try entries.append(allocator, 4000 + i);
    }

    f2.writeFreelistEntries(&page, entries.items);
    const got = f2.readFreelistEntries(&page);

    try std.testing.expectEqual(MAX_ENTRIES, @as(u32, @intCast(got.len)));
    const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    const stored_count = std.mem.readInt(u32, payload[0..4], .little);
    // at exactly max, count agrees with reality (no-bug path)
    try std.testing.expectEqual(MAX_ENTRIES, stored_count);
    try std.testing.expectEqual(@as(u32, 4000), got[0]);
    try std.testing.expectEqual(@as(u32, 4000 + MAX_ENTRIES - 1), got[got.len - 1]);
}

test "freelist_overflow: zero entries — empty read-back, count 0" {
    var page = newFreePage();
    f2.writeFreelistEntries(&page, &.{});
    const got = f2.readFreelistEntries(&page);
    try std.testing.expectEqual(@as(usize, 0), got.len);
    const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    const stored_count = std.mem.readInt(u32, payload[0..4], .little);
    try std.testing.expectEqual(@as(u32, 0), stored_count);
}

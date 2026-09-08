//! freelist_overflow_test.zig - T-3 / T-33(T1): writeFreelistEntries over-capacity contract
//!
//! Original T-3 finding: given more entries than one FREE page holds, writeFreelistEntries'
//! `if (pos + 4 > payload.len) break` silently dropped the overflow while the count field was
//! written as the original entries.len — count != actually-written, masked on the read side by
//! readFreelistEntries' `@min(count, max)` clamp.
//!
//! T-33 (freelist persistence) turns that into the contract asserted here:
//!
//!     stored count == @min(entries.len, MAX_FREE_ENTRIES_PER_PAGE)
//!
//! The count field always tells the truth about what is physically on the page; the read-side clamp
//! stays as defense-in-depth against a corrupt count field. Entries beyond one page are the caller's
//! job — it chains another FREE page (freelist_persist_test.zig T2) — never a silent truncation.
//!
//! The two former `// FIXME: known bug - write count mismatch` assertions are reversed below: RED
//! against main (93ec9fc), GREEN with T-33 step 1 (src/format.zig).
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

test "freelist_overflow: max+1 entries — count truthful (min(len,cap)), read-back = cap" {
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

    // T-33(T1) reversed FIXME: count field must tell the truth — the page physically holds
    // MAX_ENTRIES entries, so stored count == @min(entries.len, MAX_ENTRIES) == MAX_ENTRIES,
    // never entries.len (MAX_ENTRIES+1). RED on main (format.zig still writes entries.len);
    // GREEN with T-33 step 1.
    const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    const stored_count = std.mem.readInt(u32, payload[0..4], .little);
    try std.testing.expectEqual(MAX_ENTRIES, stored_count);

    // read-back content: the first max entries intact, the max+1-th (dropped by break) is unreachable
    try std.testing.expectEqual(@as(u32, 1000), got[0]);
    try std.testing.expectEqual(@as(u32, 1000 + MAX_ENTRIES - 1), got[got.len - 1]);
}

test "freelist_overflow: max+10 entries — count still truthful, read-back = cap" {
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

    // T-33(T1) reversed FIXME: count == actually written == @min(entries.len, cap) == MAX_ENTRIES,
    // never entries.len (MAX_ENTRIES+10). RED on main.
    const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    const stored_count = std.mem.readInt(u32, payload[0..4], .little);
    try std.testing.expectEqual(MAX_ENTRIES, stored_count);
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

// ===== T-33(T1) additions =====

test "freelist_overflow: exactly 1016 entries — count==1016 and header untouched" {
    // A FREE page's header carries the chain link (free_next) and, per T-33 H1, the gen stamp
    // (= the sequence of the meta that points at this chain). writeFreelistEntries owns the payload
    // + CRC only: if it clobbered the header, chaining and gen validation would break silently.
    var page: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page, 0);
    const chain_next: u32 = 0x00BE_EEFC;
    const gen_stamp: u64 = 0x1122_3344_5566_7788;
    var hdr = f2.PageHeader{
        .page_no = 77,
        .page_type = f2.PAGE_TYPE_FREE,
        .gen = gen_stamp,
        .nkeys = 0,
        .free_next = chain_next,
    };
    f2.encodePageHeader(&page, &hdr);

    const allocator = std.testing.allocator;
    var entries = std.ArrayList(u32).empty;
    defer entries.deinit(allocator);
    var i: u32 = 0;
    while (i < MAX_ENTRIES) : (i += 1) {
        try entries.append(allocator, 5000 + i);
    }

    f2.writeFreelistEntries(&page, entries.items);

    // count == exactly the capacity (the boundary case: nothing dropped, nothing inflated)
    const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    const stored_count = std.mem.readInt(u32, payload[0..4], .little);
    try std.testing.expectEqual(MAX_ENTRIES, stored_count);
    const got = f2.readFreelistEntries(&page);
    try std.testing.expectEqual(MAX_ENTRIES, @as(u32, @intCast(got.len)));
    try std.testing.expectEqual(@as(u32, 5000), got[0]);
    try std.testing.expectEqual(@as(u32, 5000 + MAX_ENTRIES - 1), got[got.len - 1]);

    // header (chain link + gen stamp + identity) survives the payload write
    const got_hdr = f2.decodePageHeader(&page);
    try std.testing.expectEqual(chain_next, got_hdr.free_next);
    try std.testing.expectEqual(gen_stamp, got_hdr.gen);
    try std.testing.expectEqual(@as(u32, 77), got_hdr.page_no);
    try std.testing.expectEqual(f2.PAGE_TYPE_FREE, got_hdr.page_type);

    // the payload write must leave a valid whole-page CRC (it recomputes over header+payload)
    try std.testing.expect(f2.verifyPageChecksum(&page));
}

test "freelist_overflow: format exposes MAX_FREE_ENTRIES_PER_PAGE == single-page capacity" {
    // T-33 contract: the per-page capacity becomes a named format constant so the persistence layer
    // (chain split, restore walk bound) and these tests share one source of truth instead of each
    // recomputing (PAGE_SIZE - PAGE_HEADER_SIZE - 4 - 4) / 4. RED on main.
    try std.testing.expect(@hasDecl(f2, "MAX_FREE_ENTRIES_PER_PAGE"));
    if (@hasDecl(f2, "MAX_FREE_ENTRIES_PER_PAGE")) {
        try std.testing.expectEqual(MAX_ENTRIES, @as(u32, @intCast(f2.MAX_FREE_ENTRIES_PER_PAGE)));
    }
}

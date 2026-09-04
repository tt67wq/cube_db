//! btree_overflow_chain_test.zig - T-12: overflow page chain tests (#7)
//!
//! src/btree.zig:75-150 overflow page chain mechanism:
//! - writeOverflowPages (:76 private) writes large values to an overflow chain linked via free_next
//! - readOverflowValue (:131 private) reads back and reassembles
//! - freeOverflowPages (:144 private) reclaims; on readPage failure it silently returns (:148)
//!
//! These functions are all private; this file triggers them indirectly through pub APIs
//! (btree.insert / btree.get), then uses MemPageStore + format page-header decoding to directly
//! observe the overflow chain structure and reclamation behavior.
//!
//! Hookup: comptime block in tests/btree_storage/btree_test.zig.

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const ps = cube.page_store;
const btree = cube.btree;

const allocator = std.testing.allocator;

/// Overflow page payload capacity = PAGE_SIZE - PAGE_HEADER_SIZE(24) - CRC(4) = 4068
const OVERFLOW_PAYLOAD: usize = f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4;

/// Number of overflow pages needed for a given value length = ceil(len / OVERFLOW_PAYLOAD)
fn expectedOverflowPages(vlen: usize) u32 {
    return @intCast(@divTrunc(vlen + OVERFLOW_PAYLOAD - 1, OVERFLOW_PAYLOAD));
}

/// Read the first entry from a leaf root; if it is an overflow entry, return the first overflow page number, else null
fn overflowFirstPage(store: ps.PageStore, root: u32) !?u32 {
    const payload = try btree.readNodePayload(store, root);
    var entries: [1]btree.DecodedLeafEntry = undefined;
    try btree.decodeLeafPayload(payload, &entries);
    const e = entries[0];
    // An overflow entry's value is a 4-byte page_no (.little); flags & LEAF_FLAG_OVERFLOW
    if (e.value.len == 4 and (e.flags & 1) != 0) {
        return std.mem.readInt(u32, e.value[0..4], .little);
    }
    return null;
}

/// Walk the overflow chain via free_next, returning the list of page numbers visited + verifying each page's page_type
fn walkOverflowChain(store: ps.PageStore, first_page: u32, out: *std.ArrayList(u32)) !void {
    var cur: u32 = first_page;
    var guard: u32 = 0;
    while (cur != 0 and guard < 10000) : (guard += 1) {
        const page = try store.readPage(cur);
        const hdr = f2.decodePageHeader(page[0..f2.PAGE_HEADER_SIZE]);
        // every page's page_type must be OVERFLOW
        if (hdr.page_type != f2.PAGE_TYPE_OVERFLOW) return error.WrongPageType;
        try out.append(allocator, cur);
        cur = hdr.free_next;
    }
}

// ===== 1. multi-page overflow chain (50KB) =====

test "overflow_chain: 50KB value - chain length, page_type, content match" {
    var ms = ps.MemPageStore.init(allocator, 100000);
    defer ms.deinit();
    const s = ms.store();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    // Build a verifiable 50000-byte value (each byte = i % 251, a non-trivial pattern)
    var value: [50000]u8 = undefined;
    var i: usize = 0;
    while (i < value.len) : (i += 1) value[i] = @intCast(i % 251);

    const wr = try btree.insert(allocator, s, btree.NULL_ROOT, "big", &value, false, &dirty);
    // WriteResult.new_root is a page number u32; the key/value dupes inside insert are freed in the function, callers need not free

    // lookup returns the correct value
    const got = try btree.get(allocator, s, wr.new_root, "big");
    try std.testing.expect(got != null);
    defer allocator.free(got.?);
    try std.testing.expectEqual(@as(usize, 50000), got.?.len);
    try std.testing.expectEqualSlices(u8, &value, got.?);

    // assert overflow chain length = ceil(50000 / 4068) = 13
    const first = (try overflowFirstPage(s, wr.new_root)) orelse return error.NotOverflow;
    var chain = std.ArrayList(u32).empty;
    defer chain.deinit(allocator);
    try walkOverflowChain(s, first, &chain);
    try std.testing.expectEqual(expectedOverflowPages(50000), @as(u32, @intCast(chain.items.len)));
    // 13 pages: 50000 = 12*4068 + 16 (last page holds only 16 bytes)
    try std.testing.expectEqual(@as(u32, 13), @as(u32, @intCast(chain.items.len)));

    // per-page content assertion: first 12 pages 4068 bytes each, last page 16 bytes, all matching the corresponding segment of value
    var offset: usize = 0;
    for (chain.items, 0..) |pn, idx| {
        const page = try s.readPage(pn);
        const hdr = f2.decodePageHeader(page[0..f2.PAGE_HEADER_SIZE]);
        try std.testing.expectEqual(f2.PAGE_TYPE_OVERFLOW, hdr.page_type);
        // linked-list free_next: non-last pages point to the next page, last page is 0
        if (idx + 1 < chain.items.len) {
            try std.testing.expectEqual(chain.items[idx + 1], hdr.free_next);
        } else {
            try std.testing.expectEqual(@as(u32, 0), hdr.free_next);
        }
        // payload region content
        const chunk_len = @min(OVERFLOW_PAYLOAD, 50000 - offset);
        const chunk = page[f2.PAGE_HEADER_SIZE ..][0..chunk_len];
        try std.testing.expectEqualSlices(u8, value[offset..][0..chunk_len], chunk);
        offset += chunk_len;
    }
    try std.testing.expectEqual(@as(usize, 50000), offset);
}

// ===== 2. larger value (100KB) =====

test "overflow_chain: 100KB value - correct read-back and chain length" {
    var ms = ps.MemPageStore.init(allocator, 200000);
    defer ms.deinit();
    const s = ms.store();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    var value: [100000]u8 = undefined;
    var i: usize = 0;
    while (i < value.len) : (i += 1) value[i] = @intCast((i * 7) % 251);

    const wr = try btree.insert(allocator, s, btree.NULL_ROOT, "huge", &value, false, &dirty);

    const got = try btree.get(allocator, s, wr.new_root, "huge");
    try std.testing.expect(got != null);
    defer allocator.free(got.?);
    try std.testing.expectEqual(@as(usize, 100000), got.?.len);
    try std.testing.expectEqualSlices(u8, &value, got.?);

    // chain length = ceil(100000/4068) = 25
    const first = (try overflowFirstPage(s, wr.new_root)) orelse return error.NotOverflow;
    var chain = std.ArrayList(u32).empty;
    defer chain.deinit(allocator);
    try walkOverflowChain(s, first, &chain);
    try std.testing.expectEqual(expectedOverflowPages(100000), @as(u32, @intCast(chain.items.len)));
    try std.testing.expectEqual(@as(u32, 25), @as(u32, @intCast(chain.items.len)));
}

// ===== 3. reclaimed overflow pages are reusable =====

test "overflow_chain: freed overflow pages reused by later alloc (LIFO)" {
    var ms = ps.MemPageStore.init(allocator, 100000);
    defer ms.deinit();
    const s = ms.store();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    // put a 50KB overflow value
    var value: [50000]u8 = undefined;
    @memset(&value, 0x77);
    const wr1 = try btree.insert(allocator, s, btree.NULL_ROOT, "k", &value, false, &dirty);

    // record the first overflow page number + chain
    const first = (try overflowFirstPage(s, wr1.new_root)) orelse return error.NotOverflow;
    var chain = std.ArrayList(u32).empty;
    defer chain.deinit(allocator);
    try walkOverflowChain(s, first, &chain);
    const overflow_page_count = chain.items.len;

    // overwrite with a small inline value -> insertIntoLeaf triggers freeOverflowPages, adding the old chain to dirty
    var dirty2 = std.ArrayList(u32).empty;
    defer dirty2.deinit(allocator);
    const wr2 = try btree.insert(allocator, s, wr1.new_root, "k", "small", false, &dirty2);
    _ = wr2;

    // dirty2 should contain the old overflow chain page numbers (count >= overflow_page_count)
    var freed_count: usize = 0;
    for (dirty2.items) |pn| {
        for (chain.items) |opn| {
            if (pn == opn) freed_count += 1;
        }
    }
    try std.testing.expect(freed_count >= overflow_page_count);

    // manually flush dirty -> freePage into freelist (simulating writer pending_free reclamation)
    for (dirty2.items) |pn| s.freePage(pn);

    // subsequent allocPage should reuse these pages LIFO: consecutive allocs should see page numbers from the chain
    var reused: usize = 0;
    var allocd = std.ArrayList(u32).empty;
    defer allocd.deinit(allocator);
    var n: usize = 0;
    while (n < overflow_page_count) : (n += 1) {
        const pn = try s.allocPage();
        try allocd.append(allocator, pn);
        for (chain.items) |opn| {
            if (pn == opn) reused += 1;
        }
    }
    // at least partial reuse (LIFO; the first alloc should be the last freed page)
    try std.testing.expect(reused > 0);
}

// ===== 4. freeOverflowPages silent failure =====

test "overflow_chain: freeOverflowPages silent on broken chain - no panic, partial dirty" {
    var ms = ps.MemPageStore.init(allocator, 100000);
    defer ms.deinit();
    const s = ms.store();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    // put a 50KB overflow value
    var value: [50000]u8 = undefined;
    @memset(&value, 0x99);
    const wr1 = try btree.insert(allocator, s, btree.NULL_ROOT, "k", &value, false, &dirty);

    // take the overflow chain
    const first = (try overflowFirstPage(s, wr1.new_root)) orelse return error.NotOverflow;
    var chain = std.ArrayList(u32).empty;
    defer chain.deinit(allocator);
    try walkOverflowChain(s, first, &chain);
    try std.testing.expect(chain.items.len >= 3);
    // break page 2's free_next: point it at an invalid page number (>= max_pages or nonexistent)
    // this makes freeOverflowPages, after walking to page 2, fail reading the (invalid) next via readPage -> silent return
    const break_page = chain.items[1];
    const w = try s.writePage(break_page);
    var hdr = f2.decodePageHeader(w[0..f2.PAGE_HEADER_SIZE]);
    const invalid_next: u32 = 0xFFFFFFFE; // far beyond max_pages, readPage necessarily PageNotFound
    hdr.free_next = invalid_next;
    f2.encodePageHeader(w[0..f2.PAGE_HEADER_SIZE], &hdr);
    // note: CRC is not recomputed; freeOverflowPages reads the page header directly via store.readPage (no readNodePayload CRC check)

    // overwrite triggers freeOverflowPages -- must not panic
    var dirty2 = std.ArrayList(u32).empty;
    defer dirty2.deinit(allocator);
    const wr2 = btree.insert(allocator, s, wr1.new_root, "k", "v", false, &dirty2) catch |err| {
        // even if insert fails due to the broken chain it is not a panic-crash; but it is expected to succeed (freeOverflowPages swallows the error silently)
        return err;
    };
    _ = wr2;

    // pages already walked (first page + the broken page itself) should be in dirty; pages after the break (from page 3 on) should not
    var found_first = false;
    var found_break = false;
    var found_after_break = false;
    for (dirty2.items) |pn| {
        if (pn == chain.items[0]) found_first = true;
        if (pn == break_page) found_break = true;
    }
    // pages 3 and beyond should not be in dirty (chain is broken after break_page)
    var i: usize = 2;
    while (i < chain.items.len) : (i += 1) {
        for (dirty2.items) |pn| {
            if (pn == chain.items[i]) found_after_break = true;
        }
    }
    try std.testing.expect(found_first); // first page reclaimed
    try std.testing.expect(found_break); // the broken page itself reclaimed (appended before the readPage failure)
    try std.testing.expect(!found_after_break); // pages after the break not reclaimed
}

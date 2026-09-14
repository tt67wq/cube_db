//! batch_payload_chunking_test.zig — T-40 RED: batch chunking bounds by count, not bytes
//!
//! Issue T-40: btree.zig's batch path chunks by entry count
//! (LEAF_MAX_ENTRIES=32 / BRANCH_MAX_CHILDREN=64), never by encoded payload
//! size. A batch of near-MAX_KEY_SIZE keys makes a single chunk's encoded
//! payload exceed f2.PAGE_SIZE, and encodeLeafPayload's `buf[0..pl]`
//! (overflowed integer / slice bounds) panics.
//!
//! RED EVIDENCE — `zig build test-batchpayload` on this commit's HEAD crashes:
//!   - fresh-tree load: src/btree.zig:1449 insertBatchSplitLeaves —
//!       panic: index out of bounds: index 128323, len 4096 (encodeLeafPayload buf[0..pl])
//!   - overflow into existing tree: src/btree.zig:1711 insertBatchIntoLeaf —
//!       panic: index out of bounds: index 96419, len 4096 (via insertBatchIntoBranch:1854)
//! Both tests crash (0/2 pass) — exactly the count-vs-bytes chunking bug.
//!
//! This test must FAIL (crash) on current HEAD and PASS after T-40-B lands
//! payload-size-aware chunking. Only the public Db.putBatch entry point is used.
//!
//! Wiring: registered in build.zig under the test-batchpayload step
//! (also part of the aggregate test step).

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const dbi = cube.db;
const btree = cube.btree;

const alloc = std.testing.allocator;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 10000);
}

/// One near-MAX_KEY_SIZE key: filler prefix + 8-byte big-endian monotonic
/// suffix. Length 4000 leaves headroom under btree.MAX_KEY_SIZE (4051) while
/// 32 of them (~128KB) vastly exceed a 4068-byte usable leaf payload.
const BIG_KEY_LEN = 4000;

fn bigKey(buf: []u8, idx: usize, filler: u8) []const u8 {
    @memset(buf[0 .. BIG_KEY_LEN - 8], filler);
    std.mem.writeInt(u64, buf[BIG_KEY_LEN - 8 ..][0..8], @intCast(idx), .big);
    return buf[0..BIG_KEY_LEN];
}

fn bigEntry(buf: []u8, idx: usize) dbi.Entry {
    return .{ .key = bigKey(buf, idx, 'a'), .value = "" };
}

/// Verify the whole contract: count, sampled point-gets, full select scan.
/// `filler` is the big-key filler byte (test 1 'a', test 2 'z' so big keys
/// sort after the small 'k' keys).
fn verify(db: *dbi.Db, total: usize, big_from: usize, big_to: usize, filler: u8) !void {
    try std.testing.expectEqual(@as(u64, total), db.entryCount());

    // Sampled point gets over the big-key range (every 7th, plus both ends).
    var buf: [BIG_KEY_LEN]u8 = undefined;
    var i = big_from;
    while (i < big_to) : (i += @max(1, (big_to - big_from) / 16)) {
        const v = try db.get(bigKey(&buf, i, filler));
        try std.testing.expect(v != null);
        try std.testing.expectEqual(@as(usize, 0), v.?.len);
        alloc.free(v.?);
    }
    if (big_to > big_from) {
        const v = try db.get(bigKey(&buf, big_to - 1, filler));
        try std.testing.expect(v != null);
        alloc.free(v.?);
    }

    // Full ordered scan: total entries, all keys in order.
    var it = try db.select(null, null);
    defer it.deinit();
    var count: usize = 0;
    var prev: ?[]const u8 = null;
    while (try it.next()) |e| {
        count += 1;
        if (prev) |p| try std.testing.expect(std.mem.order(u8, p, e.key) == .lt);
        if (prev) |p| alloc.free(p);
        prev = try alloc.dupe(u8, e.key);
    }
    if (prev) |p| alloc.free(p);
    try std.testing.expectEqual(total, count);
}

// ===== 1. Fresh-tree bulk load: empty DB, one putBatch of near-MAX keys =====

test "batch payload chunking: fresh tree bulk load of near-MAX_KEY_SIZE keys" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), .{});
    defer db.close();

    const n = 120; // 4 chunks of 32 by count; ~480KB of key bytes total.
    var entries = try alloc.alloc(dbi.Entry, n);
    defer alloc.free(entries);
    var keybufs = try alloc.alloc([BIG_KEY_LEN]u8, n);
    defer alloc.free(keybufs);
    for (0..n) |i| entries[i] = bigEntry(&keybufs[i], i);

    try db.putBatch(entries);

    try verify(db, n, 0, n, 'a');
}

// ===== 2. Overflow into an existing tree: small keys first, then big batch =====

test "batch payload chunking: overflow batch into existing small-key tree" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), .{});
    defer db.close();

    // Phase 1: 40 small keys ("k%010d") — builds at least one real leaf.
    const small_n = 40;
    var small = try alloc.alloc(dbi.Entry, small_n);
    defer alloc.free(small);
    var sbufs = try alloc.alloc([16]u8, small_n);
    defer alloc.free(sbufs);
    for (0..small_n) |i| {
        sbufs[i] = undefined;
        const k = std.fmt.bufPrint(&sbufs[i], "k{d:0>10}", .{i}) catch unreachable;
        small[i] = .{ .key = k, .value = "v" };
    }
    try db.putBatch(small);

    // Phase 2: 90 near-MAX keys sorting AFTER the small keys (suffix high bits),
    // forcing leaf splits + branch splices on the existing tree.
    const big_n = 90;
    var big = try alloc.alloc(dbi.Entry, big_n);
    defer alloc.free(big);
    var bbufs = try alloc.alloc([BIG_KEY_LEN]u8, big_n);
    defer alloc.free(bbufs);
    for (0..big_n) |i| {
        // 'b' > 'k'? No: 'b' < 'k'. Use filler 'z' so big keys sort last.
        // Suffix continues after the small keys (small_n + i) so the
        // inserted key set is exactly z{small_n}..z{small_n+big_n-1} —
        // matching verify's [big_from, big_to) sampling.
        @memset(bbufs[i][0 .. BIG_KEY_LEN - 8], 'z');
        std.mem.writeInt(u64, bbufs[i][BIG_KEY_LEN - 8 ..][0..8], @intCast(small_n + i), .big);
        big[i] = .{ .key = bbufs[i][0..BIG_KEY_LEN], .value = "" };
    }
    try db.putBatch(big);

    try verify(db, small_n + big_n, small_n, small_n + big_n, 'z');

    // Phase 1 keys still intact (sampled).
    var kbuf: [16]u8 = undefined;
    const k0 = std.fmt.bufPrint(&kbuf, "k{d:0>10}", .{0}) catch unreachable;
    const v0 = try db.get(k0);
    try std.testing.expect(v0 != null);
    try std.testing.expectEqualStrings("v", v0.?);
    alloc.free(v0.?);
}

// ===== 3. GAP A regression: fresh-tree putBatch of 3 big keys =====
// insertBatchFresh's `entries.len <= LEAF_MAX_ENTRIES` single-leaf early
// return had no byte budget: 3 x 4000B keys (~12KB) overflowed the 4068B
// leaf payload -> encodeLeafPayload panic. (review 34e5afb Finding 1, PA)

test "batch payload chunking: fresh tree putBatch of 3 near-MAX_KEY_SIZE keys" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), .{});
    defer db.close();

    const n = 3; // way under the 32-entry count cap; ~12KB of key bytes.
    var keybufs = try alloc.alloc([BIG_KEY_LEN]u8, n);
    defer alloc.free(keybufs);
    var entries: [n]dbi.Entry = undefined;
    for (0..n) |i| entries[i] = bigEntry(&keybufs[i], i);

    try db.putBatch(&entries);

    try verify(db, n, 0, n, 'a');
}

// ===== 4. GAP B regression: 2 big keys onto an existing small-key leaf =====
// insertBatchIntoLeaf's `merged_entries.len <= LEAF_MAX_ENTRIES` single-leaf
// re-encode had no byte budget: a 3-entry small leaf + 2 x 4000B keys
// (~8KB merged) overflowed the leaf payload -> panic. (review 34e5afb
// Finding 1, PC)

test "batch payload chunking: 2 near-MAX_KEY_SIZE keys onto existing small leaf" {
    var ms = newStore();
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), .{});
    defer db.close();

    // Phase 1: single small-key leaf (putBatch of 3 -> fresh single leaf).
    const small_n = 3;
    var sbufs = try alloc.alloc([16]u8, small_n);
    defer alloc.free(sbufs);
    var small: [small_n]dbi.Entry = undefined;
    for (0..small_n) |i| {
        sbufs[i] = undefined;
        const k = std.fmt.bufPrint(&sbufs[i], "k{d:0>10}", .{i}) catch unreachable;
        small[i] = .{ .key = k, .value = "v" };
    }
    try db.putBatch(&small);

    // Phase 2: 2 big keys sorting AFTER the small keys -> merged (5 entries)
    // passes the count cap but blows the byte budget.
    const big_n = 2;
    var bbufs = try alloc.alloc([BIG_KEY_LEN]u8, big_n);
    defer alloc.free(bbufs);
    var big: [big_n]dbi.Entry = undefined;
    for (0..big_n) |i| {
        @memset(bbufs[i][0 .. BIG_KEY_LEN - 8], 'z');
        std.mem.writeInt(u64, bbufs[i][BIG_KEY_LEN - 8 ..][0..8], @intCast(small_n + i), .big);
        big[i] = .{ .key = bbufs[i][0..BIG_KEY_LEN], .value = "" };
    }
    try db.putBatch(&big);

    try verify(db, small_n + big_n, small_n, small_n + big_n, 'z');

    // Phase 1 keys still intact.
    var kbuf: [16]u8 = undefined;
    const k0 = std.fmt.bufPrint(&kbuf, "k{d:0>10}", .{0}) catch unreachable;
    const v0 = try db.get(k0);
    try std.testing.expect(v0 != null);
    try std.testing.expectEqualStrings("v", v0.?);
    alloc.free(v0.?);
}

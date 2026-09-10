//! crc_integrity_test.zig — T-35 Part A: configurable CRC check tiers (off/sample/full)
//!
//! RED stage (this file landed first): `writer.Options.crc_check`,
//! `btree.CrcCheck`/`sampleHit`/`getChecked` did not exist yet, so compilation
//! failure was the RED signal (same TDD precedent as T-27 durability_order_test
//! and T-29 getinto_borrow_test).
//!
//! The defect being exposed: on the OLD code the hot read path
//! (readNodePayloadFast — used by get/getInto/iterator descent) always skips
//! the page checksum, so a bit-rotted page is silently returned as legal data.
//! The `.full` assertions below are exactly the reads that used to be silent.
//!
//! GREEN contract:
//! - off (default): hot path skips CRC — corrupted padding byte is still read
//!   through, value intact, no error (status quo, no perf regression).
//! - full: every hot-path page read is checksum-verified; a damaged page
//!   returns error.CorruptCrc, never silent garbage.
//! - sample: deterministic page-number sampling (page_no % 64 == 0, pure
//!   predicate `btree.sampleHit`): hit pages verified (CorruptCrc on damage),
//!   non-hit pages skipped.

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;
const wrt = cube.writer;
const f2 = cube.format;
const Db = cube.Db;

const alloc = std.testing.allocator;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 100000);
}

/// Corrupt one payload byte in place, bypassing CRC recompute (bit-rot
/// simulation). Offset is the last payload-region byte before the trailing
/// CRC — inside the zero padding of a small leaf, so parsing is unaffected
/// and only the checksum breaks: under `.off` the value must still read out
/// correctly and silently.
fn corruptPayloadByte(store: ps.PageStore, page_no: u32) void {
    const page = store.readPage(page_no) catch unreachable;
    const mutable: []u8 = @constCast(page);
    mutable[f2.PAGE_SIZE - 5] ^= 0xFF;
}

/// Write a valid checksummed single-entry leaf at an arbitrary page number
/// (>= ps.FIRST_DATA_PAGE), so tests can pick exact page numbers for the
/// sampling predicate.
fn writeLeafAt(store: ps.PageStore, page_no: u32, key: []const u8, value: []const u8) !void {
    var entries = [_]btree.LeafEntry{.{ .tombstone = false, .key = key, .value = value }};
    var dirty: std.ArrayList(u32) = .empty;
    defer dirty.deinit(alloc);
    const pl = btree.leafPayloadSize(&entries);
    var buf: [f2.PAGE_SIZE]u8 = undefined;
    _ = try btree.encodeLeafPayload(buf[0..pl], &entries, store, &dirty);
    try btree.writeNodePage(store, page_no, f2.PAGE_TYPE_LEAF, 1, buf[0..pl]);
}

test "crc: default option is off" {
    try std.testing.expect((wrt.Options{}).crc_check == .off);
}

test "crc sample: sampleHit is a deterministic pure predicate (page_no % 64 == 0)" {
    try std.testing.expectEqual(@as(u32, 64), btree.SAMPLE_INTERVAL);
    // hit
    try std.testing.expect(btree.sampleHit(0));
    try std.testing.expect(btree.sampleHit(64));
    try std.testing.expect(btree.sampleHit(128));
    try std.testing.expect(btree.sampleHit(192));
    // miss
    try std.testing.expect(!btree.sampleHit(1));
    try std.testing.expect(!btree.sampleHit(63));
    try std.testing.expect(!btree.sampleHit(65));
    try std.testing.expect(!btree.sampleHit(4095));
    // determinism: same page -> same verdict, every call
    for (0..10) |_| {
        try std.testing.expectEqual(btree.sampleHit(64), btree.sampleHit(64));
        try std.testing.expectEqual(btree.sampleHit(65), btree.sampleHit(65));
    }
}

test "crc btree: off reads corrupted page silently, full returns CorruptCrc" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    try writeLeafAt(s, 10, "k", "v");
    corruptPayloadByte(s, 10);

    // off (legacy signature): status quo — silent read, value intact
    const v = try btree.get(alloc, s, 10, "k");
    defer alloc.free(v.?);
    try std.testing.expectEqualStrings("v", v.?);

    // full: the read that used to be silent must now fail loudly
    try std.testing.expectError(error.CorruptCrc, btree.getChecked(alloc, s, 10, "k", .full));
    // and a healthy page under full still reads fine
    try writeLeafAt(s, 11, "k", "v");
    const v2 = try btree.getChecked(alloc, s, 11, "k", .full);
    defer alloc.free(v2.?);
    try std.testing.expectEqualStrings("v", v2.?);
}

test "crc btree: sample verifies hit pages, skips non-hit pages" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    try writeLeafAt(s, 64, "k", "v"); // 64 % 64 == 0 -> sampled
    try writeLeafAt(s, 65, "k", "v"); // not sampled
    corruptPayloadByte(s, 64);
    corruptPayloadByte(s, 65);

    // hit page damaged -> CorruptCrc
    try std.testing.expectError(error.CorruptCrc, btree.getChecked(alloc, s, 64, "k", .sample));
    // non-hit page damaged but not verified -> silent read, value intact
    const v = try btree.getChecked(alloc, s, 65, "k", .sample);
    defer alloc.free(v.?);
    try std.testing.expectEqualStrings("v", v.?);
}

test "crc Db: off keeps hot path silent (no regression)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try db.put("k", "v");
    corruptPayloadByte(db.store, db.getRoot());
    const v = try db.get("k");
    defer alloc.free(v.?);
    try std.testing.expectEqualStrings("v", v.?);
}

test "crc Db: full detects bit rot on the hot read path (get)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{ .crc_check = .full });
    defer db.close();
    try db.put("k", "v");
    corruptPayloadByte(db.store, db.getRoot());
    // OLD behavior: silently returns "v". NEW: loud CorruptCrc.
    try std.testing.expectError(error.CorruptCrc, db.get("k"));
    var buf8: [8]u8 = undefined;
    try std.testing.expectError(error.CorruptCrc, db.getInto("k", &buf8));
}

test "crc Db: full detects bit rot via getInto buffer read" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{ .crc_check = .full });
    defer db.close();
    try db.put("k", "value");
    corruptPayloadByte(db.store, db.getRoot());
    var buf: [16]u8 = undefined;
    try std.testing.expectError(error.CorruptCrc, db.getInto("k", &buf));
}

test "crc Db: sample detects a corrupted sampled page via full-range scan" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{ .crc_check = .sample });
    defer db.close();
    // One batch -> sequential page allocation, all pages live (no COW churn);
    // with ~3000 keys the tree spans pages 3..~100, so page 64 is a live
    // tree page and a sampling hit.
    const entries = try alloc.alloc(cube.Entry, 3000);
    defer alloc.free(entries);
    for (entries, 0..) |*e, i| {
        e.* = .{ .key = try std.fmt.allocPrint(alloc, "k{d:0>6}", .{i}), .value = "v", .tombstone = false };
    }
    defer for (entries) |e| alloc.free(e.key);
    try db.putBatch(entries);
    try std.testing.expect(ms.next_free > 64); // page 64 exists

    // Corrupt ONLY the sampled hit page; every other page stays healthy, so
    // any CorruptCrc observed below must come from the sampled verification.
    corruptPayloadByte(db.store, 64);

    var saw_corrupt = false;
    var maybe_it: ?btree.Iterator = db.select(null, null) catch |e| blk: {
        try std.testing.expectEqual(error.CorruptCrc, e);
        break :blk null;
    };
    if (maybe_it) |*it| {
        defer it.deinit();
        while (true) {
            const r = it.next() catch |e| {
                try std.testing.expectEqual(error.CorruptCrc, e);
                saw_corrupt = true;
                break;
            };
            if (r == null) break;
        }
    }
    try std.testing.expect(saw_corrupt);
}

test "crc Db: sample skips healthy-path reads — non-hit corruption stays silent" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{ .crc_check = .sample });
    defer db.close();
    try db.put("k", "v"); // root lands on page 3 (3 % 64 != 0 -> not sampled)
    corruptPayloadByte(db.store, db.getRoot());
    const v = try db.get("k");
    defer alloc.free(v.?);
    try std.testing.expectEqualStrings("v", v.?);
}

// ===== wf-pi-3 (test worker) strengthening — plan M1/M2/M3/M9/M10 =====

test "crc: CrcCheck enum is exactly { off, sample, full } (M1)" {
    const fields = @typeInfo(wrt.CrcCheck).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("off", fields[0].name);
    try std.testing.expectEqualStrings("sample", fields[1].name);
    try std.testing.expectEqualStrings("full", fields[2].name);
}

test "crc Db: off full-range scan over corrupted page completes silently (M2)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    try db.put("k1", "v1");
    try db.put("k2", "v2");
    try db.put("k3", "v3");
    corruptPayloadByte(db.store, db.getRoot());
    // off: the iterator path (readNodePayloadFast callers) reads the damaged
    // root page without verifying — full walk completes, all values intact.
    var it = try db.select(null, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |e| {
        try std.testing.expectEqual(@as(usize, 2), e.value.len);
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), n);
}

test "crc Db: full detects bit rot via iterator scan (M3)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{ .crc_check = .full });
    defer db.close();
    try db.put("k1", "v1");
    try db.put("k2", "v2");
    corruptPayloadByte(db.store, db.getRoot());
    var saw_corrupt = false;
    var maybe_it: ?btree.Iterator = db.select(null, null) catch |e| blk: {
        try std.testing.expectEqual(error.CorruptCrc, e);
        saw_corrupt = true; // detection at iterator creation counts too
        break :blk null;
    };
    if (maybe_it) |*it| {
        defer it.deinit();
        while (true) {
            const r = it.next() catch |e| {
                try std.testing.expectEqual(error.CorruptCrc, e);
                saw_corrupt = true;
                break;
            };
            if (r == null) break;
        }
    }
    try std.testing.expect(saw_corrupt);
}

test "crc Db: off putBatch/get/select roundtrip — status quo, no regression (M9)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    const N = 200;
    const entries = try alloc.alloc(cube.Entry, N);
    defer alloc.free(entries);
    for (entries, 0..) |*e, i| {
        e.* = .{ .key = try std.fmt.allocPrint(alloc, "r{d:0>4}", .{i}), .value = "val", .tombstone = false };
    }
    defer for (entries) |e| alloc.free(e.key);
    try db.putBatch(entries);
    try std.testing.expectEqual(@as(u64, N), db.entryCount());
    // every key get()s its exact value back
    for (0..N) |i| {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "r{d:0>4}", .{i});
        const v = try db.get(k);
        defer alloc.free(v.?);
        try std.testing.expectEqualStrings("val", v.?);
    }
    // full-range scan sees all N entries
    var it = try db.select(null, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    try std.testing.expectEqual(N, n);
}

test "crc btree: readNodePayload (public API) always verifies, tier-independent (M10)" {
    var ms = newStore();
    defer ms.deinit();
    const s = ms.store();
    try writeLeafAt(s, 10, "k", "v");
    corruptPayloadByte(s, 10);
    // the public API contract is unchanged by T-35: it verifies, period
    try std.testing.expectError(error.CorruptCrc, btree.readNodePayload(s, 10));
    try writeLeafAt(s, 11, "k", "v");
    const payload = try btree.readNodePayload(s, 11);
    try std.testing.expectEqual(f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4, payload.len);
}

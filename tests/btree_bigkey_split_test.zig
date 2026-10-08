//! tests/btree_bigkey_split_test.zig — T-65: per-op put at key ≥62B + branch
//! split panics with index-out-of-bounds (pre-existing at base 8f578cd).
//!
//! Root cause (verified by measurement + arithmetic, see T-65-report.md):
//! `branchChunkLen`'s byte bookkeeping charges each admitted separator only
//! `4 + k.len` (klen field + key bytes) but every admitted separator also
//! introduces ONE MORE CHILD whose 4B page-number slot is never counted —
//! the baseline `3 + 4` pays only the FIRST child. A chunk admitting m
//! separators is really `3 + m*(4+klen) + 4*(m+1)` bytes, i.e. 4m bytes
//! larger than the chunker believes. Consequences by klen (branch with
//! C children overflows into the chunk loop at C≥60 for these shapes):
//!   - klen ≤ 56: 64-child chunk fits CAP anyway → OK;
//!   - 57 ≤ klen ≤ 61: real payload lands in (4068, 4096] → fits the raw
//!     PAGE_SIZE stack buffer (no panic) but exceeds NODE_PAYLOAD_CAP →
//!     writeNodePage's defense fires graceful error.PayloadTooLarge (LATE
//!     but safe);
//!   - klen ≥ 62: real payload > 4096 → OOB panic inside encodeBranchPayload
//!     (`index 4137, len 4096` — 4137 = exactly the first chunk's true size).
//! The issue's proposed frame ("branchChunkLen single-entry premise vs
//! insertIntoBranch fixed buf[0..pl]") is refined: the staging buffer is
//! sized from branchPayloadSize (correct math); the CHUNKER is what lies.
//!
//! Expected behavior after fix (decision, see report): the chunker must
//! produce only CAP-fitting chunks for ANY legal klen ≤ MAX_KEY_SIZE, so
//! puts with big keys SUCCEED (never panic, never the late graceful error).
//! putBatch's chunking calls the same branchChunkLen and is fixed by the
//! same one-line change (its own T-40 accounting was correct, the chunker
//! was not — no batch-side edit).

const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const FilePageStore = cube.file_page_store.FilePageStore;
const ps = cube.page_store;

const c = @import("cube_db").libc; // 0.17: @cImport removed

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

/// Sequential keys of exactly `klen` bytes ("{d:0>klen}"-style zero-padded,
/// fixed width via manual padding so width is runtime-independent).
fn makeKey(buf: []u8, i: usize) []const u8 {
    // decimal digits of i, right-aligned, zero-padded to buf.len
    var tmp: [24]u8 = undefined;
    const dec = std.fmt.bufPrint(&tmp, "{d}", .{i}) catch unreachable;
    @memset(buf, '0');
    @memcpy(buf[buf.len - dec.len ..], dec);
    return buf;
}

const N_PUTS: usize = 5000;
const VAL_LEN: usize = 200;

fn putSequentialKeys(allocator: std.mem.Allocator, path: []const u8, klen: usize, n: usize) !void {
    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    var db = try Db.open(allocator, fps.store(), .{});
    defer db.close();

    const value = try allocator.alloc(u8, VAL_LEN);
    defer allocator.free(value);
    @memset(value, 'v');
    const kbuf = try allocator.alloc(u8, klen);
    defer allocator.free(kbuf);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const k = makeKey(kbuf, i);
        try db.put(k, value);
    }
}

// (a) THE bug: 62B keys × 5000 per-op puts cross a branch split (≥62B real
// chunk payload > 4096 stack buf → OOB panic at base). Post-fix these puts
// must SUCCEED (root-cause conclusion: the chunker was lying about byte
// budgets; corrected accounting yields CAP-fitting chunks for every legal
// klen, so the write completes — no panic, no late graceful error).
test "T-65: 5000 per-op puts, 62B keys, 200B values — no panic, all land" {
    const allocator = std.heap.page_allocator;
    const path = ".t65_k62.db";
    defer unlinkPath(path);
    try putSequentialKeys(allocator, path, 62, N_PUTS);

    // Reopen and verify count + spot-check first/middle/last values.
    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    var db = try Db.open(allocator, fps.store(), .{});
    defer db.close();
    try std.testing.expectEqual(@as(u64, N_PUTS), db.entryCount());
    const kbuf = try allocator.alloc(u8, 62);
    defer allocator.free(kbuf);
    const vbuf = try allocator.alloc(u8, VAL_LEN);
    defer allocator.free(vbuf);
    for ([_]usize{ 0, N_PUTS / 2, N_PUTS - 1 }) |idx| {
        const k = makeKey(kbuf, idx);
        const got = (try db.get(k)).?;
        defer allocator.free(got);
        try std.testing.expectEqual(@as(usize, VAL_LEN), got.len);
        try std.testing.expectEqualSlices(u8, "vvvv", got[0..4]);
    }
}

// Boundary pin: the same shape one byte BELOW the panic line must also
// succeed post-fix (it used to die with the LATE graceful PayloadTooLarge
// at put #8850 — legal input rejected ~9000 puts in). This is the behavioral
// upgrade the fix buys beyond not-crashing.
test "T-65: 10000 per-op puts, 61B keys — previously late-graceful, now succeeds" {
    const allocator = std.heap.page_allocator;
    const path = ".t65_k61.db";
    defer unlinkPath(path);
    try putSequentialKeys(allocator, path, 61, 10000);

    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    var db = try Db.open(allocator, fps.store(), .{});
    defer db.close();
    try std.testing.expectEqual(@as(u64, 10000), db.entryCount());
}

// Boundary regression pin (issue text): 56B keys always worked — must stay
// working and byte-identical in semantics (per-op path unaffected by the
// chunker fix on shapes that already fit).
test "T-65: 5000 per-op puts, 56B keys — historical OK band stays OK" {
    const allocator = std.heap.page_allocator;
    const path = ".t65_k56.db";
    defer unlinkPath(path);
    try putSequentialKeys(allocator, path, 56, N_PUTS);
    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    var db = try Db.open(allocator, fps.store(), .{});
    defer db.close();
    try std.testing.expectEqual(@as(u64, N_PUTS), db.entryCount());
}

// Unit pin of the arithmetic itself: branchChunkLen must never return a
// chunk whose TRUE encoded size (branchPayloadSize of the chunk) exceeds
// NODE_PAYLOAD_CAP, for any legal separator length — including the
// near-MAX_KEY_SIZE extreme. This is the invariant whose violation was the
// bug; keeping it as a unit test makes the chunker's contract explicit.
test "T-65: branchChunkLen chunks always fit NODE_PAYLOAD_CAP (arithmetic invariant)" {
    const btree = cube.btree;
    const MAX_KLEN_TEST = 4051;
    var keys_buf: [128][MAX_KLEN_TEST]u8 = undefined;
    var keys: [128][]const u8 = undefined;
    inline for (.{ 56, 57, 60, 61, 62, 63, 80, 100, 1000, 4051 }) |klen| {
        var children: [65]u32 = undefined;
        for (&children, 0..) |*ch, i| ch.* = @intCast(i + 3); // arbitrary page numbers
        for (&keys, 0..) |*k, i| k.* = (makeKey(&keys_buf[i], i))[0..klen];
        const clen = btree.branchChunkLen(&keys, keys.len + 1, 64);
        // chunk = clen children + clen-1 keys; true size must fit CAP
        const pl = btree.branchPayloadSize(keys[0 .. clen - 1], children[0..clen]);
        try std.testing.expect(clen <= 64);
        try std.testing.expect(pl <= btree.NODE_PAYLOAD_CAP);
    }
}

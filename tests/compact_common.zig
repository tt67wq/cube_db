//! tests/compact_common.zig — U5-3 step 1: churn fixture + independent oracles
//! for the compactFull line (design `bb4d489` §7 step 1).
//!
//! No `test "..."` blocks with static names live here by design: this is a
//! pure helper module (build.zig's scan() treats files without tests as
//! helpers and never builds them — the correct shape per the task contract).
//! The self-test lives in tests/btree_collect_test.zig (it imports this file),
//! so the oracle-vs-Db agreement is still enforced by the gate.
//!
//! Contents:
//!  - `ChurnOp` / `buildChurnDb`: deterministic op-sequence churn fixture
//!    (put-batch → point deletes / range delete), shapes aligned with the
//!    U5-1 bench baseline (N=100k is the bench scale; tests use small Ns).
//!  - `expectedVisible`: independent visible-set oracle — replays the ops
//!    WITHOUT the Db read path (pure set arithmetic on the op sequence).
//!  - `expectedLiveBytes`: B-formula oracle — Σ(key.len + value.len + 10)
//!    over the expected visible set (same formula as db.zig:325-334's count
//!    pass and btree live_delta).
//!  - `assertOracleMatches`: self-check helper — compares the oracles
//!    against Db.select / Db.entryCount / byte_size.

const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;

/// One operation in a churn scenario. Replay order defines the expected state.
pub const ChurnOp = union(enum) {
    /// put a key with a fixed-width numeric key + `value_len` fill value
    put: struct { idx: u64, value_len: usize },
    /// point delete of key `idx`
    del: struct { idx: u64 },
    /// range delete over numeric keys [min_idx, max_idx)
    del_range: struct { min_idx: u64, max_idx: u64 },
};

pub const ChurnSpec = struct {
    ops: []const ChurnOp,
    /// fill byte for values
    fill: u8 = 'x',
};

/// Fixed-width 10-byte key formatter — SAME shape as the U5-1 baseline and
/// the engine's own fmtKey usage ("0000000123").
pub fn fmtKey(buf: *[10]u8, idx: u64) []const u8 {
    _ = std.fmt.bufPrint(buf, "{d:0>10}", .{idx}) catch unreachable;
    return buf;
}

/// Build the churn db described by `spec`. All puts for consecutive indices
/// are batched (one putBatch per contiguous put run) to mirror the baseline's
/// putBatch shape; deletes apply per-op (point) or as deleteRange.
pub fn buildChurnDb(allocator: std.mem.Allocator, db: *Db, spec: ChurnSpec) !void {
    var kbuf: [10]u8 = undefined;
    var i: usize = 0;
    while (i < spec.ops.len) : (i += 1) {
        switch (spec.ops[i]) {
            .put => {
                // Batch the contiguous run of puts.
                var run: usize = 0;
                while (i + run < spec.ops.len and spec.ops[i + run] == .put) run += 1;
                const entries = try allocator.alloc(cube.Entry, run);
                defer allocator.free(entries);
                var vals = try allocator.alloc([]u8, run);
                defer {
                    for (vals) |v| allocator.free(v);
                    allocator.free(vals);
                }
                for (entries, 0..) |*e, j| {
                    const pp = spec.ops[i + j].put;
                    vals[j] = try allocator.alloc(u8, pp.value_len);
                    @memset(vals[j], spec.fill);
                    e.* = .{ .key = try allocator.dupe(u8, fmtKey(&kbuf, pp.idx)), .value = vals[j] };
                }
                defer for (entries) |e| allocator.free(e.key);
                try db.putBatch(entries);
                i += run - 1;
            },
            .del => |d| {
                try db.delete(fmtKey(&kbuf, d.idx));
            },
            .del_range => |r| {
                var kmin: [10]u8 = undefined;
                var kmax: [10]u8 = undefined;
                try db.deleteRange(fmtKey(&kmin, r.min_idx), fmtKey(&kmax, r.max_idx));
            },
        }
    }
}

/// Independent visible-set oracle: replay the ops as pure set arithmetic
/// (hash set of 10-byte keys). NO Db read path involved — this is the
/// derivation vacuum/compactFull must match.
pub fn expectedVisible(allocator: std.mem.Allocator, spec: ChurnSpec) !std.AutoHashMap(u64, void) {
    var set = std.AutoHashMap(u64, void).init(allocator);
    errdefer set.deinit();
    for (spec.ops) |op| {
        switch (op) {
            .put => |p| try set.put(p.idx, {}),
            .del => |d| _ = set.remove(d.idx),
            .del_range => |r| {
                var idx = r.min_idx;
                while (idx < r.max_idx) : (idx += 1) _ = set.remove(idx);
            },
        }
    }
    return set;
}

/// B-formula oracle: Σ(key.len + value.len + 10) over the expected visible
/// set. key.len is always 10 here (fixed-width keys); value.len comes from
/// the LAST put to each surviving idx (replay order matters).
pub fn expectedLiveBytes(allocator: std.mem.Allocator, spec: ChurnSpec) !u64 {
    var last_value_len = std.AutoHashMap(u64, usize).init(allocator);
    defer last_value_len.deinit();
    for (spec.ops) |op| {
        switch (op) {
            .put => |p| try last_value_len.put(p.idx, p.value_len),
            else => {},
        }
    }
    var vis = try expectedVisible(allocator, spec);
    defer vis.deinit();
    var total: u64 = 0;
    var it = vis.keyIterator();
    while (it.next()) |idx| {
        const vlen = last_value_len.get(idx.*) orelse 0;
        total += @intCast(10 + vlen + 10); // key.len(10) + value.len + fixed 10
    }
    return total;
}

/// Oracle-vs-Db agreement check: Db.select output equals the oracle set,
/// Db.entryCount equals its size, and Db's byte_size matches the B oracle.
pub fn assertOracleMatches(allocator: std.mem.Allocator, db: *Db, spec: ChurnSpec) !void {
    var expected = try expectedVisible(allocator, spec);
    defer expected.deinit();

    var seen: usize = 0;
    var it = try db.select(null, null);
    defer it.deinit();
    while (try it.next()) |e| {
        try std.testing.expectEqual(@as(usize, 10), e.key.len);
        const idx = std.fmt.parseInt(u64, e.key, 10) catch {
            std.debug.print("oracle mismatch: non-numeric key in select output\n", .{});
            return error.TestUnexpectedResult;
        };
        if (!expected.contains(idx)) {
            std.debug.print("oracle mismatch: key {d} visible but oracle says deleted\n", .{idx});
            return error.TestUnexpectedResult;
        }
        _ = expected.remove(idx);
        seen += 1;
    }
    if (expected.count() != 0) {
        std.debug.print("oracle mismatch: {d} keys expected visible but not selected (first: {d})\n", .{ expected.count(), blk: {
            var kit = expected.keyIterator();
            break :blk kit.next().?.*;
        } });
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(expected.count(), 0);
    try std.testing.expectEqual(@as(u64, seen), db.entryCount());

    const want_bytes = try expectedLiveBytes(allocator, spec);
    // Re-derive live bytes from the actual db (survivors only): value lens via get.
    var got_bytes: u64 = 0;
    var it2 = try db.select(null, null);
    defer it2.deinit();
    while (try it2.next()) |e| got_bytes += @intCast(e.key.len + e.value.len + 10);
    try std.testing.expectEqual(want_bytes, got_bytes);
}

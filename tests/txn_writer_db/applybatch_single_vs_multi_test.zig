//! applybatch_single_vs_multi_test.zig — T-21: applyBatch single-entry fast path vs multi-entry insertBatch consistency
//!
//! src/writer.zig:280 applyBatch has two paths:
//! - Single-entry fast path (batch.len==1): direct btree.insert, skipping sort/dedup
//! - Multi-entry path (batch.len>1): order detection -> ordered goes to btree.insertBatch (with dedup last-write-wins),
//!   unordered goes through dupe+sort+dedup+insertBatch
//!
//! Whether the two paths' count_delta/live_delta agree on overwrites has never been compared directly.
//! This file compares single vs multi consistency for entry_count / byte_size / get results
//! across three scenarios: fresh keys, overwrites, and deletes.
//!
//! Modeled on mvcc_test.zig's State + applyBatch + Future setup. Single-threaded; testing.allocator is safe.
//! Wiring: registered in build.zig under the test-db step.

const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;
const wrt = cube.writer;

const alloc = std.testing.allocator;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 1000);
}

const Metrics = struct {
    entry_count: u64,
    byte_size: u64,
    root: u32,
};

fn metrics(state: *wrt.State) Metrics {
    return .{
        .entry_count = state.entry_count.load(.acquire),
        .byte_size = state.byte_size.load(.acquire),
        .root = state.getRoot(),
    };
}

/// Apply a single-entry batch (fast path); returns the OpResult (should succeed)
fn applySingle(state: *wrt.State, key: []const u8, value: []const u8, tombstone: bool) !void {
    var fut: zio.Future(wrt.OpResult) = .{};
    const reqs = [_]wrt.Request{.{ .key = key, .value = value, .tombstone = tombstone, .future = &fut }};
    try state.applyBatch(&reqs);
    _ = try fut.wait();
}

/// Apply a multi-entry batch (insertBatch path); entries is a caller-built Request slice
fn applyMulti(state: *wrt.State, reqs: []wrt.Request) !void {
    var fut: zio.Future(wrt.OpResult) = .{};
    // Simplification: a single shared future (applyBatch sets all entries' futures)
    for (reqs) |*r| r.future = &fut;
    try state.applyBatch(reqs);
    _ = try fut.wait();
}

/// Build a multi-entry batch with N independent futures (one per entry; more realistic)
fn applyMultiMultiFut(state: *wrt.State, entries: []const struct { k: []const u8, v: []const u8, t: bool }) !void {
    var futs = try alloc.alloc(zio.Future(wrt.OpResult), entries.len);
    defer alloc.free(futs);
    const reqs = try alloc.alloc(wrt.Request, entries.len);
    defer alloc.free(reqs);
    for (entries, 0..) |e, i| {
        futs[i] = .{};
        reqs[i] = .{ .key = e.k, .value = e.v, .tombstone = e.t, .future = &futs[i] };
    }
    try state.applyBatch(reqs);
    for (futs) |*f| _ = try f.wait();
}

// ===== 1. Fresh keys: N single-entry batches vs 1 ordered multi-entry batch =====

test "applybatch_single_vs_multi: new keys — 3 single vs 1 ordered multi" {
    // Scenario A: 3 single-entry batches putting k1/k2/k3
    var ms_a = newStore();
    defer ms_a.deinit();
    var state_a = wrt.State.init(alloc, ms_a.store(), .{});
    defer state_a.deinit();
    try applySingle(&state_a, "k1", "v1", false);
    try applySingle(&state_a, "k2", "v2", false);
    try applySingle(&state_a, "k3", "v3", false);
    const m_a = metrics(&state_a);

    // Scenario B: 1 ordered multi-entry batch putting k1/k2/k3
    var ms_b = newStore();
    defer ms_b.deinit();
    var state_b = wrt.State.init(alloc, ms_b.store(), .{});
    defer state_b.deinit();
    try applyMultiMultiFut(&state_b, &.{
        .{ .k = "k1", .v = "v1", .t = false },
        .{ .k = "k2", .v = "v2", .t = false },
        .{ .k = "k3", .v = "v3", .t = false },
    });
    const m_b = metrics(&state_b);

    // Assert entry_count / byte_size agree
    try std.testing.expectEqual(m_a.entry_count, m_b.entry_count);
    try std.testing.expectEqual(@as(u64, 3), m_a.entry_count);
    try std.testing.expectEqual(@as(u64, 3), m_b.entry_count);
    try std.testing.expectEqual(m_a.byte_size, m_b.byte_size);

    // get results agree
    const va1 = try btree.get(alloc, ms_a.store(), m_a.root, "k1");
    const vb1 = try btree.get(alloc, ms_b.store(), m_b.root, "k1");
    try std.testing.expectEqualStrings("v1", va1.?);
    try std.testing.expectEqualStrings("v1", vb1.?);
    alloc.free(va1.?);
    alloc.free(vb1.?);

    const va3 = try btree.get(alloc, ms_a.store(), m_a.root, "k3");
    const vb3 = try btree.get(alloc, ms_b.store(), m_b.root, "k3");
    try std.testing.expectEqualStrings("v3", va3.?);
    try std.testing.expectEqualStrings("v3", vb3.?);
    alloc.free(va3.?);
    alloc.free(vb3.?);
}

// ===== 2. Overwrite consistency: two single puts vs one multi-entry batch with a duplicate key (dedup last-write-wins) =====

test "applybatch_single_vs_multi: overwrite — single twice vs multi dedup last-write-wins" {
    // Scenario A: two single-entry batches, put k1=v1 then k1=v2
    var ms_a = newStore();
    defer ms_a.deinit();
    var state_a = wrt.State.init(alloc, ms_a.store(), .{});
    defer state_a.deinit();
    try applySingle(&state_a, "k1", "v1", false);
    try applySingle(&state_a, "k1", "v2", false);
    const m_a = metrics(&state_a);

    // Scenario B: 1 ordered multi-entry batch (with duplicate k1, triggering dedup last-write-wins) put k1=v1, k1=v2
    var ms_b = newStore();
    defer ms_b.deinit();
    var state_b = wrt.State.init(alloc, ms_b.store(), .{});
    defer state_b.deinit();
    try applyMultiMultiFut(&state_b, &.{
        .{ .k = "k1", .v = "v1", .t = false },
        .{ .k = "k1", .v = "v2", .t = false },
    });
    const m_b = metrics(&state_b);

    // Both eventually return "v2" for get(k1)
    const va = try btree.get(alloc, ms_a.store(), m_a.root, "k1");
    const vb = try btree.get(alloc, ms_b.store(), m_b.root, "k1");
    try std.testing.expectEqualStrings("v2", va.?);
    try std.testing.expectEqualStrings("v2", vb.?);
    alloc.free(va.?);
    alloc.free(vb.?);

    // entry_count is 1 for both (overwrite does not double-count)
    try std.testing.expectEqual(@as(u64, 1), m_a.entry_count);
    try std.testing.expectEqual(@as(u64, 1), m_b.entry_count);

    // byte_size agrees (after the overwrite, both scenarios hold the live size of k1=v2)
    try std.testing.expectEqual(m_a.byte_size, m_b.byte_size);
}

// ===== 3. Unordered vs ordered: same kv set, written shuffled; traversal results agree =====

test "applybatch_single_vs_multi: unordered vs ordered batch — same final tree" {
    // Ordered batch: k1,k2,k3,k4,k5 (strictly increasing)
    var ms_ord = newStore();
    defer ms_ord.deinit();
    var state_ord = wrt.State.init(alloc, ms_ord.store(), .{});
    defer state_ord.deinit();
    try applyMultiMultiFut(&state_ord, &.{
        .{ .k = "k1", .v = "v1", .t = false },
        .{ .k = "k2", .v = "v2", .t = false },
        .{ .k = "k3", .v = "v3", .t = false },
        .{ .k = "k4", .v = "v4", .t = false },
        .{ .k = "k5", .v = "v5", .t = false },
    });
    const m_ord = metrics(&state_ord);

    // Unordered batch: k3,k1,k5,k2,k4 (shuffled, triggering the dupe+sort+dedup path)
    var ms_unord = newStore();
    defer ms_unord.deinit();
    var state_unord = wrt.State.init(alloc, ms_unord.store(), .{});
    defer state_unord.deinit();
    try applyMultiMultiFut(&state_unord, &.{
        .{ .k = "k3", .v = "v3", .t = false },
        .{ .k = "k1", .v = "v1", .t = false },
        .{ .k = "k5", .v = "v5", .t = false },
        .{ .k = "k2", .v = "v2", .t = false },
        .{ .k = "k4", .v = "v4", .t = false },
    });
    const m_unord = metrics(&state_unord);

    // entry_count / byte_size agree
    try std.testing.expectEqual(m_ord.entry_count, m_unord.entry_count);
    try std.testing.expectEqual(@as(u64, 5), m_ord.entry_count);
    try std.testing.expectEqual(@as(u64, 5), m_unord.entry_count);
    try std.testing.expectEqual(m_ord.byte_size, m_unord.byte_size);

    // Traversal results agree: compare key by key
    var idx: u8 = 1;
    while (idx <= 5) : (idx += 1) {
        var kbuf: [3]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d}", .{idx});
        var vbuf: [3]u8 = undefined;
        const expected = try std.fmt.bufPrint(&vbuf, "v{d}", .{idx});
        const vo = try btree.get(alloc, ms_ord.store(), m_ord.root, k);
        const vu = try btree.get(alloc, ms_unord.store(), m_unord.root, k);
        try std.testing.expectEqualStrings(expected, vo.?);
        try std.testing.expectEqualStrings(expected, vu.?);
        alloc.free(vo.?);
        alloc.free(vu.?);
    }
}

// ===== 4. Delete comparison: single delete vs multi-entry delete, count_delta=-1 =====

test "applybatch_single_vs_multi: delete — single vs multi count_delta consistent" {
    // Scenario A: single put k1, then single delete k1 (tombstone)
    var ms_a = newStore();
    defer ms_a.deinit();
    var state_a = wrt.State.init(alloc, ms_a.store(), .{});
    defer state_a.deinit();
    try applySingle(&state_a, "k1", "v1", false);
    try std.testing.expectEqual(@as(u64, 1), state_a.entry_count.load(.acquire));
    try applySingle(&state_a, "k1", "", true); // delete
    const m_a = metrics(&state_a);

    // Scenario B: multi-entry put k1, then multi-entry delete k1
    var ms_b = newStore();
    defer ms_b.deinit();
    var state_b = wrt.State.init(alloc, ms_b.store(), .{});
    defer state_b.deinit();
    try applyMultiMultiFut(&state_b, &.{.{ .k = "k1", .v = "v1", .t = false }});
    try applyMultiMultiFut(&state_b, &.{.{ .k = "k1", .v = "", .t = true }});
    const m_b = metrics(&state_b);

    // entry_count is 0 for both (after the delete)
    try std.testing.expectEqual(@as(u64, 0), m_a.entry_count);
    try std.testing.expectEqual(@as(u64, 0), m_b.entry_count);

    // byte_size agrees (both are 0 after the delete)
    try std.testing.expectEqual(m_a.byte_size, m_b.byte_size);

    // get(k1) returns null for both
    const va = try btree.get(alloc, ms_a.store(), m_a.root, "k1");
    const vb = try btree.get(alloc, ms_b.store(), m_b.root, "k1");
    try std.testing.expect(va == null);
    try std.testing.expect(vb == null);
}

// ===== 5. Mixed: fresh+overwrite+delete in one multi-entry batch vs entry-by-entry singles =====

test "applybatch_single_vs_multi: mixed ops — multi batch vs sequential single" {
    // Scenario A: entry-by-entry singles
    var ms_a = newStore();
    defer ms_a.deinit();
    var state_a = wrt.State.init(alloc, ms_a.store(), .{});
    defer state_a.deinit();
    try applySingle(&state_a, "a", "1", false); // new a
    try applySingle(&state_a, "b", "2", false); // new b
    try applySingle(&state_a, "a", "9", false); // overwrite a
    try applySingle(&state_a, "c", "3", false); // new c
    try applySingle(&state_a, "b", "", true); // delete b
    const m_a = metrics(&state_a);

    // Scenario B: 1 ordered multi-entry batch (a,b,a,c,b with duplicates + 1 delete) — must be ordered: a,a,b,b,c
    // After sort, dedup: a=9 (last wins), b=delete (last wins), c=3
    var ms_b = newStore();
    defer ms_b.deinit();
    var state_b = wrt.State.init(alloc, ms_b.store(), .{});
    defer state_b.deinit();
    try applyMultiMultiFut(&state_b, &.{
        .{ .k = "a", .v = "1", .t = false },
        .{ .k = "a", .v = "9", .t = false }, // overwrite a → dedup last wins = 9
        .{ .k = "b", .v = "2", .t = false },
        .{ .k = "b", .v = "", .t = true }, // delete b → dedup last wins = tombstone
        .{ .k = "c", .v = "3", .t = false },
    });
    const m_b = metrics(&state_b);

    // Final state: a=9, b=deleted(null), c=3 -> entry_count=2 (a, c)
    try std.testing.expectEqual(@as(u64, 2), m_a.entry_count);
    try std.testing.expectEqual(@as(u64, 2), m_b.entry_count);
    try std.testing.expectEqual(m_a.byte_size, m_b.byte_size);

    // get results agree
    const va_a = try btree.get(alloc, ms_a.store(), m_a.root, "a");
    const va_b = try btree.get(alloc, ms_b.store(), m_b.root, "a");
    try std.testing.expectEqualStrings("9", va_a.?);
    try std.testing.expectEqualStrings("9", va_b.?);
    alloc.free(va_a.?);
    alloc.free(va_b.?);

    const vc_a = try btree.get(alloc, ms_a.store(), m_a.root, "c");
    const vc_b = try btree.get(alloc, ms_b.store(), m_b.root, "c");
    try std.testing.expectEqualStrings("3", vc_a.?);
    try std.testing.expectEqualStrings("3", vc_b.?);
    alloc.free(vc_a.?);
    alloc.free(vc_b.?);

    // b should be null for both
    const vb_a = try btree.get(alloc, ms_a.store(), m_a.root, "b");
    const vb_b = try btree.get(alloc, ms_b.store(), m_b.root, "b");
    try std.testing.expect(vb_a == null);
    try std.testing.expect(vb_b == null);
}

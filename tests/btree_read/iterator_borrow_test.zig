//! iterator_borrow_test.zig - T-29 Phase B: contract tests for the borrowed Iterator
//!
//! RED stage (this file landed first, failing at runtime against the old full-dupe Iterator):
//! - Borrow contract (T5): after next() the previous entry is invalidated - overflow values are
//!   assembled in a reused iterator buffer, so the previous entry's value slice is overwritten
//!   once the next entry is assembled (the observable surface of borrow semantics).
//!   The old implementation heap-duped (previous entry stayed valid) -> this test fails.
//! - Zero-allocation scan (T1): a full scan of inline values performs 0 allocations across
//!   select+next (fixed-size descent stack O(depth), borrowed payload, no per-entry dupe).
//!   The old implementation allocated on every descent/leaf/entry -> this test fails.
//! - Snapshot pin (T2): while an iterator is open (Db.select) an MVCC reader slot is held;
//!   COW dirty pages committed by the writer stay in pending_free, unclaimed until deinit.
//!   The old select did not pin -> this test fails.
//!
//! Also regression locks (already passing on the old implementation, guarding against borrow
//! conversion regressions):
//! - Range golden comparison (T4): multi-leaf/bounds/tombstone semantics cross-checked against per-key getInto.
//! - Overflow value iteration (T3): >3800B overflow chains byte-exact (including consecutive overflow entries).
//! - Snapshot data stability (T6): while iterating, writer overwrites are invisible; the iterator still sees snapshot values.
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;
const Db = cube.Db;

const alloc = std.testing.allocator;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 200000);
}

/// Counting allocator: wraps std.testing.allocator, counts alloc calls (resize/remap don't count - not new allocations)
const CountingAllocator = struct {
    child: std.mem.Allocator,
    count: usize = 0,

    fn vAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.child.rawAlloc(len, alignment, ra);
    }
    fn vResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(buf, alignment, new_len, ra);
    }
    fn vRemap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(buf, alignment, new_len, ra);
    }
    fn vFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, alignment, ra);
    }
    const vtable = std.mem.Allocator.VTable{
        .alloc = vAlloc,
        .resize = vResize,
        .remap = vRemap,
        .free = vFree,
    };
    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

// ===== T1: zero-allocation scan =====

test "iterator borrow: inline-value full scan performs zero allocations" {
    var counter = CountingAllocator{ .child = alloc };
    const calloc = counter.allocator();

    var ms = ps.MemPageStore.init(calloc, 200000);
    defer ms.deinit();
    var db = try Db.open(calloc, ms.store(), .{});
    defer db.close();

    // 200 inline entries (spanning multiple leaves), written first (write path may allocate freely)
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>4}", .{i});
        try db.put(k, "inline-value");
    }

    // reset counter: select + full next must be 0 allocations
    counter.count = 0;
    var it = try db.select(null, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |e| {
        try std.testing.expectEqualStrings("inline-value", e.value);
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 200), n);
    try std.testing.expectEqual(@as(usize, 0), counter.count);
}

// ===== T2: snapshot pin (MVCC reader slot) =====

test "iterator borrow: Db.select pins read snapshot - dirty pages held until deinit" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    try db.put("k1", "v1");
    try db.put("k2", "v2");

    var it = try db.select(null, null);
    // pin is active: reader count >= 1 now

    // writer commits mid-iteration (COW produces new pages, old pages become dirty)
    try db.put("k3", "v3");

    // dirty pages must stay in pending_free (iterator still borrows old pages), not reclaimed
    try std.testing.expect(db.state.pendingFreeCount() > 0);

    // iterator still sees the snapshot: k3 invisible (not present in the snapshot taken at select)
    var seen: usize = 0;
    var saw_k3 = false;
    while (try it.next()) |e| {
        seen += 1;
        if (std.mem.eql(u8, e.key, "k3")) saw_k3 = true;
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
    try std.testing.expect(!saw_k3);

    // deinit (last reader exits) -> dirty pages reclaimed
    it.deinit();
    try std.testing.expectEqual(@as(usize, 0), db.state.pendingFreeCount());
}

// ===== T3: overflow value iteration golden comparison =====

test "iterator borrow: overflow values scanned byte-exact (consecutive overflow entries)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    // 3 consecutive overflow entries (distinct value patterns, guarding against buffer-reuse crosstalk) + inline entries around them
    var ov: [4200]u8 = undefined;
    const vals = [3][]const u8{ "A", "B", "C" };
    for (vals, 0..) |tag, vi| {
        @memset(&ov, tag[0]);
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "ov{d}", .{vi});
        try db.put(k, &ov);
    }
    try db.put("zz-inline", "small");

    var it = try db.select(null, null);
    defer it.deinit();
    var ov_seen: usize = 0;
    var inline_seen: usize = 0;
    while (try it.next()) |e| {
        if (e.value.len > 3800) {
            try std.testing.expectEqual(@as(usize, 4200), e.value.len);
            const want_tag = vals[ov_seen];
            for (e.value) |b| try std.testing.expectEqual(want_tag[0], b);
            // byte-exact golden comparison against getInto
            var gbuf: [4200]u8 = undefined;
            const gn = (try db.getInto(e.key, &gbuf)).?;
            try std.testing.expectEqualSlices(u8, e.value, gbuf[0..gn]);
            ov_seen += 1;
        } else {
            inline_seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), ov_seen);
    try std.testing.expectEqual(@as(usize, 1), inline_seen);
}

// ===== T4: range golden comparison (multi-leaf + bounds + tombstones) =====

test "iterator borrow: range scan golden - bounds, tombstones, multi-leaf" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    // 300 entries (multiple leaves and branches), even keys store value=original key, odd keys deleted
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>4}", .{i});
        try db.put(k, k);
    }
    i = 1;
    while (i < 300) : (i += 2) {
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>4}", .{i});
        try db.delete(k);
    }

    // half-open range [k0100, k0200): 50 even keys, odd ones excluded by tombstone
    var it = try db.select("k0100", "k0200");
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |e| {
        var kbuf: [8]u8 = undefined;
        const want = try std.fmt.bufPrint(&kbuf, "k{d:0>4}", .{100 + 2 * n});
        try std.testing.expectEqualStrings(want, e.key);
        try std.testing.expectEqualStrings(want, e.value); // value == key (as written)
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 50), n);

    // null bounds, full scan: 150 surviving
    var full = try db.select(null, null);
    defer full.deinit();
    var total: usize = 0;
    while (try full.next()) |_| total += 1;
    try std.testing.expectEqual(@as(usize, 150), total);
    try std.testing.expectEqual(db.entryCount(), total);
}

// ===== T5: borrow contract - previous entry invalidated after next() =====

test "iterator borrow: next() invalidates previous entry (overflow buffer reuse)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    // two overflow entries with distinct value patterns
    var a: [4200]u8 = undefined;
    @memset(&a, 'A');
    var b: [4200]u8 = undefined;
    @memset(&b, 'B');
    try db.put("ov1", &a);
    try db.put("ov2", &b);

    var it = try db.select(null, null);
    defer it.deinit();

    const e1 = (try it.next()).?;
    try std.testing.expectEqualStrings("ov1", e1.key);
    for (e1.value) |c| try std.testing.expectEqual(@as(u8, 'A'), c);

    const e2 = (try it.next()).?;
    try std.testing.expectEqualStrings("ov2", e2.key);
    for (e2.value) |c| try std.testing.expectEqual(@as(u8, 'B'), c);

    // Borrow contract: e1.value and e2.value reuse the same assembly buffer -> e1.value has been overwritten with B.
    // After borrow conversion this is an explicit contract (previous entry is invalid after next(); callers must not use it);
    // in the old heap-dupe implementation e1.value was still A -> this assertion failed (RED signal).
    for (e1.value) |c| try std.testing.expectEqual(@as(u8, 'B'), c);
}

// ===== T6: snapshot data stability (mid-iteration overwrite, iterator sees old values) =====

test "iterator borrow: concurrent overwrite invisible to open iterator" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    try db.put("k1", "old1");
    try db.put("k2", "old2");
    try db.put("k3", "old3");

    var it = try db.select(null, null);
    defer it.deinit();

    const e1 = (try it.next()).?;
    try std.testing.expectEqualStrings("old1", e1.value);

    // overwrite two keys
    try db.put("k2", "new2");
    try db.put("k3", "new3");

    // iterator still sees snapshot old values
    const e2 = (try it.next()).?;
    try std.testing.expectEqualStrings("old2", e2.value);
    const e3 = (try it.next()).?;
    try std.testing.expectEqualStrings("old3", e3.value);
    try std.testing.expect((try it.next()) == null);
}

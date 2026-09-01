//! applybatch_single_vs_multi_test.zig — T-21: applyBatch 单条 fast path vs 多条 insertBatch 一致性
//!
//! src/writer.zig:280 applyBatch 两条路径：
//! - 单条 fast path（batch.len==1）：直接 btree.insert，跳过 sort/dedup
//! - 多条 path（batch.len>1）：有序性检测 → 有序走 btree.insertBatch（含 dedup last-write-wins），
//!   无序走 dupe+sort+dedup+insertBatch
//!
//! 两条路径的 count_delta/live_delta 在 overwrite 场景下是否一致从未直接对比。
//! 本文件在新建 key / overwrite / delete 三场景下对比单条 vs 多条的
//! entry_count / byte_size / get 结果一致性。
//!
//! 参考 mvcc_test.zig 的 State + applyBatch + Future 搭建。单线程，testing.allocator 安全。
//! 接入：build.zig 注册到 test-db step。

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

/// 应用单条 batch（走 fast path），返回 OpResult（应成功）
fn applySingle(state: *wrt.State, key: []const u8, value: []const u8, tombstone: bool) !void {
    var fut: zio.Future(wrt.OpResult) = .{};
    const reqs = [_]wrt.Request{.{ .key = key, .value = value, .tombstone = tombstone, .future = &fut }};
    try state.applyBatch(&reqs);
    _ = try fut.wait();
}

/// 应用多条 batch（走 insertBatch path），entries 须调用方构造好的 Request 切片
fn applyMulti(state: *wrt.State, reqs: []wrt.Request) !void {
    var fut: zio.Future(wrt.OpResult) = .{};
    // 简化：只支持单一 future（多 entry 共享一个 future，applyBatch 会 set 所有）
    for (reqs) |*r| r.future = &fut;
    try state.applyBatch(reqs);
    _ = try fut.wait();
}

/// 构造 N 个独立 future 的多条 batch（每 entry 一个 future，更真实）
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

// ===== 1. 新建 key：单条 ×N vs 多条有序 ×1 =====

test "applybatch_single_vs_multi: new keys — 3 single vs 1 ordered multi" {
    // 场景 A：3 次单条 batch put k1/k2/k3
    var ms_a = newStore();
    defer ms_a.deinit();
    var state_a = wrt.State.init(alloc, ms_a.store(), .{});
    defer state_a.deinit();
    try applySingle(&state_a, "k1", "v1", false);
    try applySingle(&state_a, "k2", "v2", false);
    try applySingle(&state_a, "k3", "v3", false);
    const m_a = metrics(&state_a);

    // 场景 B：1 次多条有序 batch put k1/k2/k3
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

    // 断言 entry_count / byte_size 一致
    try std.testing.expectEqual(m_a.entry_count, m_b.entry_count);
    try std.testing.expectEqual(@as(u64, 3), m_a.entry_count);
    try std.testing.expectEqual(@as(u64, 3), m_b.entry_count);
    try std.testing.expectEqual(m_a.byte_size, m_b.byte_size);

    // get 结果一致
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

// ===== 2. overwrite 一致性：单条两次 vs 多条含重复 key（dedup last-write-wins）=====

test "applybatch_single_vs_multi: overwrite — single twice vs multi dedup last-write-wins" {
    // 场景 A：两次单条 batch put k1=v1 然后 k1=v2
    var ms_a = newStore();
    defer ms_a.deinit();
    var state_a = wrt.State.init(alloc, ms_a.store(), .{});
    defer state_a.deinit();
    try applySingle(&state_a, "k1", "v1", false);
    try applySingle(&state_a, "k1", "v2", false);
    const m_a = metrics(&state_a);

    // 场景 B：1 次多条有序 batch（含重复 k1，触发 dedup last-write-wins）put k1=v1, k1=v2
    var ms_b = newStore();
    defer ms_b.deinit();
    var state_b = wrt.State.init(alloc, ms_b.store(), .{});
    defer state_b.deinit();
    try applyMultiMultiFut(&state_b, &.{
        .{ .k = "k1", .v = "v1", .t = false },
        .{ .k = "k1", .v = "v2", .t = false },
    });
    const m_b = metrics(&state_b);

    // 两者最终 get(k1) 都返回 "v2"
    const va = try btree.get(alloc, ms_a.store(), m_a.root, "k1");
    const vb = try btree.get(alloc, ms_b.store(), m_b.root, "k1");
    try std.testing.expectEqualStrings("v2", va.?);
    try std.testing.expectEqualStrings("v2", vb.?);
    alloc.free(va.?);
    alloc.free(vb.?);

    // entry_count 都为 1（overwrite 不翻倍）
    try std.testing.expectEqual(@as(u64, 1), m_a.entry_count);
    try std.testing.expectEqual(@as(u64, 1), m_b.entry_count);

    // byte_size 一致（overwrite 后两场景都是 k1=v2 的 live size）
    try std.testing.expectEqual(m_a.byte_size, m_b.byte_size);
}

// ===== 3. 无序 vs 有序：同一组 kv，shuffle 顺序写入，遍历结果一致 =====

test "applybatch_single_vs_multi: unordered vs ordered batch — same final tree" {
    // 有序 batch：k1,k2,k3,k4,k5（严格递增）
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

    // 无序 batch：k3,k1,k5,k2,k4（乱序，触发 dupe+sort+dedup 路径）
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

    // entry_count / byte_size 一致
    try std.testing.expectEqual(m_ord.entry_count, m_unord.entry_count);
    try std.testing.expectEqual(@as(u64, 5), m_ord.entry_count);
    try std.testing.expectEqual(@as(u64, 5), m_unord.entry_count);
    try std.testing.expectEqual(m_ord.byte_size, m_unord.byte_size);

    // 遍历结果一致：逐个 key 对比
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

// ===== 4. delete 对比：单条 delete vs 多条 delete，count_delta=-1 =====

test "applybatch_single_vs_multi: delete — single vs multi count_delta consistent" {
    // 场景 A：单条 put k1, 然后 单条 delete k1（tombstone）
    var ms_a = newStore();
    defer ms_a.deinit();
    var state_a = wrt.State.init(alloc, ms_a.store(), .{});
    defer state_a.deinit();
    try applySingle(&state_a, "k1", "v1", false);
    try std.testing.expectEqual(@as(u64, 1), state_a.entry_count.load(.acquire));
    try applySingle(&state_a, "k1", "", true); // delete
    const m_a = metrics(&state_a);

    // 场景 B：多条 batch put k1, 然后 多条 batch delete k1
    var ms_b = newStore();
    defer ms_b.deinit();
    var state_b = wrt.State.init(alloc, ms_b.store(), .{});
    defer state_b.deinit();
    try applyMultiMultiFut(&state_b, &.{.{ .k = "k1", .v = "v1", .t = false }});
    try applyMultiMultiFut(&state_b, &.{.{ .k = "k1", .v = "", .t = true }});
    const m_b = metrics(&state_b);

    // 两者 entry_count 都为 0（delete 后）
    try std.testing.expectEqual(@as(u64, 0), m_a.entry_count);
    try std.testing.expectEqual(@as(u64, 0), m_b.entry_count);

    // byte_size 一致（delete 后都是 0）
    try std.testing.expectEqual(m_a.byte_size, m_b.byte_size);

    // get(k1) 都返回 null
    const va = try btree.get(alloc, ms_a.store(), m_a.root, "k1");
    const vb = try btree.get(alloc, ms_b.store(), m_b.root, "k1");
    try std.testing.expect(va == null);
    try std.testing.expect(vb == null);
}

// ===== 5. 混合：新建+overwrite+delete 在同一多条 batch vs 逐条单条 =====

test "applybatch_single_vs_multi: mixed ops — multi batch vs sequential single" {
    // 场景 A：逐条单条
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

    // 场景 B：1 次多条有序 batch（a,b,a,c,b 含重复 + 1 delete）— 需有序：a,a,b,b,c
    // 排序后 dedup：a=9（last wins），b=delete（last wins），c=3
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

    // 最终：a=9, b=deleted(null), c=3 → entry_count=2（a, c）
    try std.testing.expectEqual(@as(u64, 2), m_a.entry_count);
    try std.testing.expectEqual(@as(u64, 2), m_b.entry_count);
    try std.testing.expectEqual(m_a.byte_size, m_b.byte_size);

    // get 结果一致
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

    // b 都应 null
    const vb_a = try btree.get(alloc, ms_a.store(), m_a.root, "b");
    const vb_b = try btree.get(alloc, ms_b.store(), m_b.root, "b");
    try std.testing.expect(vb_a == null);
    try std.testing.expect(vb_b == null);
}

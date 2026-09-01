//! btree_readfast_consistency_test.zig — T-17: readNodePayloadFast vs readNodePayload 一致性
//!
//! src/btree.zig:49 readNodePayloadFast 跳过 CRC 校验（热读路径），readNodePayload（:39）带 CRC。
//! 注释称 COW 保证不需校验，但无测试证明 fast 与 full 读出一致。本文件构造 leaf/branch/
//! overflow/满 leaf 四种页，断言两者返回 payload 内容完全一致（std.mem.eql）。
//!
//! readNodePayload / readNodePayloadFast / writeNodePage 均 pub，直接构造页后双读对比。
//! 接入：tests/btree_storage/btree_test.zig comptime 块。

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const ps = cube.page_store;
const btree = cube.btree;

const allocator = std.testing.allocator;

fn newStore(n: u32) ps.MemPageStore {
    return ps.MemPageStore.init(allocator, n);
}

/// 构造合法 leaf payload（1 entry，内联值，不触发溢出）到 buf，返回实际长度
fn buildLeafPayload(buf: []u8, key: []const u8, value: []const u8) !usize {
    var ms = ps.MemPageStore.init(allocator, 64);
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);
    const entries = [_]btree.LeafEntry{
        .{ .tombstone = false, .key = key, .value = value },
    };
    return try btree.encodeLeafPayload(buf, &entries, ms.store(), &dirty);
}

/// 构造合法 branch payload（n children）到 buf，返回实际长度
fn buildBranchPayload(buf: []u8, n_children: u32) usize {
    // n children, n-1 keys "m0","m1"...
    var keys: [8][]const u8 = .{ "k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7" };
    var children: [9]u32 = .{ 10, 20, 30, 40, 50, 60, 70, 80, 90 };
    return btree.encodeBranchPayload(buf, keys[0 .. n_children - 1], children[0..n_children]);
}

/// 双读同一页，断言 payload 切片内容完全一致
fn assertFastEqFull(store: ps.PageStore, page_no: u32) !void {
    const slow = try btree.readNodePayload(store, page_no);
    const fast = try btree.readNodePayloadFast(store, page_no);
    // 同一页应返回等长 payload（均 [HEADER_SIZE..PAGE_SIZE-4]）
    try std.testing.expectEqual(slow.len, fast.len);
    try std.testing.expect(std.mem.eql(u8, slow, fast));
}

test "readfast: leaf page payload consistent" {
    var ms = newStore(64);
    defer ms.deinit();
    const s = ms.store();

    var payload_buf: [f2.PAGE_SIZE]u8 = undefined;
    const pl = try buildLeafPayload(&payload_buf, "key1", "val1");
    const pn = try s.allocPage();
    try btree.writeNodePage(s, pn, f2.PAGE_TYPE_LEAF, 1, payload_buf[0..pl]);

    try assertFastEqFull(s, pn);
}

test "readfast: full-ish leaf page payload consistent" {
    // 逼近满 leaf：多个 entry 使 payload 接近上限。LEAF_MAX_ENTRIES=32，
    // 用 32 个短 key/value 填满（leafPayloadSize 逼近 PAGE_SIZE-28-4）。
    var ms = newStore(64);
    defer ms.deinit();
    const s = ms.store();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    // 构造 32 个 entry（逼近 LEAF_MAX_ENTRIES）
    var entries: [32]btree.LeafEntry = undefined;
    var kbufs: [32][4]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const k = try std.fmt.bufPrint(&kbufs[i], "k{d:0>2}", .{i});
        entries[i] = .{ .tombstone = false, .key = k, .value = "v" };
    }
    var payload_buf: [f2.PAGE_SIZE]u8 = undefined;
    const pl = try btree.encodeLeafPayload(&payload_buf, &entries, s, &dirty);
    try std.testing.expect(pl > 100); // 确实写了内容

    const pn = try s.allocPage();
    try btree.writeNodePage(s, pn, f2.PAGE_TYPE_LEAF, @intCast(entries.len), payload_buf[0..pl]);

    try assertFastEqFull(s, pn);
}

test "readfast: branch page payload consistent" {
    var ms = newStore(64);
    defer ms.deinit();
    const s = ms.store();

    var payload_buf: [f2.PAGE_SIZE]u8 = undefined;
    const pl = buildBranchPayload(&payload_buf, 5); // 5 children, 4 keys
    const pn = try s.allocPage();
    try btree.writeNodePage(s, pn, f2.PAGE_TYPE_BRANCH, 5, payload_buf[0..pl]);

    try assertFastEqFull(s, pn);
}

test "readfast: overflow page payload consistent" {
    // overflow 页：raw data chunk 作为 payload，page_type=OVERFLOW
    var ms = newStore(64);
    defer ms.deinit();
    const s = ms.store();

    var chunk: [4068]u8 = undefined; // OVERFLOW_PAYLOAD = PAGE_SIZE-24-4 = 4068
    var i: usize = 0;
    while (i < chunk.len) : (i += 1) chunk[i] = @intCast(i % 251);

    const pn = try s.allocPage();
    try btree.writeNodePage(s, pn, f2.PAGE_TYPE_OVERFLOW, 0, &chunk);

    try assertFastEqFull(s, pn);

    // 额外断言：overflow payload 内容与写入 chunk 一致（fast 与 full 都对得上）
    const fast = try btree.readNodePayloadFast(s, pn);
    try std.testing.expect(std.mem.eql(u8, &chunk, fast[0..chunk.len]));
}

test "readfast: multiple pages in a tree all consistent" {
    // 建一棵多页 btree（insert 多 key 触发 leaf split + branch），对 root
    // 及若干页双读对比（验证真实 COW 树的页一致性，而非仅人工构造页）
    var ms = newStore(10000);
    defer ms.deinit();
    const s = ms.store();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    var root: u32 = btree.NULL_ROOT;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key{d:0>3}", .{i});
        const wr = try btree.insert(allocator, s, root, k, "val", false, &dirty);
        root = wr.new_root;
    }
    try std.testing.expect(root != btree.NULL_ROOT);

    // root 页（可能是 branch 或 leaf）双读一致
    try assertFastEqFull(s, root);

    // dirty list 里的页（COW 出的旧/新页）也应双读一致
    for (dirty.items, 0..) |pn, idx| {
        if (idx >= 8) break; // 抽查前 8 页
        try assertFastEqFull(s, pn);
    }
}

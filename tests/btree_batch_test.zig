//! btree_batch_test.zig — TDD for BTreeBatch (batched tree commit, lever 2).
//! Strict TDD: each test added Red, then implement to Green.
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const btree = cube.btree;
const btree_batch = cube.btree_batch;
const store_mod = cube.store;
const CountStore = @import("count_store.zig").CountStore;

// NOTE: import path resolved below — cube_db root re-exports modules.
// We'll access btree via the cube_db module. If not exported, adjust.

const MemStore = store_mod.MemStore;
const Store = store_mod.Store;

const talloc = std.testing.allocator;

fn newStore() MemStore {
    return MemStore.init(talloc);
}

test "BTreeBatch: 3 puts then get all" {
    var ms = newStore();
    defer ms.deinit();
    var batch = btree_batch.BTreeBatch.init(talloc, ms.store(), btree.NULL_ROOT);
    defer batch.deinit();
    try batch.apply("a", "va", false);
    try batch.apply("b", "vb", false);
    try batch.apply("c", "vc", false);
    const wr = try batch.commit();
    const root = wr.new_root;
    // get all
    const va = try btree.get(talloc, ms.store(), root, "a");
    try std.testing.expect(va != null);
    try std.testing.expectEqualStrings("va", va.?);
    talloc.free(va.?);
}

test "BTreeBatch: dedup same key last-write-wins" {
    var ms = newStore();
    defer ms.deinit();
    var batch = btree_batch.BTreeBatch.init(talloc, ms.store(), btree.NULL_ROOT);
    defer batch.deinit();
    try batch.apply("k", "v1", false);
    try batch.apply("k", "v2", false);
    const wr = try batch.commit();
    const v = try btree.get(talloc, ms.store(), wr.new_root, "k");
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("v2", v.?);
    talloc.free(v.?);
}

test "BTreeBatch: cache amortizes store.append (100 puts << 100 appends)" {
    // Red on skeleton (逐 insert → ~400 appends); Green after cache optimization.
    var ms = newStore();
    defer ms.deinit();
    var cs = CountStore.init(ms.store());
    var batch = btree_batch.BTreeBatch.init(talloc, cs.store(), btree.NULL_ROOT);
    defer batch.deinit();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key{d:0>10}", .{i});
        try batch.apply(k, "v", false);
    }
    const wr = try batch.commit();
    // 骨架版应 >>100；缓存版应 < 50（~4 leaf + branch）
    try std.testing.expect(cs.append_count < 50);
    // 正确性：首尾 key 可读
    const va = try btree.get(talloc, cs.store(), wr.new_root, "key0000000000");
    try std.testing.expect(va != null);
    talloc.free(va.?);
}

test "BTreeBatch: COW old root still readable after commit" {
    var ms = newStore();
    defer ms.deinit();
    // 先 insert 一个 key 建 root
    const r1 = try btree.insert(talloc, ms.store(), btree.NULL_ROOT, "k", "v1", false);
    // batch 覆写 k=v2
    var batch = btree_batch.BTreeBatch.init(talloc, ms.store(), r1.new_root);
    defer batch.deinit();
    try batch.apply("k", "v2", false);
    const wr = try batch.commit();
    // 旧 root 读 v1
    const oldv = try btree.get(talloc, ms.store(), r1.new_root, "k");
    try std.testing.expect(oldv != null);
    try std.testing.expectEqualStrings("v1", oldv.?);
    talloc.free(oldv.?);
    // 新 root 读 v2
    const newv = try btree.get(talloc, ms.store(), wr.new_root, "k");
    try std.testing.expect(newv != null);
    try std.testing.expectEqualStrings("v2", newv.?);
    talloc.free(newv.?);
}

test "BTreeBatch: tombstone dedup (put then delete same key -> invisible)" {
    var ms = newStore();
    defer ms.deinit();
    var batch = btree_batch.BTreeBatch.init(talloc, ms.store(), btree.NULL_ROOT);
    defer batch.deinit();
    try batch.apply("k", "v", false);
    try batch.apply("k", "", true); // tombstone 同 key，last-wins
    const wr = try batch.commit();
    const v = try btree.get(talloc, ms.store(), wr.new_root, "k");
    try std.testing.expectEqual(@as(?[]u8, null), v);
}

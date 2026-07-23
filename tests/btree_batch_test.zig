//! btree_batch_test.zig — TDD for BTreeBatch (batched tree commit, lever 2).
//! Strict TDD: each test added Red, then implement to Green.
const std = @import("std");
const zio = @import("zio");
const btree = @import("cube_db").btree; // if btree exported; else via root
const store_mod = @import("cube_db").store;

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
    var batch = btree.BTreeBatch.init(talloc, ms.store(), btree.NULL_ROOT);
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

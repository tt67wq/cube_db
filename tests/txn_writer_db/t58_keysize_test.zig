//! t58_keysize_test.zig — T-58：key 尺寸入口校验与 btree 实际容量的 ±1 边界锁死
//!
//! 复验结论（2026-09 当前 main，T-58 report §1）：issue 声称的「4044 可写 /
//! 4045 PayloadTooLarge」是 **N-1 修复（6d1d318）之前的过期数字**——组合感知
//! overflow 判定落地后，入口界 MAX_KEY_SIZE=4051 与 btree 实际容量**精确一致**：
//!   - key ≤ 4051：任意 value（内联或溢出链）均可写（实测 empty/1B/100B/5000B
//!     四剖面 + staged 路径全部 last_ok=4051）；
//!   - key = 4052：入口报 error.KeyTooLarge（put/putDirect/delete/WriteTxn 全
//!     入口，先于 staging/commit）。
//! 本文件把 ±1 边界锁死为回归网（当前态即 GREEN——复验未发现不一致，故无
//! RED；「上限不一致」类回归由本文件的 KeyTooLarge-vs-PayloadTooLarge 错误
//! 语义断言 + mutation 验证兜住，见 report §mutation）。
//!
//! 7 字节构成（逐项对 src/btree.zig）：MAX_KEY_SIZE = NODE_PAYLOAD_CAP(4068
//! = 4096 - 页头 24 - 尾 CRC 4) − 叶头 3（kind 1 + nkeys 2）− 单 entry 最小编码
//! 10（tombstone 1 + klen 4 + vlen 4 + flags 1）− 溢出页号 4 = 4051。issue 的
//! 7 字节差 = vlen(11) − 溢出指针(4)：N-1 之前 value ≤ 3800 一律内联，vlen=11
//! 的 value 在 k=4045 时叶 payload = 3+10+4045+11 = 4069 > 4068 → commit 期
//! PayloadTooLarge（4044 恰好 4068 可写）——正是 issue 的数字。

const std = @import("std");
const c = @cImport({
    @cInclude("unistd.h");
});
const cube = @import("cube_db");
const btree = cube.btree;
const ps = cube.page_store;
const dbi = cube.db;

const alloc = std.testing.allocator;

const MAX_KEY = btree.MAX_KEY_SIZE; // 4051

fn fillKey(len: usize, fill: u8) ![]u8 {
    const k = try alloc.alloc(u8, len);
    @memset(k, fill);
    return k;
}

fn fillVal(len: usize, fill: u8) ![]u8 {
    const v = try alloc.alloc(u8, len);
    @memset(v, fill);
    return v;
}

// ---- t58 t1: 入口放行的最大 key（4051）—— 三种 value 剖面全部可写 ----

test "t58 t1: max allowed key (MAX_KEY_SIZE) puts and reads back, three value profiles" {
    const profiles = [_]struct { name: []const u8, vlen: usize }{
        .{ .name = "empty", .vlen = 0 },
        .{ .name = "inline-small", .vlen = 4 }, // 预算恰 4：内联边界
        .{ .name = "overflow-chain", .vlen = 5000 }, // 走溢出链（叶内 4B 页号）
    };
    for (profiles) |p| {
        var ms = ps.MemPageStore.init(alloc, 1 << 22);
        defer ms.deinit();
        var db = try dbi.Db.open(alloc, ms.store(), .{});
        defer db.close();

        const k = try fillKey(MAX_KEY, 0xAB);
        defer alloc.free(k);
        const v = try fillVal(p.vlen, 0xCD);
        defer alloc.free(v);

        try db.putDirect(k, v); // put+commit 成功（入口放行的最大 key）
        const got = try db.get(k);
        defer if (got) |g| alloc.free(g);
        try std.testing.expect(got != null);
        try std.testing.expectEqual(@as(usize, p.vlen), got.?.len);
        try std.testing.expectEqualSlices(u8, v, got.?);
    }
}

// ---- t58 t2: 最大+1 —— 全入口报 error.KeyTooLarge（入口层，非 commit 期 PayloadTooLarge）----

test "t58 t2: MAX_KEY_SIZE+1 is rejected with error.KeyTooLarge at every entry point" {
    var ms = ps.MemPageStore.init(alloc, 1 << 22);
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), .{});
    defer db.close();

    const k = try fillKey(MAX_KEY + 1, 0xAB);
    defer alloc.free(k);

    // 入口层错误语义：恰为 KeyTooLarge（若实现错位，这里会变成 commit 期的
    // PayloadTooLarge 或成功——mutation 验证见 report）
    try std.testing.expectError(error.KeyTooLarge, db.put(k, "v")); // staged 入口
    try std.testing.expectError(error.KeyTooLarge, db.putDirect(k, "v"));
    try std.testing.expectError(error.KeyTooLarge, db.delete(k));
    try std.testing.expectError(error.KeyTooLarge, db.putBatch(&[_]cube.Entry{
        .{ .key = "ok", .value = "1", .tombstone = false },
        .{ .key = k, .value = "v", .tombstone = false },
    }));
    {
        var txn = try db.beginWriteTxn();
        defer txn.deinit();
        try std.testing.expectError(error.KeyTooLarge, txn.put(k, "v"));
    }
    // staged 未写入（入口拒绝先于 staging）
    try db.put("ok", "1");
    try db.flush();
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
}

// ---- t58 t3: staged 路径 + FilePageStore 真落盘 reopen（持久化维度）----

test "t58 t3: staged put of max key persists via FilePageStore reopen; +1 stays entry-rejected" {
    const path = ".test_t58_keysize.db";
    {
        var fps = try cube.file_page_store.FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try dbi.Db.open(alloc, fps.store(), .{});
        defer db.close();

        const k = try fillKey(MAX_KEY, 0xBC);
        defer alloc.free(k);
        const v = try fillVal(5000, 0xDE); // 溢出链
        defer alloc.free(v);
        try db.put(k, v); // staged
        try db.flush(); // commit

        const k1 = try fillKey(MAX_KEY + 1, 0xBC);
        defer alloc.free(k1);
        try std.testing.expectError(error.KeyTooLarge, db.put(k1, "v"));
    }
    { // reopen：最大 key 数据持久
        var fps = try cube.file_page_store.FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try dbi.Db.open(alloc, fps.store(), .{});
        defer db.close();
        const k = try fillKey(MAX_KEY, 0xBC);
        defer alloc.free(k);
        const got = try db.get(k);
        defer if (got) |g| alloc.free(g);
        try std.testing.expect(got != null);
        try std.testing.expectEqual(@as(usize, 5000), got.?.len);
    }
    _ = c.unlink(@ptrCast(path));
}

// ---- t58 t4: 墓碑面不误伤（item 5）—— MAX key 的 delete 走通，t38 墓碑约束独立 ----

test "t58 t4: tombstone surface — max-key delete works, near-max range endpoints unaffected" {
    var ms = ps.MemPageStore.init(alloc, 1 << 22);
    defer ms.deinit();
    var db = try dbi.Db.open(alloc, ms.store(), .{});
    defer db.close();

    const k = try fillKey(MAX_KEY, 0xAA);
    defer alloc.free(k);
    try db.putDirect(k, "v");
    try db.delete(k); // 墓碑 entry = 3+10+4051 = 4064 ≤ 4068（ TombPayload 独立约束）
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
    // 幂等：再删不炸
    try db.delete(k);
    // deleteRange 端点用近-MAX key（succ(k) 紧凑编码 4052B ≤ TOMB 单端 4052B 上限）
    try db.putDirect("m1", "v");
    try db.deleteRange("m1", k); // 端点 k=4051B：T-38-3 约束面独立于 checkKeySize
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

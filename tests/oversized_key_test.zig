//! oversized_key_test.zig — T-33 (U-6)：key 尺寸入口校验 RED→GREEN
//!
//! RED 阶段（本 commit）：`btree.MAX_KEY_SIZE` 尚不存在、各写入口尚无校验，
//! 本文件编译失败 / 断言失败，即为预期 RED 状态。
//! GREEN 阶段：所有能携带用户 key 的写入口对超限 key 优雅返回
//! `error.KeyTooLarge`（不 panic、不越界、不进 btree encode 路径），
//! 恰好等于上限的 key 正常成功。
//!
//! 上限语义（推导见 src/btree.zig MAX_KEY_SIZE 注释）：
//! 叶页可用 payload = PAGE_SIZE - PAGE_HEADER_SIZE - 4(尾 CRC) = 4068B；
//! 单条目最小编码 = 叶头 3B + [tombstone 1 + klen 4 + key + vlen 4 + flags 1
//! + overflow page_no 4]（value 可走 overflow 只占 4B，key 无此逃生通道）。
//! MAX_KEY_SIZE = 4068 - 3 - 14 = 4051。

const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const btree = cube.btree;
const ps = cube.page_store;

const MAX_KEY = btree.MAX_KEY_SIZE;

fn newDb(allocator: std.mem.Allocator, ms: *ps.MemPageStore) !*Db {
    return Db.open(allocator, ms.store(), .{});
}

fn bigKey(allocator: std.mem.Allocator, len: usize) ![]u8 {
    const k = try allocator.alloc(u8, len);
    @memset(k, 'z');
    return k;
}

// ---- 各写入口：超限 key 必须 error.KeyTooLarge ----

test "oversized: Db.put rejects key > MAX_KEY_SIZE" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const big = try bigKey(std.testing.allocator, MAX_KEY + 1);
    defer std.testing.allocator.free(big);
    try std.testing.expectError(error.KeyTooLarge, db.put(big, "v"));

    // 拒绝后 db 仍可用
    try db.put("ok", "v");
    const v = try db.get("ok");
    defer std.testing.allocator.free(v.?);
    try std.testing.expectEqualStrings("v", v.?);
}

test "oversized: Db.put micro-batch path rejects immediately (not at flush)" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 100 } });
    defer db.close();

    const big = try bigKey(std.testing.allocator, MAX_KEY + 1);
    defer std.testing.allocator.free(big);
    // 一次 put 即触发，不等 flush
    try std.testing.expectError(error.KeyTooLarge, db.put(big, "v"));
    // 无残留 staging：flush 是 no-op，库里没东西
    try db.flush();
    const v = try db.get(big);
    try std.testing.expect(v == null);
}

test "oversized: Db.putDirect rejects" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const big = try bigKey(std.testing.allocator, MAX_KEY + 1);
    defer std.testing.allocator.free(big);
    try std.testing.expectError(error.KeyTooLarge, db.putDirect(big, "v"));
}

test "oversized: Db.putBatch rejects and applies nothing" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const big = try bigKey(std.testing.allocator, MAX_KEY + 1);
    defer std.testing.allocator.free(big);
    const entries = [_]cube.Entry{
        .{ .key = "a", .value = "1" },
        .{ .key = big, .value = "2" },
    };
    try std.testing.expectError(error.KeyTooLarge, db.putBatch(&entries));
    // 批次原子拒绝：合法条目也不落库
    const v = try db.get("a");
    try std.testing.expect(v == null);
}

test "oversized: WriteTxn.put rejects at put time (before commit)" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    var w = try db.beginWriteTxn();
    defer w.deinit();
    const big = try bigKey(std.testing.allocator, MAX_KEY + 1);
    defer std.testing.allocator.free(big);
    // put 阶段即报错，而非 commit
    try std.testing.expectError(error.KeyTooLarge, w.put(big, "v"));
    try w.commit();
}

// ---- delete：tombstone 同样携带 key，统一按同一上限拒绝 ----
// （tombstone 的 value 为空，理论上可放宽 4B；统一上限换取更简单的
//   用户契约：一个 MAX_KEY_SIZE 对所有入口生效。见 db.zig 注释。）

test "oversized: Db.delete rejects oversized key" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const big = try bigKey(std.testing.allocator, MAX_KEY + 1);
    defer std.testing.allocator.free(big);
    try std.testing.expectError(error.KeyTooLarge, db.delete(big));
}

test "oversized: Db.deleteDirect / WriteTxn.delete reject oversized key" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const big = try bigKey(std.testing.allocator, MAX_KEY + 1);
    defer std.testing.allocator.free(big);
    try std.testing.expectError(error.KeyTooLarge, db.deleteDirect(big));

    var w = try db.beginWriteTxn();
    defer w.deinit();
    try std.testing.expectError(error.KeyTooLarge, w.delete(big));
    try w.commit();
}

// ---- deleteRange：min/max 只是 select 边界、从不落库，不校验 ----

test "oversized: deleteRange bounds are never stored — no KeyTooLarge" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    try db.put("a", "1");
    try db.put("m", "2");

    const big = try bigKey(std.testing.allocator, MAX_KEY + 1);
    defer std.testing.allocator.free(big);

    // (null, big)：大上界，删掉所有 < big 的 key（全部）
    try db.deleteRange(null, big);
    var it = try db.select(null, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 0), n);

    // (big, null)：大下界，删除 nothing，不报错
    try db.deleteRange(big, null);
}

// ---- 边界：恰好等于上限的 key 必须成功 ----

test "boundary: key exactly MAX_KEY_SIZE succeeds (inline value, exact fit)" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const k = try bigKey(std.testing.allocator, MAX_KEY);
    defer std.testing.allocator.free(k);
    // 3B 叶头 + 10B 条目开销 + 4051B key + 4B value = 4068B，精确占满叶页
    try db.put(k, "abcd");
    const v = try db.get(k);
    defer std.testing.allocator.free(v.?);
    try std.testing.expectEqualStrings("abcd", v.?);
}

test "boundary: max key with overflow value succeeds" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const k = try bigKey(std.testing.allocator, MAX_KEY);
    defer std.testing.allocator.free(k);
    const val = try std.testing.allocator.alloc(u8, MAX_KEY + 1000); // > MAX_INLINE_VALUE → overflow 链
    defer std.testing.allocator.free(val);
    @memset(val, 'v');
    try db.put(k, val);
    const v = try db.get(k);
    defer std.testing.allocator.free(v.?);
    try std.testing.expectEqualSlices(u8, val, v.?);
}

test "boundary: two max-size keys split correctly" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const k1 = try bigKey(std.testing.allocator, MAX_KEY);
    defer std.testing.allocator.free(k1);
    const k2 = try bigKey(std.testing.allocator, MAX_KEY);
    defer std.testing.allocator.free(k2);
    @memset(k1, 'y'); // k1 < k2 (bigKey fills 'z')

    try db.put(k1, "1");
    try db.put(k2, "2"); // 触发叶分裂，separator 也是 max-size key

    const v1 = try db.get(k1);
    defer std.testing.allocator.free(v1.?);
    const v2 = try db.get(k2);
    defer std.testing.allocator.free(v2.?);
    try std.testing.expectEqualStrings("1", v1.?);
    try std.testing.expectEqualStrings("2", v2.?);
    try std.testing.expectEqual(@as(u64, 2), db.entryCount());
}

// ---- 对照：value 无此限制（overflow 链本就为 value 而设）----

test "control: oversized value is fine (overflow chain)" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const val = try std.testing.allocator.alloc(u8, 100_000);
    defer std.testing.allocator.free(val);
    @memset(val, 'x');
    try db.put("big-value", val);
    const v = try db.get("big-value");
    defer std.testing.allocator.free(v.?);
    try std.testing.expectEqualSlices(u8, val, v.?);
}

// ====================================================================
// T-33 test worker 补充（ws1-pi-2，依 docs/evolution/T-33-ws1-pi-2-testplan.md
// 补齐矩阵缺口：B2 绝对锚点 4056 / B3 巨型 key / B4 有数据树（split 路径）
// / B6 计数不变 / B7 读路径负对照 / D2 墓碑批条目 / D3 同 key last-wins
// / A7 上限 key 生命周期 / A8+C3 txn 边界与可用性 / A9 全合法批次 / F3 文件重开
// ====================================================================

test "supp B2: absolute anchor — key 4056 (beyond every derivable ceiling) rejected" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    // 4056 超出一切可推导上限（空 value 理论上限 4055），必须拒绝。
    // 同时覆盖 4052–4055 带：本实现选择统一 4051（tombstone 理论上还可宽 4B，
    // 统一常量换取更简单的用户契约，见 db.zig checkKeySize 注释）。
    const k4056 = try bigKey(std.testing.allocator, 4056);
    defer std.testing.allocator.free(k4056);
    try std.testing.expectError(error.KeyTooLarge, db.put(k4056, ""));

    const k4055 = try bigKey(std.testing.allocator, 4055); // 空 value 时物理可放下，但超出统一上限
    defer std.testing.allocator.free(k4055);
    try std.testing.expectError(error.KeyTooLarge, db.put(k4055, ""));
    try std.testing.expectError(error.KeyTooLarge, db.delete(k4055)); // tombstone 同一上限
}

test "supp B3: huge key (100KB, old stack-smash band) rejected gracefully" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    // 修复前该输入会命中 buf[0..pl] 栈溢出档（pl=100013 ≫ 4096）。
    const huge = try bigKey(std.testing.allocator, 100_000);
    defer std.testing.allocator.free(huge);
    try std.testing.expectError(error.KeyTooLarge, db.put(huge, "v"));
    try std.testing.expectError(error.KeyTooLarge, db.delete(huge));

    const entries = [_]cube.Entry{.{ .key = huge, .value = "", .tombstone = true }};
    try std.testing.expectError(error.KeyTooLarge, db.putBatch(&entries));
}

test "supp B4+B6: populated tree (split path) rejects; counts unchanged; usable after" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    // 非空树：走 insertIntoLeaf → payload_cap → split 路径，与空库新根路径互补
    for (0..100) |i| {
        var kb: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kb, "k{d:0>4}", .{i});
        try db.put(k, "v");
    }
    try std.testing.expectEqual(@as(u64, 100), db.entryCount());

    const big = try bigKey(std.testing.allocator, MAX_KEY + 1);
    defer std.testing.allocator.free(big);
    try std.testing.expectError(error.KeyTooLarge, db.put(big, "v"));

    // 拒绝不留残留：计数不变，引擎继续可用，compact 正常
    try std.testing.expectEqual(@as(u64, 100), db.entryCount());
    try db.put("after", "ok");
    try db.compact();
    try std.testing.expectEqual(@as(u64, 101), db.entryCount());
}

test "supp B7: read path unaffected — get/getInto/select on oversized key" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    try db.put("a", "1");
    const big = try bigKey(std.testing.allocator, MAX_KEY + 1);
    defer std.testing.allocator.free(big);

    const v = try db.get(big);
    try std.testing.expect(v == null); // 读路径只比较不编码，安全返回 null

    var buf: [8]u8 = undefined;
    const n = try db.getInto(big, &buf);
    try std.testing.expect(n == null);

    var it = try db.select(big, big); // [big, big) 空区间
    defer it.deinit();
    var cnt: usize = 0;
    while (try it.next()) |_| cnt += 1;
    try std.testing.expectEqual(@as(usize, 0), cnt);
}

test "supp D2: putBatch tombstone entry with oversized key rejected" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    try db.put("a", "1");
    const big = try bigKey(std.testing.allocator, MAX_KEY + 1);
    defer std.testing.allocator.free(big);
    // usage §3.3 批量删除配方形态：tombstone=true 条目同样逐条校验
    const dels = [_]cube.Entry{
        .{ .key = "a", .value = "", .tombstone = true },
        .{ .key = big, .value = "", .tombstone = true },
    };
    try std.testing.expectError(error.KeyTooLarge, db.putBatch(&dels));
    // 原子拒绝：合法墓碑未应用，a 仍在
    const v = try db.get("a");
    defer std.testing.allocator.free(v.?);
    try std.testing.expectEqualStrings("1", v.?);
}

test "supp D3+A9: putBatch all-valid; last-wins; single max key per batch" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    // 注：含 >1 条大 key 的同批 putBatch 会触发【已知缺陷 F-1】（见
    // test-report.md：多条合法尺寸条目合并超页容量时 insertBatchFresh/
    // insertBatchSplitLeaves 按条数盲分块，Debug panic / ReleaseFast UB），
    // 此处刻意让每批的合并字节数 ≤ 叶页容量 4068，不踩已知缺陷。

    // (1) 全小尺寸混合批：正常提交
    const e1 = [_]cube.Entry{
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "2" },
    };
    try db.putBatch(&e1);
    try std.testing.expectEqual(@as(u64, 2), db.entryCount());

    // (2) 同 key 两条：last-wins，不增条目
    const e2 = [_]cube.Entry{
        .{ .key = "dup", .value = "first" },
        .{ .key = "dup", .value = "last" },
    };
    try db.putBatch(&e2);
    try std.testing.expectEqual(@as(u64, 3), db.entryCount());
    const vd = try db.get("dup");
    defer std.testing.allocator.free(vd.?);
    try std.testing.expectEqualStrings("last", vd.?);

    // (3) 单条上限 key 批（3+10+4051+4=4068 恰好占满一叶）：成功。
    // 必须在【空库】上跑：向非空树插入/批插大 key 会触发【已知缺陷 F-1c】
    // （insertIntoLeafSplit 按条数盲分裂，大 key 与邻居同侧时 >4068 →
    // writeNodePage panic；见 test-report.md）。空库走 insertBatchFresh
    // 单叶精确放下，不踩缺陷。
    {
        var ms2 = ps.MemPageStore.init(std.testing.allocator, 100000);
        defer ms2.deinit();
        var db2 = try newDb(std.testing.allocator, &ms2);
        defer db2.close();

        const kmax = try bigKey(std.testing.allocator, MAX_KEY);
        defer std.testing.allocator.free(kmax);
        const e3 = [_]cube.Entry{.{ .key = kmax, .value = "abcd" }};
        try db2.putBatch(&e3);
        try std.testing.expectEqual(@as(u64, 1), db2.entryCount());
        const vm = try db2.get(kmax);
        defer std.testing.allocator.free(vm.?);
        try std.testing.expectEqualStrings("abcd", vm.?);
    }
}

test "supp A7: max-size key full lifecycle — put, get, overwrite, delete" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const k = try bigKey(std.testing.allocator, MAX_KEY);
    defer std.testing.allocator.free(k);

    try db.put(k, "1");
    try db.put(k, "2"); // 覆盖更新（替换同 key entry，不增条目）
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
    const v = try db.get(k);
    defer std.testing.allocator.free(v.?);
    try std.testing.expectEqualStrings("2", v.?);

    try db.delete(k); // tombstone
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
    const gone = try db.get(k);
    try std.testing.expect(gone == null);
}

test "supp A8+C3: WriteTxn boundary key commits; txn usable after reject" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    // txn 内上限 key 正常提交
    {
        var w = try db.beginWriteTxn();
        defer w.deinit();
        const k = try bigKey(std.testing.allocator, MAX_KEY);
        defer std.testing.allocator.free(k);
        try w.put(k, "tv");
        try w.commit();
        const v = try db.get(k);
        defer std.testing.allocator.free(v.?);
        try std.testing.expectEqualStrings("tv", v.?);
    }
    // 拒绝后 txn 不被毒化：后续正常 put + commit 成功
    {
        var w = try db.beginWriteTxn();
        defer w.deinit();
        const big = try bigKey(std.testing.allocator, MAX_KEY + 1);
        defer std.testing.allocator.free(big);
        try std.testing.expectError(error.KeyTooLarge, w.put(big, "x"));
        try std.testing.expectError(error.KeyTooLarge, w.delete(big));
        try w.put("recover", "ok");
        try w.commit();
        const v = try db.get("recover");
        defer std.testing.allocator.free(v.?);
        try std.testing.expectEqualStrings("ok", v.?);
    }
}

/// 删除测试残留文件（repo 惯用法：libc unlink，见 crash_putbatch_test.zig）
const c = @cImport({
    @cInclude("unistd.h");
});

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

test "supp F3: FilePageStore — reject + close/reopen stays clean" {
    const alloc = std.testing.allocator;
    const path = ".test_oversized_key_fps.db";
    defer unlinkPath(path);

    const big = try bigKey(alloc, MAX_KEY + 1);
    defer alloc.free(big);
    const kmax = try bigKey(alloc, MAX_KEY);
    defer alloc.free(kmax);

    {
        var fps = try cube.file_page_store.FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();

        // mmap 路径同样优雅拒绝（不写穿邻页）
        try std.testing.expectError(error.KeyTooLarge, db.put(big, "v"));
        try db.put(kmax, "mmap"); // 上限 key 落盘成功
        try std.testing.expectEqual(@as(u64, 1), db.entryCount());
    }
    // 重开：无超限残留，上限 key 完整回读
    {
        var fps = try cube.file_page_store.FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try Db.open(alloc, fps.store(), .{});
        defer db.close();
        try std.testing.expectEqual(@as(u64, 1), db.entryCount());
        const v = try db.get(kmax);
        defer alloc.free(v.?);
        try std.testing.expectEqualStrings("mmap", v.?);

        // 重开后拒绝依然有效
        try std.testing.expectError(error.KeyTooLarge, db.put(big, "v"));
    }
}

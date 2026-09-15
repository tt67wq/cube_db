//! n1_composite_overflow_test.zig — N-1：put 组合条目溢出 panic 修复（方向 B）
//!
//! RED 阶段（本 commit）：`inlineValueBudget` 尚不存在，needsOverflow 等判定点
//! 只看 value.len。探路报告 §3 边界表的 #7/#8/#11-#14 panic（integer overflow /
//! index OOB），本文件预期失败/崩溃，即为 RED 状态。
//!
//! GREEN 阶段：组合感知 overflow —— 内联预算 = min(MAX_INLINE_VALUE,
//! NODE_PAYLOAD_CAP-3-10-key.len)。组合超限时无论 value 多小都走溢出链
//! （叶内 4B 页号）。原本 panic 的输入全部变为可存储，读回逐字节一致。
//!
//! 断言合同（每条 RED 用例）：
//! ① 存储成功（不 panic 不报错）；② get 后逐字节比对 key/value（小 value
//! 走溢出链是新路径，必须显式验读回）；③ entryCount 正确；④ 覆盖/删除后
//! 无泄漏（std.testing.allocator 全程校验，溢出链经 freeOverflowPages 回收）。
//! ⑤ 全量 zig build test 不回归（基线 436/437+1 skipped）。
//!
//! 控制组（修复前后都绿）：#6 恰好内联用满预算、#1 空键空值、#2 MAX key、
//! #9 key>MAX_KEY_SIZE 仍 error.KeyTooLarge（保持原样，不新增错误）。

const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const btree = cube.btree;
const ps = cube.page_store;

const MAX_KEY = btree.MAX_KEY_SIZE;
const INLINE = btree.MAX_INLINE_VALUE; // 3800
const PAYLOAD_CAP = btree.NODE_PAYLOAD_CAP; // 4068

fn newDb(allocator: std.mem.Allocator, ms: *ps.MemPageStore) !*Db {
    return Db.open(allocator, ms.store(), .{});
}

/// 用可校验的伪随机字节填充（非全零），读回逐字节比对才有意义
fn fillBuf(allocator: std.mem.Allocator, len: usize, seed: u8) ![]u8 {
    const b = try allocator.alloc(u8, len);
    for (b, 0..) |*p, i| p.* = seed +% @as(u8, @intCast(i % 251));
    return b;
}

/// 核心断言合同：存 → 逐字节读回 → entryCount → 覆盖（换 value）→ 再读回 →
/// 删除 → get null。全程 std.testing.allocator 兜底泄漏。
fn roundtripPut(db: *Db, key: []const u8, value: []const u8) !void {
    // ① 存储 + ③ entryCount（只数 key，不数 value）
    try db.put(key, value);
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());

    // ② 逐字节读回（小 value 走溢出链是新路径）
    const got = try db.get(key);
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualSlices(u8, value, got.?);

    // ④ 覆盖：旧溢出链必须被 freeOverflowPages 回收（覆盖大→小/小→大交叉）
    try db.put(key, "shrunken");
    const got2 = try db.get(key);
    try std.testing.expect(got2 != null);
    defer std.testing.allocator.free(got2.?);
    try std.testing.expectEqualStrings("shrunken", got2.?);
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());

    // ④ 删除：墓碑覆盖，溢出链回收，get miss
    try db.delete(key);
    const gone = try db.get(key);
    try std.testing.expect(gone == null);
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

test "N-1 #6 control: klen+vlen=4055 exactly fills inline budget (stays inline)" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    // 2005 + 2050 = 4055 = 4068 - 3 - 10 → 恰好内联用满，控制组
    const k = try fillBuf(std.testing.allocator, 2005, 0xA1);
    defer std.testing.allocator.free(k);
    const v = try fillBuf(std.testing.allocator, 2050, 0xB2);
    defer std.testing.allocator.free(v);
    try db.putDirect(k, v);
    const got = try db.get(k);
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualSlices(u8, v, got.?);
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
}

test "N-1 #7 RED: klen+vlen=4056 (1B over) — value must escape to overflow chain" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const k = try fillBuf(std.testing.allocator, 2005, 0xC3);
    defer std.testing.allocator.free(k);
    const v = try fillBuf(std.testing.allocator, 2051, 0xD4);
    defer std.testing.allocator.free(v);
    try roundtripPut(db, k, v);
}

test "N-1 #8a RED: key=4000 value=64 fresh tree putDirect" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const k = try fillBuf(std.testing.allocator, 4000, 0xE5);
    defer std.testing.allocator.free(k);
    const v = try fillBuf(std.testing.allocator, 64, 0xF6);
    defer std.testing.allocator.free(v);
    try roundtripPut(db, k, v);
}

test "N-1 #8b RED: key=4000 value=64 non-fresh leaf root" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    // 先放一条小 key 让树非 fresh（单叶根），再触发
    try db.putDirect("anchor", "a");
    const k = try fillBuf(std.testing.allocator, 4000, 0xE5);
    defer std.testing.allocator.free(k);
    const v = try fillBuf(std.testing.allocator, 64, 0xF6);
    defer std.testing.allocator.free(v);
    try db.putDirect(k, v);
    const got = try db.get(k);
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualSlices(u8, v, got.?);
    try std.testing.expectEqual(@as(u64, 2), db.entryCount());
}

test "N-1 #8c RED: key=4000 value=64 after branch root (500 small keys)" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    // 500 条小 key 撑出 branch 根，走 insertIntoBranch 路径
    for (0..500) |i| {
        var kb: [8]u8 = undefined;
        _ = try std.fmt.bufPrint(&kb, "k{d:0>7}", .{i});
        try db.putDirect(&kb, "v");
    }
    try std.testing.expectEqual(@as(u64, 500), db.entryCount());

    const k = try fillBuf(std.testing.allocator, 4000, 0xE5);
    defer std.testing.allocator.free(k);
    const v = try fillBuf(std.testing.allocator, 64, 0xF6);
    defer std.testing.allocator.free(v);
    try db.putDirect(k, v);
    const got = try db.get(k);
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualSlices(u8, v, got.?);
    try std.testing.expectEqual(@as(u64, 501), db.entryCount());
}

test "N-1 #11 RED: putBatch single entry key=4000 value=64" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const k = try fillBuf(std.testing.allocator, 4000, 0x11);
    defer std.testing.allocator.free(k);
    const v = try fillBuf(std.testing.allocator, 64, 0x22);
    defer std.testing.allocator.free(v);
    try db.putBatch(&.{.{ .key = k, .value = v }});
    const got = try db.get(k);
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualSlices(u8, v, got.?);
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
}

test "N-1 #12 RED: putBatch multiple sorted incl. key=4000 value=64" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const k = try fillBuf(std.testing.allocator, 4000, 0x11);
    defer std.testing.allocator.free(k);
    const v = try fillBuf(std.testing.allocator, 64, 0x22);
    defer std.testing.allocator.free(v);
    // 有序（'a' < 4000 填充 < 'z'）→ insertBatch 有序路径
    try db.putBatch(&.{
        .{ .key = "a", .value = "va" },
        .{ .key = k, .value = v },
        .{ .key = "z", .value = "vz" },
    });
    const got = try db.get(k);
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualSlices(u8, v, got.?);
    // 邻居完整性：同批其它条目也须读回正确
    const ga = try db.get("a");
    defer std.testing.allocator.free(ga.?);
    try std.testing.expectEqualStrings("va", ga.?);
    const gz = try db.get("z");
    defer std.testing.allocator.free(gz.?);
    try std.testing.expectEqualStrings("vz", gz.?);
    try std.testing.expectEqual(@as(u64, 3), db.entryCount());
}

test "N-1 #13 RED: putBatch multiple unsorted incl. key=4000 value=64" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const k = try fillBuf(std.testing.allocator, 4000, 0x33);
    defer std.testing.allocator.free(k);
    const v = try fillBuf(std.testing.allocator, 64, 0x44);
    defer std.testing.allocator.free(v);
    // 无序（'z' 在 4000 填充之前）→ applyBatch 归并排序路径
    try db.putBatch(&.{
        .{ .key = "z", .value = "vz" },
        .{ .key = k, .value = v },
        .{ .key = "a", .value = "va" },
    });
    const got = try db.get(k);
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualSlices(u8, v, got.?);
    try std.testing.expectEqual(@as(u64, 3), db.entryCount());
}

test "N-1 #14 RED: WriteTxn.put key=4000 value=64 + commit" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const k = try fillBuf(std.testing.allocator, 4000, 0x55);
    defer std.testing.allocator.free(k);
    const v = try fillBuf(std.testing.allocator, 64, 0x66);
    defer std.testing.allocator.free(v);
    var txn = try db.beginWriteTxn();
    defer (txn.abort() catch {}); // commit 后 finished=true，此为 no-op 兜底
    try txn.put(k, v);
    try txn.put("neighbor", "vn");
    try txn.commit();
    const got = try db.get(k);
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualSlices(u8, v, got.?);
    const gn = try db.get("neighbor");
    defer std.testing.allocator.free(gn.?);
    try std.testing.expectEqualStrings("vn", gn.?);
    try std.testing.expectEqual(@as(u64, 2), db.entryCount());
}

test "N-1 micro-batch path RED: Db.put (staged) key=4000 value=64" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    // 探路报告【未实测】#2：staged micro-batch 路径显式覆盖
    var db = try Db.open(std.testing.allocator, ms.store(), .{ .micro_batch = .{ .batch_threshold = 1 } });
    defer db.close();

    const k = try fillBuf(std.testing.allocator, 4000, 0x77);
    defer std.testing.allocator.free(k);
    const v = try fillBuf(std.testing.allocator, 64, 0x88);
    defer std.testing.allocator.free(v);
    try db.put(k, v);
    try db.flush();
    const got = try db.get(k);
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualSlices(u8, v, got.?);
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
}

test "N-1 #9 control: key > MAX_KEY_SIZE still error.KeyTooLarge (unchanged)" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const big = try fillBuf(std.testing.allocator, MAX_KEY + 1, 0x99);
    defer std.testing.allocator.free(big);
    // 修复不新增任何返回错误：超限 key 语义保持
    try std.testing.expectError(error.KeyTooLarge, db.put(big, "v"));
    try std.testing.expectError(error.KeyTooLarge, db.putDirect(big, "v"));
    try db.put("ok", "v");
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
}

test "N-1 #1/#2/#3 control: empty and MAX-key entries still store" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    // #1 空键空值
    try db.put("", "");
    // #2 key=MAX value=""（组合 4064 ≤ 4068，内联）
    const kmax = try fillBuf(std.testing.allocator, MAX_KEY, 0xAA);
    defer std.testing.allocator.free(kmax);
    try db.put(kmax, "");
    // #3 key=MAX value=1（预算 = min(3800, 4068-13-4051) = 4 ≥ 1，内联）
    try db.putDirect(kmax, "x");
    try std.testing.expectEqual(@as(u64, 2), db.entryCount());
    const v1 = try db.get("");
    defer std.testing.allocator.free(v1.?);
    try std.testing.expectEqualStrings("", v1.?);
    const v2 = try db.get(kmax);
    defer std.testing.allocator.free(v2.?);
    try std.testing.expectEqualStrings("x", v2.?);
}

test "N-1 defense: writeNodePage rejects payload > NODE_PAYLOAD_CAP (typed error)" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10);
    defer ms.deinit();
    // writeNodePage 是 pub 的 btree 编码原语：直接按契约调用（非伪造内部状态）。
    // 修后公开写入路径不再产生超限 payload，此处只能直调验证防御分支本身。
    var over: [btree.NODE_PAYLOAD_CAP + 1]u8 = undefined;
    @memset(&over, 0);
    try std.testing.expectError(error.PayloadTooLarge, btree.writeNodePage(ms.store(), 3, 2, 0, &over));
    // 恰好在上限：正常写入，不报错
    var at_cap: [btree.NODE_PAYLOAD_CAP]u8 = undefined;
    @memset(&at_cap, 0);
    try btree.writeNodePage(ms.store(), 3, 2, 0, &at_cap);
}
test "N-1 #15 control: delete with near-MAX key is a safe no-op tombstone" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    const kmax = try fillBuf(std.testing.allocator, MAX_KEY, 0xBB);
    defer std.testing.allocator.free(kmax);
    // 墓碑 value 恒空：3+10+4051 = 4064 ≤ 4068，恒安全
    try db.delete(kmax);
    const gone = try db.get(kmax);
    try std.testing.expect(gone == null);
    // 删除不存在的 key 幂等
    try db.delete(kmax);
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}

test "N-1 overwrite inline<->overflow crossing frees the old chain" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try newDb(std.testing.allocator, &ms);
    defer db.close();

    // 同一 key 先小后大（内联→溢出）、再大后小（溢出→内联），
    // 两次换挡都涉及 overflow 链的建立与回收，泄漏/双回收都会炸
    const k = try fillBuf(std.testing.allocator, 4000, 0xCC);
    defer std.testing.allocator.free(k);
    const small = try fillBuf(std.testing.allocator, 64, 0xDD);
    defer std.testing.allocator.free(small);
    const big = try fillBuf(std.testing.allocator, INLINE + 100, 0xEE);
    defer std.testing.allocator.free(big);

    try db.put(k, small);
    const g1 = try db.get(k);
    defer std.testing.allocator.free(g1.?);
    try std.testing.expectEqualSlices(u8, small, g1.?);

    try db.put(k, big); // 溢出→溢出（换链）
    const g2 = try db.get(k);
    defer std.testing.allocator.free(g2.?);
    try std.testing.expectEqualSlices(u8, big, g2.?);

    try db.put(k, small); // 溢出→（组合感知后仍溢出，换链）
    const g3 = try db.get(k);
    defer std.testing.allocator.free(g3.?);
    try std.testing.expectEqualSlices(u8, small, g3.?);
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
}

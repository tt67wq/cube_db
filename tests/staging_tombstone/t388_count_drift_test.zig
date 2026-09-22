//! t388_count_drift_test.zig — T-38-8 / T-59 回归：count_delta 感知链遮蔽
//!
//! 被修对象：T-59（点删被区间墓碑遮蔽但物理在场的 key → entryCount/byte_size
//! 恒漂移 -1/-bytes）。修复点：`Db.planTombPunch` 第二遍补偿（T-59 pass）。
//! 本文件是 T-38-8 impact-scan 的可执行证据（全部确定性，无线程，MemPageStore）：
//!   P1 点删四态矩阵：covered+live（S3 同款，FilePageStore 版在 t387 S3）、
//!      covered+absent、covered+tree-tombstone、uncovered+visible —— 计数各自正确。
//!   P2 同批同 key 混合序（putBatch [tomb, put] / [put, tomb]）—— 第二遍
//!      按 POST-PLAN 链判覆盖，不与 punch revive 双记。
//!   P3 deleteDirect（WriteTxn 路径，走 db.zig:650 同一 planner）同款补偿。
//!   P4 put-back 打洞 revive（既有补偿通道）小尺度确定版。
//!   P5 gcTombstones × 点删交互：点删遮蔽 live key 后 interval 可收割（计数
//!      不动、不复活）；遮蔽 live key 未点删时 interval 必须保留（F1 方向）。
//!   P6 deleteRange 幂等重删 + 宽区间部分遮蔽 —— 计数 pass（可见口径）不动。

const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const ps = cube.page_store;

const alloc = std.testing.allocator;

fn openDb() !struct { ms: *ps.MemPageStore, db: *Db } {
    const ms = try alloc.create(ps.MemPageStore);
    errdefer alloc.destroy(ms);
    ms.* = ps.MemPageStore.init(alloc, 1 << 20);
    errdefer ms.deinit();
    const db = try Db.open(alloc, ms.store(), .{
        .micro_batch = .{ .batch_threshold = 1 << 30 }, // 手动批：put/delete 全走 flush()/putBatch
    });
    return .{ .ms = ms, .db = db };
}

/// 三口径一致：entryCount == select 计数。
fn expectCountsConsistent(db: *Db) !void {
    var it = try db.select(null, null);
    defer it.deinit();
    var n: u64 = 0;
    while (try it.next()) |_| n += 1;
    if (db.entryCount() != n) return error.CountMismatch;
}

// ---- P1：点删四态矩阵（每态计数语义各自正确） ----

test "t388 P1: point-delete state matrix keeps counts exact" {
    const o = try openDb();
    defer {
        o.db.close();
        o.ms.deinit();
        alloc.destroy(o.ms);
    }
    const db = o.db;

    try db.put("a", "va");
    try db.put("b", "vb"); // 将被遮蔽（物理在场）
    try db.put("c", "vc"); // 将被遮蔽后点删（变 tree tombstone）
    try db.put("d", "vd"); // 范围外
    try db.deleteRange("b", "d"); // 遮蔽 b, c → 可见 a, d
    try std.testing.expectEqual(@as(u64, 2), db.entryCount());
    try expectCountsConsistent(db);

    // ① covered + physically live（T-59 本体；修复前恒 -1）
    try db.delete("b");
    try db.flush();
    try std.testing.expectEqual(@as(u64, 2), db.entryCount());
    try expectCountsConsistent(db);

    // ② covered + physically absent（insert tombstone 自身 delta 0）
    try db.delete("zz"); // 不存在且不被 [b,d) 覆盖 → 看 uncovered 路径
    try db.flush();
    try std.testing.expectEqual(@as(u64, 2), db.entryCount());
    // 真正的 covered+absent：链内但树里没有的 key
    try db.delete("bq");
    try db.flush();
    try std.testing.expectEqual(@as(u64, 2), db.entryCount());
    try expectCountsConsistent(db);

    // ③ covered + tree-tombstone（tomb→tomb，delta 0）
    try db.delete("c"); // c 物理在场 → 先点删一次变 tree tombstone
    try db.flush();
    try std.testing.expectEqual(@as(u64, 2), db.entryCount());
    try db.delete("c"); // 第二次：covered + tree-tombstone
    try db.flush();
    try std.testing.expectEqual(@as(u64, 2), db.entryCount());
    try expectCountsConsistent(db);

    // ④ uncovered + visible（正常可见点删，-1 正确）
    try db.delete("d");
    try db.flush();
    try std.testing.expectEqual(@as(u64, 1), db.entryCount()); // 只剩 a
    try expectCountsConsistent(db);
}

// ---- P2：同批同 key 混合序（双记防线） ----

fn tombEntry(k: []const u8) cube.Entry {
    return .{ .key = k, .value = "", .tombstone = true };
}

test "t388 P2a: same-batch [delete, put] on a shadowed-live key counts exact" {
    const o = try openDb();
    defer {
        o.db.close();
        o.ms.deinit();
        alloc.destroy(o.ms);
    }
    const db = o.db;

    try db.put("a", "va");
    try db.put("b", "vb");
    try db.deleteRange("b", "c"); // b 遮蔽（物理在场），可见 a
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());

    // 同批 [tomb(b), put(b)]：put 打洞去遮蔽 → b 应可见；delete 不多扣
    var entries = [_]cube.Entry{ tombEntry("b"), .{ .key = "b", .value = "vb2", .tombstone = false } };
    try db.putBatch(&entries);
    try std.testing.expectEqual(@as(u64, 2), db.entryCount()); // a + b
    try expectCountsConsistent(db);
    const v = (try db.get("b")) orelse return error.PutLost;
    defer alloc.free(v);
    try std.testing.expectEqualStrings("vb2", v);
}

test "t388 P2b: same-batch [put, delete] on a shadowed-live key counts exact" {
    const o = try openDb();
    defer {
        o.db.close();
        o.ms.deinit();
        alloc.destroy(o.ms);
    }
    const db = o.db;

    try db.put("a", "va");
    try db.put("b", "vb");
    try db.deleteRange("b", "c"); // b 遮蔽（物理在场），可见 a
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());

    // 同批 [put(b), tomb(b)]：净效果 = b 已删；可见性变化 0 → 计数不动
    var entries = [_]cube.Entry{ .{ .key = "b", .value = "vb2", .tombstone = false }, tombEntry("b") };
    try db.putBatch(&entries);
    try std.testing.expectEqual(@as(u64, 1), db.entryCount()); // 只剩 a
    try expectCountsConsistent(db);
    if (try db.get("b")) |v| {
        alloc.free(v);
        return error.DeletedKeyResurrected;
    }
}

// ---- P2c/P2d/P2e：T-60 —— 同批同 key 纯重复 tomb req（insertBatch last-wins
// 去重只落一次 -1，第二遍补偿须每 key 至多一次）----

test "t388 P2c: same-batch duplicate [tomb, tomb] on a shadowed-live key counts exact" {
    const o = try openDb();
    defer {
        o.db.close();
        o.ms.deinit();
        alloc.destroy(o.ms);
    }
    const db = o.db;

    try db.put("a", "va");
    try db.put("b", "vb");
    try db.deleteRange("b", "c"); // b 遮蔽（物理在场），可见 a
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());

    var entries = [_]cube.Entry{ tombEntry("b"), tombEntry("b") };
    try db.putBatch(&entries);
    try std.testing.expectEqual(@as(u64, 1), db.entryCount()); // a 仍可见，不漂移
    try expectCountsConsistent(db);
}

test "t388 P2d: staged delete x2 then flush (one duplicate tomb batch) counts exact" {
    const o = try openDb();
    defer {
        o.db.close();
        o.ms.deinit();
        alloc.destroy(o.ms);
    }
    const db = o.db;

    try db.put("a", "va");
    try db.put("b", "vb");
    try db.deleteRange("b", "c");
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());

    // micro-batch staging 主路径：同批两条 tomb(b)（评审 T-60 探针原形）
    try db.delete("b");
    try db.delete("b");
    try db.flush();
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
    try expectCountsConsistent(db);
}

test "t388 P2e: WriteTxn with two deletes of the same key counts exact" {
    const o = try openDb();
    defer {
        o.db.close();
        o.ms.deinit();
        alloc.destroy(o.ms);
    }
    const db = o.db;

    try db.put("a", "va");
    try db.put("b", "vb");
    try db.deleteRange("b", "c");
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());

    var txn = try db.beginWriteTxn();
    defer txn.deinit();
    try txn.delete("b");
    try txn.delete("b");
    try txn.commit();
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
    try expectCountsConsistent(db);
}

// ---- P3：deleteDirect（WriteTxn 路径，同一 planner） ----

test "t388 P3: deleteDirect of a shadowed-live key (WriteTxn path) counts exact" {
    const o = try openDb();
    defer {
        o.db.close();
        o.ms.deinit();
        alloc.destroy(o.ms);
    }
    const db = o.db;

    try db.put("a", "va");
    try db.put("b", "vb");
    try db.deleteRange("b", "c");
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());

    try db.deleteDirect("b"); // WriteTxn.delete → commit → planTombPunch
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
    try expectCountsConsistent(db);
}

// ---- P4：put-back 打洞 revive（既有补偿通道，确定小尺度版） ----

test "t388 P4: put-back punches through, revives only that key, counts exact" {
    const o = try openDb();
    defer {
        o.db.close();
        o.ms.deinit();
        alloc.destroy(o.ms);
    }
    const db = o.db;

    try db.put("a", "va");
    try db.put("b", "vb");
    try db.put("c", "vc");
    try db.deleteRange("b", "d"); // 遮蔽 b, c → 可见 a
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());

    try db.put("b", "vb2"); // 打洞：[succ(b), d) 段继续遮蔽 c
    try db.flush();
    try std.testing.expectEqual(@as(u64, 2), db.entryCount()); // a + b
    try expectCountsConsistent(db);
    const v = (try db.get("b")) orelse return error.PunchKeyShadowed;
    defer alloc.free(v);
    try std.testing.expectEqualStrings("vb2", v);
    if (try db.get("c")) |vc| {
        alloc.free(vc);
        return error.NeighborResurrected; // c 仍被右段遮蔽
    }
}

// ---- P5：gcTombstones × 点删交互 ----

test "t388 P5a: gc harvests interval left empty by point-deleting its live key" {
    const o = try openDb();
    defer {
        o.db.close();
        o.ms.deinit();
        alloc.destroy(o.ms);
    }
    const db = o.db;

    try db.put("a", "va");
    try db.put("b", "vb");
    try db.deleteRange("b", "c"); // b 遮蔽（物理在场）→ interval 有 live entry，gc 会保留
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());

    try db.gcTombstones(); // b 仍物理 live → interval 保留
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());
    try expectCountsConsistent(db);
    if (try db.get("b")) |v| {
        alloc.free(v);
        return error.ShadowedKeyResurrected; // 保留的 interval 继续遮蔽
    }

    try db.delete("b"); // T-59 修复后：物理 live → tree tombstone，计数不动
    try db.flush();
    try std.testing.expectEqual(@as(u64, 1), db.entryCount());

    try db.gcTombstones(); // interval 现在只压着 tree tombstone → 可收割
    try std.testing.expectEqual(@as(u64, 1), db.entryCount()); // 计数不动
    try expectCountsConsistent(db);
    if (try db.get("b")) |v| {
        alloc.free(v);
        return error.HarvestResurrected; // 收割后 tree tombstone 仍不可见
    }
    const v = (try db.get("a")) orelse return error.VisibleLost;
    defer alloc.free(v);
    try std.testing.expectEqualStrings("va", v);
}

// ---- P6：deleteRange 幂等重删 + 宽区间部分遮蔽（可见口径 count pass） ----

test "t388 P6: idempotent re-delete and wider partial-shadow deleteRange keep counts exact" {
    const o = try openDb();
    defer {
        o.db.close();
        o.ms.deinit();
        alloc.destroy(o.ms);
    }
    const db = o.db;

    try db.put("a", "va");
    try db.put("b", "vb");
    try db.put("c", "vc");
    try db.put("d", "vd");
    try db.deleteRange("b", "c"); // 遮蔽 b → 可见 a, c, d
    try std.testing.expectEqual(@as(u64, 3), db.entryCount());

    try db.deleteRange("b", "c"); // 幂等短路：无任何可见变化
    try std.testing.expectEqual(@as(u64, 3), db.entryCount());
    try expectCountsConsistent(db);

    try db.deleteRange("a", "e"); // 宽区间：可见口径 pass 只减可见的 a, c, d
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
    try expectCountsConsistent(db);

    // 宽区间删后，物理在场的 b 仍不可见；点删它（T-59）计数仍须不动
    try db.delete("b");
    try db.flush();
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
    try expectCountsConsistent(db);
}

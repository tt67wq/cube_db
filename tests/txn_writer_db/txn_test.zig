//! txn_test.zig — P2 TDD: 显式事务 API（LMDB 式 WriteTxn / ReadTxn）
//! WriteTxn: beginWriteTxn → put/delete → commit(meta 切换+fsync) / abort(丢弃)
//! 单写者互斥：同一时刻只有一个活跃 WriteTxn。
//! ReadTxn: beginReadTxn → 取快照 → get/select → endReadTxn（MVCC 不阻写者）

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const Db = cube.Db;

const alloc = std.testing.allocator;

// ms 与 db 必须同作用域（ms.store() 持有 &ms，生命周期须 ≥ db）

// ===== WriteTxn =====

test "WriteTxn: commit persists" {
    var ms = ps.MemPageStore.init(alloc, 1000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    var txn = try db.beginWriteTxn();
    try txn.put("k1", "v1");
    try txn.put("k2", "v2");
    try txn.commit();
    const v = try db.get("k1");
    defer if (v) |val| alloc.free(val);
    try std.testing.expectEqualStrings("v1", v.?);
}

test "WriteTxn: abort discards (no data applied)" {
    var ms = ps.MemPageStore.init(alloc, 1000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    {
        var txn = try db.beginWriteTxn();
        try txn.put("keep", "yes");
        try txn.commit();
    }
    const root_before = db.getRoot();
    {
        var txn = try db.beginWriteTxn();
        try txn.put("discard", "me");
        try txn.abort();
    }
    try std.testing.expectEqual(root_before, db.getRoot());
    const v = try db.get("discard");
    defer if (v) |val| alloc.free(val);
    try std.testing.expectEqual(@as(?[]u8, null), v);
    const k = try db.get("keep");
    defer if (k) |val| alloc.free(val);
    try std.testing.expectEqualStrings("yes", k.?);
}

test "WriteTxn: delete then commit" {
    var ms = ps.MemPageStore.init(alloc, 1000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    {
        var txn = try db.beginWriteTxn();
        try txn.put("k", "v");
        try txn.commit();
    }
    {
        var txn = try db.beginWriteTxn();
        try txn.delete("k");
        try txn.commit();
    }
    const v = try db.get("k");
    defer if (v) |val| alloc.free(val);
    try std.testing.expectEqual(@as(?[]u8, null), v);
}

// ===== ReadTxn =====

test "ReadTxn: snapshot sees committed data" {
    var ms = ps.MemPageStore.init(alloc, 1000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    {
        var w = try db.beginWriteTxn();
        try w.put("k", "v1");
        try w.commit();
    }
    var rt = try db.beginReadTxn();
    defer rt.end();
    const v = try rt.get("k");
    defer if (v) |val| alloc.free(val);
    try std.testing.expectEqualStrings("v1", v.?);
}

test "ReadTxn: snapshot isolation — writer commits, reader still sees old value" {
    var ms = ps.MemPageStore.init(alloc, 1000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    {
        var w = try db.beginWriteTxn();
        try w.put("k", "v1");
        try w.commit();
    }
    var rt = try db.beginReadTxn();
    // 写者提交新值（COW 不原地改，旧页保留供 reader）
    {
        var w = try db.beginWriteTxn();
        try w.put("k", "v2");
        try w.commit();
    }
    // reader 仍读快照旧值
    const v = try rt.get("k");
    defer if (v) |val| alloc.free(val);
    try std.testing.expectEqualStrings("v1", v.?);
    rt.end();
    // 结束读后，新值可见
    const v2 = try db.get("k");
    defer if (v2) |val| alloc.free(val);
    try std.testing.expectEqualStrings("v2", v2.?);
}

// ===== 并发：多读 + 单写互斥 =====

const ThreadCtx = struct { db: *Db, err: ?anyerror = null };

fn writerThread(ctx: *ThreadCtx) void {
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        var txn = ctx.db.beginWriteTxn() catch |err| { ctx.err = err; return; };
        var keybuf: [16]u8 = undefined;
        const k = std.fmt.bufPrint(&keybuf, "w{d}", .{i}) catch { txn.deinit(); return; };
        txn.put(k, k) catch |err| { ctx.err = err; txn.deinit(); return; };
        txn.commit() catch |err| { ctx.err = err; txn.deinit(); return; };
    }
}

fn readerThread(ctx: *ThreadCtx) void {
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        var rt = ctx.db.beginReadTxn() catch |err| { ctx.err = err; return; };
        defer rt.end();
        var keybuf: [16]u8 = undefined;
        const k = std.fmt.bufPrint(&keybuf, "w{d}", .{i % 50}) catch return;
        if (rt.get(k) catch |err| { ctx.err = err; return; }) |v| alloc.free(v);
    }
}

test "concurrency: 2 writers + 2 readers interleave, no deadlock" {
    var ms = ps.MemPageStore.init(alloc, 4000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    var w1: ThreadCtx = .{ .db = db };
    var w2: ThreadCtx = .{ .db = db };
    var r1: ThreadCtx = .{ .db = db };
    var r2: ThreadCtx = .{ .db = db };

    const t1 = try std.Thread.spawn(.{}, writerThread, .{&w1});
    const t2 = try std.Thread.spawn(.{}, writerThread, .{&w2});
    const t3 = try std.Thread.spawn(.{}, readerThread, .{&r1});
    const t4 = try std.Thread.spawn(.{}, readerThread, .{&r2});
    t1.join();
    t2.join();
    t3.join();
    t4.join();

    try std.testing.expect(w1.err == null);
    try std.testing.expect(w2.err == null);
    try std.testing.expect(r1.err == null);
    try std.testing.expect(r2.err == null);
    // 2 个写者各 50 个 put → 100 entries（key w0..w49 由两个写者覆盖，同一 key）
    // 至少 w0 应在
    const v = try db.get("w0");
    defer if (v) |val| alloc.free(val);
    try std.testing.expect(v != null);
}

// ===== group commit：单 txn 多操作 = 一次 applyBatch + 一次 fsync =====
test "group commit: 16 puts in one txn = single commit, single fsync batch" {
    var ms = ps.MemPageStore.init(alloc, 4000);
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();
    // group commit 语义：单 WriteTxn 中 16 次 put → 一次 commit 走一次 applyBatch + 一次 meta 切换
    // key 用堆分配（避免 bufPrint 复用栈缓冲的别名 bug）
    const keys = try alloc.alloc([]u8, 16);
    defer {
        for (keys) |k| alloc.free(k);
        alloc.free(keys);
    }
    var txn = try db.beginWriteTxn();
    for (keys, 0..) |*k, i| {
        k.* = try std.fmt.allocPrint(alloc, "g{d}", .{i});
        try txn.put(k.*, "v");
    }
    try txn.commit();
    // 提交后 entryCount 应=16（一次提交即一致）
    try std.testing.expectEqual(@as(u64, 16), db.entryCount());
    // 全部 key 可读
    for (keys) |k| {
        const v = try db.get(k);
        defer if (v) |val| alloc.free(val);
        try std.testing.expectEqualStrings("v", v.?);
    }
}

//! t389_s3_interleave_test.zig — T-38-9：重建完整 S3 交错场景
//!
//! T-38-7 的完整 S3（gcTombstones/punch × 并发 staging 交错 + reopen）从未交付
//! （T-38-7 review NB-1 + T-38-8 review §6 裁决）。本文件按其 report 的场景
//! 指引重建；T-60 形态（同 key 重复点删，once-set 补偿）在多线程下复测。
//! 不碰 t387 冻结文件与 t388 确定性文件；零 src/ 改动。
//!
//! 场景（不变量式断言：任意交错后三口径一致 + 无幻影 + 已删不复活 +
//! 可见集单调保持；seed/sleep 只影响交错深度，不影响断言结果）：
//!   S1 deleteRange × 并发 put（范围内 d-put 走 punch 路径）× 显式 flusher ×
//!      并发 gcTombstones 多轮，FilePageStore 真落盘：
//!      节点 A（交错后，staged 子集态）→ 确定性 punch 断言（put 回区间内 key
//!      必须可见）→ 节点 B（flush 后，范围外精确 + 单调保持）→ close/reopen →
//!      节点 C（重启保持 + 墓碑链真落盘）。三口径每节点全查。
//!   S2 **T-60 多线程复测**：K 线程对同一被遮蔽 key 重复点删（staging 混批：
//!      大量重复 tomb req + 范围外 put 同批提交）× flusher 交错 → 精确终态
//!      （once-set 补偿按 key 净账：不多补不少补）→ gcTombstones（收割空
//!      interval）→ reopen 保持。

const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const FilePageStore = cube.file_page_store.FilePageStore;
const f2 = cube.format;

const c = @cImport({
    @cInclude("unistd.h");
});

const alloc = std.testing.allocator;

const S1_ITERS = 1500; // S1 putter 迭代数（key 集确定；时序只影响交错深度）
const S2_THREADS = 4; // S2 并发点删线程数
const S2_DELS_PER_THREAD = 60; // 每线程对同一 key 的点删次数

// =====================================================================
// helpers（同 t387 模式：FilePageStore 必须堆分配，vtable 持有结构体地址）
// =====================================================================

fn sleepNs(ns: u64) void {
    var req: std.c.timespec = .{
        .sec = @intCast(ns / 1_000_000_000),
        .nsec = @intCast(ns % 1_000_000_000),
    };
    _ = std.c.nanosleep(&req, null);
}

fn unlinkTmp(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

const Opened = struct { fps: *FilePageStore, db: *Db };

fn openFileDb(path: []const u8) !Opened {
    const fps = try alloc.create(FilePageStore);
    errdefer alloc.destroy(fps);
    fps.* = try FilePageStore.init(alloc, path);
    errdefer fps.deinit();
    const db = try Db.open(alloc, fps.store(), .{
        // fsync=false：process-crash 模型（reopen 同进程读页缓存）；power-fail
        // 耐久性归 T-38-5 崩溃注入轮。真落盘维度（close/reopen）保留。
        .fsync = false,
        .micro_batch = .{ .batch_threshold = 1 << 30 }, // 手动批：交错靠显式 flusher
    });
    return .{ .fps = fps, .db = db };
}

fn closeOpened(o: Opened) void {
    o.db.close();
    o.fps.deinit();
    alloc.destroy(o.fps);
}

fn requireTombOnDisk(fps: *FilePageStore) !void {
    const m = (try fps.store().readMeta()) orelse return error.NoMeta;
    if (m.version != 3 or m.tomb_head == 0) return error.NoTombChainOnDisk;
}

/// 三口径之①②：entryCount == select(null,null) 计数。
fn expectCountsConsistent(db: *Db) !void {
    var it = try db.select(null, null);
    defer it.deinit();
    var n: u64 = 0;
    while (try it.next()) |_| n += 1;
    if (db.entryCount() != n) return error.CountMismatch;
}

// =====================================================================
// S1 — deleteRange × 并发 put（punch）× flusher × gcTombstones + reopen
// =====================================================================

const S1Map = [S1_ITERS]bool;

const S1PutterCtx = struct {
    db: *Db,
    err: ?anyerror = null,
};

/// 范围外 a-key（永不被 ["d000000","e") 覆盖）+ 范围内 d-key（put 命中
/// 区间墓碑 → 同 commit punch，INV-RT1）。key 全局唯一 → 在场者 value 确定。
fn workerS1Putter(ctx: *S1PutterCtx) void {
    var kbuf: [16]u8 = undefined;
    var vbuf: [16]u8 = undefined;
    for (0..S1_ITERS) |i| {
        const ka = std.fmt.bufPrint(&kbuf, "a{d:0>6}", .{i}) catch unreachable;
        const va = std.fmt.bufPrint(&vbuf, "va{d:0>6}", .{i}) catch unreachable;
        ctx.db.put(ka, va) catch |e| {
            ctx.err = e;
            return;
        };
        const kd = std.fmt.bufPrint(&kbuf, "d{d:0>6}", .{i}) catch unreachable;
        const vd = std.fmt.bufPrint(&vbuf, "vd{d:0>6}", .{i}) catch unreachable;
        ctx.db.put(kd, vd) catch |e| {
            ctx.err = e;
            return;
        };
        sleepNs(100_000); // ~300ms 窗口
    }
}

const S1DeleterCtx = struct {
    db: *Db,
    stop: *std.atomic.Value(bool),
    err: ?anyerror = null,
    passes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn workerS1Deleter(ctx: *S1DeleterCtx) void {
    while (!ctx.stop.load(.acquire)) {
        ctx.db.deleteRange("d000000", "e") catch |e| {
            ctx.err = e;
            return;
        };
        _ = ctx.passes.fetchAdd(1, .monotonic);
        sleepNs(50_000);
    }
}

fn workerS1Flusher(db: *Db, stop: *std.atomic.Value(bool), err: *?anyerror) void {
    while (!stop.load(.acquire)) {
        db.flush() catch |e| {
            err.* = e;
            return;
        };
        sleepNs(1_000_000);
    }
}

const S1GcCtx = struct {
    db: *Db,
    stop: *std.atomic.Value(bool),
    err: ?anyerror = null,
    passes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

/// 并发 gcTombstones 多轮（与 deleteRange/punch 提交竞争 write_mutex）。
fn workerS1Gc(ctx: *S1GcCtx) void {
    while (!ctx.stop.load(.acquire)) {
        ctx.db.gcTombstones() catch |e| {
            ctx.err = e;
            return;
        };
        _ = ctx.passes.fetchAdd(1, .monotonic);
        sleepNs(2_000_000);
    }
}

/// 三口径全查（不变量式）：①entryCount==select 计数；②无幻影 + 值正确；
/// ③逐 key get 与 select 在场集一致；④prev_* 单调保持（不丢）；⑤a_exact
/// 时范围外精确全在场。
fn checkS1Node(
    db: *Db,
    a_map: *S1Map,
    d_map: *S1Map,
    a_exact: bool,
    prev_a: ?*const S1Map,
    prev_d: ?*const S1Map,
) !void {
    for (a_map) |*b| b.* = false;
    for (d_map) |*b| b.* = false;

    var it = try db.select(null, null);
    defer it.deinit();
    var n: u64 = 0;
    var a_seen: u64 = 0;
    var d_present: u64 = 0;
    var vbuf: [16]u8 = undefined;
    while (try it.next()) |e| {
        n += 1;
        if (e.key.len != 7) return error.PhantomKey;
        const idx = std.fmt.parseInt(u64, e.key[1..], 10) catch return error.PhantomKey;
        switch (e.key[0]) {
            'a' => {
                if (idx >= S1_ITERS) return error.PhantomKey;
                a_map[idx] = true;
                a_seen += 1;
                const want = try std.fmt.bufPrint(&vbuf, "va{d:0>6}", .{idx});
                if (!std.mem.eql(u8, want, e.value)) return error.ValueMismatch;
            },
            'd' => {
                if (idx >= S1_ITERS) return error.PhantomKey;
                d_map[idx] = true;
                d_present += 1;
                const want = try std.fmt.bufPrint(&vbuf, "vd{d:0>6}", .{idx});
                if (!std.mem.eql(u8, want, e.value)) return error.ValueMismatch;
            },
            else => return error.PhantomKey,
        }
    }
    if (db.entryCount() != n) return error.CountMismatch;
    if (a_exact and a_seen != S1_ITERS) return error.OutOfRangeLost;
    if (prev_a) |pa| for (0..S1_ITERS) |i| {
        if (pa[i] and !a_map[i]) return error.VisibleLost;
    };
    if (prev_d) |pd| for (0..S1_ITERS) |i| {
        if (pd[i] and !d_map[i]) return error.VisibleLost;
    };

    // 逐 key get（第三口径）
    var kbuf: [16]u8 = undefined;
    var a_got: u64 = 0;
    var d_got: u64 = 0;
    for (0..S1_ITERS) |i| {
        const ka = try std.fmt.bufPrint(&kbuf, "a{d:0>6}", .{i});
        if (try db.get(ka)) |v| {
            defer alloc.free(v);
            a_got += 1;
            const want = try std.fmt.bufPrint(&vbuf, "va{d:0>6}", .{i});
            if (!std.mem.eql(u8, want, v)) return error.ValueMismatchGet;
        }
        const kd = try std.fmt.bufPrint(&kbuf, "d{d:0>6}", .{i});
        if (try db.get(kd)) |v| {
            defer alloc.free(v);
            d_got += 1;
            const want = try std.fmt.bufPrint(&vbuf, "vd{d:0>6}", .{i});
            if (!std.mem.eql(u8, want, v)) return error.ValueMismatchGet;
        }
    }
    if (a_got != a_seen or d_got != d_present) return error.SelectGetDisagree;
}

test "t389 S1: deleteRange x punch x flusher x gcTombstones interleave on FilePageStore, survives reopen" {
    const path = ".test_t389_s1.db";
    defer unlinkTmp(path);
    unlinkTmp(path);

    var a_map: S1Map = undefined;
    var d_map: S1Map = undefined;
    var snap_a: S1Map = undefined;
    var snap_d: S1Map = undefined;

    {
        const o = try openFileDb(path);
        defer closeOpened(o);
        const db = o.db;

        var stop = std.atomic.Value(bool).init(false);
        var dctx = S1DeleterCtx{ .db = db, .stop = &stop };
        var gctx = S1GcCtx{ .db = db, .stop = &stop };
        var pctx = S1PutterCtx{ .db = db };

        var fstop = std.atomic.Value(bool).init(false);
        var ferr: ?anyerror = null;

        // deleter 先起（链尽快非空），gc 与 flusher 随后，putter 最后（交错）
        const td = try std.Thread.spawn(.{}, workerS1Deleter, .{&dctx});
        const tg = try std.Thread.spawn(.{}, workerS1Gc, .{&gctx});
        const tf = try std.Thread.spawn(.{}, workerS1Flusher, .{ db, &fstop, &ferr });
        const tp = try std.Thread.spawn(.{}, workerS1Putter, .{&pctx});

        tp.join();
        stop.store(true, .release);
        td.join();
        tg.join();
        fstop.store(true, .release);
        tf.join();

        try std.testing.expect(pctx.err == null);
        try std.testing.expect(dctx.err == null);
        try std.testing.expect(gctx.err == null);
        try std.testing.expect(ferr == null);
        try std.testing.expect(dctx.passes.load(.monotonic) > 0); // deleter 真跑
        try std.testing.expect(gctx.passes.load(.monotonic) > 0); // gc 真跑（多轮）

        // 节点 A：交错后（deleter 已停，可见集此后单调；staged 子集态）
        try checkS1Node(db, &a_map, &d_map, false, null, null);
        snap_a = a_map;
        snap_d = d_map;

        // 确定性 punch 断言：put 回区间内 key 必须可见（punch 路径在并发
        // 交错中已由 d-put 反复走过；此处收口再验一次）
        try db.put("d000000", "vd000000");
        try db.flush();
        {
            const v = (try db.get("d000000")) orelse return error.PunchKeyShadowed;
            defer alloc.free(v);
            if (!std.mem.eql(u8, v, "vd000000")) return error.PunchKeyValue;
        }

        // 节点 B：flush 后——范围外精确 + 单调保持
        try checkS1Node(db, &a_map, &d_map, true, &snap_a, &snap_d);
        snap_a = a_map;
        snap_d = d_map;

        try requireTombOnDisk(o.fps);
    }

    // 节点 C：reopen——重启保持
    {
        const o = try openFileDb(path);
        defer closeOpened(o);
        try checkS1Node(o.db, &a_map, &d_map, true, &snap_a, &snap_d);
        try requireTombOnDisk(o.fps);
    }
}

// =====================================================================
// S2 — T-60 多线程复测：同一被遮蔽 key 的并发重复点删（once-set 净账）
// =====================================================================

const S2DelCtx = struct {
    db: *Db,
    t: usize,
    err: ?anyerror = null,
};

/// 每线程：反复点删同一被遮蔽 key（staging 混批：重复 tomb req）+ 每轮一个
/// 范围外 z-put（与重复 tomb 同批提交 → T-60 形态 + 混批补偿都在一批内）。
fn workerS2Deleter(ctx: *S2DelCtx) void {
    var kbuf: [16]u8 = undefined;
    var vbuf: [16]u8 = undefined;
    for (0..S2_DELS_PER_THREAD) |m| {
        ctx.db.delete("b") catch |e| {
            ctx.err = e;
            return;
        };
        const kz = std.fmt.bufPrint(&kbuf, "z{d:0>2}{d:0>4}", .{ ctx.t, m }) catch unreachable;
        const vz = std.fmt.bufPrint(&vbuf, "vz{d:0>2}{d:0>4}", .{ ctx.t, m }) catch unreachable;
        ctx.db.put(kz, vz) catch |e| {
            ctx.err = e;
            return;
        };
    }
}

fn workerS2Flusher(db: *Db, stop: *std.atomic.Value(bool), err: *?anyerror) void {
    while (!stop.load(.acquire)) {
        db.flush() catch |e| {
            err.* = e;
            return;
        };
        sleepNs(500_000);
    }
}

test "t389 S2: concurrent duplicate point-deletes of one shadowed key (T-60 form) net exactly once, survives gc + reopen" {
    const path = ".test_t389_s2.db";
    defer unlinkTmp(path);
    unlinkTmp(path);

    {
        const o = try openFileDb(path);
        defer closeOpened(o);
        const db = o.db;

        // 被遮蔽 key：b 物理 live、被 [b,c) 遮蔽 → 可见 a，entryCount=1
        try db.put("a", "va");
        try db.put("b", "vb");
        try db.deleteRange("b", "c");
        try std.testing.expectEqual(@as(u64, 1), db.entryCount());
        try expectCountsConsistent(db);

        var fstop = std.atomic.Value(bool).init(false);
        var ferr: ?anyerror = null;
        const tf = try std.Thread.spawn(.{}, workerS2Flusher, .{ db, &fstop, &ferr });

        var dctxs: [S2_THREADS]S2DelCtx = undefined;
        var threads: [S2_THREADS]std.Thread = undefined;
        for (0..S2_THREADS) |t| {
            dctxs[t] = .{ .db = db, .t = t };
            threads[t] = try std.Thread.spawn(.{}, workerS2Deleter, .{&dctxs[t]});
        }
        for (&threads) |*th| th.join();
        fstop.store(true, .release);
        tf.join();
        try std.testing.expect(ferr == null);
        for (&dctxs) |*dc| try std.testing.expect(dc.err == null);

        try db.flush();

        // 精确终态：a + 全部 z-key（S2_THREADS*S2_DELS_PER_THREAD）可见；
        // b 无论被点删多少次仍不可见；计数无漂移（once-set 按 key 净账）
        const want_total: u64 = 1 + S2_THREADS * S2_DELS_PER_THREAD;
        try std.testing.expectEqual(want_total, db.entryCount());
        try expectCountsConsistent(db);
        {
            var it = try db.select(null, null);
            defer it.deinit();
            var seen_a: u64 = 0;
            var seen_z: u64 = 0;
            var vbuf: [16]u8 = undefined;
            while (try it.next()) |e| {
                if (std.mem.eql(u8, e.key, "a")) {
                    seen_a += 1;
                    if (!std.mem.eql(u8, e.value, "va")) return error.ValueMismatch;
                } else if (e.key[0] == 'z') {
                    seen_z += 1;
                    const want = try std.fmt.bufPrint(&vbuf, "vz{s}", .{e.key[1..]});
                    if (!std.mem.eql(u8, want, e.value)) return error.ValueMismatch;
                } else {
                    return error.PhantomKey; // b 复活即在此爆
                }
            }
            if (seen_a != 1 or seen_z != S2_THREADS * S2_DELS_PER_THREAD) return error.ExactCountMismatch;
        }
        {
            const v = (try db.get("a")) orelse return error.VisibleLost;
            defer alloc.free(v);
            if (!std.mem.eql(u8, v, "va")) return error.ValueMismatchGet;
        }
        if (try db.get("b")) |v| {
            alloc.free(v);
            return error.DeletedKeyResurrected;
        }
        try requireTombOnDisk(o.fps);

        // gc：interval [b,c) 现在只压 tree tombstone（b 已点删）→ 可收割；
        // 收割不得改变可见性与计数
        try db.gcTombstones();
        try std.testing.expectEqual(want_total, db.entryCount());
        try expectCountsConsistent(db);
        if (try db.get("b")) |v| {
            alloc.free(v);
            return error.HarvestResurrected;
        }
    }

    // reopen：重启保持
    {
        const o = try openFileDb(path);
        defer closeOpened(o);
        const want_total: u64 = 1 + S2_THREADS * S2_DELS_PER_THREAD;
        try std.testing.expectEqual(want_total, o.db.entryCount());
        try expectCountsConsistent(o.db);
        if (try o.db.get("b")) |v| {
            alloc.free(v);
            return error.ReopenResurrected;
        }
    }
}

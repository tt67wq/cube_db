//! t387_staging_tomb_test.zig — T-38-7 验收 (c)：墓碑 × 并发 staging/flush 交错 + 重启保持
//!
//! 契约：.agents/tasks/T-38-7/task.md（issues/T-38 验收判据 (c) + checklist
//! 「回归测试 + 评审（阶段 2 起需并发 staging 交错测试）」——阶段 2 起欠下的债）。
//!
//! 与 tests/staging_concurrent_test.zig T7 的分工：T7 用 MemPageStore 只测**仅内存态**；
//! 本文件全部用 **FilePageStore + 临时文件（真落盘）**，补上 flush/close/reopen 维度。
//! 零 src/ 改动——本文件是纯回归测试轮。
//!
//! 场景（不变量式断言：任意交错后三口径一致 + 无幻影 key + 已删不复活；
//! seed 只喂 key 选择，断言不依赖交错时序）：
//!   S1 交错（deleteRange × 并发 put）→ flush → close → reopen：
//!      三口径（entryCount / select 计数 / 逐 key get）在交错后、flush 后、
//!      reopen 后三个节点各全查一遍；范围外 key 精确不丢（flush 后）；
//!      node A 可见集在后续节点单调保持（不丢、不复活）。GREEN。
//!   S2 同 S1 + 显式并发 flusher 线程（复用 workerFlusher 模式）：deleteRange
//!      「先 flush 再提交墓碑」内部序与外部 flush 竞态下仍自洽。GREEN。
//!   S3 **冻结的最小 repro（RED by design，勿弱化断言）**：点删一个被区间
//!      墓碑遮蔽但物理在场的 key → entryCount 与 select 计数失恒。
//!      完全确定性（无线程、无交错、公开 API 五行序列）。BLOCKED 详见
//!      report.md：症状 / 定位线索（planTombPunch 跳过 tombstone req +
//!      btree.insertBatch count_delta）。
//!      原计划的 S3 打洞/点删/gcTombstones 交错场景被同一 bug 阻塞——
//!      任意「点删命中墓碑区间」的交错都会触发 entryCount 漂移。
//!   S4 多页墓碑链压力：200 个互不相交区间的 deleteRange 把链推到多页
//!      （参考 T-38-5 C6 负载），与并发 put（范围外 z-key，精确计数）交错
//!      + reopen；盘上链页数 >= 2 + 页分区不变量（page_partition）。GREEN。

const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;
const FilePageStore = cube.file_page_store.FilePageStore;
const f2 = cube.format;
const part = @import("page_partition");

const c = @cImport({
    @cInclude("unistd.h");
});

const alloc = std.testing.allocator;

const GATE_SEED: u64 = 0x8c40347c; // 只喂 key 选择，不碰时序

const S12_ITERS = 1500; // S1/S2 putter 迭代数（key 集确定性；时序只影响死活分布）
const S4_PRE = 400;
const S4_Z_ITERS = 1500;

// =====================================================================
// helpers
// =====================================================================

/// Sleep ns（std.Thread.sleep 在 0.16 移到 Io；libc nanosleep，同 staging_concurrent_test）
fn sleepNs(ns: u64) void {
    var req: std.c.timespec = .{
        .sec = @intCast(ns / 1_000_000_000),
        .nsec = @intCast(ns % 1_000_000_000),
    };
    _ = std.c.nanosleep(&req, null);
}

/// POSIX unlink（仓库既有风格：不依赖 std.fs 的 Io 接口，同 file_page_store.zig unlinkPath）
fn unlinkTmp(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

const Opened = struct { fps: *FilePageStore, db: *Db };

/// FilePageStore 必须堆分配：db 的 PageStore vtable 持有 &fps，按值返回会移动
/// 结构体 → vtable 指向已死栈帧（真实踩过的坑：freelist_mu 被栈复用砸烂后死锁）。
fn openFileDb(path: []const u8) !Opened {
    const fps = try alloc.create(FilePageStore);
    errdefer alloc.destroy(fps);
    fps.* = try FilePageStore.init(alloc, path);
    errdefer fps.deinit();
    const db = try Db.open(alloc, fps.store(), .{
        // fsync=false：process-crash 模型（reopen 同进程读页缓存立即可见）；
        // power-fail 耐久性由 T-38-5 崩溃注入轮覆盖。真落盘维度（close/reopen）保留。
        .fsync = false,
        .micro_batch = .{ .batch_threshold = 1 << 30 },
    });
    return .{ .fps = fps, .db = db };
}

fn closeOpened(o: Opened) void {
    o.db.close();
    o.fps.deinit();
    alloc.destroy(o.fps);
}

/// 墓碑链确实落盘了（防 false-green：遮蔽语义必须建立在真链上）。
fn requireTombOnDisk(fps: *FilePageStore) !void {
    const m = (try fps.store().readMeta()) orelse return error.NoMeta;
    if (m.version != 3 or m.tomb_head == 0) return error.NoTombChainOnDisk;
}

/// 盘上墓碑链的页数（顺链遍历）。
fn chainPageCount(fps: *FilePageStore) !usize {
    var head: u32 = ((try fps.store().readMeta()) orelse return error.NoMeta).tomb_head;
    var n: usize = 0;
    while (head != 0) {
        n += 1;
        if (n > 4096) return error.ChainTooLong;
        const raw = try fps.store().readPage(head);
        const tp = try f2.decodeTombPage(alloc, raw[0..f2.PAGE_SIZE]);
        defer alloc.free(tp.tobs);
        head = tp.next;
    }
    return n;
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
// S1 / S2 — deleteRange × 并发 staging put 交错 + flush + reopen
// =====================================================================

const S12PutterCtx = struct {
    db: *Db,
    err: ?anyerror = null,
};

/// 范围外 key（"a..."，永不被 ["d000000","e") 覆盖）+ 范围内 key（"d..."）。
/// key 全局唯一（迭代下标）→ 在场者 value 必须与 key 后缀对应（确定）。
fn workerS12Putter(ctx: *S12PutterCtx) void {
    var kbuf: [16]u8 = undefined;
    var vbuf: [16]u8 = undefined;
    for (0..S12_ITERS) |i| {
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
        sleepNs(100_000); // ~150ms 窗口，让 deleter 真正交错
    }
}

const S12DeleterCtx = struct {
    db: *Db,
    stop: *std.atomic.Value(bool),
    err: ?anyerror = null,
    passes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn workerS12Deleter(ctx: *S12DeleterCtx) void {
    while (!ctx.stop.load(.acquire)) {
        ctx.db.deleteRange("d000000", "e") catch |e| {
            ctx.err = e;
            return;
        };
        _ = ctx.passes.fetchAdd(1, .monotonic);
        sleepNs(50_000);
    }
}

/// T2 同款显式 flusher（staging_concurrent_test workerFlusher 模式）。
fn workerS12Flusher(db: *Db, stop: *std.atomic.Value(bool), err: *?anyerror) void {
    while (!stop.load(.acquire)) {
        db.flush() catch |e| {
            err.* = e;
            return;
        };
        sleepNs(1_000_000);
    }
}

const S12Map = [S12_ITERS]bool;

/// 三口径全查（不变量式，不依赖交错时序）：
///   ① entryCount == select 计数；
///   ② 无幻影：所有可见 key ∈ 已写 key 集（前缀 + 下标界），在场者 value 正确；
///   ③ 逐 key get 与 select 在场集一致且值正确；
///   ④ prev_*（上一节点可见集）单调保持（可见者不丢——flush 只增提交、
///      reopen 持久化，遮蔽不掉已提交的活 entry）；
///   ⑤ a_exact=true 时范围外 key 精确不丢（全量在场）。
fn checkS12Node(
    db: *Db,
    a_map: *S12Map,
    d_map: *S12Map,
    a_exact: bool,
    prev_a: ?*const S12Map,
    prev_d: ?*const S12Map,
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
                if (idx >= S12_ITERS) return error.PhantomKey;
                a_map[idx] = true;
                a_seen += 1;
                const want = try std.fmt.bufPrint(&vbuf, "va{d:0>6}", .{idx});
                if (!std.mem.eql(u8, want, e.value)) return error.ValueMismatch;
            },
            'd' => {
                if (idx >= S12_ITERS) return error.PhantomKey;
                d_map[idx] = true;
                d_present += 1;
                const want = try std.fmt.bufPrint(&vbuf, "vd{d:0>6}", .{idx});
                if (!std.mem.eql(u8, want, e.value)) return error.ValueMismatch;
            },
            else => return error.PhantomKey,
        }
    }
    if (db.entryCount() != n) return error.CountMismatch;
    if (a_exact and a_seen != S12_ITERS) return error.OutOfRangeLost;
    if (prev_a) |pa| for (0..S12_ITERS) |i| {
        if (pa[i] and !a_map[i]) return error.VisibleLost;
    };
    if (prev_d) |pd| for (0..S12_ITERS) |i| {
        if (pd[i] and !d_map[i]) return error.VisibleLost;
    };

    // 逐 key get（第三口径）
    var kbuf: [16]u8 = undefined;
    var a_got: u64 = 0;
    var d_got: u64 = 0;
    for (0..S12_ITERS) |i| {
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

fn runS12(comptime with_flusher: bool, path: []const u8) !void {
    var a_map: S12Map = undefined;
    var d_map: S12Map = undefined;
    var snap_a: S12Map = undefined;
    var snap_d: S12Map = undefined;

    {
        const o = try openFileDb(path);
        defer closeOpened(o);

        var stop = std.atomic.Value(bool).init(false);
        var dctx = S12DeleterCtx{ .db = o.db, .stop = &stop };
        var pctx = S12PutterCtx{ .db = o.db };
        const td = try std.Thread.spawn(.{}, workerS12Deleter, .{&dctx});

        var fstop = std.atomic.Value(bool).init(false);
        var ferr: ?anyerror = null;
        var tf: ?std.Thread = null;
        if (with_flusher) tf = try std.Thread.spawn(.{}, workerS12Flusher, .{ o.db, &fstop, &ferr });

        const tp = try std.Thread.spawn(.{}, workerS12Putter, .{&pctx});
        tp.join();
        stop.store(true, .release);
        td.join();
        if (tf) |t| {
            fstop.store(true, .release);
            t.join();
        }

        try std.testing.expect(pctx.err == null);
        try std.testing.expect(dctx.err == null);
        try std.testing.expect(ferr == null);
        try std.testing.expect(dctx.passes.load(.monotonic) > 0); // deleter 确实跑了

        // node A：交错后（未显式 flush）——不变量式（staged 未提交的子集态）
        try checkS12Node(o.db, &a_map, &d_map, false, null, null);
        snap_a = a_map;
        snap_d = d_map;

        // 确定性 punch 断言：deleter 停止后 put 回覆盖区间内的 key 并 flush，
        // punch（INV-RT1 分裂）必须让它可见——punch 路径在本场景确实走过。
        try o.db.put("d000000", "vd000000");
        try o.db.flush();
        {
            const v = (try o.db.get("d000000")) orelse return error.PunchKeyShadowed;
            defer alloc.free(v);
            if (!std.mem.eql(u8, v, "vd000000")) return error.PunchKeyValue;
        }

        // node B：flush 后——范围外精确 + 单调保持
        try checkS12Node(o.db, &a_map, &d_map, true, &snap_a, &snap_d);
        snap_a = a_map;
        snap_d = d_map;

        try requireTombOnDisk(o.fps);
    }

    // node C：reopen——重启保持
    {
        const o = try openFileDb(path);
        defer closeOpened(o);
        try checkS12Node(o.db, &a_map, &d_map, true, &snap_a, &snap_d);
        try requireTombOnDisk(o.fps);
    }
}

test "t387 S1: deleteRange x staging interleave on FilePageStore, tombstone semantics survive flush+reopen" {
    const path = ".test_t387_s1.db";
    defer unlinkTmp(path);
    unlinkTmp(path);
    try runS12(false, path);
}

test "t387 S2: same interleave with a concurrent explicit flusher thread stays self-consistent" {
    const path = ".test_t387_s2.db";
    defer unlinkTmp(path);
    unlinkTmp(path);
    try runS12(true, path);
}

// =====================================================================
// S3 — 冻结的最小 repro（RED by design）：entryCount 失恒
// =====================================================================
// 症状：点删一个被区间墓碑遮蔽但**物理在场**的 key 并提交后，
//       entryCount 比 select 可见数少 1（每次一次漂移；@max(0) 钳制会在
//       entryCount==0 时吸收漂移，所以要在 entryCount>0 时触发）。
//
// 定位线索：
//   1. btree.insertBatch / insertIntoLeaf（src/btree.zig ~:1056）：覆盖物理
//      live entry 为 tombstone → count_delta = -1。该 delta 只看**物理**
//      新旧态，不看链遮蔽（语义上该 key 本来就不可见，可见性变化 = 0）。
//   2. putBatch 的链感知补偿只在 planTombPunch（src/db.zig ~:995），而它
//      显式跳过 tombstone req（"a delete inside a tomb range is already
//      shadowed"）——对 entryCount 计数而言恰恰不成立：物理 live 但被链
//      遮蔽的 key 被点删时，count_delta -1 是**错**的。
//   3. 后果：entry_count != 可见 live 数（三口径不变量破裂）；deleteRange
//      的 count pass 只按可见数做 delta，不会修复这个漂移。
//   4. 修复方向（供排障参考，本任务零 src/ 改动）：要么点删路径感知链
//      遮蔽（被遮蔽 key 的 tombstone req 不产生 count_delta），要么
//      planTombPunch/putBatch 对「物理 live 且被链覆盖」的 tombstone req
//      补 +1（对应 insert 的 -1）。

test "t387 S3 BLOCKED-repro: point delete of a chain-shadowed live key breaks entryCount==select" {
    const path = ".test_t387_s3.db";
    defer unlinkTmp(path);
    unlinkTmp(path);

    const o = try openFileDb(path);
    defer closeOpened(o);

    try o.db.put("a", "va");
    try o.db.put("b", "vb");
    try o.db.deleteRange("b", "c"); // 遮蔽 b；entryCount = 1（只剩 a 可见）
    try std.testing.expectEqual(@as(u64, 1), o.db.entryCount());
    try expectCountsConsistent(o.db);

    // 点删被遮蔽但物理在场的 b：可见性变化 = 0（本来就不可见、删后仍不可见），
    // 但 insertBatch 报 count_delta = -1 → entryCount 漂移到 0。
    try o.db.delete("b");
    try o.db.flush();

    // 不变量：entryCount == select 可见数（a 仍可见）。修复前必然失败。
    try expectCountsConsistent(o.db);
    try std.testing.expectEqual(@as(u64, 1), o.db.entryCount());
}

// =====================================================================
// S4 — 多页墓碑链压力：200 个互不相交区间 × 并发 put × reopen
// =====================================================================

const S4PutterCtx = struct {
    db: *Db,
    err: ?anyerror = null,
};

/// 范围外 z-key（所有区间都在 [d000000, d000399) 内）→ 终态全确定。
fn workerS4Putter(ctx: *S4PutterCtx) void {
    var kbuf: [16]u8 = undefined;
    var vbuf: [16]u8 = undefined;
    for (0..S4_Z_ITERS) |i| {
        const k = std.fmt.bufPrint(&kbuf, "z{d:0>6}", .{i}) catch unreachable;
        const v = std.fmt.bufPrint(&vbuf, "vz{d:0>6}", .{i}) catch unreachable;
        ctx.db.put(k, v) catch |e| {
            ctx.err = e;
            return;
        };
        sleepNs(300_000); // ~0.45s 窗口：与 200 次 deleteRange 交错
    }
}

/// 确定性终态：偶数 d-key 全遮蔽（各自区间已提交）、奇数 d-key 全在场值正确、
/// z-key 全在场精确计数、无幻影、三口径一致。
fn checkS4Node(db: *Db) !void {
    var it = try db.select(null, null);
    defer it.deinit();
    var n: u64 = 0;
    var vbuf: [16]u8 = undefined;
    while (try it.next()) |e| {
        n += 1;
        if (e.key.len != 7) return error.PhantomKey;
        const idx = std.fmt.parseInt(u64, e.key[1..], 10) catch return error.PhantomKey;
        switch (e.key[0]) {
            'd' => {
                if (idx >= S4_PRE) return error.PhantomKey;
                if (idx % 2 == 0) return error.Resurrection; // 偶数被区间遮蔽
                const want = try std.fmt.bufPrint(&vbuf, "w{d:0>6}", .{idx});
                if (!std.mem.eql(u8, want, e.value)) return error.ValueMismatch;
            },
            'z' => {
                if (idx >= S4_Z_ITERS) return error.PhantomKey;
                const want = try std.fmt.bufPrint(&vbuf, "vz{d:0>6}", .{idx});
                if (!std.mem.eql(u8, want, e.value)) return error.ValueMismatch;
            },
            else => return error.PhantomKey,
        }
    }
    if (db.entryCount() != n) return error.CountMismatch;
    if (n != S4_PRE / 2 + S4_Z_ITERS) return error.ExactCountMismatch; // 200 + 1500

    var kbuf: [16]u8 = undefined;
    for (0..S4_PRE) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "d{d:0>6}", .{i});
        const v = try db.get(k);
        if (i % 2 == 0) {
            if (v) |vv| {
                alloc.free(vv);
                return error.Resurrection;
            }
        } else {
            const vv = v orelse return error.OddKeyLost;
            defer alloc.free(vv);
            const want = try std.fmt.bufPrint(&vbuf, "w{d:0>6}", .{i});
            if (!std.mem.eql(u8, want, vv)) return error.ValueMismatchGet;
        }
    }
    for (0..S4_Z_ITERS) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "z{d:0>6}", .{i});
        const vv = (try db.get(k)) orelse return error.ZKeyLost;
        defer alloc.free(vv);
        const want = try std.fmt.bufPrint(&vbuf, "vz{d:0>6}", .{i});
        if (!std.mem.eql(u8, want, vv)) return error.ValueMismatchGet;
    }
}

fn checkS4Partition(fps: *FilePageStore) !void {
    const meta = (try fps.store().readMeta()) orelse return error.NoMeta;
    var rep = try part.classify(alloc, fps.store(), meta);
    defer rep.deinit();
    try part.expectDisjoint(&rep);
}

fn reopenAndCheckS4(path: []const u8) !void {
    const o = try openFileDb(path);
    defer closeOpened(o);
    try checkS4Node(o.db);
    if (try chainPageCount(o.fps) < 2) return error.ChainNotMultiPage;
    try checkS4Partition(o.fps);
}

test "t387 S4: 200-disjoint-range multi-page tomb chain under concurrent puts, survives reopen" {
    const path = ".test_t387_s4.db";
    defer unlinkTmp(path);
    unlinkTmp(path);

    {
        const o = try openFileDb(path);
        defer closeOpened(o);

        // 前置：400 个 d-key（T-38-5 C6 同款负载）
        {
            var entries: std.ArrayList(cube.Entry) = .empty;
            defer {
                for (entries.items) |e| {
                    alloc.free(e.key);
                    alloc.free(e.value);
                }
                entries.deinit(alloc);
            }
            var kbuf: [16]u8 = undefined;
            var vbuf: [16]u8 = undefined;
            for (0..S4_PRE) |i| {
                const k = try alloc.dupe(u8, std.fmt.bufPrint(&kbuf, "d{d:0>6}", .{i}) catch unreachable);
                errdefer alloc.free(k);
                const v = try alloc.dupe(u8, std.fmt.bufPrint(&vbuf, "w{d:0>6}", .{i}) catch unreachable);
                errdefer alloc.free(v);
                try entries.append(alloc, .{ .key = k, .value = v, .tombstone = false });
            }
            try o.db.putBatch(entries.items);
        }

        // 并发 z-putter（范围外，精确计数）与主线程 200 次 deleteRange 交错
        var pctx = S4PutterCtx{ .db = o.db };
        const tp = try std.Thread.spawn(.{}, workerS4Putter, .{&pctx});
        var kbuf: [16]u8 = undefined;
        var lo: usize = 0;
        while (lo < S4_PRE) : (lo += 2) {
            const k1 = std.fmt.bufPrint(&kbuf, "d{d:0>6}", .{lo}) catch unreachable;
            var k2buf: [16]u8 = undefined;
            const k2 = std.fmt.bufPrint(&k2buf, "d{d:0>6}", .{lo + 1}) catch unreachable;
            try o.db.deleteRange(k1, k2);
        }
        tp.join();
        try std.testing.expect(pctx.err == null);
        try o.db.flush();

        try checkS4Node(o.db); // node A：确定性终态
        if (try chainPageCount(o.fps) < 2) return error.ChainNotMultiPage; // 链确实多页
        try checkS4Partition(o.fps);
    }

    try reopenAndCheckS4(path); // node B：重启保持 + 多页链持久
}

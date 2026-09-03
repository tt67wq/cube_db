//! iterator_borrow_test.zig — T-29 Phase B: Iterator 借用化契约测试
//!
//! RED 阶段（本文件先落，基于旧全量-dupe Iterator 运行时失败）：
//! - 借用契约（T5）：next() 后上一 entry 失效——溢出值经迭代器复用缓冲拼接，
//!   前一 entry 的 value 切片在新 entry 拼接后内容被覆盖（借用语义可观察面）。
//!   旧实现为堆 dupe（上一 entry 仍有效）→ 本测试失败。
//! - 零分配扫描（T1）：内联值全量扫描 select+next 全程 0 次分配
//!   （下推栈 O(深度) 定长、payload 借用、无 per-entry dupe）。旧实现每次
//!   下降/每叶/每 entry 都 alloc → 本测试失败。
//! - 快照 pin（T2）：迭代器活跃期间（Db.select）MVCC 读者名额被持有，
//!   写者提交的 COW 脏页滞留 pending_free 不回收；deinit 后回收。
//!   旧实现 select 不 pin → 本测试失败。
//!
//! 另含回归锁定（旧实现即过，防借用化引入回归）：
//! - 范围黄金对照（T4）：多叶/边界/tombstone 语义与逐条 getInto 交叉验证。
//! - 溢出值迭代（T3）：>3800B 溢出链逐字节正确（含连续多个溢出条目）。
//! - 快照数据稳定性（T6）：迭代中写者覆写，迭代器仍见快照旧值。
const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;
const Db = cube.Db;

const alloc = std.testing.allocator;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 200000);
}

/// 计数分配器：包 std.testing.allocator，数 alloc 次数（resize/remap 不计——非新分配）
const CountingAllocator = struct {
    child: std.mem.Allocator,
    count: usize = 0,

    fn vAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.child.rawAlloc(len, alignment, ra);
    }
    fn vResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(buf, alignment, new_len, ra);
    }
    fn vRemap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(buf, alignment, new_len, ra);
    }
    fn vFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, alignment, ra);
    }
    const vtable = std.mem.Allocator.VTable{
        .alloc = vAlloc,
        .resize = vResize,
        .remap = vRemap,
        .free = vFree,
    };
    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

// ===== T1: 零分配扫描 =====

test "iterator borrow: inline-value full scan performs zero allocations" {
    var counter = CountingAllocator{ .child = alloc };
    const calloc = counter.allocator();

    var ms = ps.MemPageStore.init(calloc, 200000);
    defer ms.deinit();
    var db = try Db.open(calloc, ms.store(), .{});
    defer db.close();

    // 200 个内联 entry（跨多叶），先全部写入（写路径随便分配）
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>4}", .{i});
        try db.put(k, "inline-value");
    }

    // 复位计数：select + 全量 next 必须 0 分配
    counter.count = 0;
    var it = try db.select(null, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |e| {
        try std.testing.expectEqualStrings("inline-value", e.value);
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 200), n);
    try std.testing.expectEqual(@as(usize, 0), counter.count);
}

// ===== T2: 快照 pin（MVCC 读者名额） =====

test "iterator borrow: Db.select pins read snapshot — dirty pages held until deinit" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    try db.put("k1", "v1");
    try db.put("k2", "v2");

    var it = try db.select(null, null);
    // pin 已生效：此时读者名额 >= 1

    // 迭代中途写者提交（COW 出新页，旧页成脏页）
    try db.put("k3", "v3");

    // 脏页必须滞留 pending_free（迭代器仍借用旧页），不得回收
    try std.testing.expect(db.state.pendingFreeCount() > 0);

    // 迭代器仍看到快照：k3 不可见（select 时的快照里没有 k3）
    var seen: usize = 0;
    var saw_k3 = false;
    while (try it.next()) |e| {
        seen += 1;
        if (std.mem.eql(u8, e.key, "k3")) saw_k3 = true;
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
    try std.testing.expect(!saw_k3);

    // deinit（末位读者退出）→ 脏页回收
    it.deinit();
    try std.testing.expectEqual(@as(usize, 0), db.state.pendingFreeCount());
}

// ===== T3: 溢出值迭代黄金对照 =====

test "iterator borrow: overflow values scanned byte-exact (consecutive overflow entries)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    // 3 个连续溢出条目（值模式互异，防缓冲复用串值）+ 前后内联条目
    var ov: [4200]u8 = undefined;
    const vals = [3][]const u8{ "A", "B", "C" };
    for (vals, 0..) |tag, vi| {
        @memset(&ov, tag[0]);
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "ov{d}", .{vi});
        try db.put(k, &ov);
    }
    try db.put("zz-inline", "small");

    var it = try db.select(null, null);
    defer it.deinit();
    var ov_seen: usize = 0;
    var inline_seen: usize = 0;
    while (try it.next()) |e| {
        if (e.value.len > 3800) {
            try std.testing.expectEqual(@as(usize, 4200), e.value.len);
            const want_tag = vals[ov_seen];
            for (e.value) |b| try std.testing.expectEqual(want_tag[0], b);
            // 逐字节黄金对照 getInto
            var gbuf: [4200]u8 = undefined;
            const gn = (try db.getInto(e.key, &gbuf)).?;
            try std.testing.expectEqualSlices(u8, e.value, gbuf[0..gn]);
            ov_seen += 1;
        } else {
            inline_seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), ov_seen);
    try std.testing.expectEqual(@as(usize, 1), inline_seen);
}

// ===== T4: 范围黄金对照（多叶 + 边界 + tombstone） =====

test "iterator borrow: range scan golden — bounds, tombstones, multi-leaf" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    // 300 个 entry（多叶多 branch），偶数 key 存 value=原始 key，奇数 key 删除
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>4}", .{i});
        try db.put(k, k);
    }
    i = 1;
    while (i < 300) : (i += 2) {
        var kbuf: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "k{d:0>4}", .{i});
        try db.delete(k);
    }

    // 半开区间 [k0100, k0200)：偶数 key 50 个，奇数被 tombstone 排除
    var it = try db.select("k0100", "k0200");
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |e| {
        var kbuf: [8]u8 = undefined;
        const want = try std.fmt.bufPrint(&kbuf, "k{d:0>4}", .{100 + 2 * n});
        try std.testing.expectEqualStrings(want, e.key);
        try std.testing.expectEqualStrings(want, e.value); // value == key（写入时）
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 50), n);

    // null 边界全量：150 存活
    var full = try db.select(null, null);
    defer full.deinit();
    var total: usize = 0;
    while (try full.next()) |_| total += 1;
    try std.testing.expectEqual(@as(usize, 150), total);
    try std.testing.expectEqual(db.entryCount(), total);
}

// ===== T5: 借用契约 —— next() 后上一 entry 失效 =====

test "iterator borrow: next() invalidates previous entry (overflow buffer reuse)" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    // 两个溢出条目，值模式互异
    var a: [4200]u8 = undefined;
    @memset(&a, 'A');
    var b: [4200]u8 = undefined;
    @memset(&b, 'B');
    try db.put("ov1", &a);
    try db.put("ov2", &b);

    var it = try db.select(null, null);
    defer it.deinit();

    const e1 = (try it.next()).?;
    try std.testing.expectEqualStrings("ov1", e1.key);
    for (e1.value) |c| try std.testing.expectEqual(@as(u8, 'A'), c);

    const e2 = (try it.next()).?;
    try std.testing.expectEqualStrings("ov2", e2.key);
    for (e2.value) |c| try std.testing.expectEqual(@as(u8, 'B'), c);

    // 借用契约：e1.value 与 e2.value 复用同一拼接缓冲 → e1.value 已被覆盖为 B。
    // 借用化后这是显式契约（上一 entry 在 next() 后失效，调用方不得再使用）；
    // 旧堆-dupe 实现里 e1.value 仍是 A → 本断言失败（RED 信号）。
    for (e1.value) |c| try std.testing.expectEqual(@as(u8, 'B'), c);
}

// ===== T6: 快照数据稳定性（迭代中覆写，迭代器见旧值） =====

test "iterator borrow: concurrent overwrite invisible to open iterator" {
    var ms = newStore();
    defer ms.deinit();
    var db = try Db.open(alloc, ms.store(), .{});
    defer db.close();

    try db.put("k1", "old1");
    try db.put("k2", "old2");
    try db.put("k3", "old3");

    var it = try db.select(null, null);
    defer it.deinit();

    const e1 = (try it.next()).?;
    try std.testing.expectEqualStrings("old1", e1.value);

    // 覆写后两 key
    try db.put("k2", "new2");
    try db.put("k3", "new3");

    // 迭代器仍见快照旧值
    const e2 = (try it.next()).?;
    try std.testing.expectEqualStrings("old2", e2.value);
    const e3 = (try it.next()).?;
    try std.testing.expectEqualStrings("old3", e3.value);
    try std.testing.expect((try it.next()) == null);
}

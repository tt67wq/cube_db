//! T-53 — 开库路径必须区分「invalid meta」与「fresh DB」（关闭 T-49 + T-50）
//!
//! 本文件由 **conductor 亲自编写**（TDD：先红后绿）。impl worker **不得修改本文件**。
//! 若认为断言有误 → 标 `blocked`，由 conductor 裁决。
//!
//! 背景（T-49 / T-50 同一根因）：
//! `readMetaPageSingle` 对「magic 坏 / version 非 2 非 3」返回 `null`；
//! 下游 `Db.open` / `FilePageStore.init` 把 `null` 一律解释为「未曾初始化（fresh DB）」。
//! 于是：
//!   - 旧代码读 v3 库 → 打开成功、entryCount=0 → 后续写入从 FIRST_DATA_PAGE 起
//!     **覆盖既有数据页**（T-49，Db 级数据破坏，high）；
//!   - 新代码读未来版本（v4 / 坏 magic）→ 同样静默当空库（T-50，将来会重演）。
//!
//! 本文件把该行为**固化为不可回退的契约**：
//!   - a1/a2/a3/a4：非法 meta（v4 / 坏 magic / v1）必须**拒绝打开**；
//!   - a5：拒绝时**不得写入任何字节**（数据破坏面）；
//!   - a6：拒绝时**无内存泄漏**；
//!   - a7/a8/a9：fresh DB / 正常 v2 / 正常 v3 **必须照常打开**（防误杀）。
//!
//! 判定用「必须返回错误」而非具体错误码 —— 错误码的**命名**属实现自由
//! （typed error 或三值枚举均可），但「必须拒绝」是硬约束。
//!
//! 当前（RED）：a1/a2/a3/a4/a5/a6 全部失败（非法 meta 被当空库接受）；
//!             a7/a8/a9 通过（正常路径未受影响）。GREEN 时九条全过。

const std = @import("std");
const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});
const cube = @import("cube_db");
const ps = cube.page_store;
const dbi = cube.db;
const f2 = cube.format;
const FilePageStore = cube.file_page_store.FilePageStore;
const MemPageStore = cube.page_store.MemPageStore;

const alloc = std.testing.allocator;

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

/// 读整个文件（POSIX open/read，仓库既有风格：不依赖 std.fs 的 Io 接口）
fn readWholeFile(path: []const u8) ![]u8 {
    var pbuf: [256]u8 = undefined;
    if (path.len >= pbuf.len) return error.PathTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;

    const fd = c.open(@ptrCast(&pbuf), @as(c_int, c.O_RDONLY));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(fd, @ptrCast(&chunk), chunk.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(alloc, chunk[0..@intCast(n)]);
    }
    return out.toOwnedSlice(alloc);
}

fn saneMeta(version: u16, magic: u32) f2.MetaPage {
    return .{
        .magic = magic,
        .version = version,
        .mapsize = 1 << 20,
        .sequence = 7,
        .root_page = 0,
        .entry_count = 0,
        .byte_size = 0,
        .free_head = 0,
        .free_count = 0,
        .last_page = 0,
        .tomb_head = 0,
    };
}

/// 伪造双 meta 的 MemPageStore 包装：调用方负责 deinit（含释放底层分配）。
const ForgedStore = struct {
    ms: *MemPageStore,
    store: ps.PageStore,

    fn deinit(self: ForgedStore) void {
        self.ms.deinit();
        alloc.destroy(self.ms);
    }
};

/// 在 MemPageStore 上写一份伪造的双 meta（两个槽），返回所有权给调用方。
/// 只用 format 层原语，不通过 Db —— 这样写入的 meta 内容完全受控。
fn forgeMeta(version: u16, magic: u32) !ForgedStore {
    const ms = try alloc.create(MemPageStore);
    errdefer alloc.destroy(ms);
    ms.* = MemPageStore.init(alloc, 4096);
    errdefer ms.deinit();
    const s = ms.store();
    // 两个槽写同一份（sequence 相同即可）；非法版本/魔数由此注入。
    const m = saneMeta(version, magic);
    {
        const p0 = try s.writePage(f2.META_PAGE_0);
        var buf: [f2.PAGE_SIZE]u8 = undefined;
        @memcpy(buf[0..], p0[0..f2.PAGE_SIZE]);
        f2.writeMetaPage(&buf, &m, 0);
        @memcpy(p0[0..f2.PAGE_SIZE], buf[0..]);
    }
    {
        const p1 = try s.writePage(f2.META_PAGE_1);
        var buf: [f2.PAGE_SIZE]u8 = undefined;
        @memcpy(buf[0..], p1[0..f2.PAGE_SIZE]);
        f2.writeMetaPage(&buf, &m, 1);
        @memcpy(p1[0..f2.PAGE_SIZE], buf[0..]);
    }
    return .{ .ms = ms, .store = s };
}

/// 把某个 FPS 库的两槽 meta **直接落盘**为指定 version（CRC 合法）。
///
/// 为什么不用 `store().writePage()`：FPS 的 `vtWritePage` 对 META_PAGE_0/1
/// 返回的是**内存缓冲** `&self.meta0`/`&self.meta1`，不是 mmap 区域 —— 写进去
/// 不会到磁盘。而且 `Db.open` 的拒绝发生在 `FilePageStore.init` 重读磁盘之后，
/// 所以必须真正改文件字节，否则重开时 init 读到的还是旧的合法 meta。
///
/// 这里用 POSIX pwrite 直接改页；meta 字节由 format 层原语生成（保证 CRC/头正确，
/// 从而命中「CRC 合法但版本不认识」这条 invalid 路径，而非 torn/坏 CRC）。
fn writeMetaVersionToFile(path: []const u8, version: u16) !void {
    var pbuf: [256]u8 = undefined;
    if (path.len >= pbuf.len) return error.PathTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;

    const fd = c.open(@ptrCast(&pbuf), @as(c_int, c.O_RDWR));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);

    const m = saneMeta(version, f2.MAGIC_V2);
    inline for (.{ f2.META_PAGE_0, f2.META_PAGE_1 }, .{ 0, 1 }) |pn, idx| {
        var page: [f2.PAGE_SIZE]u8 = undefined;
        @memset(&page, 0);
        f2.writeMetaPage(&page, &m, idx);
        const off: c.off_t = @intCast(@as(u64, pn) * f2.PAGE_SIZE);
        const n = c.pwrite(fd, @ptrCast(&page), f2.PAGE_SIZE, off);
        if (n != @as(isize, f2.PAGE_SIZE)) return error.WriteFailed;
    }
    if (c.fsync(fd) != 0) return error.SyncFailed;
}

// =====================================================================
// a1 — 未来版本（v4）：必须拒绝，不得当空库打开（T-50 核心）
// =====================================================================
test "T-53 a1: unsupported version is rejected, not opened as empty" {
    const forged = try forgeMeta(4, f2.MAGIC_V2);
    defer forged.deinit();
    const r = dbi.Db.open(alloc, forged.store, .{});
    if (r) |db| {
        db.close();
        std.debug.print("\nRED: Db.open ACCEPTED version=4 meta (T-50)\n", .{});
        return error.AcceptedInvalidMeta;
    } else |_| {}
}

// =====================================================================
// a2 — magic 损坏：必须拒绝
// =====================================================================
test "T-53 a2: corrupted magic is rejected" {
    const forged = try forgeMeta(2, 0xDEAD_BEEF); // 错误的魔数
    defer forged.deinit();
    const r = dbi.Db.open(alloc, forged.store, .{});
    if (r) |db| {
        db.close();
        std.debug.print("\nRED: Db.open ACCEPTED corrupted magic\n", .{});
        return error.AcceptedInvalidMeta;
    } else |_| {}
}

// =====================================================================
// a3 — 过老版本（v1）：必须拒绝
// =====================================================================
test "T-53 a3: legacy version=1 is rejected" {
    const forged = try forgeMeta(1, f2.MAGIC_V2);
    defer forged.deinit();
    const r = dbi.Db.open(alloc, forged.store, .{});
    if (r) |db| {
        db.close();
        std.debug.print("\nRED: Db.open ACCEPTED version=1 meta\n", .{});
        return error.AcceptedInvalidMeta;
    } else |_| {}
}

// =====================================================================
// a4 — FilePageStore 侧同样必须拒绝（T-49 的原始证据链在 FPS）
// =====================================================================
test "T-53 a4: FilePageStore rejects unsupported version (no silent fresh-DB)" {
    const path = ".test_t53_fps_v4.db";
    defer unlinkPath(path);

    {
        // 先建一个正常 v2 库并写点数据，确保文件里**真的有数据页**
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try dbi.Db.open(alloc, fps.store(), .{});
        defer db.close();
        try db.putDirect("keep", "v");
        try db.putDirect("keep2", "v2");
    }

    // 把两槽 meta 落盘改写为 version=4（CRC 合法），模拟「未来版本库」
    try writeMetaVersionToFile(path, 4);

    // 重开：必须拒绝
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    const r = dbi.Db.open(alloc, fps.store(), .{});
    if (r) |db| {
        db.close();
        std.debug.print("\nRED: FPS opened version=4 db — silent fresh-DB (T-49)\n", .{});
        return error.AcceptedInvalidMeta;
    } else |_| {}
}

// =====================================================================
// a5 — 拒绝打开时不得写入任何字节（数据破坏面硬约束）
// =====================================================================
test "T-53 a5: rejected open must not modify the file" {
    const path = ".test_t53_nomutate.db";
    defer unlinkPath(path);

    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        var db = try dbi.Db.open(alloc, fps.store(), .{});
        defer db.close();
        try db.putDirect("keep", "important");
    }
    // 把两槽 meta 落盘改写为 version=4（CRC 合法）
    try writeMetaVersionToFile(path, 4);

    // 快照「拒绝前」的文件字节
    const before = try readWholeFile(path);
    defer alloc.free(before);

    {
        var fps = try FilePageStore.init(alloc, path);
        defer fps.deinit();
        if (dbi.Db.open(alloc, fps.store(), .{})) |db| {
            db.close();
            std.debug.print("\nRED: version=4 db was opened — non-mutation unverifiable\n", .{});
        } else |_| {}
    }

    const after = try readWholeFile(path);
    defer alloc.free(after);

    try std.testing.expectEqual(before.len, after.len);
    try std.testing.expectEqualSlices(u8, before, after);
}

// =====================================================================
// a6 — 反复走拒绝路径不得泄漏（错误路径资源清理）
// =====================================================================
test "T-53 a6: repeated rejected opens leak nothing" {
    var accepted: usize = 0;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const forged = try forgeMeta(4, f2.MAGIC_V2);
        defer forged.deinit();
        if (dbi.Db.open(alloc, forged.store, .{})) |db| {
            db.close();
            accepted += 1;
        } else |_| {}
    }
    if (accepted != 0) {
        std.debug.print("\nRED: {d}/50 version=4 metas were accepted\n", .{accepted});
    }
    // 全部必须被拒绝；std.testing.allocator 同时检查泄漏
    try std.testing.expectEqual(@as(usize, 0), accepted);
}

// =====================================================================
// a7 — fresh DB（双槽全空）必须照常打开（防误杀，T-50 的 D 项）
// =====================================================================
test "T-53 a7: fresh DB still opens normally" {
    const ms = try alloc.create(MemPageStore);
    ms.* = MemPageStore.init(alloc, 4096);
    defer {
        ms.deinit();
        alloc.destroy(ms);
    }
    const s = ms.store();
    // 不写任何 meta → 双槽全空 = fresh
    var db = try dbi.Db.open(alloc, s, .{});
    defer db.close();
    try db.putDirect("a", "1");
    const got = try db.get("a");
    defer if (got) |v| alloc.free(v);
    try std.testing.expect(got != null);
}

// =====================================================================
// a8 — 正常 v2 库必须照常打开，且字段取值不变（防回归）
// =====================================================================
test "T-53 a8: valid v2 DB still opens with identical field values" {
    const ms = try alloc.create(MemPageStore);
    ms.* = MemPageStore.init(alloc, 4096);
    defer {
        ms.deinit();
        alloc.destroy(ms);
    }
    const s = ms.store();
    var db = try dbi.Db.open(alloc, s, .{});
    try db.putDirect("k", "v");
    db.close();

    var db2 = try dbi.Db.open(alloc, s, .{});
    defer db2.close();
    const got = try db2.get("k");
    defer if (got) |v| alloc.free(v);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v", got.?);
}

// =====================================================================
// a9 — 正常 v3 库必须照常打开（本仓库 v3 是合法版本）
// =====================================================================
test "T-53 a9: valid v3 meta still opens" {
    const forged = try forgeMeta(3, f2.MAGIC_V2);
    defer forged.deinit();
    // v3 是合法版本 → 必须打开成功
    var db = try dbi.Db.open(alloc, forged.store, .{});
    defer db.close();
    try db.putDirect("a", "1");
}

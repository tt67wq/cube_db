//! t535_torn_meta_test.zig — T-53-1: torn meta 不得被当 fresh 可写态打开
//!
//! 破坏面（issues/T-53-torn-meta-still-fresh-db-data-overwrite.md，adv4b）：
//! 双槽皆 torn（非零但 CRC 坏），或单提交库唯一已写槽 torn 时，readMetaPage
//! 双 null → Db.open 当 fresh 打开 → next_free = FIRST_DATA_PAGE → 后续写
//! 从数据区起点分配，覆盖既有数据页（T-49 同族数据破坏面）。
//!
//! 断言（协议无关——修前单槽交替协议与修后 T-53-1 双槽协议都成立）：
//!   t1 多提交库（≥2 commit，两槽都已写）+ 双槽撕坏 → 必须拒绝打开；
//!   t2 单提交库 + 全部已写槽撕坏 → 必须拒绝打开。
//!      修前：单提交只写一个槽，撕掉它 → 双 null → fresh 打开 → RED；
//!      修后（双槽协议）：单提交即写满双槽，「全部已写槽」= 双槽，撕双槽 → 拒绝。
//!   t3 防误杀：两提交库撕坏恰好一个槽 → 另一槽有效 → 必须照常打开且数据完整；
//!   t4 防误杀：真 fresh（双槽全零）→ 照常打开可写；
//!   t5 拒绝路径不得改动文件字节（数据破坏面硬约束，T-53 a5 同款）。
//!
//! 判定用「必须返回错误」而非具体错误码（与 open_meta_guard_test 同约定）。

const std = @import("std");
const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});
const cube = @import("cube_db");
const f2 = cube.format;
const FilePageStore = cube.file_page_store.FilePageStore;
const dbi = cube.db;

const alloc = std.testing.allocator;

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

fn pathZ(path: []const u8) ![:0]u8 {
    return try alloc.dupeZ(u8, path);
}

/// 把槽页 page_no 的第 `off` 字节按位取反（破坏 CRC → torn，且保持非零）。
fn corruptSlotByte(path: []const u8, page_no: u32, off: usize) !void {
    var pbuf: [256]u8 = undefined;
    if (path.len >= pbuf.len) return error.PathTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;

    const fd = c.open(@ptrCast(&pbuf), @as(c_int, c.O_RDWR));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);

    const abs_off: c.off_t = @intCast(@as(u64, page_no) * f2.PAGE_SIZE + off);
    var byte: u8 = 0;
    const rn = c.pread(fd, @ptrCast(&byte), 1, abs_off);
    if (rn != 1) return error.ReadFailed;
    byte ^= 0xFF; // 翻转：非零性保持取反后仍可能为 0？——0^0xFF=0xFF，非零^0xFF 可能
    // 为 0 的情形只有原值恰为 0xFF；meta 页中部字段不会是全 FF，保险起见再兜底
    if (byte == 0) byte = 0x5A;
    const wn = c.pwrite(fd, @ptrCast(&byte), 1, abs_off);
    if (wn != 1) return error.WriteFailed;
    if (c.fsync(fd) != 0) return error.SyncFailed;
}

/// 槽页是否含任何非零字节（全零 = 从未写过）。
fn slotIsNonZero(path: []const u8, page_no: u32) !bool {
    var pbuf: [256]u8 = undefined;
    if (path.len >= pbuf.len) return error.PathTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;

    const fd = c.open(@ptrCast(&pbuf), @as(c_int, c.O_RDONLY));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);

    var page: [f2.PAGE_SIZE]u8 = undefined;
    const abs_off: c.off_t = @intCast(@as(u64, page_no) * f2.PAGE_SIZE);
    const n = c.pread(fd, @ptrCast(&page), f2.PAGE_SIZE, abs_off);
    if (n != @as(isize, f2.PAGE_SIZE)) return error.ReadFailed;
    for (page) |b| {
        if (b != 0) return true;
    }
    return false;
}

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

/// 建库 + n 次独立提交（每次 putDirect = 一个 commit）。
fn buildDb(path: []const u8, commits: usize) !void {
    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try dbi.Db.open(alloc, fps.store(), .{});
    defer db.close();
    var i: usize = 0;
    while (i < commits) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "keep{d}", .{i});
        try db.putDirect(k, "v");
    }
}

// =====================================================================
// t1 — 多提交库 + 双槽撕坏：必须拒绝（不得 fresh 可写态）
// =====================================================================
test "t535 t1: both slots torn on a multi-commit db is refused, not fresh-opened" {
    const path = ".test_t535_both_torn.db";
    defer unlinkPath(path);
    try buildDb(path, 2); // 两提交：两种协议下两槽均已写

    // 双槽各撕一字节（CRC 坏、保持非零）
    try corruptSlotByte(path, f2.META_PAGE_0, 200);
    try corruptSlotByte(path, f2.META_PAGE_1, 200);

    // 快照拒绝前字节（t5 同款硬约束顺手覆盖）
    const before = try readWholeFile(path);
    defer alloc.free(before);

    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    if (dbi.Db.open(alloc, fps.store(), .{})) |db| {
        // 被当 fresh 打开 = 数据破坏面（adv4b）。若实现选择「带恢复入口的
        // 打开」，next_free 不得落在数据区——但本契约直接要求拒绝。
        db.close();
        std.debug.print("\nRED: both-slots-torn db was fresh-opened (T-53-1)\n", .{});
        return error.AcceptedTornMetaAsFresh;
    } else |_| {}

    const after = try readWholeFile(path);
    defer alloc.free(after);
    try std.testing.expectEqual(before.len, after.len);
    try std.testing.expectEqualSlices(u8, before, after);
}

// =====================================================================
// t2 — 单提交库 + 全部已写槽撕坏：必须拒绝
// =====================================================================
test "t535 t2: single-commit db with every written slot torn is refused" {
    const path = ".test_t535_single_torn.db";
    defer unlinkPath(path);
    try buildDb(path, 1); // 单提交

    // 撕坏「全部已写槽」：逐槽检查非零即撕（协议无关）。
    // 修前单槽协议：只有 META_PAGE_0 非零 → 撕它 → 双 null → fresh（RED）。
    // 修后双槽协议：两槽均非零 → 全撕 → 必须拒绝（GREEN）。
    for ([_]u32{ f2.META_PAGE_0, f2.META_PAGE_1 }) |pn| {
        if (try slotIsNonZero(path, pn)) {
            try corruptSlotByte(path, pn, 200);
        }
    }

    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    if (dbi.Db.open(alloc, fps.store(), .{})) |db| {
        db.close();
        std.debug.print("\nRED: single-commit torn db was fresh-opened (T-53-1)\n", .{});
        return error.AcceptedTornMetaAsFresh;
    } else |_| {}
}

// =====================================================================
// t3 — 防误杀：两提交库撕坏单槽 → 另一槽有效，必须照常恢复
// =====================================================================
test "t535 t3: single-slot tear on a two-commit db still recovers data" {
    const path = ".test_t535_one_torn.db";
    defer unlinkPath(path);
    try buildDb(path, 2);

    try corruptSlotByte(path, f2.META_PAGE_0, 200); // 只撕一槽

    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try dbi.Db.open(alloc, fps.store(), .{});
    defer db.close();
    try std.testing.expectEqual(@as(u64, 2), db.entryCount());
    const v = try db.get("keep1");
    defer if (v) |vv| alloc.free(vv);
    try std.testing.expectEqualStrings("v", v.?);
}

// =====================================================================
// t4 — 防误杀：真 fresh（双槽全零）照常打开可写
// =====================================================================
test "t535 t4: genuinely fresh db (both slots zero) still opens writable" {
    const path = ".test_t535_fresh.db";
    defer unlinkPath(path);

    var fps = try FilePageStore.init(alloc, path);
    defer fps.deinit();
    var db = try dbi.Db.open(alloc, fps.store(), .{});
    defer db.close();
    try db.putDirect("a", "1");
    const got = try db.get("a");
    defer if (got) |v| alloc.free(v);
    try std.testing.expectEqualStrings("1", got.?);
}

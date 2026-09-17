//! range_tombstone_format_test.zig — T-38-1 阶段 1（格式层）RED 测试（pi-3，测试者）
//!
//! 规格：docs/design/T-38-range-tombstone-probe.md
//!   §1.2 页布局（修订版：payload 计数移除 / 条头 16B / append_zero 紧凑标志）
//!   §1.4 条目语义（Bound / null 边界 / succ(k) 紧凑表示 / seq 从页 gen 继承）
//!   §2   meta version 2→3 升级 + 三值判定（v2 / v3 / 其它→明确拒绝）
//! 蓝本：spike/rangetomb_probe.zig 探针 1/4/5/6 的断言。
//!
//! 本文件是 TDD RED：引用的 src/format.zig API 尚未实现，预期编译失败
//! （RED 类型=编译失败；见 .agents/tasks/T-38-1/red-report.md）。
//!
//! =====================================================================
//! 【假定 API 契约 — pi-1 实现时必须按此对齐（测试即契约）】
//!
//! // 页类型（现有 kind 用到 4=OVERFLOW，新增）：
//! pub const PAGE_TYPE_RANGE_TOMBSTONE: u8 = 5;
//!
//! // 条头大小（设计 §1.2 修订版）：
//! pub const TOMB_ENTRY_SIZE: usize = 16;
//!
//! // 边界（设计 §1.4）：effective 字节串 = bytes ++ (0x00 if append_zero)。
//! // append_zero 是 succ(k) = k ++ 0x00 的紧凑表示（存原键长）。
//! pub const TombBound = struct {
//!     bytes: []const u8,
//!     append_zero: bool = false,
//! };
//!
//! // 墓碑条目。逐条 seq 不落盘：解码后从 TombPage.hdr.gen（=写入时
//! // commit sequence）继承（设计 §1.4——条头保持 16B 的代价）。
//! pub const RangeTombstone = struct {
//!     min: ?TombBound,  // null = 负无穷
//!     max: ?TombBound,  // null = 正无穷
//! };
//!
//! // 解码结果。tobs 由 decodeTombPage 用传入 allocator 分配（调用方 free）；
//! // 各 bound.bytes 借用 page 缓冲（调用方保持 page 生命周期）。
//! pub const TombPage = struct {
//!     hdr: PageHeader,   // hdr.gen = commit sequence（页 gen 继承 seq）
//!     tobs: []RangeTombstone,
//!     next: u32,         // = hdr.free_next：下一链页（0=尾）
//! };
//!
//! // 编码（页布局逐字节对齐设计 §1.2 修订版）：
//! //   PageHeader(24B): page_no / page_type=5 / gen=commit_seq /
//! //                    nkeys=墓碑条数 / free_next=next_page
//! //   payload[0..]  = 连续定长条头 16B × nkeys（无 payload 计数——页头为准）：
//! //     min_len u32  # min 存储键长；bit31 = append_zero 标志
//! //     max_len u32  # max 存储键长；bit31 = append_zero 标志
//! //     min_off u32  # min 键字节偏移（payload 起）
//! //     max_off u32  # max 键字节偏移（payload 起）
//! //   变长区紧跟条头数组（entry0 的 min_off == 16*nkeys——无 2B 计数）
//! //   尾部 4B CRC32（复用 setPageChecksum/computePageChecksum）
//! // 错误（两级，不得混同——设计 §1.2 F2 返工）：
//! //   error.TombBoundTooLarge — 单条 16 + min_stored + max_stored > 4068
//! //     （双长边界，typed 明确拒绝；生产方向 = 边界 spill 到 overflow 页）
//! //   error.TombPageOverflow  — 多条装箱超页（正常路径，调用方分页串链）
//! pub fn encodeTombPage(page: *[PAGE_SIZE]u8, page_no: u32,
//!     tobs: []const RangeTombstone, commit_seq: u64, next_page: u32) !void;
//!
//! // 解码（设计 §1.2 N1：offset 越界必须 typed error，不得 @panic）：
//! //   error.CorruptCrc — CRC 失败（§5.1：报错不静默）
//! //   error.Truncated  — 条头数组 / offset / len 越界或截断
//! pub fn decodeTombPage(allocator: std.mem.Allocator,
//!     page: *const [PAGE_SIZE]u8) !TombPage;
//!
//! // spill 预留位（用户定案）：min_len/max_len 的 bit30 恒 0——保留给
//! // 「边界 spill 到 overflow 链页」（设计 §1.2 阶段 1 决策）。预留本身是
//! // 格式的一部分：编码恒写 0（bit31 仍为 append_zero）。
//!
//! // meta v3（设计 §2）：
//! //   MetaPage 增加 tomb_head: u32（0 = 无墓碑链；建议默认值 0，
//! //   避免破坏既有测试的 struct 字面量构造）。
//! //   META_PAGE_PAYLOAD_SIZE: 58 → 62（v2 基础 58B + tomb_head u32）。
//! //   encodeMetaPayload：恒写 58B v2 基础布局（前 58B 与 v2 逐字节一致）；
//! //     meta.version == 3 时追加 tomb_head 于 [58..62]。
//! //   writeMetaPage：按 meta.version 编码（v2=58B / v3=62B），v2 不动 tomb 区。
//! //   readMetaPageSingle（三值判定，设计 §2 N2——不得把「非 v2」当 v2）：
//! //     v2 → 有效，tomb_head = 0（行为与旧版逐字节一致）
//! //     v3 → 有效，读 tomb_head
//! //     magic 不符 或 version >= 4 → null（打开失败，明确拒绝）
//! //   readMetaPage：双槽取高 sequence，v2/v3 混合槽无混合态。
//! =====================================================================

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;

const alloc = std.testing.allocator;

// ===== 小工具（对齐 spike 的 plain/succ 构造器） =====

fn plain(bytes: []const u8) ?f2.TombBound {
    return .{ .bytes = bytes };
}

/// succ(k)：effective = bytes ++ 0x00（> bytes 的最短字节串），紧凑表示存原键长。
fn succ(bytes: []const u8) ?f2.TombBound {
    return .{ .bytes = bytes, .append_zero = true };
}

fn expectBoundEq(expected: ?f2.TombBound, got: ?f2.TombBound) !void {
    if (expected == null) {
        try std.testing.expect(got == null); // null = 负/正无穷
        return;
    }
    try std.testing.expect(got != null);
    try std.testing.expectEqualSlices(u8, expected.?.bytes, got.?.bytes);
    try std.testing.expectEqual(expected.?.append_zero, got.?.append_zero);
}

/// 条头 len 字的期望编码：bit31 = append_zero，bit30 = spill 预留（恒 0），
/// 低 31 位 = 存储键长（append_zero 存原键长——succ 紧凑表示）。null 边界 = 0。
fn rawLenWord(b: ?f2.TombBound) u32 {
    const m = b orelse return 0;
    var w: u32 = @intCast(m.bytes.len);
    if (m.append_zero) w |= 0x8000_0000;
    return w;
}

fn tombPayload(page: *[f2.PAGE_SIZE]u8) []u8 {
    return page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
}

// =====================================================================
// 0. 常量与布局（规格 §1.2：页 kind=5 / 条头 16B / meta payload 62B）
// =====================================================================

test "T-38-1: constants — page kind 5 / 16B entry header / meta payload 62B" {
    try std.testing.expectEqual(@as(u8, 5), f2.PAGE_TYPE_RANGE_TOMBSTONE);
    try std.testing.expectEqual(@as(usize, 16), f2.TOMB_ENTRY_SIZE);
    try std.testing.expectEqual(@as(usize, 62), f2.META_PAGE_PAYLOAD_SIZE); // 58 + tomb_head u32
}

// =====================================================================
// 1. 墓碑页 round-trip：16B 条头 + append_zero 边界 + null 边界 +
//    无 payload 计数 + len 字位布局（bit31 标志 / bit30 spill 预留恒 0）
//    （规格 §1.2 / §1.4；蓝本：探针 1）
// =====================================================================

test "T-38-1: tomb page round-trip — 16B entries, append_zero bounds, raw layout" {
    const tobs = [_]f2.RangeTombstone{
        .{ .min = plain("apple"), .max = plain("banana") },
        .{ .min = succ("apple"), .max = plain("banana") }, // succ 紧凑（F1 核心）
        .{ .min = plain("a"), .max = succ("m") },
        .{ .min = null, .max = plain("\xff\xff\xff") }, // min=null → 负无穷
        .{ .min = plain("x"), .max = null }, // max=null → 正无穷
        // len=0 且有 append_zero 标志 ≠ null：effective = "\x00"（§1.4）
        .{ .min = .{ .bytes = "", .append_zero = true }, .max = plain("\x00") },
    };
    var page: [f2.PAGE_SIZE]u8 = undefined;
    try f2.encodeTombPage(&page, 77, &tobs, 4242, 99);

    // 页头逐字段（§1.2：gen = commit_seq，nkeys = 条数，free_next = 链）
    const hdr = f2.decodePageHeader(page[0..f2.PAGE_HEADER_SIZE]);
    try std.testing.expectEqual(@as(u32, 77), hdr.page_no);
    try std.testing.expectEqual(f2.PAGE_TYPE_RANGE_TOMBSTONE, hdr.page_type);
    try std.testing.expectEqual(@as(u64, 4242), hdr.gen); // 页 gen 继承 seq（§1.4）
    try std.testing.expectEqual(@as(u16, tobs.len), hdr.nkeys);
    try std.testing.expectEqual(@as(u32, 99), hdr.free_next);

    const payload = tombPayload(&page);
    // 无 payload 计数（F2 修订）：变长区紧跟条头数组——
    // entry0 的 min_off == 16*nkeys（基线的 2B 计数会让它 +2）
    const min_off0 = std.mem.readInt(u32, payload[8..12], .little);
    try std.testing.expectEqual(@as(u32, 16 * tobs.len), min_off0);

    // 条头 len 字逐位：bit31 = append_zero、bit30 = spill 预留（恒 0）、
    // 低 31 位 = 存储键长（succ 存原键长）。null 边界字 = 0。
    for (tobs, 0..) |t, i| {
        const min_raw = std.mem.readInt(u32, payload[16 * i ..][0..4], .little);
        const max_raw = std.mem.readInt(u32, payload[16 * i + 4 ..][0..4], .little);
        try std.testing.expectEqual(rawLenWord(t.min), min_raw);
        try std.testing.expectEqual(rawLenWord(t.max), max_raw);
        // spill 预留位（用户定案）：bit30 恒 0，保留给边界 spill 到 overflow 链页
        try std.testing.expectEqual(@as(u32, 0), min_raw & 0x4000_0000);
        try std.testing.expectEqual(@as(u32, 0), max_raw & 0x4000_0000);
    }

    // 解码 round-trip：条目内容逐项一致
    const d = try f2.decodeTombPage(alloc, &page);
    defer alloc.free(d.tobs);
    try std.testing.expectEqual(@as(u32, 99), d.next); // free_next = 链
    try std.testing.expectEqual(@as(u64, 4242), d.hdr.gen); // seq 从页 gen 继承
    try std.testing.expectEqual(tobs.len, d.tobs.len);
    for (tobs, d.tobs) |want, got| {
        try expectBoundEq(want.min, got.min);
        try expectBoundEq(want.max, got.max);
    }
}

// =====================================================================
// 2. CRC 损坏墓碑页 → typed error.CorruptCrc，不得 panic / 静默
//    （规格 §5.1；蓝本：探针 1）
// =====================================================================

test "T-38-1: corrupted tomb page CRC -> error.CorruptCrc (typed, no panic)" {
    const tobs = [_]f2.RangeTombstone{
        .{ .min = plain("apple"), .max = succ("banana") },
        .{ .min = null, .max = null }, // 全区间
    };
    var page: [f2.PAGE_SIZE]u8 = undefined;
    try f2.encodeTombPage(&page, 5, &tobs, 7, 0);

    // payload 区翻转一字节 → CorruptCrc
    page[f2.PAGE_HEADER_SIZE + 10] ^= 0xff;
    try std.testing.expectError(error.CorruptCrc, f2.decodeTombPage(alloc, &page));
    page[f2.PAGE_HEADER_SIZE + 10] ^= 0xff;

    // 变长区（深处）翻转一字节 → CorruptCrc
    page[3000] ^= 0x01;
    try std.testing.expectError(error.CorruptCrc, f2.decodeTombPage(alloc, &page));
    page[3000] ^= 0x01;

    // 复原后可解
    const d = try f2.decodeTombPage(alloc, &page);
    defer alloc.free(d.tobs);
    try std.testing.expectEqual(tobs.len, d.tobs.len);
}

// =====================================================================
// 3. offset 越界 / 条头数组截断 → typed error.Truncated，不得 @panic
//    （规格 §1.2 N1：探针的 @panic 是 spike 特权，迁移必须改 typed error）
// =====================================================================

test "T-38-1: OOB offset / truncated header array -> error.Truncated (no panic)" {
    const tobs = [_]f2.RangeTombstone{
        .{ .min = plain("k0"), .max = plain("k9") },
    };
    var page: [f2.PAGE_SIZE]u8 = undefined;
    try f2.encodeTombPage(&page, 5, &tobs, 7, 0);
    const saved = page; // 原始有效页，每轮破坏后复原
    const payload = tombPayload(&page);

    // (a) min_off 单独越界（off > payload.len）
    std.mem.writeInt(u32, payload[8..12], 0x7FFF_0000, .little);
    f2.setPageChecksum(&page, f2.computePageChecksum(&page));
    try std.testing.expectError(error.Truncated, f2.decodeTombPage(alloc, &page));
    page = saved;

    // (b) off + len 合计越界（各自都在界内）
    std.mem.writeInt(u32, payload[0..4], 1000, .little); // min_len
    std.mem.writeInt(u32, payload[8..12], 4000, .little); // min_off
    f2.setPageChecksum(&page, f2.computePageChecksum(&page));
    try std.testing.expectError(error.Truncated, f2.decodeTombPage(alloc, &page));
    page = saved;

    // (c) nkeys 超容量：条头数组 16*nkeys 超出 payload → 截断
    var hdr = f2.decodePageHeader(page[0..f2.PAGE_HEADER_SIZE]);
    hdr.nkeys = 1000; // 16000B > 4068B
    f2.encodePageHeader(page[0..f2.PAGE_HEADER_SIZE], &hdr);
    f2.setPageChecksum(&page, f2.computePageChecksum(&page));
    try std.testing.expectError(error.Truncated, f2.decodeTombPage(alloc, &page));
    page = saved;

    // 复原后可解（破坏全部可逆）
    const d = try f2.decodeTombPage(alloc, &page);
    defer alloc.free(d.tobs);
    try std.testing.expectEqualSlices(u8, "k0", d.tobs[0].min.?.bytes);
}

// =====================================================================
// 4. 多页 free_next 链 + 容量上界 + 两级错误区分
//    （规格 §1.2 容量声明 / 链式；蓝本：探针 5）
// =====================================================================

test "T-38-1: multi-page free_next chain, gen inheritance, TombPageOverflow vs TombBoundTooLarge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const n: usize = 500;
    const min_kb = try a.alloc(u8, n);
    const max_kb = try a.alloc(u8, n);
    const tobs = try a.alloc(f2.RangeTombstone, n);
    for (0..n) |i| {
        min_kb[i] = @intCast((i * 7) % 256);
        max_kb[i] = @intCast((i * 13 + 1) % 256);
        tobs[i] = .{ .min = plain(min_kb[i..][0..1]), .max = plain(max_kb[i..][0..1]) };
    }

    // 每条 16 + 1 + 1 = 18B → 每页 4068/18 = 226 条（设计 §1.2 容量声明核对）
    const per_page: usize = (f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4) / 18;
    try std.testing.expect(per_page >= 226);

    // 恰好装满一页（226×18 = 4068）必须成功——不 off-by-one
    var full: [f2.PAGE_SIZE]u8 = undefined;
    try f2.encodeTombPage(&full, 1, tobs[0..per_page], 500, 0);

    // 227 条装不进一页 → TombPageOverflow（多条装箱错误——调用方分页，
    // 与单条 TombBoundTooLarge 是两级不同错误，不得混同）
    var over: [f2.PAGE_SIZE]u8 = undefined;
    try std.testing.expectError(error.TombPageOverflow, f2.encodeTombPage(&over, 1, tobs[0 .. per_page + 1], 500, 0));

    // 三页链：10 → 11 → 12 → 0（尾）
    const n1 = per_page;
    const n2 = per_page;
    const n3 = n - n1 - n2;
    try std.testing.expect(n3 >= 1);
    var p1: [f2.PAGE_SIZE]u8 = undefined;
    var p2: [f2.PAGE_SIZE]u8 = undefined;
    var p3: [f2.PAGE_SIZE]u8 = undefined;
    try f2.encodeTombPage(&p1, 10, tobs[0..n1], 500, 11);
    try f2.encodeTombPage(&p2, 11, tobs[n1..][0..n2], 500, 12);
    try f2.encodeTombPage(&p3, 12, tobs[n1 + n2 ..], 500, 0);

    const d1 = try f2.decodeTombPage(alloc, &p1);
    defer alloc.free(d1.tobs);
    const d2 = try f2.decodeTombPage(alloc, &p2);
    defer alloc.free(d2.tobs);
    const d3 = try f2.decodeTombPage(alloc, &p3);
    defer alloc.free(d3.tobs);

    // free_next 链逐页核对
    try std.testing.expectEqual(@as(u32, 11), d1.next);
    try std.testing.expectEqual(@as(u32, 12), d2.next);
    try std.testing.expectEqual(@as(u32, 0), d3.next); // 尾页

    // 页 gen 继承 seq：链上每页 gen = 同一 commit sequence（§1.4）
    try std.testing.expectEqual(@as(u64, 500), d1.hdr.gen);
    try std.testing.expectEqual(@as(u64, 500), d2.hdr.gen);
    try std.testing.expectEqual(@as(u64, 500), d3.hdr.gen);

    // 全量内容跨页核对
    try std.testing.expectEqual(n1, d1.tobs.len);
    try std.testing.expectEqual(n2, d2.tobs.len);
    try std.testing.expectEqual(n3, d3.tobs.len);
    for (0..n1) |i| try expectBoundEq(tobs[i].min, d1.tobs[i].min);
    for (0..n2) |i| try expectBoundEq(tobs[n1 + i].min, d2.tobs[i].min);
    for (0..n3) |i| try expectBoundEq(tobs[n1 + n2 + i].min, d3.tobs[i].min);
}

// =====================================================================
// 5. 边界可表示性 envelope（规格 §1.2 F2 返工 + 双长边界决策；
//    蓝本：探针 6）
// =====================================================================

test "T-38-1: bound representability envelope — 4051 single-side / succ exact-fill / double-long rejected" {
    var page: [f2.PAGE_SIZE]u8 = undefined;

    // (a) 单侧 4051B（= MAX_KEY_SIZE）用户边界 + null：16 + 4051 = 4067 ≤ 4068 → 可表示
    const kmax = [_]u8{'m'} ** cube.btree.MAX_KEY_SIZE;
    try std.testing.expectEqual(@as(usize, 4051), cube.btree.MAX_KEY_SIZE); // envelope 算术前提
    const single = [_]f2.RangeTombstone{
        .{ .min = plain(&kmax), .max = null },
    };
    try f2.encodeTombPage(&page, 5, &single, 9, 0);
    {
        const d = try f2.decodeTombPage(alloc, &page);
        defer alloc.free(d.tobs);
        try std.testing.expectEqualSlices(u8, &kmax, d.tobs[0].min.?.bytes);
        try std.testing.expect(d.tobs[0].max == null);
    }

    // (a') 对称：min=null + max=4051B 单侧同样可表示
    const single_r = [_]f2.RangeTombstone{
        .{ .min = null, .max = plain(&kmax) },
    };
    try f2.encodeTombPage(&page, 5, &single_r, 9, 0);

    // (b) 打洞右段形状 [succ('q'×4051), "z")：succ 紧凑存储 = 原键长 4051，
    //     16 + 4051 + 1 = 4068 恰好装满 → 可表示（F1/F2 核心：右段恒可建）
    const big = [_]u8{'q'} ** cube.btree.MAX_KEY_SIZE;
    const right = [_]f2.RangeTombstone{
        .{ .min = succ(&big), .max = plain("z") },
    };
    try f2.encodeTombPage(&page, 6, &right, 9, 0);
    {
        const d = try f2.decodeTombPage(alloc, &page);
        defer alloc.free(d.tobs);
        try std.testing.expectEqualSlices(u8, &big, d.tobs[0].min.?.bytes);
        try std.testing.expect(d.tobs[0].min.?.append_zero); // succ 紧凑标志存活
        try std.testing.expectEqualSlices(u8, "z", d.tobs[0].max.?.bytes);
    }

    // (c) 双长边界 ['a'×3000, 'z'×3000]：16 + 6000 > 4068 →
    //     typed error.TombBoundTooLarge（不得是笼统 TombPageOverflow；
    //     生产方向 = 边界 spill 到 overflow 页，阶段 1 决策按 typed 拒绝）
    const lo = [_]u8{'a'} ** 3000;
    const hi = [_]u8{'z'} ** 3000;
    const both_long = [_]f2.RangeTombstone{
        .{ .min = plain(&lo), .max = plain(&hi) },
    };
    try std.testing.expectError(error.TombBoundTooLarge, f2.encodeTombPage(&page, 7, &both_long, 9, 0));

    // (d) 边界恰好装满：16 + 2026 + 2026 = 4068 → 可表示（不 off-by-one）
    const lo2 = [_]u8{'a'} ** 2026;
    const hi2 = [_]u8{'z'} ** 2026;
    const exact = [_]f2.RangeTombstone{
        .{ .min = plain(&lo2), .max = plain(&hi2) },
    };
    try f2.encodeTombPage(&page, 8, &exact, 9, 0);
    {
        const d = try f2.decodeTombPage(alloc, &page);
        defer alloc.free(d.tobs);
        try std.testing.expectEqualSlices(u8, &lo2, d.tobs[0].min.?.bytes);
        try std.testing.expectEqualSlices(u8, &hi2, d.tobs[0].max.?.bytes);
    }

    // (e) 恰好装满 +1B：16 + 2026 + 2027 = 4069 > 4068 → TombBoundTooLarge
    const lo3 = [_]u8{'a'} ** 2026;
    const hi3 = [_]u8{'z'} ** 2027;
    const one_over = [_]f2.RangeTombstone{
        .{ .min = plain(&lo3), .max = plain(&hi3) },
    };
    try std.testing.expectError(error.TombBoundTooLarge, f2.encodeTombPage(&page, 9, &one_over, 9, 0));
}

// =====================================================================
// 6. meta v2↔v3 编解码 + 三值判定（规格 §2 N2；蓝本：探针 4）
// =====================================================================

fn baseMeta() f2.MetaPage {
    return .{
        .magic = f2.MAGIC_V2,
        .version = 2,
        .mapsize = 1 << 30,
        .sequence = 42,
        .root_page = 100,
        .entry_count = 5000,
        .byte_size = 1_000_000,
        .free_head = 50,
        .free_count = 200,
        .last_page = 300,
        .tomb_head = 0,
    };
}

test "T-38-1: meta v2 round-trip — tomb_head=0, byte-identical v2 encoding" {
    var meta = baseMeta(); // version=2, tomb_head=0
    var page: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page, 0);
    f2.writeMetaPage(&page, &meta, 0);

    const got = f2.readMetaPageSingle(&page);
    try std.testing.expect(got != null);
    // v2 解码 → tomb_head = 0，行为与旧版一致
    try std.testing.expectEqual(@as(u32, 0), got.?.tomb_head);
    try std.testing.expectEqual(meta.sequence, got.?.sequence);
    try std.testing.expectEqual(meta.root_page, got.?.root_page);
    try std.testing.expectEqual(meta.free_head, got.?.free_head);
    try std.testing.expectEqual(meta.last_page, got.?.last_page);
    try std.testing.expectEqual(@as(u16, 2), got.?.version);

    // v2=58B：encodeMetaPayload 不动 tomb 区（payload[58..62] 恒 0）
    // —— 新代码写的 v2 页与旧二进制逐字节一致
    const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 4), payload[58..62]);
}

test "T-38-1: meta v3 round-trip — tomb_head persists, old code rejects cleanly" {
    var meta = baseMeta();
    meta.version = 3;
    meta.tomb_head = 777;
    var page: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&page, 0);
    f2.writeMetaPage(&page, &meta, 1);

    // v3 解码 → 读 tomb_head，基础字段与 v2 布局一致
    const got = f2.readMetaPageSingle(&page);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u16, 3), got.?.version);
    try std.testing.expectEqual(@as(u32, 777), got.?.tomb_head);
    try std.testing.expectEqual(meta.sequence, got.?.sequence);
    try std.testing.expectEqual(meta.root_page, got.?.root_page);
    try std.testing.expectEqual(meta.last_page, got.?.last_page);

    // 单向升级：v3 编码把 version=3 写进盘上字段——旧代码 isValidMeta
    // 硬判 version==2 失败 → 干净拒绝（现状保持，不会误读）
    const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    const ver = std.mem.readInt(u16, payload[4..6], .little);
    try std.testing.expectEqual(@as(u16, 3), ver);
    // tomb_head 落在 payload[58..62]（v2 基础布局尾部追加）
    const th = std.mem.readInt(u32, payload[58..62], .little);
    try std.testing.expectEqual(@as(u32, 777), th);
}

test "T-38-1: meta three-way — v4 / bad magic rejected, not conflated with v2" {
    var page: [f2.PAGE_SIZE]u8 = undefined;

    // version=4（未来版本）→ 明确拒绝（null = 打开失败），不得当 v2 打开
    var v4 = baseMeta();
    v4.version = 4;
    @memset(&page, 0);
    f2.writeMetaPage(&page, &v4, 0);
    try std.testing.expect(f2.readMetaPageSingle(&page) == null);

    // magic 不符 → 明确拒绝
    var bad_magic = baseMeta();
    bad_magic.magic = 0xDEAD_BEEF;
    @memset(&page, 0);
    f2.writeMetaPage(&page, &bad_magic, 0);
    try std.testing.expect(f2.readMetaPageSingle(&page) == null);

    // 对照：v2 / v3 均可打开（三值判定的另外两值）
    var v2 = baseMeta();
    @memset(&page, 0);
    f2.writeMetaPage(&page, &v2, 0);
    try std.testing.expect(f2.readMetaPageSingle(&page) != null);
    var v3 = baseMeta();
    v3.version = 3;
    v3.tomb_head = 55;
    @memset(&page, 0);
    f2.writeMetaPage(&page, &v3, 0);
    try std.testing.expect(f2.readMetaPageSingle(&page) != null);
}

test "T-38-1: meta mixed v2/v3 slots — higher sequence wins, no mixed state" {
    // (e) v2(seq=100) vs v3(seq=101, tomb_head=777) → 取 v3（拿到墓碑语义）
    var v2m = baseMeta();
    v2m.sequence = 100;
    var v3m = baseMeta();
    v3m.version = 3;
    v3m.sequence = 101;
    v3m.tomb_head = 777;
    var p_v2: [f2.PAGE_SIZE]u8 = undefined;
    var p_v3: [f2.PAGE_SIZE]u8 = undefined;
    @memset(&p_v2, 0);
    @memset(&p_v3, 0);
    f2.writeMetaPage(&p_v2, &v2m, 0);
    f2.writeMetaPage(&p_v3, &v3m, 1);
    {
        const got = try f2.readMetaPage(&p_v2, &p_v3);
        try std.testing.expect(got != null);
        try std.testing.expectEqual(@as(u64, 101), got.?.sequence);
        try std.testing.expectEqual(@as(u32, 777), got.?.tomb_head);
        try std.testing.expectEqual(@as(u16, 3), got.?.version);
    }

    // (f) torn-sync 反向：v3(seq=101) vs v2(seq=102)（旧代码最后一写更高 seq）
    //     → 取 v2，tomb_head=0（按无墓碑打开，不产生混合态）
    v2m.sequence = 102;
    @memset(&p_v2, 0);
    f2.writeMetaPage(&p_v2, &v2m, 0);
    {
        const got = try f2.readMetaPage(&p_v3, &p_v2);
        try std.testing.expect(got != null);
        try std.testing.expectEqual(@as(u64, 102), got.?.sequence);
        try std.testing.expectEqual(@as(u32, 0), got.?.tomb_head);
        try std.testing.expectEqual(@as(u16, 2), got.?.version);
    }
}

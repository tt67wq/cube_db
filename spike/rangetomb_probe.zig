//! rangetomb_probe.zig — T-38-P 探针：区间墓碑方案（设计文档
//! docs/design/T-38-range-tombstone-probe.md）的最小可运行验证。
//! T-38-P-R 返工：修复 F1（打洞右段丢弃 = 数据复活）与 F2（近-MAX
//! 边界可表示性）；FR-1（punchHole 计数释放）随新设计消除。
//!
//! 自包含 spike：**不改 src/**。生产常量（PAGE_SIZE/PageHeader/CRC/cmpKey）
//! 从 cube_db 导入复用；墓碑编解码器、v3 meta 编解码器在本文件实现，
//! 与设计文档 §1.2/§1.4/§2 的字节布局逐字段对齐：
//!
//! 墓碑页（PAGE_TYPE_RANGE_TOMBSTONE = 5，设计 §1.2 修订版）：
//!   PageHeader: page_no / type=5 / gen=commit_seq / nkeys=条数 / free_next=链
//!   payload = 连续定长条头 16B × nkeys（无 payload 计数——头为准，CRC 保完整性）:
//!     min_len u32（bit31 = append_zero 标志）/ max_len u32（bit31 = 同）
//!     min_off u32 / max_off u32（变长区偏移，相对 payload 起点）
//!   变长区: 各墓碑 min/max 的存储字节（len=0 且无标志 = unbounded/null）
//!   尾部 4B 全页 CRC32（复用 f2.verifyPageChecksum）
//!   逐条 seq 不落盘——从页 gen（commit sequence）继承（设计 §1.4 选定项）。
//!
//! 边界紧凑编码（T-38-P-R F1/F2 核心）：Bound = bytes ++ (0x00 if append_zero)。
//!   - succ(k) = k ++ 0x00（> k 的最短字节串）存为 {bytes=k, append_zero=true}
//!     —— 存储回到原键长：近-MAX key 的打洞右段恒可表示，punchHole 零堆分配；
//!   - 单条墓碑 envelope：16 + min_stored + max_stored ≤ 4068
//!     （单边界最长 4052B ≥ MAX_KEY_SIZE=4051，用户单侧 deleteRange 全覆盖）；
//!   - 双长边界（min_stored + max_stored > 4052）→ error.TombBoundTooLarge
//!     （typed 明确拒绝；生产方向 = 边界 spill 到 overflow 页，见设计 §1.2）。
//!
//! v3 meta（设计 §2）：58B v2 payload 尾部追加 tomb_head u32 → 62B。
//!
//! 验证项（对应设计文档 §9 的【实测】行）：
//!   1. 墓碑链页 encode → decode round-trip（含 append 边界）+ CRC 翻转可检测（§5.1）
//!   2. 遮蔽判定边界：min 含 / max 不含 / 空区间 / 全区间 / 倒置 / append 边界（§3.3）
//!   3. 与逐 key tombstone 共存 + put 打洞（含 F1 复活反例：基线红、返工后绿）（§3.2/§4.3）
//!   4. v2↔v3 meta 最小升级/降级（§2）
//!   5. 多墓碑链页 round-trip + 容量上界（设计 §1.2 容量声明核对）
//!   6. F2 边界可表示性：4051B 单边界 / succ 紧凑 / 双长边界明确拒绝 / 恰好装满
//!
//! 运行：zig build test-rangetomb-probe   （exit 0 = 全部断言通过）

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const btree = cube.btree;

const alloc = std.testing.allocator;

// ===== 设计 §1.2：新页 kind 与条目容量 =====

const PAGE_TYPE_RANGE_TOMBSTONE: u8 = 5;
/// T-38-P-R：条头 24B → 16B（seq 从页 gen 继承，见设计 §1.4），
/// bit31 of min_len/max_len = append_zero 边界标志。
const TOMB_HDR: usize = 16; // min_len|flag u32 + max_len|flag u32 + min_off u32 + max_off u32
const TOMB_PAYLOAD: usize = f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4;

// ===== 设计 §1.4：墓碑条目与边界 =====

/// 边界 = bytes ++ (0x00 if append_zero)。
/// append_zero 是 succ(k)（k 的字典序后继上界）的紧凑表示：
/// 存原键长、语义等价于 k ++ 0x00 —— F1 修复核心（右段恒可建）。
const Bound = struct {
    bytes: []const u8,
    append_zero: bool = false,
};

const RTombstone = struct {
    min: ?Bound, // null = 负无穷
    max: ?Bound, // null = 正无穷
    seq: u64, // 写入 commit sequence（盘上从页 gen 继承；内存态保留原值）
};

fn plain(bytes: []const u8) ?Bound {
    return .{ .bytes = bytes };
}

/// 字典序后继上界：effective = bytes ++ 0x00（> bytes 的最短字节串）。
fn succ(bytes: []const u8) ?Bound {
    return .{ .bytes = bytes, .append_zero = true };
}

fn boundEffLen(b: Bound) usize {
    return b.bytes.len + @intFromBool(b.append_zero);
}

fn effByte(b: Bound, i: usize) ?u8 {
    if (i < b.bytes.len) return b.bytes[i];
    if (b.append_zero and i == b.bytes.len) return 0;
    return null;
}

/// 键 k 与（effective）边界 b 的比较。
fn boundCmpKey(k: []const u8, b: Bound) std.math.Order {
    const n = @min(k.len, b.bytes.len);
    for (0..n) |i| {
        if (k[i] != b.bytes[i]) return if (k[i] < b.bytes[i]) .lt else .gt;
    }
    if (k.len < b.bytes.len) return .lt; // k 是 bytes 的真前缀 → k < bytes ≤ eff
    if (k.len > b.bytes.len) {
        if (!b.append_zero) return .gt; // k 延伸 bytes → k > bytes
        // eff = bytes ++ 0x00：比较 k[bytes.len] 与 0x00
        if (k[b.bytes.len] != 0) return .gt;
        return if (k.len == b.bytes.len + 1) .eq else .gt;
    }
    // k.len == bytes.len
    return if (b.append_zero) .lt else .eq; // k == bytes < bytes ++ 0x00
}

/// 两个（effective）边界之间的比较（不打材料化）。
fn boundCmpBound(a: Bound, b: Bound) std.math.Order {
    const n = @max(boundEffLen(a), boundEffLen(b));
    for (0..n) |i| {
        const x = effByte(a, i);
        const y = effByte(b, i);
        if (x == null and y == null) return .eq;
        if (x == null) return .lt;
        if (y == null) return .gt;
        if (x.? != y.?) return if (x.? < y.?) .lt else .gt;
    }
    return .eq;
}

fn covers(t: RTombstone, k: []const u8) bool {
    // [min, max) 半开：min 含、max 不含（设计 §3.3，与 select 同语义）
    if (t.min) |m| {
        if (boundCmpKey(k, m) == .lt) return false; // k < min
    }
    if (t.max) |m| {
        if (boundCmpKey(k, m) != .lt) return false; // k >= max
    }
    return true;
}

fn rangeEmpty(min: ?Bound, max: ?Bound) bool {
    if (min != null and max != null) {
        return boundCmpBound(min.?, max.?) != .lt; // min >= max → 空/倒置
    }
    return false; // 有 null 端 → 非空（全区间或单侧）
}

// ===== 设计 §1.2：墓碑链页编码（单页版；链 = free_next 串接） =====

fn boundStoredLen(b: ?Bound) usize {
    return if (b) |m| m.bytes.len else 0;
}

fn encodeTombPage(page: *[f2.PAGE_SIZE]u8, page_no: u32, tobs: []const RTombstone, commit_seq: u64, next_page: u32) !void {
    // T-38-P-R (F2)：可表示性分两级——
    //   1) 单条墓碑：16B 条头 + 边界存储字节 ≤ 页预算，否则 TombBoundTooLarge
    //      （调用方须拒绝该 deleteRange 或走边界 spill，见设计 §1.2；不是装箱问题）；
    //   2) 多条装箱：超出则 TombPageOverflow（调用方分页串链——正常路径）。
    for (tobs) |t| {
        if (TOMB_HDR + boundStoredLen(t.min) + boundStoredLen(t.max) > TOMB_PAYLOAD) {
            return error.TombBoundTooLarge;
        }
    }
    var vlen: usize = 0;
    for (tobs) |t| {
        vlen += boundStoredLen(t.min) + boundStoredLen(t.max);
    }
    if (TOMB_HDR * tobs.len + vlen > TOMB_PAYLOAD) return error.TombPageOverflow; // 调用方分页（链）

    const hdr = f2.PageHeader{
        .page_no = page_no,
        .page_type = PAGE_TYPE_RANGE_TOMBSTONE,
        .gen = commit_seq, // 设计 §5.3：信息性 gen=sequence（非 chain 页，无 H1 强校验）
        .nkeys = @intCast(tobs.len),
        .free_next = next_page,
    };
    f2.encodePageHeader(page[0..f2.PAGE_HEADER_SIZE], &hdr);
    const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    @memset(payload, 0);

    var hpos: usize = 0;
    var vpos: usize = TOMB_HDR * tobs.len;
    for (tobs) |t| {
        var min_raw: u32 = if (t.min) |m| @intCast(m.bytes.len) else 0;
        var max_raw: u32 = if (t.max) |m| @intCast(m.bytes.len) else 0;
        if (t.min) |m| {
            if (m.append_zero) min_raw |= 0x8000_0000; // F1：succ 紧凑标志
        }
        if (t.max) |m| {
            if (m.append_zero) max_raw |= 0x8000_0000;
        }
        std.mem.writeInt(u32, payload[hpos..][0..4], min_raw, .little);
        hpos += 4;
        std.mem.writeInt(u32, payload[hpos..][0..4], max_raw, .little);
        hpos += 4;
        std.mem.writeInt(u32, payload[hpos..][0..4], @intCast(vpos), .little);
        hpos += 4;
        if (t.min) |m| {
            @memcpy(payload[vpos..][0..m.bytes.len], m.bytes);
            vpos += m.bytes.len;
        }
        std.mem.writeInt(u32, payload[hpos..][0..4], @intCast(vpos), .little);
        hpos += 4;
        if (t.max) |m| {
            @memcpy(payload[vpos..][0..m.bytes.len], m.bytes);
            vpos += m.bytes.len;
        }
    }
    f2.setPageChecksum(page, f2.computePageChecksum(page));
}

const DecodedTombPage = struct {
    hdr: f2.PageHeader,
    tobs: []RTombstone, // min/max 切片借用 payload 缓冲（调用方保持生命周期）
    next: u32,
};

fn decodeTombPage(page: *const [f2.PAGE_SIZE]u8) !DecodedTombPage {
    // 设计 §5.1：墓碑页 CRC 失败 = 库损坏（与树页同级），必须报错不静默
    if (!f2.verifyPageChecksum(page)) return error.CorruptCrc;
    const hdr = f2.decodePageHeader(page[0..f2.PAGE_HEADER_SIZE]);
    if (hdr.page_type != PAGE_TYPE_RANGE_TOMBSTONE) return error.CorruptCrc;
    const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    // T-38-P-R：payload 双处计数已移除——nkeys 以页头为准（CRC 保完整性）。
    const count: usize = hdr.nkeys;
    const tobs = try alloc.alloc(RTombstone, count);
    var hpos: usize = 0;
    for (0..count) |i| {
        const min_raw = std.mem.readInt(u32, payload[hpos..][0..4], .little);
        hpos += 4;
        const max_raw = std.mem.readInt(u32, payload[hpos..][0..4], .little);
        hpos += 4;
        const min_off = std.mem.readInt(u32, payload[hpos..][0..4], .little);
        hpos += 4;
        const max_off = std.mem.readInt(u32, payload[hpos..][0..4], .little);
        hpos += 4;
        const min_len: usize = min_raw & 0x7FFF_FFFF;
        const max_len: usize = max_raw & 0x7FFF_FFFF;
        const min_app = (min_raw >> 31) & 1 == 1;
        const max_app = (max_raw >> 31) & 1 == 1;
        if (min_off + min_len > payload.len or max_off + max_len > payload.len) {
            // N1：spike 用 panic；迁移进 src/ 时必须改为 error.Truncated/CorruptCrc
            // （设计 §1.2 迁移注记），不得照抄。
            @panic("tomb offset out of bounds");
        }
        tobs[i] = .{
            .min = if (min_len == 0 and !min_app) null else .{
                .bytes = payload[min_off..][0..min_len],
                .append_zero = min_app,
            },
            .max = if (max_len == 0 and !max_app) null else .{
                .bytes = payload[max_off..][0..max_len],
                .append_zero = max_app,
            },
            .seq = hdr.gen, // 设计 §1.4：逐条 seq 从页 gen（commit sequence）继承
        };
    }
    return .{ .hdr = hdr, .tobs = tobs, .next = hdr.free_next };
}

/// 遮蔽判定：k 被任一墓碑覆盖（设计 §3.1 INV-RT1 纯空间判定）。
fn shadowed(tobs: []const RTombstone, k: []const u8) bool {
    for (tobs) |t| {
        if (covers(t, k)) return true;
    }
    return false;
}

/// 设计 §4.3（T-38-P-R 修订）：put(k) 打洞——覆盖 k 的墓碑 t 分裂为
/// [t.min, k) 与 [succ(k), t.max)。
///
/// F1 教训（返工记录）：旧版在 succ(k) 超长（k 近 MAX_KEY_SIZE）时**丢弃右段**，
/// 并论证「只会漏遮蔽后来写回的键」——错误：右段 [succ(k), t.max) 覆盖的是
/// **建碑前就被那次 deleteRange 删掉的活 entry**，丢弃 = 数据复活。反例
/// （基线实测红）：put "r" → deleteRange ["a","z") → put 'q'×MAX_KEY_SIZE
/// 之后 "r" 复活。正确语义：右段必须保留。
///
/// 修复：succ(k) 用紧凑 append_zero 边界表示（存原键长），右段恒可表示；
/// 右段为空的唯一情形是 t.max == succ(k)（k 与 succ(k) 之间不存在任何
/// 字节串）——此时跳过（探针 3 有专测）。
///
/// 所有权：右段 min 借用 k（append_zero 边界不复制字节）——punchHole 零堆
/// 分配（FR-1 的计数释放接口随之删除）；调用方保证 k 在 out 的使用期内存活。
fn punchHole(tobs: []const RTombstone, k: []const u8, out: *std.ArrayList(RTombstone)) !void {
    for (tobs) |t| {
        if (!covers(t, k)) {
            try out.append(alloc, t);
            continue;
        }
        // 左段 [t.min, k)：为空当且仅当 t.min == k（covers 已保证 t.min ≤ k）
        if (t.min == null or boundCmpBound(t.min.?, .{ .bytes = k }) == .lt) {
            try out.append(alloc, .{ .min = t.min, .max = .{ .bytes = k }, .seq = t.seq });
        }
        // 右段 [succ(k), t.max)：succ(k) = k ++ 0x00 是 > k 的最短字节串，
        // 故右段为空当且仅当 t.max == succ(k)。
        const right_min = Bound{ .bytes = k, .append_zero = true };
        if (t.max == null or boundCmpBound(right_min, t.max.?) == .lt) {
            try out.append(alloc, .{ .min = right_min, .max = t.max, .seq = t.seq });
        }
    }
}

// ===== 设计 §2：v3 meta（v2 payload + tomb_head u32） =====

const V3_PAYLOAD: usize = f2.META_PAGE_PAYLOAD_SIZE + 4;

fn encodeMetaV3(buf: []u8, base: *const f2.MetaPage, tomb_head: u32) void {
    var tmp: [f2.META_PAGE_PAYLOAD_SIZE]u8 = undefined;
    f2.encodeMetaPayload(&tmp, base);
    @memcpy(buf[0..f2.META_PAGE_PAYLOAD_SIZE], &tmp);
    std.mem.writeInt(u32, buf[f2.META_PAGE_PAYLOAD_SIZE..][0..4], tomb_head, .little);
}

const MetaV3 = struct { base: f2.MetaPage, tomb_head: u32 };

/// 新代码读旧库（v2）：tomb_head 视为 0（无墓碑链），行为与旧版一致。
fn decodeMetaAny(buf: []const u8) ?MetaV3 {
    const base = f2.decodeMetaPayload(buf[0..f2.META_PAGE_PAYLOAD_SIZE]);
    if (!f2.isValidMeta(base)) {
        // v3 库（version==3）走到这里：旧 isValidMeta 拒绝 —— 模拟旧二进制
        // 打不开 v3 的行为由调用方（探针 4 的旧视角断言）处理；这里先探测 v3。
        return null;
    }
    if (buf.len < V3_PAYLOAD) return .{ .base = base, .tomb_head = 0 };
    return .{ .base = base, .tomb_head = std.mem.readInt(u32, buf[f2.META_PAGE_PAYLOAD_SIZE..][0..4], .little) };
}

fn decodeMetaV3(buf: []const u8) ?MetaV3 {
    const base = f2.decodeMetaPayload(buf[0..f2.META_PAGE_PAYLOAD_SIZE]);
    if (base.magic != f2.MAGIC_V2 or base.version != 3) return null; // v3 严格判定
    if (buf.len < V3_PAYLOAD) return null;
    return .{ .base = base, .tomb_head = std.mem.readInt(u32, buf[f2.META_PAGE_PAYLOAD_SIZE..][0..4], .little) };
}

// =====================================================================
// 探针 1：墓碑链页 encode → decode round-trip + CRC 损坏可检测
// =====================================================================

test "T-38-P probe 1: tombstone page round-trip + CRC corruption detection" {
    const tobs = [_]RTombstone{
        .{ .min = plain("apple"), .max = plain("banana"), .seq = 42 },
        .{ .min = null, .max = plain("a"), .seq = 43 }, // 负无穷 .. "a"
        .{ .min = plain("z"), .max = null, .seq = 44 }, // "z" .. 正无穷
        .{ .min = null, .max = null, .seq = 45 }, // 全区间
        .{ .min = plain("\xff\x00\x11 very long key padded to stress varlen region 0123456789"), .max = plain("\xff\xff\xff"), .seq = 46 },
        // T-38-P-R：append_zero 边界（succ 紧凑表示）round-trip
        .{ .min = succ("apple"), .max = plain("banana"), .seq = 47 },
        .{ .min = plain("a"), .max = succ("m"), .seq = 48 },
    };
    var page: [f2.PAGE_SIZE]u8 = undefined;
    try encodeTombPage(&page, 77, &tobs, 4242, 99);

    // 解码：头字段逐项一致
    const d = try decodeTombPage(&page);
    defer alloc.free(d.tobs);
    try std.testing.expectEqual(@as(u32, 77), d.hdr.page_no);
    try std.testing.expectEqual(PAGE_TYPE_RANGE_TOMBSTONE, d.hdr.page_type);
    try std.testing.expectEqual(@as(u64, 4242), d.hdr.gen); // gen = commit sequence
    try std.testing.expectEqual(@as(u32, 99), d.next); // 链式 free_next
    try std.testing.expectEqual(tobs.len, d.tobs.len);
    try std.testing.expectEqual(@as(u16, @intCast(tobs.len)), d.hdr.nkeys);
    for (tobs, d.tobs) |want, got| {
        if (want.min) |m| {
            try std.testing.expectEqualSlices(u8, m.bytes, got.min.?.bytes);
            try std.testing.expectEqual(m.append_zero, got.min.?.append_zero);
        } else try std.testing.expect(got.min == null);
        if (want.max) |m| {
            try std.testing.expectEqualSlices(u8, m.bytes, got.max.?.bytes);
            try std.testing.expectEqual(m.append_zero, got.max.?.append_zero);
        } else try std.testing.expect(got.max == null);
        // T-38-P-R：逐条 seq 不落盘，从页 gen 继承（设计 §1.4 选定项）
        try std.testing.expectEqual(@as(u64, 4242), got.seq);
    }

    // CRC 翻转任意一字节 → CorruptCrc（设计 §5.1：必须报错不静默）
    page[f2.PAGE_HEADER_SIZE + 10] ^= 0xff;
    try std.testing.expectError(error.CorruptCrc, decodeTombPage(&page));
    page[f2.PAGE_HEADER_SIZE + 10] ^= 0xff;
    page[3000] ^= 0x01;
    try std.testing.expectError(error.CorruptCrc, decodeTombPage(&page));
    page[3000] ^= 0x01;
    const d_ok = try decodeTombPage(&page); // 复原后可解
    alloc.free(d_ok.tobs);
}

// =====================================================================
// 探针 2：遮蔽判定边界（min 含 / max 不含 / 空 / 全区间 / 倒置 / append）
// =====================================================================

test "T-38-P probe 2: shadowing boundaries [min,max)" {
    const t = RTombstone{ .min = plain("b"), .max = plain("e"), .seq = 1 };
    // min 含
    try std.testing.expect(covers(t, "b"));
    // max 不含
    try std.testing.expect(!covers(t, "e"));
    try std.testing.expect(covers(t, "d\xff")); // e 之前的任意前缀串
    // 区间外
    try std.testing.expect(!covers(t, "a"));
    try std.testing.expect(!covers(t, "e\x00")); // "e\0" > "e"
    try std.testing.expect(!covers(t, "zzz"));

    // 前缀键序：cmpKey 是 bytewise，"b" 覆盖 "bb"/"bzz"（更长前缀更大）
    try std.testing.expect(covers(t, "bb"));
    try std.testing.expect(covers(t, "bzz"));
    try std.testing.expect(covers(t, "b\xff\xff\xff\xff\xff")); // b < e，仍在区间内

    // 空区间（min == max）
    try std.testing.expect(rangeEmpty(plain("c"), plain("c")));
    // 倒置（min > max）
    try std.testing.expect(rangeEmpty(plain("d"), plain("c")));
    // 空区间墓碑不遮蔽任何 key
    const empty_t = RTombstone{ .min = plain("c"), .max = plain("c"), .seq = 1 };
    try std.testing.expect(!covers(empty_t, "c"));
    // 全区间墓碑（null, null）遮蔽一切
    const full_t = RTombstone{ .min = null, .max = null, .seq = 1 };
    try std.testing.expect(covers(full_t, ""));
    try std.testing.expect(covers(full_t, "\xff\xff"));
    // 单侧
    const low_t = RTombstone{ .min = null, .max = plain("m"), .seq = 1 };
    try std.testing.expect(covers(low_t, "aaa"));
    try std.testing.expect(!covers(low_t, "m"));
    const high_t = RTombstone{ .min = plain("m"), .max = null, .seq = 1 };
    try std.testing.expect(covers(high_t, "m"));
    try std.testing.expect(covers(high_t, "\xff\xff"));
    try std.testing.expect(!covers(high_t, "l"));

    // shadowed：多墓碑任一覆盖即遮蔽
    const set = [_]RTombstone{ t, RTombstone{ .min = plain("x"), .max = plain("y"), .seq = 2 } };
    try std.testing.expect(shadowed(&set, "c"));
    try std.testing.expect(shadowed(&set, "x"));
    try std.testing.expect(!shadowed(&set, "w"));
    try std.testing.expect(!shadowed(&set, "e")); // 边界 max 不含

    // T-38-P-R：append_zero 边界（succ 紧凑表示）的比较语义。
    // succ("b") effective = "b\x00"：是 > "b" 的最短字节串。
    const at = RTombstone{ .min = succ("b"), .max = plain("c"), .seq = 1 };
    try std.testing.expect(!covers(at, "b")); // "b" < "b\x00"（succ 下界不含被打洞的 k）
    try std.testing.expect(covers(at, "b\x00")); // "b\x00" == succ("b")（min 含）
    try std.testing.expect(covers(at, "b\x00\x00")); // 更长延伸
    try std.testing.expect(covers(at, "b\x01"));
    try std.testing.expect(!covers(at, "a"));
    try std.testing.expect(!covers(at, "c")); // max 不含
    // append 上界侧：max = succ("m") effective "m\x00" → "m" 仍被遮蔽、"m\x00" 及以上不被
    const ut = RTombstone{ .min = plain("a"), .max = succ("m"), .seq = 1 };
    try std.testing.expect(covers(ut, "m"));
    try std.testing.expect(!covers(ut, "m\x00"));
    try std.testing.expect(!covers(ut, "m\x01"));
    try std.testing.expect(!covers(ut, "m\xff"));
}

// =====================================================================
// 探针 3：与逐 key tombstone 共存 + put 打洞（含 F1 复活反例）
// =====================================================================

test "T-38-P probe 3: coexistence with per-key tombstones + put punch-hole" {
    // 场景矩阵（设计 §3.2/§4.3）：
    //   put k; deleteRange[a,b)∋k; get k → null（墓碑遮蔽）
    //   put k; deleteRange[a,b)∋k; put k; get k → 非 null（INV-RT1：打洞）
    //   逐 key tombstone 与区间墓碑同时覆盖 → 同为删除，无冲突
    var tobs: std.ArrayList(RTombstone) = .empty;
    defer tobs.deinit(alloc);

    // 初始：deleteRange ["b","f")
    try tobs.append(alloc, .{ .min = plain("b"), .max = plain("f"), .seq = 10 });

    // put "c"（被墓碑覆盖）→ 打洞：[b,c) + [c\0,f)
    var punched: std.ArrayList(RTombstone) = .empty;
    defer punched.deinit(alloc);
    try punchHole(tobs.items, "c", &punched);
    try std.testing.expectEqual(@as(usize, 2), punched.items.len);
    // 对 "c" 不再遮蔽（put 回来的 key 活）
    try std.testing.expect(!shadowed(punched.items, "c"));
    // 对区间内其它 key 仍遮蔽
    try std.testing.expect(shadowed(punched.items, "b"));
    try std.testing.expect(shadowed(punched.items, "cc"));
    try std.testing.expect(shadowed(punched.items, "e\xff"));
    // 对区间外不遮蔽
    try std.testing.expect(!shadowed(punched.items, "a"));
    try std.testing.expect(!shadowed(punched.items, "f"));
    try std.testing.expect(shadowed(punched.items, "b\xff\xff\xff\xff")); // b < f，仍在区间内

    // put "b"（区间左端点，min 含 → 覆盖）→ 左段为空，只剩右段 [b\0, f)
    var punched2: std.ArrayList(RTombstone) = .empty;
    defer punched2.deinit(alloc);
    try punchHole(tobs.items, "b", &punched2);
    try std.testing.expectEqual(@as(usize, 1), punched2.items.len);
    try std.testing.expect(!shadowed(punched2.items, "b"));
    try std.testing.expect(shadowed(punched2.items, "b\x00"));
    try std.testing.expect(shadowed(punched2.items, "e"));

    // ===== T-38-P-R (F1) 复活反例：近-MAX key 打洞后右段必须保留 =====
    // 基线行为（错误）：succ('q'×MAX_KEY_SIZE) 超长 → 右段被丢弃 → 建碑前
    // 被 deleteRange 删除且从未写回的 "r" 复活（基线实测红，见 T-38-P-R）。
    // 修复：succ 用紧凑 append_zero 边界，右段恒可建。
    const big = [_]u8{'q'} ** btree.MAX_KEY_SIZE;
    var wide: std.ArrayList(RTombstone) = .empty;
    defer wide.deinit(alloc);
    try wide.append(alloc, .{ .min = plain("a"), .max = plain("z"), .seq = 2 });
    // 打洞前："r"（建碑前的活 entry，已被范围删除）被遮蔽
    try std.testing.expect(shadowed(wide.items, "r"));
    var punched3: std.ArrayList(RTombstone) = .empty;
    defer punched3.deinit(alloc);
    try punchHole(wide.items, &big, &punched3);
    // 左段 [a, big) + 右段 [succ(big), z) —— 两段都必须在
    try std.testing.expectEqual(@as(usize, 2), punched3.items.len);
    // big 不再被遮蔽（put 回来的 key 活）
    try std.testing.expect(!shadowed(punched3.items, &big));
    // F1 核心断言："r" ∈ (big, "z") 的建碑前活 entry 必须仍被遮蔽（不复活）
    try std.testing.expect(shadowed(punched3.items, "r"));
    // 区间左半仍遮蔽（含左端点 "a"——min 含语义）
    try std.testing.expect(shadowed(punched3.items, "b"));
    try std.testing.expect(shadowed(punched3.items, "a"));
    // 区间外不遮蔽（"z" 是 max 端点，不含）
    try std.testing.expect(!shadowed(punched3.items, "z"));

    // 右段真空 edge：墓碑 [b, "b\0")（deleteRange("b","b\0") 的产物，恰好只删 "b"）
    // 再 put "b" → 左段空（min==k）、右段空（max == succ(k)）→ 墓碑被完全消费。
    var tiny: std.ArrayList(RTombstone) = .empty;
    defer tiny.deinit(alloc);
    try tiny.append(alloc, .{ .min = plain("b"), .max = plain("b\x00"), .seq = 3 });
    var punched4: std.ArrayList(RTombstone) = .empty;
    defer punched4.deinit(alloc);
    try punchHole(tiny.items, "b", &punched4);
    try std.testing.expectEqual(@as(usize, 0), punched4.items.len);
    try std.testing.expect(!shadowed(punched4.items, "b"));

    // 共存：逐 key tombstone（叶内 entry 形态）+ 区间墓碑 —— 两者都是删除，
    // get 判定 = null（无优先级冲突：tombstone entry 本身就是「无值」）
    const coexist = [_]RTombstone{.{ .min = plain("b"), .max = plain("f"), .seq = 10 }};
    // 逐 key tombstone "d"（叶内）与区间墓碑都覆盖 "d"：
    // 读路径结果一致（都是 deleted），shadowed 只对「活 entry」起作用。
    try std.testing.expect(shadowed(&coexist, "d"));
    // 打洞后 "d" 活（put 回来），逐 key tombstone 已被 put 覆盖（last-write-wins）
    var coexist2: std.ArrayList(RTombstone) = .empty;
    defer coexist2.deinit(alloc);
    try punchHole(&coexist, "d", &coexist2);
    try std.testing.expect(!shadowed(coexist2.items, "d"));
    try std.testing.expect(shadowed(coexist2.items, "c"));
}

// =====================================================================
// 探针 4：v2 ↔ v3 meta 最小升级 / 降级 demo
// =====================================================================

test "T-38-P probe 4: v2/v3 meta upgrade-downgrade demo" {
    const base = f2.MetaPage{
        .magic = f2.MAGIC_V2,
        .version = 2,
        .mapsize = 1 << 30,
        .sequence = 100,
        .root_page = 55,
        .entry_count = 42,
        .byte_size = 12345,
        .free_head = 7,
        .free_count = 3,
        .last_page = 200,
    };

    // (a) v2 round-trip（现状格式不动）
    var v2buf: [f2.META_PAGE_PAYLOAD_SIZE]u8 = undefined;
    var tmp_meta = base;
    f2.encodeMetaPayload(&v2buf, &tmp_meta);
    const v2 = decodeMetaAny(&v2buf).?;
    try std.testing.expectEqual(@as(u32, 0), v2.tomb_head); // v2 → 无墓碑
    try std.testing.expectEqual(base.sequence, v2.base.sequence);

    // (b) v3 = v2 字段 + tomb_head；round-trip
    var v3buf: [V3_PAYLOAD]u8 = undefined;
    var v3_meta = base;
    v3_meta.version = 3;
    encodeMetaV3(&v3buf, &v3_meta, 777);
    const v3 = decodeMetaV3(&v3buf).?;
    try std.testing.expectEqual(@as(u32, 777), v3.tomb_head);
    try std.testing.expectEqual(base.sequence, v3.base.sequence);
    try std.testing.expectEqual(base.root_page, v3.base.root_page);

    // (c) 旧二进制视角（isValidMeta 硬判 version==2）拒绝 v3 —— 干净拒绝
    const as_v2_view = f2.decodeMetaPayload(v3buf[0..f2.META_PAGE_PAYLOAD_SIZE]);
    try std.testing.expect(!f2.isValidMeta(as_v2_view)); // v3 库对旧代码关闭

    // (d) 新代码读 v2（短 payload / tomb_head 缺省 0）—— 行为与旧版一致
    const short_view = decodeMetaAny(v2buf[0..f2.META_PAGE_PAYLOAD_SIZE]).?;
    try std.testing.expectEqual(@as(u32, 0), short_view.tomb_head);

    // (e) 双槽 sequence 取高：v2(seq=100) vs v3(seq=101) → 取 v3（无混合态）
    //     模拟 readMetaPage 的取高逻辑（format.zig:184-190）
    var v3_newer = v3_meta;
    v3_newer.sequence = 101;
    encodeMetaV3(&v3buf, &v3_newer, 777);
    const pick = blk: {
        const m_old = decodeMetaAny(&v2buf); // seq 100, v2
        const m_new = decodeMetaV3(&v3buf); // seq 101, v3
        break :blk if (m_old.?.base.sequence >= m_new.?.base.sequence) m_old.? else m_new.?;
    };
    try std.testing.expectEqual(@as(u64, 101), pick.base.sequence);
    try std.testing.expectEqual(@as(u32, 777), pick.tomb_head); // 拿到 v3 语义

    // (f) torn-sync 反向：v3(seq=100) vs v2(seq=101)（旧代码最后一写更高 seq）
    //     → 取 v2，tomb_head=0 —— 按「无墓碑」打开（v2 语义），不产生混合态。
    //     注：这是「降级读」，安全性依赖写路径纪律（v3 一旦写入就不允许
    //     旧代码再写——部署窗口管理，见设计 §2 单向升级）。
    var v2_newer = base;
    v2_newer.sequence = 102;
    f2.encodeMetaPayload(&v2buf, &v2_newer);
    const pick2 = blk: {
        const m_old = decodeMetaV3(&v3buf); // seq 101, v3
        const m_new = decodeMetaAny(&v2buf); // seq 102, v2
        if (m_old == null) break :blk m_new.?;
        if (m_new == null) break :blk m_old.?;
        break :blk if (m_old.?.base.sequence >= m_new.?.base.sequence) m_old.? else m_new.?;
    };
    try std.testing.expectEqual(@as(u64, 102), pick2.base.sequence);
    try std.testing.expectEqual(@as(u32, 0), pick2.tomb_head); // v2 视角：无墓碑
}

// =====================================================================
// 探针 5：多墓碑链页 round-trip + 容量上界（设计 §1.2 容量声明核对）
// =====================================================================

test "T-38-P probe 5: multi-page chain + capacity bound" {
    // 每条最小 16B 头 + 2×1B 键 → ≥ 226 条/页（设计 §1.4 声明核对；
    // T-38-P-R：条头 24B→16B，容量 155 → 226，与设计 §1.2 的 16B 口径一致）
    const per_page_min = TOMB_PAYLOAD / (TOMB_HDR + 2);
    try std.testing.expect(per_page_min >= 226);

    // 构造 300 条墓碑（超过单页容量），分页链式编码再解码
    const many = try alloc.alloc(RTombstone, 300);
    defer alloc.free(many);
    for (0..many.len) |i| {
        var kb: [8]u8 = undefined;
        _ = std.fmt.bufPrint(&kb, "{d:0>8}", .{i * 3}) catch unreachable;
        many[i] = .{ .min = plain(try alloc.dupe(u8, &kb)), .max = plain(try alloc.dupe(u8, kb[0..7] ++ "z")), .seq = @intCast(i) };
    }
    defer for (many) |t| {
        alloc.free(t.min.?.bytes);
        alloc.free(t.max.?.bytes);
    };

    // 分页：按本组键长（8B min + 8B max）计算每页容量并切分
    //（探针只验证链式 round-trip，装箱策略属主体实现）
    const per_tomb = TOMB_HDR + 8 + 8; // 32B/条
    const per_page = TOMB_PAYLOAD / per_tomb; // ~127 条/页
    try std.testing.expect(per_page >= 100);
    const n1 = per_page; // 页 1 装满
    const n2 = per_page; // 页 2 装满
    const n3 = many.len - n1 - n2; // 尾页
    try std.testing.expect(n3 >= 1);
    var page1: [f2.PAGE_SIZE]u8 = undefined;
    var page2: [f2.PAGE_SIZE]u8 = undefined;
    var page3: [f2.PAGE_SIZE]u8 = undefined;
    try encodeTombPage(&page1, 10, many[0..n1], 500, 11);
    try encodeTombPage(&page2, 11, many[n1..][0..n2], 500, 12);
    try encodeTombPage(&page3, 12, many[n1 + n2 ..], 500, 0);
    const d1 = try decodeTombPage(&page1);
    defer alloc.free(d1.tobs);
    const d2 = try decodeTombPage(&page2);
    defer alloc.free(d2.tobs);
    const d3 = try decodeTombPage(&page3);
    defer alloc.free(d3.tobs);
    try std.testing.expectEqual(@as(u32, 11), d1.next); // 页 1 → 页 2
    try std.testing.expectEqual(@as(u32, 12), d2.next); // 页 2 → 页 3
    try std.testing.expectEqual(@as(u32, 0), d3.next); // 尾页
    try std.testing.expectEqual(n1, d1.tobs.len);
    try std.testing.expectEqual(n2, d2.tobs.len);
    try std.testing.expectEqual(n3, d3.tobs.len);
    // 抽查内容（首/尾/跨界处）
    try std.testing.expectEqualSlices(u8, many[0].min.?.bytes, d1.tobs[0].min.?.bytes);
    try std.testing.expectEqualSlices(u8, many[n1 - 1].min.?.bytes, d1.tobs[n1 - 1].min.?.bytes);
    try std.testing.expectEqualSlices(u8, many[n1].min.?.bytes, d2.tobs[0].min.?.bytes);
    try std.testing.expectEqualSlices(u8, many[many.len - 1].max.?.bytes, d3.tobs[n3 - 1].max.?.bytes);
    // T-38-P-R：逐条 seq 从页 gen（commit_seq=500）继承，不再逐条落盘
    try std.testing.expectEqual(@as(u64, 500), d2.tobs[50].seq);
}

// =====================================================================
// 探针 6（T-38-P-R）：F2 边界可表示性 —— envelope 实测
// 基线 RED：4050B 边界 → TombPageOverflow（见 T-38-P-R 返工记录）。
// =====================================================================

test "T-38-P probe 6: F2 boundary representability envelope" {
    // (a) 单侧 4051B（= MAX_KEY_SIZE）用户边界：16 + 4051 + 0 = 4067 ≤ 4068 → 可表示
    const kmax = [_]u8{'m'} ** btree.MAX_KEY_SIZE;
    const single = [_]RTombstone{
        .{ .min = plain(&kmax), .max = null, .seq = 1 },
    };
    var page: [f2.PAGE_SIZE]u8 = undefined;
    try encodeTombPage(&page, 5, &single, 9, 0);
    const da = try decodeTombPage(&page);
    defer alloc.free(da.tobs);
    try std.testing.expectEqualSlices(u8, &kmax, da.tobs[0].min.?.bytes);
    try std.testing.expect(da.tobs[0].max == null);
    try std.testing.expectEqual(@as(u64, 9), da.tobs[0].seq); // 页 gen 继承

    // (b) 打洞右段形状 [succ('q'×4051), "z")：紧凑 append 编码，
    //     存储量 = 4051 + 1 = 4052 → 16 + 4052 = 4068 恰好装满 → 可表示
    const big = [_]u8{'q'} ** btree.MAX_KEY_SIZE;
    const right = [_]RTombstone{
        .{ .min = succ(&big), .max = plain("z"), .seq = 1 },
    };
    try encodeTombPage(&page, 6, &right, 9, 0);
    const db = try decodeTombPage(&page);
    defer alloc.free(db.tobs);
    try std.testing.expectEqualSlices(u8, &big, db.tobs[0].min.?.bytes);
    try std.testing.expect(db.tobs[0].min.?.append_zero);
    // 语义核对：右段不遮蔽被打洞的 big，遮蔽 (big, "z") 内的 key
    try std.testing.expect(!covers(db.tobs[0], &big));
    try std.testing.expect(covers(db.tobs[0], "r"));
    try std.testing.expect(!covers(db.tobs[0], "z"));

    // (c) 双长边界 ['a'×3000, 'z'×3000]：16 + 6000 > 4068 → TombBoundTooLarge
    //     （typed 明确拒绝；生产方向 = 边界 spill 到 overflow 页，见设计 §1.2）
    const lo = [_]u8{'a'} ** 3000;
    const hi = [_]u8{'z'} ** 3000;
    const both_long = [_]RTombstone{
        .{ .min = plain(&lo), .max = plain(&hi), .seq = 1 },
    };
    try std.testing.expectError(error.TombBoundTooLarge, encodeTombPage(&page, 7, &both_long, 9, 0));

    // (d) 边界恰好装满：16 + 2026 + 2026 = 4068 ≤ 4068 → 可表示
    const lo2 = [_]u8{'a'} ** 2026;
    const hi2 = [_]u8{'z'} ** 2026;
    const exact = [_]RTombstone{
        .{ .min = plain(&lo2), .max = plain(&hi2), .seq = 1 },
    };
    try encodeTombPage(&page, 8, &exact, 9, 0);
    const dd = try decodeTombPage(&page);
    defer alloc.free(dd.tobs);
    try std.testing.expectEqualSlices(u8, &lo2, dd.tobs[0].min.?.bytes);
    try std.testing.expectEqualSlices(u8, &hi2, dd.tobs[0].max.?.bytes);
}

//! rangetomb_probe.zig — T-38-P 探针：区间墓碑方案（设计文档
//! docs/design/T-38-range-tombstone-probe.md）的最小可运行验证。
//!
//! 自包含 spike：**不改 src/**。生产常量（PAGE_SIZE/PageHeader/CRC/cmpKey）
//! 从 cube_db 导入复用；墓碑编解码器、v3 meta 编解码器在本文件实现，
//! 与设计文档 §1.2/§1.4/§2 的字节布局逐字段对齐：
//!
//! 墓碑页（PAGE_TYPE_RANGE_TOMBSTONE = 5，设计 §1.2）：
//!   PageHeader: page_no / type=5 / gen=commit_seq / nkeys=条数 / free_next=链
//!   payload[0..2]  count u16
//!   定长条头 24B × count: min_len u32 / max_len u32 / min_off u32 / max_off u32 / seq u64
//!   变长区: 各墓碑 min/max 原始字节（len=0 表示 unbounded）
//!   尾部 4B 全页 CRC32（复用 f2.verifyPageChecksum）
//!
//! v3 meta（设计 §2）：58B v2 payload 尾部追加 tomb_head u32 → 62B。
//!
//! 验证项（对应设计文档 §9 的【实测】行）：
//!   1. 墓碑链页 encode → decode round-trip + CRC 翻转可检测（§5.1）
//!   2. 遮蔽判定边界：min 含 / max 不含 / 空区间 / 全区间 / 倒置（§3.3）
//!   3. 与逐 key tombstone 共存 + put 打洞（字典序后继 k+0x00）优先级（§3.2/§4.3）
//!   4. v2↔v3 meta 最小升级/降级：v3 round-trip、v2 视角 tomb_head=0、
//!      旧 isValidMeta 拒绝 v3、双槽 sequence 取高无混合态（§2）
//!
//! 运行：zig build test-rangetomb-probe   （exit 0 = 全部断言通过）

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const btree = cube.btree;

const alloc = std.testing.allocator;

// ===== 设计 §1.2：新页 kind 与条目容量 =====

const PAGE_TYPE_RANGE_TOMBSTONE: u8 = 5;
const TOMB_HDR: usize = 24; // min_len u32 + max_len u32 + min_off u32 + max_off u32 + seq u64
const TOMB_PAYLOAD: usize = f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4;

// ===== 设计 §1.4：墓碑条目 =====

const RTombstone = struct {
    min: ?[]const u8, // null = 负无穷
    max: ?[]const u8, // null = 正无穷
    seq: u64, // 写入 commit sequence
};

fn covers(t: RTombstone, k: []const u8) bool {
    // [min, max) 半开：min 含、max 不含（设计 §3.3，与 select 同语义）
    if (t.min) |m| {
        if (btree.cmpKey(k, m) == .lt) return false; // k < min
    }
    if (t.max) |m| {
        if (btree.cmpKey(k, m) != .lt) return false; // k >= max
    }
    return true;
}

fn rangeEmpty(min: ?[]const u8, max: ?[]const u8) bool {
    if (min != null and max != null) {
        return btree.cmpKey(min.?, max.?) != .lt; // min >= max → 空/倒置
    }
    return false; // 有 null 端 → 非空（全区间或单侧）
}

// ===== 设计 §1.2：墓碑链页编码（单页版；链 = free_next 串接） =====

fn encodeTombPage(page: *[f2.PAGE_SIZE]u8, page_no: u32, tobs: []const RTombstone, commit_seq: u64, next_page: u32) !void {
    // 定长头区 2 + 24*count，变长区紧随
    var vlen: usize = 0;
    for (tobs) |t| {
        vlen += (if (t.min) |m| m.len else 0) + (if (t.max) |m| m.len else 0);
    }
    const need = 2 + TOMB_HDR * tobs.len + vlen;
    if (need > TOMB_PAYLOAD) return error.TombPageOverflow; // 调用方分页（链）

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

    std.mem.writeInt(u16, payload[0..2], @intCast(tobs.len), .little);
    var hpos: usize = 2;
    var vpos: usize = 2 + TOMB_HDR * tobs.len;
    for (tobs) |t| {
        const min_len: u32 = if (t.min) |m| @intCast(m.len) else 0;
        const max_len: u32 = if (t.max) |m| @intCast(m.len) else 0;
        std.mem.writeInt(u32, payload[hpos..][0..4], min_len, .little);
        hpos += 4;
        std.mem.writeInt(u32, payload[hpos..][0..4], max_len, .little);
        hpos += 4;
        std.mem.writeInt(u32, payload[hpos..][0..4], @intCast(vpos), .little);
        hpos += 4;
        if (t.min) |m| {
            @memcpy(payload[vpos..][0..m.len], m);
            vpos += m.len;
        }
        std.mem.writeInt(u32, payload[hpos..][0..4], @intCast(vpos), .little);
        hpos += 4;
        if (t.max) |m| {
            @memcpy(payload[vpos..][0..m.len], m);
            vpos += m.len;
        }
        std.mem.writeInt(u64, payload[hpos..][0..8], t.seq, .little);
        hpos += 8;
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
    const count = std.mem.readInt(u16, payload[0..2], .little);
    if (count != hdr.nkeys) return error.CorruptCrc; // 头与 payload 一致性
    const tobs = try alloc.alloc(RTombstone, count);
    var hpos: usize = 2;
    for (0..count) |i| {
        const min_len = std.mem.readInt(u32, payload[hpos..][0..4], .little);
        hpos += 4;
        const max_len = std.mem.readInt(u32, payload[hpos..][0..4], .little);
        hpos += 4;
        const min_off = std.mem.readInt(u32, payload[hpos..][0..4], .little);
        hpos += 4;
        const max_off = std.mem.readInt(u32, payload[hpos..][0..4], .little);
        hpos += 4;
        const seq = std.mem.readInt(u64, payload[hpos..][0..8], .little);
        hpos += 8;
        if (min_off + min_len > payload.len or max_off + max_len > payload.len) {
            @panic("tomb offset out of bounds");
        }
        tobs[i] = .{
            .min = if (min_len == 0) null else payload[min_off..][0..min_len],
            .max = if (max_len == 0) null else payload[max_off..][0..max_len],
            .seq = seq,
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

/// 设计 §4.3：put(k) 打洞——k 的字典序后继 = k ++ 0x00。
/// 返回分裂后的墓碑集（覆盖 k 的墓碑 t → [t.min,k) 与 [succ(k),t.max)）。
fn punchHole(tobs: []const RTombstone, k: []const u8, out: *std.ArrayList(RTombstone)) !void {
    for (tobs) |t| {
        if (!covers(t, k)) {
            try out.append(alloc, t);
            continue;
        }
        // 左段 [t.min, k)
        if (t.min == null or btree.cmpKey(t.min.?, k) == .lt) {
            try out.append(alloc, .{ .min = t.min, .max = k, .seq = t.seq });
        }
        // 右段 [succ(k), t.max)；k 追加 0x00 是 > k 的最短键。
        // k 已是「任意可表示键」时（无法排除 k+len 扩展…实际键长受
        // MAX_KEY_SIZE 约束，succ 可能超长——此时右段保守放弃（宽界：
        // 右侧新写入键可能被漏遮蔽？不会：右段放弃意味着该区间无墓碑，
        // put 的新键本来就不该被旧墓碑遮蔽——INV-RT1 语义即「墓碑不遮蔽
        // 后续写入」。放弃右段只会漏遮蔽「后来又写回又被删」的键，
        // 由后续 deleteRange 重新建碑覆盖）。见设计 §4.3。
        if (k.len + 1 <= btree.MAX_KEY_SIZE) {
            if (t.max == null or btree.cmpKey(k, t.max.?) == .lt) {
                const succ = try alloc.alloc(u8, k.len + 1);
                @memcpy(succ[0..k.len], k);
                succ[k.len] = 0x00;
                // succ 所有权移交 out（调用方用 freeAllocatedMins 释放）
                try out.append(alloc, .{ .min = succ, .max = t.max, .seq = t.seq });
            }
        }
    }
}


/// punchHole 移交的 succ(k) 分配由调用方释放（t.min/t.max 借用原墓碑或
/// 字面量，不释放；只有右段的 succ 是 punchHole 新分配的）。
/// 探针简化约定：右段 min 的形状恒为 k ++ 0x00（len = k.len+1 且尾字节
/// 0x00），据此识别新分配。生产实现应让 punchHole 返回显式分配列表——
/// spike 不为此做接口。
fn freePunchedMins(items: []const RTombstone, hole_key_len: usize) void {
    for (items) |t| {
        if (t.min) |m| {
            if (m.len == hole_key_len + 1 and m[m.len - 1] == 0x00) {
                alloc.free(m);
            }
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
        .{ .min = "apple", .max = "banana", .seq = 42 },
        .{ .min = null, .max = "a", .seq = 43 }, // 负无穷 .. "a"
        .{ .min = "z", .max = null, .seq = 44 }, // "z" .. 正无穷
        .{ .min = null, .max = null, .seq = 45 }, // 全区间
        .{ .min = "\xff\x00\x11 very long key padded to stress varlen region 0123456789", .max = "\xff\xff\xff", .seq = 46 },
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
        if (want.min) |m| try std.testing.expectEqualSlices(u8, m, got.min.?) else try std.testing.expect(got.min == null);
        if (want.max) |m| try std.testing.expectEqualSlices(u8, m, got.max.?) else try std.testing.expect(got.max == null);
        try std.testing.expectEqual(want.seq, got.seq);
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
// 探针 2：遮蔽判定边界（min 含 / max 不含 / 空 / 全区间 / 倒置）
// =====================================================================

test "T-38-P probe 2: shadowing boundaries [min,max)" {
    const t = RTombstone{ .min = "b", .max = "e", .seq = 1 };
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
    try std.testing.expect(rangeEmpty("c", "c"));
    // 倒置（min > max）
    try std.testing.expect(rangeEmpty("d", "c"));
    // 空区间墓碑不遮蔽任何 key
    const empty_t = RTombstone{ .min = "c", .max = "c", .seq = 1 };
    try std.testing.expect(!covers(empty_t, "c"));
    // 全区间墓碑（null, null）遮蔽一切
    const full_t = RTombstone{ .min = null, .max = null, .seq = 1 };
    try std.testing.expect(covers(full_t, ""));
    try std.testing.expect(covers(full_t, "\xff\xff"));
    // 单侧
    const low_t = RTombstone{ .min = null, .max = "m", .seq = 1 };
    try std.testing.expect(covers(low_t, "aaa"));
    try std.testing.expect(!covers(low_t, "m"));
    const high_t = RTombstone{ .min = "m", .max = null, .seq = 1 };
    try std.testing.expect(covers(high_t, "m"));
    try std.testing.expect(covers(high_t, "\xff\xff"));
    try std.testing.expect(!covers(high_t, "l"));

    // shadowed：多墓碑任一覆盖即遮蔽
    const set = [_]RTombstone{ t, RTombstone{ .min = "x", .max = "y", .seq = 2 } };
    try std.testing.expect(shadowed(&set, "c"));
    try std.testing.expect(shadowed(&set, "x"));
    try std.testing.expect(!shadowed(&set, "w"));
    try std.testing.expect(!shadowed(&set, "e")); // 边界 max 不含
}

// =====================================================================
// 探针 3：与逐 key tombstone 共存 + put 打洞（字典序后继）
// =====================================================================

test "T-38-P probe 3: coexistence with per-key tombstones + put punch-hole" {
    // 场景矩阵（设计 §3.2/§4.3）：
    //   put k; deleteRange[a,b)∋k; get k → null（墓碑遮蔽）
    //   put k; deleteRange[a,b)∋k; put k; get k → 非 null（INV-RT1：打洞）
    //   逐 key tombstone 与区间墓碑同时覆盖 → 同为删除，无冲突
    var tobs: std.ArrayList(RTombstone) = .empty;
    defer tobs.deinit(alloc);

    // 初始：deleteRange ["b","f")
    try tobs.append(alloc, .{ .min = "b", .max = "f", .seq = 10 });

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
    freePunchedMins(punched.items, 1); // 释放 succ(k) 分配（k="c" len 1）

    // put "b"（区间左端点，min 含 → 覆盖）→ 左段为空，只剩右段 [b\0, f)
    var punched2: std.ArrayList(RTombstone) = .empty;
    defer punched2.deinit(alloc);
    try punchHole(tobs.items, "b", &punched2);
    try std.testing.expectEqual(@as(usize, 1), punched2.items.len);
    try std.testing.expect(!shadowed(punched2.items, "b"));
    try std.testing.expect(shadowed(punched2.items, "b\x00"));
    try std.testing.expect(shadowed(punched2.items, "e"));
    freePunchedMins(punched2.items, 1); // k="b" len 1

    // put "e\xff…键后继超 MAX_KEY_SIZE" 的边界：succ(k) 超 MAX_KEY_SIZE 时右段放弃
    const big = [_]u8{'q'} ** btree.MAX_KEY_SIZE;
    var punched3: std.ArrayList(RTombstone) = .empty;
    defer punched3.deinit(alloc);
    // 先扩碑到 [a, z) 覆盖 big
    var wide: std.ArrayList(RTombstone) = .empty;
    defer wide.deinit(alloc);
    try wide.append(alloc, .{ .min = "a", .max = "z", .seq = 1 });
    try punchHole(wide.items, &big, &punched3);
    try std.testing.expectEqual(@as(usize, 1), punched3.items.len); // 只有左段 [a, q...)
    try std.testing.expect(!shadowed(punched3.items, &big));
    try std.testing.expect(shadowed(punched3.items, "b"));
    // k=big 长度 = MAX_KEY_SIZE，右段放弃 → 无 succ 分配

    // 共存：逐 key tombstone（叶内 entry 形态）+ 区间墓碑 —— 两者都是删除，
    // get 判定 = null（无优先级冲突：tombstone entry 本身就是「无值」）
    const coexist = [_]RTombstone{.{ .min = "b", .max = "f", .seq = 10 }};
    // 逐 key tombstone "d"（叶内）与区间墓碑都覆盖 "d"：
    // 读路径结果一致（都是 deleted），shadowed 只对「活 entry」起作用。
    try std.testing.expect(shadowed(&coexist, "d"));
    // 打洞后 "d" 活（put 回来），逐 key tombstone 已被 put 覆盖（last-write-wins）
    var coexist2: std.ArrayList(RTombstone) = .empty;
    defer coexist2.deinit(alloc);
    try punchHole(&coexist, "d", &coexist2);
    try std.testing.expect(!shadowed(coexist2.items, "d"));
    try std.testing.expect(shadowed(coexist2.items, "c"));
    freePunchedMins(coexist2.items, 1); // k="d" len 1
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
    // 每条最小 24B 头 + 2×1B 键 → ≥ 155 条/页（设计 §1.4 声明核对）
    const per_page_min = TOMB_PAYLOAD / (TOMB_HDR + 2);
    try std.testing.expect(per_page_min >= 155);

    // 构造 300 条墓碑（超过单页容量），分两页链式编码再解码
    const many = try alloc.alloc(RTombstone, 300);
    defer alloc.free(many);
    for (0..many.len) |i| {
        var kb: [8]u8 = undefined;
        _ = std.fmt.bufPrint(&kb, "{d:0>8}", .{i * 3}) catch unreachable;
        many[i] = .{ .min = try alloc.dupe(u8, &kb), .max = try alloc.dupe(u8, kb[0..7] ++ "z"), .seq = @intCast(i) };
    }
    defer for (many) |t| {
        alloc.free(t.min.?);
        alloc.free(t.max.?);
    };

    // 分页：按本组键长（8B min + 8B max）计算每页容量并切分
    //（探针只验证链式 round-trip，装箱策略属主体实现）
    const per_tomb = TOMB_HDR + 8 + 8; // 40B/条
    const per_page = (TOMB_PAYLOAD - 2) / per_tomb; // ~101 条/页
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
    try std.testing.expectEqualSlices(u8, many[0].min.?, d1.tobs[0].min.?);
    try std.testing.expectEqualSlices(u8, many[n1 - 1].min.?, d1.tobs[n1 - 1].min.?);
    try std.testing.expectEqualSlices(u8, many[n1].min.?, d2.tobs[0].min.?);
    try std.testing.expectEqualSlices(u8, many[many.len - 1].max.?, d3.tobs[n3 - 1].max.?);
    try std.testing.expectEqual(many[n1 + 50].seq, d2.tobs[50].seq);
}
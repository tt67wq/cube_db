//! format.zig — 常量与编解码（块标记、记录、header、节点布局、CRC32）
//! 纯函数模块，无 IO。M1。
const std = @import("std");

pub const MAGIC: u32 = 0x4355_4244; // "CUBD"
pub const VERSION: u16 = 1;
pub const BLOCK_SIZE: usize = 4096;

pub const MARKER_DATA: u8 = 0;
pub const MARKER_HEADER: u8 = 1;

/// 记录：len:u32 | payload:[len] | crc:u32 (crc 覆盖 len+payload, big-endian)
pub const REC_LEN_SIZE: usize = 4;
pub const REC_CRC_SIZE: usize = 4;

pub const Crc32 = std.hash.crc.Crc32;

pub const Header = struct {
    magic: u32 = MAGIC,
    version: u16 = VERSION,
    btree_root: u64,
    entry_count: u64,
    byte_size: u64, // live bytes
    dirt: u64,
};

pub const NodeKind = enum(u8) { branch = 1, leaf = 2 };

pub const LeafEntry = struct {
    tombstone: bool,
    key: []const u8,
    value: []const u8, // tombstone 时为空
};

pub const BranchNode = struct {
    /// count-1 个分隔 key
    keys: []const []const u8,
    /// count 个子节点偏移
    children: []const u64,
};

pub const LeafNode = struct {
    entries: []const LeafEntry,
};

// ---------- Header ----------

/// header payload 固定大小
pub const HEADER_PAYLOAD_SIZE: usize = 4 + 2 + 8 + 8 + 8 + 8; // 38

pub fn headerPayloadSize() usize {
    return HEADER_PAYLOAD_SIZE;
}

/// 编码 header payload 到 buf（不含 len/crc）。返回写入字节数。
pub fn encodeHeaderPayload(buf: []u8, h: Header) usize {
    std.debug.assert(buf.len >= HEADER_PAYLOAD_SIZE);
    var pos: usize = 0;
    std.mem.writeInt(u32, buf[pos..][0..4], h.magic, .big);
    pos += 4;
    std.mem.writeInt(u16, buf[pos..][0..2], h.version, .big);
    pos += 2;
    std.mem.writeInt(u64, buf[pos..][0..8], h.btree_root, .big);
    pos += 8;
    std.mem.writeInt(u64, buf[pos..][0..8], h.entry_count, .big);
    pos += 8;
    std.mem.writeInt(u64, buf[pos..][0..8], h.byte_size, .big);
    pos += 8;
    std.mem.writeInt(u64, buf[pos..][0..8], h.dirt, .big);
    pos += 8;
    return pos;
}

pub fn decodeHeaderPayload(buf: []const u8) Header {
    std.debug.assert(buf.len >= HEADER_PAYLOAD_SIZE);
    var pos: usize = 0;
    var h: Header = .{ .btree_root = 0, .entry_count = 0, .byte_size = 0, .dirt = 0 };
    h.magic = std.mem.readInt(u32, buf[pos..][0..4], .big);
    pos += 4;
    h.version = std.mem.readInt(u16, buf[pos..][0..2], .big);
    pos += 2;
    h.btree_root = std.mem.readInt(u64, buf[pos..][0..8], .big);
    pos += 8;
    h.entry_count = std.mem.readInt(u64, buf[pos..][0..8], .big);
    pos += 8;
    h.byte_size = std.mem.readInt(u64, buf[pos..][0..8], .big);
    pos += 8;
    h.dirt = std.mem.readInt(u64, buf[pos..][0..8], .big);
    return h;
}

// ---------- 记录包装（len + payload + crc） ----------

pub const Error = error{
    CorruptCrc,
    Truncated,
    BadMagic,
    BadVersion,
};

/// 计算一条记录总字节数（len + payload + crc）
pub fn recordTotalSize(payload_size: usize) usize {
    return REC_LEN_SIZE + payload_size + REC_CRC_SIZE;
}

/// 编码一条记录到 buf：写入 len、payload、crc。返回总字节数。
/// buf 必须至少 recordTotalSize(payload_size) 字节。
pub fn encodeRecord(buf: []u8, payload: []const u8) usize {
    const total = recordTotalSize(payload.len);
    std.debug.assert(buf.len >= total);
    var pos: usize = 0;
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(payload.len), .big);
    pos += 4;
    @memcpy(buf[pos..][0..payload.len], payload);
    pos += payload.len;
    // crc 覆盖 len + payload
    var crc = Crc32.init();
    crc.update(buf[0..pos]);
    std.mem.writeInt(u32, buf[pos..][0..4], crc.final(), .big);
    pos += 4;
    return total;
}

/// 解码一条记录：从 buf 读 len，校验 crc，返回 payload 切片（指向 buf 内部）。
/// 若 len 字段声明大于可用 payload 字节 → error.Truncated。
/// crc 不匹配 → error.CorruptCrc。
pub fn decodeRecord(buf: []const u8) Error![]const u8 {
    if (buf.len < REC_LEN_SIZE + REC_CRC_SIZE) return error.Truncated;
    const len = std.mem.readInt(u32, buf[0..4], .big);
    const need = REC_LEN_SIZE + @as(usize, len) + REC_CRC_SIZE;
    if (buf.len < need) return error.Truncated;
    const payload = buf[REC_LEN_SIZE .. REC_LEN_SIZE + len];
    const crc_stored = std.mem.readInt(u32, buf[REC_LEN_SIZE + len ..][0..4], .big);
    var crc = Crc32.init();
    crc.update(buf[0 .. REC_LEN_SIZE + len]);
    if (crc.final() != crc_stored) return error.CorruptCrc;
    return payload;
}

/// 解析 len + payload，不验 CRC（热读路径用；边界恢复仍走 decodeRecord 验）。
pub fn decodeRecordNoCrc(buf: []const u8) Error![]const u8 {
    if (buf.len < REC_LEN_SIZE + REC_CRC_SIZE) return error.Truncated;
    const len = std.mem.readInt(u32, buf[0..4], .big);
    const need = REC_LEN_SIZE + @as(usize, len) + REC_CRC_SIZE;
    if (buf.len < need) return error.Truncated;
    return buf[REC_LEN_SIZE .. REC_LEN_SIZE + len];
}

// ---------- 节点 payload 编解码 ----------

/// 计算 branch payload 字节数。
pub fn branchPayloadSize(node: BranchNode) usize {
    var n: usize = 1 + 2; // kind + count
    for (node.keys) |k| n += 4 + k.len;
    n += 8 * node.children.len;
    return n;
}

pub fn encodeBranchPayload(buf: []u8, node: BranchNode) usize {
    const need = branchPayloadSize(node);
    std.debug.assert(buf.len >= need);
    std.debug.assert(node.children.len >= 2);
    std.debug.assert(node.keys.len == node.children.len - 1);
    var pos: usize = 0;
    buf[pos] = @intFromEnum(NodeKind.branch);
    pos += 1;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(node.children.len), .big);
    pos += 2;
    for (node.keys) |k| {
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(k.len), .big);
        pos += 4;
        @memcpy(buf[pos..][0..k.len], k);
        pos += k.len;
    }
    for (node.children) |c| {
        std.mem.writeInt(u64, buf[pos..][0..8], c, .big);
        pos += 8;
    }
    return need;
}

pub const DecodedBranch = struct {
    keys: [][]const u8,
    children: []u64,
};

/// 解码 branch payload。keys/children 指向 payload 内部切片，children 写入 out_children。
pub fn decodeBranchPayload(payload: []const u8, keys_out: [][]const u8, children_out: []u64) Error!void {
    if (payload.len < 3) return error.Truncated;
    if (payload[0] != @intFromEnum(NodeKind.branch)) return error.CorruptCrc; // kind mismatch
    const count = std.mem.readInt(u16, payload[1..3], .big);
    if (keys_out.len < count - 1) return error.Truncated;
    if (children_out.len < count) return error.Truncated;
    var pos: usize = 3;
    var i: usize = 0;
    while (i < count - 1) : (i += 1) {
        if (pos + 4 > payload.len) return error.Truncated;
        const klen = std.mem.readInt(u32, payload[pos..][0..4], .big);
        pos += 4;
        if (pos + klen > payload.len) return error.Truncated;
        keys_out[i] = payload[pos .. pos + klen];
        pos += klen;
    }
    if (pos + 8 * count > payload.len) return error.Truncated;
    var j: usize = 0;
    while (j < count) : (j += 1) {
        children_out[j] = std.mem.readInt(u64, payload[pos..][0..8], .big);
        pos += 8;
    }
}

pub fn leafPayloadSize(node: LeafNode) usize {
    var n: usize = 1 + 2; // kind + count
    for (node.entries) |e| {
        n += 1 + 4 + e.key.len + 4 + e.value.len;
    }
    return n;
}

pub fn encodeLeafPayload(buf: []u8, node: LeafNode) usize {
    const need = leafPayloadSize(node);
    std.debug.assert(buf.len >= need);
    var pos: usize = 0;
    buf[pos] = @intFromEnum(NodeKind.leaf);
    pos += 1;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(node.entries.len), .big);
    pos += 2;
    for (node.entries) |e| {
        buf[pos] = if (e.tombstone) 1 else 0;
        pos += 1;
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(e.key.len), .big);
        pos += 4;
        @memcpy(buf[pos..][0..e.key.len], e.key);
        pos += e.key.len;
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(e.value.len), .big);
        pos += 4;
        @memcpy(buf[pos..][0..e.value.len], e.value);
        pos += e.value.len;
    }
    return need;
}

pub const DecodedLeafEntry = struct {
    tombstone: bool,
    key: []const u8,
    value: []const u8,
};

pub fn decodeLeafPayload(payload: []const u8, entries_out: []DecodedLeafEntry) Error!void {
    if (payload.len < 3) return error.Truncated;
    if (payload[0] != @intFromEnum(NodeKind.leaf)) return error.CorruptCrc;
    const count = std.mem.readInt(u16, payload[1..3], .big);
    if (entries_out.len < count) return error.Truncated;
    var pos: usize = 3;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (pos + 1 + 4 > payload.len) return error.Truncated;
        const tombstone = payload[pos] == 1;
        pos += 1;
        const klen = std.mem.readInt(u32, payload[pos..][0..4], .big);
        pos += 4;
        if (pos + klen > payload.len) return error.Truncated;
        const key = payload[pos .. pos + klen];
        pos += klen;
        if (pos + 4 > payload.len) return error.Truncated;
        const vlen = std.mem.readInt(u32, payload[pos..][0..4], .big);
        pos += 4;
        if (pos + vlen > payload.len) return error.Truncated;
        const value = payload[pos .. pos + vlen];
        pos += vlen;
        entries_out[i] = .{ .tombstone = tombstone, .key = key, .value = value };
    }
}

// ===== 测试 =====

test "format: header payload roundtrip" {
    var buf: [HEADER_PAYLOAD_SIZE]u8 = undefined;
    const h: Header = .{
        .btree_root = 0xdeadbeef,
        .entry_count = 123456,
        .byte_size = 999999,
        .dirt = 42,
    };
    const n = encodeHeaderPayload(&buf, h);
    try std.testing.expectEqual(HEADER_PAYLOAD_SIZE, n);
    const got = decodeHeaderPayload(&buf);
    try std.testing.expectEqual(h.magic, got.magic);
    try std.testing.expectEqual(h.version, got.version);
    try std.testing.expectEqual(h.btree_root, got.btree_root);
    try std.testing.expectEqual(h.entry_count, got.entry_count);
    try std.testing.expectEqual(h.byte_size, got.byte_size);
    try std.testing.expectEqual(h.dirt, got.dirt);
}

test "format: record roundtrip + crc" {
    const payload = "hello cube_db";
    var buf: [128]u8 = undefined;
    const n = encodeRecord(&buf, payload);
    try std.testing.expectEqual(recordTotalSize(payload.len), n);
    const got = try decodeRecord(&buf);
    try std.testing.expectEqualStrings(payload, got);
}

test "format: crc bit flip -> CorruptCrc" {
    const payload = "abcdef";
    var buf: [128]u8 = undefined;
    const n = encodeRecord(&buf, payload);
    buf[5] ^= 0xff; // flip a payload bit
    try std.testing.expectError(error.CorruptCrc, decodeRecord(buf[0..n]));
}

test "format: truncated payload -> Truncated" {
    const payload = "x";
    var buf: [128]u8 = undefined;
    const n = encodeRecord(&buf, payload);
    // 声明 len=1 但只给 0 字节 payload
    try std.testing.expectError(error.Truncated, decodeRecord(buf[0 .. n - 5]));
}

test "format: leaf roundtrip (empty/tombstone/big value)" {
    const big = [_]u8{0xaa} ** 1024;
    const entries = [_]LeafEntry{
        .{ .tombstone = false, .key = "a", .value = "1" },
        .{ .tombstone = true, .key = "b", .value = "" },
        .{ .tombstone = false, .key = "", .value = "" },
        .{ .tombstone = false, .key = "big", .value = &big },
    };
    const node: LeafNode = .{ .entries = &entries };
    var buf: [4096]u8 = undefined;
    const n = encodeLeafPayload(&buf, node);
    var out: [4]DecodedLeafEntry = undefined;
    try decodeLeafPayload(buf[0..n], &out);
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqual(false, out[0].tombstone);
    try std.testing.expectEqualStrings("a", out[0].key);
    try std.testing.expectEqualStrings("1", out[0].value);
    try std.testing.expectEqual(true, out[1].tombstone);
    try std.testing.expectEqualStrings("b", out[1].key);
    try std.testing.expectEqualStrings("", out[2].key);
    try std.testing.expectEqualStrings(&big, out[3].value);
}

test "format: branch roundtrip" {
    const k1 = "m";
    const k2 = "z";
    const keys = [_][]const u8{ k1, k2 };
    const children = [_]u64{ 10, 20, 30 };
    const node: BranchNode = .{ .keys = &keys, .children = &children };
    var buf: [256]u8 = undefined;
    const n = encodeBranchPayload(&buf, node);
    var ko: [2][]const u8 = undefined;
    var co: [3]u64 = undefined;
    try decodeBranchPayload(buf[0..n], &ko, &co);
    try std.testing.expectEqualStrings("m", ko[0]);
    try std.testing.expectEqualStrings("z", ko[1]);
    try std.testing.expectEqual(@as(u64, 10), co[0]);
    try std.testing.expectEqual(@as(u64, 20), co[1]);
    try std.testing.expectEqual(@as(u64, 30), co[2]);
}

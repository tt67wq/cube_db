//! btree.zig — 页号 COW B-tree（v2，page-based）
//! 与 v1 btree.zig 相同算法，但节点寻址用 u32 页号，I/O 走 PageStore，
//! 固定页大小，分支子指针为 u32。脏页收集到 caller 的 ArrayList。
const std = @import("std");
const f2 = @import("format.zig");
const ps = @import("page_store.zig");

const PageStore = ps.PageStore;

pub const NULL_ROOT: u32 = 0;
pub const LEAF_MAX_ENTRIES: usize = 32;
pub const LEAF_MIN_ENTRIES: usize = LEAF_MAX_ENTRIES / 2;
pub const BRANCH_MAX_CHILDREN: usize = 64;
pub const BRANCH_MIN_CHILDREN: usize = BRANCH_MAX_CHILDREN / 2;

const LEAF_KIND: u8 = 2;
const BRANCH_KIND: u8 = 1;

pub const LeafEntry = struct {
    tombstone: bool,
    key: []const u8,
    value: []const u8,
};

pub const WriteResult = struct {
    new_root: u32,
    live_delta: i64,
    count_delta: i64,
};

// ===== key 比较 =====
pub fn cmpKey(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

// ===== 页 I/O 辅助 =====

/// 从页读节点 payload（借用页缓冲，不拷贝）
pub fn readNodePayload(store: PageStore, page_no: u32) ![]const u8 {
    const page = try store.readPage(page_no);
    const arr: *const [f2.PAGE_SIZE]u8 = @ptrCast(page.ptr);
    if (!f2.verifyPageChecksum(arr)) return error.CorruptCrc;
    return page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
}

/// 写节点页（页头 + payload + CRC）
pub fn writeNodePage(store: PageStore, page_no: u32, page_type: u8, nkeys: u16, payload: []const u8) !void {
    const page = try store.writePage(page_no);
    const arr: *[f2.PAGE_SIZE]u8 = @ptrCast(page.ptr);
    const hdr = f2.PageHeader{
        .page_no = page_no,
        .page_type = page_type,
        .gen = 0,
        .nkeys = nkeys,
        .free_next = 0,
    };
    f2.encodePageHeader(page[0..f2.PAGE_HEADER_SIZE], &hdr);
    @memcpy(page[f2.PAGE_HEADER_SIZE ..][0..payload.len], payload);
    const remaining = f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4 - payload.len;
    if (remaining > 0) @memset(page[f2.PAGE_HEADER_SIZE + payload.len .. f2.PAGE_SIZE - 4], 0);
    f2.setPageChecksum(arr, f2.computePageChecksum(arr));
}

// ===== Leaf 节点编码 =====

/// 最大内联值大小（留余量给页头和多个 entry）
pub const MAX_INLINE_VALUE: usize = 3800;

/// 溢出页最多可存 payload 字节数
const OVERFLOW_PAYLOAD: usize = f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4;

/// flags: 1 = 溢出页
const LEAF_FLAG_OVERFLOW: u8 = 1;

/// 写值到溢出页链，返首页号
/// ponytail: MVP 无 nkeys 更新，链靠 free_next
fn writeOverflowPages(store: PageStore, value: []const u8) !u32 {
    var remaining = value.len;
    var offset: usize = 0;
    var first_page: u32 = 0;
    var prev_page: u32 = 0;
    
    while (remaining > 0) {
        const page_no = try store.allocPage();
        const page = try store.writePage(page_no);
        const arr: *[f2.PAGE_SIZE]u8 = @ptrCast(page.ptr);
        const chunk = @min(remaining, OVERFLOW_PAYLOAD);
        
        const hdr = f2.PageHeader{
            .page_no = page_no,
            .page_type = f2.PAGE_TYPE_OVERFLOW,
            .gen = 0,
            .nkeys = 0,
            .free_next = 0,
        };
        f2.encodePageHeader(page[0..f2.PAGE_HEADER_SIZE], &hdr);
        @memcpy(page[f2.PAGE_HEADER_SIZE..][0..chunk], value[offset..offset+chunk]);
        const rem = OVERFLOW_PAYLOAD - chunk;
        if (rem > 0) @memset(page[f2.PAGE_HEADER_SIZE + chunk .. f2.PAGE_SIZE - 4], 0);
        f2.setPageChecksum(arr, f2.computePageChecksum(arr));
        
        if (first_page == 0) {
            first_page = page_no;
        } else {
            // 链接前页 → 本页
            const prev = try store.writePage(prev_page);
            const prev_arr: *[f2.PAGE_SIZE]u8 = @ptrCast(prev.ptr);
            var prev_hdr = f2.decodePageHeader(prev[0..f2.PAGE_HEADER_SIZE]);
            prev_hdr.free_next = page_no;
            f2.encodePageHeader(prev[0..f2.PAGE_HEADER_SIZE], &prev_hdr);
            f2.setPageChecksum(prev_arr, f2.computePageChecksum(prev_arr));
        }
        prev_page = page_no;
        remaining -= chunk;
        offset += chunk;
    }
    return first_page;
}

/// 读溢出页链，返回值（调用方 free）
fn readOverflowValue(allocator: std.mem.Allocator, store: PageStore, first_page: u32, vlen: u32) ![]u8 {
    const result = try allocator.alloc(u8, vlen);
    errdefer allocator.free(result);
    var offset: usize = 0;
    var cur = first_page;
    while (cur != 0 and offset < vlen) {
        const payload = try readNodePayload(store, cur);
        const chunk = @min(vlen - offset, payload.len);
        @memcpy(result[offset..][0..chunk], payload[0..chunk]);
        offset += chunk;
        const page = try store.readPage(cur);
        const hdr = f2.decodePageHeader(page[0..f2.PAGE_HEADER_SIZE]);
        cur = hdr.free_next;
    }
    return result;
}

/// 回收溢出页链到 dirty list
fn freeOverflowPages(store: PageStore, first_page: u32, dirty: *std.ArrayList(u32), allocator: std.mem.Allocator) void {
    var cur = first_page;
    while (cur != 0) {
        const page = store.readPage(cur) catch return;
        const hdr = f2.decodePageHeader(page[0..f2.PAGE_HEADER_SIZE]);
        const next = hdr.free_next;
        dirty.append(allocator, cur) catch {};
        cur = next;
    }
}

/// 判断 entry 需要溢出页
fn needsOverflow(entry: LeafEntry) bool {
    return entry.value.len > MAX_INLINE_VALUE;
}

pub fn leafPayloadSize(entries: []const LeafEntry) usize {
    var n: usize = 1 + 2;
    for (entries) |e| {
        // tombstone(1) + klen(4) + key + vlen(4) + flags(1) + value
        // For overflow, value takes 4 bytes (page_no) instead of inline
        const value_sz = if (e.value.len > MAX_INLINE_VALUE) @as(usize, 4) else e.value.len;
        n += 1 + 4 + e.key.len + 4 + 1 + value_sz;
    }
    return n;
}

pub fn encodeLeafPayload(buf: []u8, entries: []const LeafEntry, store: PageStore, dirty: *std.ArrayList(u32)) !usize {
    _ = dirty;
    const need = leafPayloadSize(entries);
    std.debug.assert(buf.len >= need);
    var pos: usize = 0;
    buf[pos] = LEAF_KIND;
    pos += 1;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(entries.len), .big);
    pos += 2;
    for (entries) |e| {
        const is_ov = e.value.len > MAX_INLINE_VALUE;
        buf[pos] = if (e.tombstone) @as(u8, 1) else 0;
        pos += 1;
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(e.key.len), .big);
        pos += 4;
        @memcpy(buf[pos..][0..e.key.len], e.key);
        pos += e.key.len;
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(e.value.len), .big);
        pos += 4;
        if (is_ov) {
            buf[pos] = LEAF_FLAG_OVERFLOW;
            pos += 1;
            const ov_page = try writeOverflowPages(store, e.value);
            std.mem.writeInt(u32, buf[pos..][0..4], ov_page, .little);
            pos += 4;
        } else {
            buf[pos] = 0;
            pos += 1;
            @memcpy(buf[pos..][0..e.value.len], e.value);
            pos += e.value.len;
        }
    }
    return need;
}

pub const DecodedLeafEntry = struct {
    tombstone: bool,
    key: []const u8,
    value: []const u8,
    flags: u8,
    vlen: u32,
};

pub fn decodeLeafPayload(payload: []const u8, entries_out: []DecodedLeafEntry) !void {
    if (payload.len < 3) return error.Truncated;
    if (payload[0] != LEAF_KIND) return error.CorruptCrc;
    const count = std.mem.readInt(u16, payload[1..3], .big);
    if (entries_out.len < count) return error.Truncated;
    var pos: usize = 3;
    for (payload, 0..) |_, i| {
        if (i >= count) break;
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
        if (pos + 1 > payload.len) return error.Truncated;
        const flags = payload[pos];
        pos += 1;
        if (flags & LEAF_FLAG_OVERFLOW != 0) {
            // overflow: 4 bytes page_no
            if (pos + 4 > payload.len) return error.Truncated;
            const ov_page = payload[pos..pos+4];
            pos += 4;
            entries_out[i] = .{ .tombstone = tombstone, .key = key, .value = ov_page, .flags = flags, .vlen = vlen };
        } else {
            if (pos + vlen > payload.len) return error.Truncated;
            const value = payload[pos .. pos + vlen];
            pos += vlen;
            entries_out[i] = .{ .tombstone = tombstone, .key = key, .value = value, .flags = flags, .vlen = vlen };
        }
    }
}

// ===== Branch 节点编码（u32 子指针） =====

pub fn branchPayloadSize(keys: []const []const u8, children: []const u32) usize {
    var n: usize = 1 + 2;
    for (keys) |k| n += 4 + k.len;
    n += 4 * children.len;
    return n;
}

pub fn encodeBranchPayload(buf: []u8, keys: []const []const u8, children: []const u32) usize {
    const need = branchPayloadSize(keys, children);
    std.debug.assert(buf.len >= need);
    std.debug.assert(children.len >= 2);
    std.debug.assert(keys.len == children.len - 1);
    var pos: usize = 0;
    buf[pos] = BRANCH_KIND;
    pos += 1;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(children.len), .big);
    pos += 2;
    for (keys) |k| {
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(k.len), .big);
        pos += 4;
        @memcpy(buf[pos..][0..k.len], k);
        pos += k.len;
    }
    for (children) |c| {
        std.mem.writeInt(u32, buf[pos..][0..4], c, .big);
        pos += 4;
    }
    return need;
}

pub fn decodeBranchPayload(payload: []const u8, keys_out: [][]const u8, children_out: []u32) !void {
    if (payload.len < 3) return error.Truncated;
    if (payload[0] != BRANCH_KIND) return error.CorruptCrc;
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
    if (pos + 4 * count > payload.len) return error.Truncated;
    var j: usize = 0;
    while (j < count) : (j += 1) {
        children_out[j] = std.mem.readInt(u32, payload[pos..][0..4], .big);
        pos += 4;
    }
}

// ===== Leaf 内存表示 =====

pub const Leaf = struct {
    entries: []LeafEntry,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Leaf {
        return .{ .entries = &.{}, .allocator = allocator };
    }

    pub fn deinit(self: *Leaf) void {
        for (self.entries) |e| {
            self.allocator.free(e.key);
            self.allocator.free(e.value);
        }
        self.allocator.free(self.entries);
    }

    pub fn fromPayload(allocator: std.mem.Allocator, store: PageStore, payload: []const u8, dirty: *std.ArrayList(u32)) !Leaf {
        const dec = try allocator.alloc(DecodedLeafEntry, LEAF_MAX_ENTRIES);
        defer allocator.free(dec);
        const count = blk: {
            if (payload.len < 3) return error.Truncated;
            if (payload[0] != LEAF_KIND) return error.CorruptCrc;
            break :blk std.mem.readInt(u16, payload[1..3], .big);
        };
        const dec_slice = try allocator.alloc(DecodedLeafEntry, count);
        defer allocator.free(dec_slice);
        try decodeLeafPayload(payload, dec_slice);
        const entries = try allocator.alloc(LeafEntry, count);
        for (dec_slice, 0..) |d, i| {
            if (d.flags & LEAF_FLAG_OVERFLOW != 0) {
                // 读溢出页链，获完整值；并将旧溢出页加入 dirty
                const ov_page = std.mem.readInt(u32, d.value[0..4], .little);
                freeOverflowPages(store, ov_page, dirty, allocator);
                const full_val = try readOverflowValue(allocator, store, ov_page, d.vlen);
                entries[i] = .{
                    .tombstone = d.tombstone,
                    .key = try allocator.dupe(u8, d.key),
                    .value = full_val,
                };
            } else {
                entries[i] = .{
                    .tombstone = d.tombstone,
                    .key = try allocator.dupe(u8, d.key),
                    .value = try allocator.dupe(u8, d.value),
                };
            }
        }
        return .{ .entries = entries, .allocator = allocator };
    }

    pub fn findPos(self: *const Leaf, key: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (cmpKey(self.entries[mid].key, key)) {
                .lt => lo = mid + 1,
                .eq, .gt => hi = mid,
            }
        }
        return lo;
    }
};

// ===== Branch 内存表示 =====

pub const Branch = struct {
    keys: [][]u8,
    children: []u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Branch {
        return .{ .keys = &.{}, .children = &.{}, .allocator = allocator };
    }

    pub fn deinit(self: *Branch) void {
        for (self.keys) |k| self.allocator.free(k);
        self.allocator.free(self.keys);
        self.allocator.free(self.children);
    }

    pub fn fromPayload(allocator: std.mem.Allocator, payload: []const u8) !Branch {
        const count = blk: {
            if (payload.len < 3) return error.Truncated;
            if (payload[0] != BRANCH_KIND) return error.CorruptCrc;
            break :blk std.mem.readInt(u16, payload[1..3], .big);
        };
        const keys_tmp = try allocator.alloc([]const u8, count - 1);
        defer allocator.free(keys_tmp);
        const children_tmp = try allocator.alloc(u32, count);
        defer allocator.free(children_tmp);
        try decodeBranchPayload(payload, keys_tmp, children_tmp);
        const keys = try allocator.alloc([]u8, count - 1);
        const children = try allocator.alloc(u32, count);
        for (keys_tmp, 0..) |k, i| keys[i] = try allocator.dupe(u8, k);
        @memcpy(children, children_tmp);
        return .{ .keys = keys, .children = children, .allocator = allocator };
    }

    /// 找 key 应走哪个子节点（返回 child index 0..count-1）
    pub fn findChild(self: *const Branch, key: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = self.keys.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (cmpKey(self.keys[mid], key)) {
                .lt, .eq => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return lo;
    }
};

// ===== get =====

pub fn get(allocator: std.mem.Allocator, store: PageStore, root: u32, key: []const u8) !?[]u8 {
    if (root == NULL_ROOT) return null;
    var cur = root;
    var depth: u32 = 0;
    while (depth < 1000) : (depth += 1) {
        const payload = try readNodePayload(store, cur);
        if (payload.len == 0) return error.Truncated;
        if (payload[0] == LEAF_KIND) {
            return findInLeaf(allocator, store, payload, key);
        } else {
            cur = try findInBranchPayload(payload, key);
        }
    }
    return error.Truncated;
}

fn findInLeaf(allocator: std.mem.Allocator, store: PageStore, payload: []const u8, key: []const u8) !?[]u8 {
    if (payload.len < 3) return error.Truncated;
    if (payload[0] != LEAF_KIND) return error.CorruptCrc;
    const count = std.mem.readInt(u16, payload[1..3], .big);
    var pos: usize = 3;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (pos + 1 + 4 > payload.len) return error.Truncated;
        const tombstone = payload[pos] == 1;
        pos += 1;
        const klen = std.mem.readInt(u32, payload[pos..][0..4], .big);
        pos += 4;
        if (pos + klen > payload.len) return error.Truncated;
        const ek = payload[pos .. pos + klen];
        pos += klen;
        if (pos + 4 > payload.len) return error.Truncated;
        const vlen = std.mem.readInt(u32, payload[pos..][0..4], .big);
        pos += 4;
        if (pos + 1 > payload.len) return error.Truncated;
        const flags = payload[pos];
        pos += 1;
        switch (cmpKey(ek, key)) {
            .lt => {
                // skip value for non-matching key
                if (flags & LEAF_FLAG_OVERFLOW == 0) {
                    if (pos + vlen > payload.len) return error.Truncated;
                    pos += vlen;
                } else {
                    if (pos + 4 > payload.len) return error.Truncated;
                    pos += 4;
                }
                continue;
            },
            .eq => {
                if (tombstone) return null;
                if (flags & LEAF_FLAG_OVERFLOW != 0) {
                    const ov_page = std.mem.readInt(u32, payload[pos..][0..4], .little);
                    return @as(?[]u8, try readOverflowValue(allocator, store, ov_page, @intCast(vlen)));
                }
                if (pos + vlen > payload.len) return error.Truncated;
                const ev = payload[pos .. pos + vlen];
                return try allocator.dupe(u8, ev);
            },
            .gt => return null,
        }
    }
    return null;
}

fn findInBranchPayload(payload: []const u8, key: []const u8) !u32 {
    if (payload.len < 3) return error.Truncated;
    if (payload[0] != BRANCH_KIND) return error.CorruptCrc;
    const count = std.mem.readInt(u16, payload[1..3], .big);
    var pos: usize = 3;
    var child_idx: usize = 0;
    var found = false;
    var i: usize = 0;
    while (i + 1 < count) : (i += 1) {
        if (pos + 4 > payload.len) return error.Truncated;
        const klen = std.mem.readInt(u32, payload[pos..][0..4], .big);
        pos += 4;
        if (pos + klen > payload.len) return error.Truncated;
        const ek = payload[pos .. pos + klen];
        pos += klen;
        if (!found and cmpKey(ek, key) == .gt) {
            child_idx = i;
            found = true;
        }
    }
    if (!found) child_idx = count - 1;
    // children 区：keys 区结束后
    if (pos + 4 * count > payload.len) return error.Truncated;
    return std.mem.readInt(u32, payload[pos + child_idx * 4 ..][0..4], .big);
}

// ===== insert（COW） =====

const InsertSub = struct {
    new_child: u32,
    split_key: ?[]u8 = null,
    split_right: u32 = 0,
    live_delta: i64 = 0,
    count_delta: i64 = 0,
};

fn insertIntoLeaf(
    store: PageStore,
    allocator: std.mem.Allocator,
    page_no: u32,
    key: []const u8,
    value: []const u8,
    tombstone: bool,
    dirty: *std.ArrayList(u32),
) !InsertSub {
    const payload = try readNodePayload(store, page_no);
    var leaf = try Leaf.fromPayload(allocator, store, payload, dirty);
    defer leaf.deinit();

    var live_delta: i64 = 0;
    var count_delta: i64 = 0;

    const pos = leaf.findPos(key);
    if (pos < leaf.entries.len and cmpKey(leaf.entries[pos].key, key) == .eq) {
        // 覆盖
        const old = leaf.entries[pos];
        live_delta -= @as(i64, @intCast(old.key.len + old.value.len + 9));
        allocator.free(old.key);
        allocator.free(old.value);
        if (!old.tombstone and tombstone) {
            count_delta = -1;
        } else if (old.tombstone and !tombstone) {
            count_delta = 1;
        }
        leaf.entries[pos] = .{
            .tombstone = tombstone,
            .key = try allocator.dupe(u8, key),
            .value = if (tombstone) try allocator.dupe(u8, "") else try allocator.dupe(u8, value),
        };
        live_delta += @as(i64, @intCast(key.len + (if (tombstone) @as(usize, 0) else value.len) + 9));
    } else {
        // 新增
        const new_entries = try allocator.alloc(LeafEntry, leaf.entries.len + 1);
        @memcpy(new_entries[0..pos], leaf.entries[0..pos]);
        new_entries[pos] = .{
            .tombstone = tombstone,
            .key = try allocator.dupe(u8, key),
            .value = if (tombstone) try allocator.dupe(u8, "") else try allocator.dupe(u8, value),
        };
        @memcpy(new_entries[pos + 1 ..], leaf.entries[pos..]);
        // 旧 entries 的 key/value 指针已拷贝到 new_entries（转移所有权），只释放数组
        allocator.free(leaf.entries);
        leaf.entries = new_entries;
        live_delta += @as(i64, @intCast(key.len + (if (tombstone) @as(usize, 0) else value.len) + 9));
        if (!tombstone) count_delta = 1;
    }

    // 记录旧页为脏
    dirty.append(allocator, page_no) catch {};

    // 分裂判定
    if (leaf.entries.len <= LEAF_MAX_ENTRIES) {
        const new_page = try store.allocPage();
        const pl = leafPayloadSize(leaf.entries);
        var payload_buf: [f2.PAGE_SIZE]u8 = undefined;
        _ = try encodeLeafPayload(payload_buf[0..pl], leaf.entries, store, dirty);
        try writeNodePage(store, new_page, f2.PAGE_TYPE_LEAF, @intCast(leaf.entries.len), payload_buf[0..pl]);
        return .{
            .new_child = new_page,
            .live_delta = live_delta,
            .count_delta = count_delta,
        };
    }
    // 分裂
    const mid = leaf.entries.len / 2;
    const right_entries = leaf.entries[mid..];
    const left_entries = leaf.entries[0..mid];
    const left_page = try store.allocPage();
    const left_pl = leafPayloadSize(left_entries);
    var left_buf: [f2.PAGE_SIZE]u8 = undefined;
    _ = try encodeLeafPayload(left_buf[0..left_pl], left_entries, store, dirty);
    try writeNodePage(store, left_page, f2.PAGE_TYPE_LEAF, @intCast(left_entries.len), left_buf[0..left_pl]);
    const right_page = try store.allocPage();
    const right_pl = leafPayloadSize(right_entries);
    var right_buf: [f2.PAGE_SIZE]u8 = undefined;
    _ = try encodeLeafPayload(right_buf[0..right_pl], right_entries, store, dirty);
    try writeNodePage(store, right_page, f2.PAGE_TYPE_LEAF, @intCast(right_entries.len), right_buf[0..right_pl]);
    const split_key = try allocator.dupe(u8, right_entries[0].key);
    return .{
        .new_child = left_page,
        .split_key = split_key,
        .split_right = right_page,
        .live_delta = live_delta,
        .count_delta = count_delta,
    };
}

fn insertIntoBranch(
    store: PageStore,
    allocator: std.mem.Allocator,
    page_no: u32,
    key: []const u8,
    value: []const u8,
    tombstone: bool,
    dirty: *std.ArrayList(u32),
) !InsertSub {
    const payload = try readNodePayload(store, page_no);
    var branch = try Branch.fromPayload(allocator, payload);
    defer branch.deinit();

    var live_delta: i64 = 0;
    var count_delta: i64 = 0;

    const ci = branch.findChild(key);
    const child_off = branch.children[ci];

    // 递归插入子节点
    const child_is_leaf = blk: {
        const cpayload = try readNodePayload(store, child_off);
        break :blk cpayload[0] == LEAF_KIND;
    };
    const sub = if (child_is_leaf)
        try insertIntoLeaf(store, allocator, child_off, key, value, tombstone, dirty)
    else
        try insertIntoBranch(store, allocator, child_off, key, value, tombstone, dirty);
    live_delta += sub.live_delta;
    count_delta += sub.count_delta;

    // 记录旧页为脏
    dirty.append(allocator, page_no) catch {};

    // 替换子指针
    branch.children[ci] = sub.new_child;

    if (sub.split_key) |sk| {
        // 子分裂，在 branch 插入新 key + 右子
        const new_keys = try allocator.alloc([]u8, branch.keys.len + 1);
        const new_children = try allocator.alloc(u32, branch.children.len + 1);
        @memcpy(new_keys[0..ci], branch.keys[0..ci]);
        new_keys[ci] = sk;
        @memcpy(new_keys[ci + 1 ..], branch.keys[ci..]);
        @memcpy(new_children[0 .. ci + 1], branch.children[0 .. ci + 1]);
        new_children[ci + 1] = sub.split_right;
        @memcpy(new_children[ci + 2 ..], branch.children[ci + 1 ..]);
        // 旧 keys/children 数组指针已转移（key 元素指针在 new_keys 中），只释放数组
        allocator.free(branch.keys);
        allocator.free(branch.children);
        branch.keys = new_keys;
        branch.children = new_children;

        // 分裂判定
        if (branch.children.len <= BRANCH_MAX_CHILDREN) {
            const new_page = try store.allocPage();
            const keys_slice = try allocator.alloc([]const u8, branch.keys.len);
            defer allocator.free(keys_slice);
            for (branch.keys, 0..) |k, i| keys_slice[i] = k;
            const pl = branchPayloadSize(keys_slice, branch.children);
            var buf: [f2.PAGE_SIZE]u8 = undefined;
            _ = encodeBranchPayload(buf[0..pl], keys_slice, branch.children);
            try writeNodePage(store, new_page, f2.PAGE_TYPE_BRANCH, @intCast(branch.children.len), buf[0..pl]);
            return .{
                .new_child = new_page,
                .live_delta = live_delta,
                .count_delta = count_delta,
            };
        }
        // 分裂 branch
        const mid = branch.keys.len / 2;
        const up_key = try allocator.dupe(u8, branch.keys[mid]);
        // 右半
        const right_keys = branch.keys[mid + 1 ..];
        const right_children = branch.children[mid + 1 ..];
        const right_page = try store.allocPage();
        const rkeys_slice = try allocator.alloc([]const u8, right_keys.len);
        defer allocator.free(rkeys_slice);
        for (right_keys, 0..) |k, i| rkeys_slice[i] = k;
        var rbuf: [f2.PAGE_SIZE]u8 = undefined;
        const rpl = branchPayloadSize(rkeys_slice, right_children);
        _ = encodeBranchPayload(rbuf[0..rpl], rkeys_slice, right_children);
        try writeNodePage(store, right_page, f2.PAGE_TYPE_BRANCH, @intCast(right_children.len), rbuf[0..rpl]);
        // 左半
        const left_keys = branch.keys[0..mid];
        const left_children = branch.children[0 .. mid + 1];
        const left_page = try store.allocPage();
        const lkeys_slice = try allocator.alloc([]const u8, left_keys.len);
        defer allocator.free(lkeys_slice);
        for (left_keys, 0..) |k, i| lkeys_slice[i] = k;
        var lbuf: [f2.PAGE_SIZE]u8 = undefined;
        const lpl = branchPayloadSize(lkeys_slice, left_children);
        _ = encodeBranchPayload(lbuf[0..lpl], lkeys_slice, left_children);
        try writeNodePage(store, left_page, f2.PAGE_TYPE_BRANCH, @intCast(left_children.len), lbuf[0..lpl]);
        // branch.deinit() 处理释放，不手动 free
        return .{
            .new_child = left_page,
            .split_key = up_key,
            .split_right = right_page,
            .live_delta = live_delta,
            .count_delta = count_delta,
        };
    }
    // 无分裂：写新 branch
    const new_page = try store.allocPage();
    const keys_slice = try allocator.alloc([]const u8, branch.keys.len);
    defer allocator.free(keys_slice);
    for (branch.keys, 0..) |k, i| keys_slice[i] = k;
    const pl = branchPayloadSize(keys_slice, branch.children);
    var buf: [f2.PAGE_SIZE]u8 = undefined;
    _ = encodeBranchPayload(buf[0..pl], keys_slice, branch.children);
    try writeNodePage(store, new_page, f2.PAGE_TYPE_BRANCH, @intCast(branch.children.len), buf[0..pl]);
    return .{
        .new_child = new_page,
        .live_delta = live_delta,
        .count_delta = count_delta,
    };
}

pub fn insert(
    allocator: std.mem.Allocator,
    store: PageStore,
    root: u32,
    key: []const u8,
    value: []const u8,
    tombstone: bool,
    dirty: *std.ArrayList(u32),
) !WriteResult {
    if (root == NULL_ROOT) {
        const new_page = try store.allocPage();
        var entries: [1]LeafEntry = .{.{ .tombstone = tombstone, .key = try allocator.dupe(u8, key), .value = try allocator.dupe(u8, if (tombstone) "" else value) }};
        defer {
            allocator.free(entries[0].key);
            allocator.free(entries[0].value);
        }
        const pl = leafPayloadSize(&entries);
        var buf: [f2.PAGE_SIZE]u8 = undefined;
        _ = try encodeLeafPayload(buf[0..pl], &entries, store, dirty);
        try writeNodePage(store, new_page, f2.PAGE_TYPE_LEAF, 1, buf[0..pl]);
        return .{
            .new_root = new_page,
            .live_delta = @intCast(key.len + (if (tombstone) @as(usize, 0) else value.len) + 9),
            .count_delta = if (tombstone) 0 else 1,
        };
    }

    const payload = try readNodePayload(store, root);
    const is_leaf = payload[0] == LEAF_KIND;

    const sub = if (is_leaf)
        try insertIntoLeaf(store, allocator, root, key, value, tombstone, dirty)
    else
        try insertIntoBranch(store, allocator, root, key, value, tombstone, dirty);

    if (sub.split_key) |sk| {
        // root 分裂：建新 root branch
        var keys: [1][]const u8 = .{sk};
        var children: [2]u32 = .{ sub.new_child, sub.split_right };
        const new_page = try store.allocPage();
        const pl = branchPayloadSize(&keys, &children);
        var buf: [f2.PAGE_SIZE]u8 = undefined;
        _ = encodeBranchPayload(buf[0..pl], &keys, &children);
        try writeNodePage(store, new_page, f2.PAGE_TYPE_BRANCH, 2, buf[0..pl]);
        allocator.free(sk);
        return .{
            .new_root = new_page,
            .live_delta = sub.live_delta,
            .count_delta = sub.count_delta,
        };
    }
    return .{
        .new_root = sub.new_child,
        .live_delta = sub.live_delta,
        .count_delta = sub.count_delta,
    };
}

// ===== 范围迭代器 =====

pub const Iterator = struct {
    allocator: std.mem.Allocator,
    store: PageStore,
    min: ?[]const u8,
    max: ?[]const u8,
    stack: std.ArrayList(StackFrame),
    cur_leaf: ?Leaf,
    cur_pos: usize,

    const StackFrame = struct {
        branch: Branch,
        child_idx: usize,
    };

    pub fn deinit(self: *Iterator) void {
        for (self.stack.items) |*fr| fr.branch.deinit();
        self.stack.deinit(self.allocator);
        if (self.cur_leaf) |*l| l.deinit();
    }

    pub fn next(self: *Iterator) !?LeafEntry {
        while (true) {
            if (self.cur_leaf) |*leaf| {
                while (self.cur_pos < leaf.entries.len) : (self.cur_pos += 1) {
                    const e = leaf.entries[self.cur_pos];
                    if (e.tombstone) continue;
                    if (self.min) |m| {
                        if (cmpKey(e.key, m) == .lt) continue;
                    }
                    if (self.max) |mx| {
                        if (cmpKey(e.key, mx) != .lt) return null;
                    }
                    self.cur_pos += 1;
                    return e;
                }
                leaf.deinit();
                self.cur_leaf = null;
            }
            if (!try self.descendToNextLeaf()) return null;
        }
    }

    fn descendToNextLeaf(self: *Iterator) !bool {
        while (self.stack.items.len > 0) {
            const top_i = self.stack.items.len - 1;
            self.stack.items[top_i].child_idx += 1;
            const ci = self.stack.items[top_i].child_idx;
            if (ci < self.stack.items[top_i].branch.children.len) {
                var cur = self.stack.items[top_i].branch.children[ci];
                var depth: u32 = 0;
                while (depth < 1000) : (depth += 1) {
                    const payload = try readNodePayload(self.store, cur);
                    if (payload[0] == LEAF_KIND) {
                        var _leaf_dirty = std.ArrayList(u32).empty;
                        defer _leaf_dirty.deinit(self.allocator);
                        self.cur_leaf = try Leaf.fromPayload(self.allocator, self.store, payload, &_leaf_dirty);
                        self.cur_pos = 0;
                        return true;
                    } else {
                        const br = try Branch.fromPayload(self.allocator, payload);
                        const first_child = br.children[0];
                        try self.stack.append(self.allocator, .{ .branch = br, .child_idx = 0 });
                        cur = first_child;
                    }
                }
                return false;
            } else {
                if (self.stack.pop()) |fr| {
                    var f = fr;
                    f.branch.deinit();
                }
            }
        }
        return false;
    }
};

pub fn select(allocator: std.mem.Allocator, store: PageStore, root: u32, min: ?[]const u8, max: ?[]const u8) !Iterator {
    var it: Iterator = .{
        .allocator = allocator,
        .store = store,
        .min = min,
        .max = max,
        .stack = .empty,
        .cur_leaf = null,
        .cur_pos = 0,
    };
    if (root == NULL_ROOT) return it;
    var cur = root;
    var depth: u32 = 0;
    var _leaf_dirty = std.ArrayList(u32).empty;
    defer _leaf_dirty.deinit(allocator);
    while (depth < 1000) : (depth += 1) {
        const payload = try readNodePayload(store, cur);
        if (payload[0] == LEAF_KIND) {
            it.cur_leaf = try Leaf.fromPayload(allocator, store, payload, &_leaf_dirty);
            it.cur_pos = 0;
            break;
        } else {
            var br = try Branch.fromPayload(allocator, payload);
            var ci: usize = 0;
            if (min) |m| ci = br.findChild(m);
            const next = br.children[ci];
            try it.stack.append(allocator, .{ .branch = br, .child_idx = ci });
            cur = next;
        }
    }
    return it;
}

// ===== 错误 =====
pub const Error = error{
    OutOfMemory,
    Truncated,
    CorruptCrc,
    IoError,
    MapFull,
    PageNotFound,
} || std.mem.Allocator.Error;
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

/// Fast read: skip CRC verification for hot read path.
/// COW guarantees pages are never modified while being read,
/// so CRC check is only needed on crash recovery / reopen.
pub fn readNodePayloadFast(store: PageStore, page_no: u32) ![]const u8 {
    const page = try store.readPage(page_no);
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

/// Borrowed get: returns a slice pointing directly into the page buffer.
/// No heap allocation for inline values. For overflow values, falls back
/// to allocator.dupe (caller must free overflow returns).
/// The returned slice is valid as long as the page is not freed — which
/// is guaranteed by MVCC COW (old pages are not overwritten).
/// For overflow values, returns null — use get() for those.
pub fn getBorrowed(store: PageStore, root: u32, key: []const u8) !?[]const u8 {
    if (root == NULL_ROOT) return null;
    var cur = root;
    var depth: u32 = 0;
    while (depth < 1000) : (depth += 1) {
        const payload = try readNodePayloadFast(store, cur);
        if (payload.len == 0) return error.Truncated;
        if (payload[0] == LEAF_KIND) {
            return findInLeafBorrowed(payload, key);
        } else {
            cur = try findInBranchPayload(payload, key);
        }
    }
    return error.Truncated;
}

/// Like findInLeaf but returns a borrowed slice into the page payload
/// for inline values. Returns null for overflow values (caller should
/// use get() for those) or tombstones.
fn findInLeafBorrowed(payload: []const u8, key: []const u8) !?[]const u8 {
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
                    // Overflow: can't return borrowed slice (spans multiple pages)
                    // Return null to signal caller to use get() instead
                    return null;
                }
                if (pos + vlen > payload.len) return error.Truncated;
                // Return borrowed slice directly into page payload
                return payload[pos .. pos + vlen];
            },
            .gt => return null,
        }
    }
    return null;
}

pub fn get(allocator: std.mem.Allocator, store: PageStore, root: u32, key: []const u8) !?[]u8 {
    if (root == NULL_ROOT) return null;
    var cur = root;
    var depth: u32 = 0;
    while (depth < 1000) : (depth += 1) {
        const payload = try readNodePayloadFast(store, cur);
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

/// Scan branch payload to find child index and children-section byte offset for a key.
/// Returns the child index (0..count-1) and the byte offset where the children
/// section starts in the payload (after the keys section).
fn findChildIdxAndOffset(payload: []const u8, key: []const u8) !struct {
    idx: usize,
    child: u32,
    children_offset: usize,
} {
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
    // pos is now at children section start
    if (pos + 4 * count > payload.len) return error.Truncated;
    const child = std.mem.readInt(u32, payload[pos + child_idx * 4 ..][0..4], .big);
    return .{ .idx = child_idx, .child = child, .children_offset = pos };
}

/// Fast path: copy old branch page + patch single child pointer.
/// Used when the child didn't split (no new key/child to insert into branch).
/// Zero heap allocations — just page copy + 4-byte write + checksum.
fn cowBranchNoSplit(
    store: PageStore,
    old_page_no: u32,
    child_idx: usize,
    children_offset: usize,
    new_child: u32,
) !u32 {
    // Copy old page to stack buffer first — allocPage/writePage may trigger
    // HashMap resize which invalidates the slice from readPage.
    const old_page = try store.readPage(old_page_no);
    var page_copy: [f2.PAGE_SIZE]u8 = undefined;
    @memcpy(&page_copy, old_page[0..f2.PAGE_SIZE]);

    const new_page_no = try store.allocPage();
    const new_page = try store.writePage(new_page_no);

    // Copy old page data to new page
    @memcpy(new_page[0..f2.PAGE_SIZE], &page_copy);

    // Update page_no in header (first 4 bytes, little-endian)
    std.mem.writeInt(u32, new_page[0..4], new_page_no, .little);

    // Patch child pointer (big-endian, as encoded by encodeBranchPayload)
    const child_byte_offset = f2.PAGE_HEADER_SIZE + children_offset + child_idx * 4;
    std.mem.writeInt(u32, new_page[child_byte_offset..][0..4], new_child, .big);

    // Recompute checksum
    const arr: *[f2.PAGE_SIZE]u8 = @ptrCast(new_page.ptr);
    f2.setPageChecksum(arr, f2.computePageChecksum(arr));

    return new_page_no;
}

fn insertIntoLeaf(
    store: PageStore,
    allocator: std.mem.Allocator,
    page_no: u32,
    key: []const u8,
    value: []const u8,
    tombstone: bool,
    dirty: *std.ArrayList(u32),
) !InsertSub {
    // Copy old page to stack buffer — allocPage may trigger HashMap resize.
    const old_page = try store.readPage(page_no);
    var old_page_buf: [f2.PAGE_SIZE]u8 = undefined;
    @memcpy(&old_page_buf, old_page[0..f2.PAGE_SIZE]);
    const old_payload = old_page_buf[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];

    // Scan leaf payload to find entry position and byte offsets.
    // Returns: entry index, found (key exists), byte offset of entry start,
    // byte offset after entry end, old entry metadata (for live_delta/count_delta).
    if (old_payload.len < 3) return error.Truncated;
    if (old_payload[0] != LEAF_KIND) return error.CorruptCrc;
    const old_count = std.mem.readInt(u16, old_payload[1..3], .big);

    var pos: usize = 3;
    var entry_idx: usize = 0;
    var found = false;
    var gt_break = false; // true if we broke at cmp == .gt (insert before this entry)
    var entry_start: usize = 0;
    var entry_end: usize = 0;
    var entries_end: usize = 3; // end of all entries (after header), updated as we scan
    var old_tombstone = false;
    var old_vlen: u32 = 0;
    var old_overflow_page: u32 = 0;
    var old_is_overflow = false;
    var old_key_len: u32 = 0;

    var i: usize = 0;
    while (i < old_count) : (i += 1) {
        if (pos + 1 + 4 > old_payload.len) return error.Truncated;
        const start = pos;
        const ts = old_payload[pos] == 1;
        pos += 1;
        const klen = std.mem.readInt(u32, old_payload[pos..][0..4], .big);
        pos += 4;
        if (pos + klen > old_payload.len) return error.Truncated;
        const ek = old_payload[pos .. pos + klen];
        pos += klen;
        if (pos + 4 > old_payload.len) return error.Truncated;
        const vlen = std.mem.readInt(u32, old_payload[pos..][0..4], .big);
        pos += 4;
        if (pos + 1 > old_payload.len) return error.Truncated;
        const flags = old_payload[pos];
        pos += 1;
        const is_ov = (flags & LEAF_FLAG_OVERFLOW != 0);
        if (is_ov) {
            if (pos + 4 > old_payload.len) return error.Truncated;
            // Don't read overflow page yet — only if this is the matching entry
            pos += 4;
        } else {
            if (pos + vlen > old_payload.len) return error.Truncated;
            pos += vlen;
        }

        const cmp = cmpKey(ek, key);
        if (cmp == .eq) {
            found = true;
            entry_idx = i;
            entry_start = start;
            entry_end = pos;
            old_tombstone = ts;
            old_vlen = vlen;
            old_is_overflow = is_ov;
            old_key_len = klen;
            if (is_ov) {
                // Read overflow page number (4 bytes after flags)
                old_overflow_page = std.mem.readInt(u32, old_payload[entry_start + 1 + 4 + klen + 4 + 1 ..][0..4], .little);
            }
            // Continue scanning to find entries_end
            i += 1;
            while (i < old_count) : (i += 1) {
                if (pos + 1 + 4 > old_payload.len) return error.Truncated;
                pos += 1;
                const klen2 = std.mem.readInt(u32, old_payload[pos..][0..4], .big);
                pos += 4;
                if (pos + klen2 > old_payload.len) return error.Truncated;
                pos += klen2;
                if (pos + 4 > old_payload.len) return error.Truncated;
                const vlen2 = std.mem.readInt(u32, old_payload[pos..][0..4], .big);
                pos += 4;
                if (pos + 1 > old_payload.len) return error.Truncated;
                const flags2 = old_payload[pos];
                pos += 1;
                if (flags2 & LEAF_FLAG_OVERFLOW != 0) {
                    if (pos + 4 > old_payload.len) return error.Truncated;
                    pos += 4;
                } else {
                    if (pos + vlen2 > old_payload.len) return error.Truncated;
                    pos += vlen2;
                }
            }
            entries_end = pos;
            break;
        } else if (cmp == .gt) {
            gt_break = true;
            entry_idx = i;
            entry_start = start;
            entry_end = start; // same as start — no entry to replace
            // Continue scanning to find entries_end
            entries_end = pos;
            i += 1;
            while (i < old_count) : (i += 1) {
                if (pos + 1 + 4 > old_payload.len) return error.Truncated;
                pos += 1;
                const klen2 = std.mem.readInt(u32, old_payload[pos..][0..4], .big);
                pos += 4;
                if (pos + klen2 > old_payload.len) return error.Truncated;
                pos += klen2;
                if (pos + 4 > old_payload.len) return error.Truncated;
                const vlen2 = std.mem.readInt(u32, old_payload[pos..][0..4], .big);
                pos += 4;
                if (pos + 1 > old_payload.len) return error.Truncated;
                const flags2 = old_payload[pos];
                pos += 1;
                if (flags2 & LEAF_FLAG_OVERFLOW != 0) {
                    if (pos + 4 > old_payload.len) return error.Truncated;
                    pos += 4;
                } else {
                    if (pos + vlen2 > old_payload.len) return error.Truncated;
                    pos += vlen2;
                }
            }
            entries_end = pos;
            break;
        }
        // cmp == .lt, continue scanning
        entries_end = pos;
    }
    if (!found and !gt_break) {
        // Key not found, loop completed — insert at end
        entry_idx = i;
        entry_start = entries_end;
        entry_end = entries_end;
    }

    // Compute live_delta and count_delta
    var live_delta: i64 = 0;
    var count_delta: i64 = 0;
    if (found) {
        // Overwrite: subtract old entry size
        const old_val_sz: usize = if (old_is_overflow) @as(usize, 4) else @as(usize, old_vlen);
        live_delta -= @as(i64, @intCast(old_key_len + old_val_sz + 9));
        if (!old_tombstone and tombstone) {
            count_delta = -1;
        } else if (old_tombstone and !tombstone) {
            count_delta = 1;
        }
    } else {
        if (!tombstone) count_delta = 1;
    }
    live_delta += @as(i64, @intCast(key.len + (if (tombstone) @as(usize, 0) else value.len) + 9));

    // Free old overflow pages if overwriting an overflow entry
    if (found and old_is_overflow) {
        freeOverflowPages(store, old_overflow_page, dirty, allocator);
    }

    // Determine new entry count
    const new_count: u16 = if (found) old_count else old_count + 1;

    // Mark old page as dirty
    dirty.append(allocator, page_no) catch {};

    // Check if split needed
    if (new_count > LEAF_MAX_ENTRIES) {
        // Split — fall back to decode/encode path
        return insertIntoLeafSplit(store, allocator, old_page_buf[0..], key, value, tombstone, dirty, found, live_delta, count_delta);
    }

    // Build new leaf payload in stack buffer (no heap allocation)
    var new_payload: [f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4]u8 = undefined;
    var wpos: usize = 0;

    // Header
    new_payload[wpos] = LEAF_KIND;
    wpos += 1;
    std.mem.writeInt(u16, new_payload[wpos..][0..2], new_count, .big);
    wpos += 2;

    // Copy entries before the insert/overwrite position
    const before_len = entry_start - 3; // subtract header (3 bytes)
    if (before_len > 0) {
        @memcpy(new_payload[wpos..][0..before_len], old_payload[3 .. 3 + before_len]);
        wpos += before_len;
    }

    // Write new entry
    new_payload[wpos] = if (tombstone) @as(u8, 1) else 0;
    wpos += 1;
    std.mem.writeInt(u32, new_payload[wpos..][0..4], @intCast(key.len), .big);
    wpos += 4;
    @memcpy(new_payload[wpos..][0..key.len], key);
    wpos += key.len;
    const val_len: u32 = if (tombstone) 0 else @intCast(value.len);
    std.mem.writeInt(u32, new_payload[wpos..][0..4], val_len, .big);
    wpos += 4;
    if (!tombstone and value.len > MAX_INLINE_VALUE) {
        // Overflow
        new_payload[wpos] = LEAF_FLAG_OVERFLOW;
        wpos += 1;
        const ov_page = try writeOverflowPages(store, value);
        std.mem.writeInt(u32, new_payload[wpos..][0..4], ov_page, .little);
        wpos += 4;
    } else {
        new_payload[wpos] = 0;
        wpos += 1;
        if (!tombstone) {
            @memcpy(new_payload[wpos..][0..value.len], value);
            wpos += value.len;
        }
    }

    // Copy entries after the insert/overwrite position
    if (found) {
        // Overwrite: copy entries after the old entry up to entries_end
        const after_len = entries_end - entry_end;
        if (after_len > 0) {
            @memcpy(new_payload[wpos..][0..after_len], old_payload[entry_end .. entry_end + after_len]);
            wpos += after_len;
        }
    } else {
        // Insert: copy entries from entry_start to entries_end (actual entry data, not padding)
        const after_len = entries_end - entry_start;
        if (after_len > 0) {
            @memcpy(new_payload[wpos..][0..after_len], old_payload[entry_start .. entry_start + after_len]);
            wpos += after_len;
        }
    }

    // Write to new page
    const new_page = try store.allocPage();
    try writeNodePage(store, new_page, f2.PAGE_TYPE_LEAF, new_count, new_payload[0..wpos]);

    return .{
        .new_child = new_page,
        .live_delta = live_delta,
        .count_delta = count_delta,
    };
}

/// Split path: decode leaf, split into two pages, return split result.
/// Used when the leaf is full and needs to split.
fn insertIntoLeafSplit(
    store: PageStore,
    allocator: std.mem.Allocator,
    old_page: []const u8,
    key: []const u8,
    value: []const u8,
    tombstone: bool,
    dirty: *std.ArrayList(u32),
    found: bool,
    live_delta: i64,
    count_delta: i64,
) !InsertSub {
    // Decode the old leaf using the copied page buffer
    const old_payload = old_page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
    var leaf = try Leaf.fromPayload(allocator, store, old_payload, dirty);
    defer leaf.deinit();

    // Apply the insert/overwrite to the in-memory leaf
    const pos = leaf.findPos(key);
    if (found) {
        // Overwrite existing entry
        const old_entry = leaf.entries[pos];
        allocator.free(old_entry.key);
        allocator.free(old_entry.value);
        leaf.entries[pos] = .{
            .tombstone = tombstone,
            .key = try allocator.dupe(u8, key),
            .value = if (tombstone) try allocator.dupe(u8, "") else try allocator.dupe(u8, value),
        };
    } else {
        // Insert new entry
        const new_entries = try allocator.alloc(LeafEntry, leaf.entries.len + 1);
        @memcpy(new_entries[0..pos], leaf.entries[0..pos]);
        new_entries[pos] = .{
            .tombstone = tombstone,
            .key = try allocator.dupe(u8, key),
            .value = if (tombstone) try allocator.dupe(u8, "") else try allocator.dupe(u8, value),
        };
        @memcpy(new_entries[pos + 1 ..], leaf.entries[pos..]);
        allocator.free(leaf.entries);
        leaf.entries = new_entries;
    }

    // Split
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

    // Fast path: find child index by scanning raw payload (no decode/alloc)
    const loc = try findChildIdxAndOffset(payload, key);
    const child_off = loc.child;

    // Recursively insert into child
    const child_is_leaf = blk: {
        const cpayload = try readNodePayload(store, child_off);
        break :blk cpayload[0] == LEAF_KIND;
    };
    const sub = if (child_is_leaf)
        try insertIntoLeaf(store, allocator, child_off, key, value, tombstone, dirty)
    else
        try insertIntoBranch(store, allocator, child_off, key, value, tombstone, dirty);

    const live_delta: i64 = sub.live_delta;
    const count_delta: i64 = sub.count_delta;

    // Mark old page as dirty
    dirty.append(allocator, page_no) catch {};

    if (sub.split_key == null) {
        // Fast path: child didn't split — copy page + patch child pointer
        const new_page = try cowBranchNoSplit(store, page_no, loc.idx, loc.children_offset, sub.new_child);
        return .{
            .new_child = new_page,
            .live_delta = live_delta,
            .count_delta = count_delta,
        };
    }

    // Slow path: child split — re-read payload (recursive insert may have
    // allocated pages, invalidating the earlier borrowed slice), decode branch,
    // insert new key + child, encode
    const fresh_payload = try readNodePayload(store, page_no);
    var branch = try Branch.fromPayload(allocator, fresh_payload);
    defer branch.deinit();

    const ci = loc.idx;

    // Replace child pointer
    branch.children[ci] = sub.new_child;

    // Insert new key + right child at position ci
    const sk = sub.split_key.?;
    const new_keys = try allocator.alloc([]u8, branch.keys.len + 1);
    const new_children = try allocator.alloc(u32, branch.children.len + 1);
    @memcpy(new_keys[0..ci], branch.keys[0..ci]);
    new_keys[ci] = sk;
    @memcpy(new_keys[ci + 1 ..], branch.keys[ci..]);
    @memcpy(new_children[0 .. ci + 1], branch.children[0 .. ci + 1]);
    new_children[ci + 1] = sub.split_right;
    @memcpy(new_children[ci + 2 ..], branch.children[ci + 1 ..]);
    // Old keys/children arrays: key pointers transferred to new_keys, only free arrays
    allocator.free(branch.keys);
    allocator.free(branch.children);
    branch.keys = new_keys;
    branch.children = new_children;

    // Split check
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
    // Split branch
    const mid = branch.keys.len / 2;
    const up_key = try allocator.dupe(u8, branch.keys[mid]);
    // Right half
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
    // Left half
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
    return .{
        .new_child = left_page,
        .split_key = up_key,
        .split_right = right_page,
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

// ===== 批量插入（单 txn 内共享 COW 路径）=====

/// 批量插入多条 entry，沿 B-tree 路径一次遍历。
/// 同一 leaf 范围内的 entry 只复制一次页，避免逐条 COW。
/// entries 必须按 key 排序（升序），同 key 取最后一条。
pub fn insertBatch(
    allocator: std.mem.Allocator,
    store: PageStore,
    root: u32,
    entries: []const LeafEntry,
    dirty: *std.ArrayList(u32),
) !WriteResult {
    if (entries.len == 0) {
        return .{ .new_root = root, .live_delta = 0, .count_delta = 0 };
    }

    if (root == NULL_ROOT) {
        // Fresh tree: build first leaf from all entries (may split)
        return insertBatchFresh(allocator, store, entries, dirty);
    }

    // Guard: if batch is large, fallback to per-entry insert for correctness.
    // The shared COW fast path only works when entries fit in existing leaves
    // without causing multi-splits (which require branch-level coordination).
    if (entries.len > LEAF_MAX_ENTRIES) {
        return insertBatchFallback(allocator, store, root, entries, dirty);
    }

    // Read root to determine type
    const payload = try readNodePayloadFast(store, root);
    const is_leaf = payload[0] == LEAF_KIND;

    const sub = if (is_leaf)
        try insertBatchIntoLeaf(store, allocator, root, entries, dirty)
    else
        try insertBatchIntoBranch(store, allocator, root, entries, dirty);

    if (sub.split_key) |sk| {
        // Root split: create new root branch
        var keys: [1][]const u8 = .{sk};
        var children: [2]u32 = .{ sub.new_child, sub.split_right };
        const new_page = try store.allocPage();
        const pl = branchPayloadSize(&keys, &children);
        var buf: [f2.PAGE_SIZE]u8 = undefined;
        _ = encodeBranchPayload(buf[0..pl], &keys, &children);
        try writeNodePage(store, new_page, f2.PAGE_TYPE_BRANCH, 2, buf[0..pl]);
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

/// Fresh tree: first insert, build leaf(s) from sorted entries
fn insertBatchFresh(
    allocator: std.mem.Allocator,
    store: PageStore,
    entries: []const LeafEntry,
    dirty: *std.ArrayList(u32),
) !WriteResult {
    if (entries.len <= LEAF_MAX_ENTRIES) {
        // Fits in one leaf
        const new_page = try store.allocPage();
        const pl = leafPayloadSize(entries);
        var buf: [f2.PAGE_SIZE]u8 = undefined;
        _ = try encodeLeafPayload(buf[0..pl], entries, store, dirty);
        try writeNodePage(store, new_page, f2.PAGE_TYPE_LEAF, @intCast(entries.len), buf[0..pl]);
        var live: i64 = 0;
        var count: i64 = 0;
        for (entries) |e| {
            live += @intCast(e.key.len + (if (e.tombstone) @as(usize, 0) else e.value.len) + 9);
            if (!e.tombstone) count += 1;
        }
        return .{ .new_root = new_page, .live_delta = live, .count_delta = count };
    }
    // Too many entries for single leaf — fallback to per-entry insert
    var new_root: u32 = NULL_ROOT;
    var live: i64 = 0;
    var count: i64 = 0;
    for (entries) |e| {
        const wr = try insert(allocator, store, new_root, e.key, e.value, e.tombstone, dirty);
        new_root = wr.new_root;
        live += wr.live_delta;
        count += wr.count_delta;
    }
    return .{ .new_root = new_root, .live_delta = live, .count_delta = count };
}

/// Split sorted entries into multiple leaves, build branch tree
fn insertBatchSplitLeaves(
    allocator: std.mem.Allocator,
    store: PageStore,
    entries: []const LeafEntry,
    dirty: *std.ArrayList(u32),
) !WriteResult {
    // Build leaves of LEAF_MAX_ENTRIES each
    var leaf_pages = std.ArrayList(u32).empty;
    defer leaf_pages.deinit(allocator);
    var split_keys = std.ArrayList([]const u8).empty;
    defer split_keys.deinit(allocator);
    var live: i64 = 0;
    var count: i64 = 0;

    var pos: usize = 0;
    while (pos < entries.len) {
        const chunk_len = @min(LEAF_MAX_ENTRIES, entries.len - pos);
        const chunk = entries[pos .. pos + chunk_len];
        const page = try store.allocPage();
        const pl = leafPayloadSize(chunk);
        var buf: [f2.PAGE_SIZE]u8 = undefined;
        _ = try encodeLeafPayload(buf[0..pl], chunk, store, dirty);
        try writeNodePage(store, page, f2.PAGE_TYPE_LEAF, @intCast(chunk_len), buf[0..pl]);
        try leaf_pages.append(allocator, page);
        if (pos + chunk_len < entries.len) {
            try split_keys.append(allocator, entries[pos + chunk_len].key);
        }
        for (chunk) |e| {
            live += @intCast(e.key.len + (if (e.tombstone) @as(usize, 0) else e.value.len) + 9);
            if (!e.tombstone) count += 1;
        }
        pos += chunk_len;
    }

    // Build branch tree from leaf pages
    // Simple case: if only 2 leaves, single branch
    if (leaf_pages.items.len <= BRANCH_MAX_CHILDREN) {
        const new_root = try store.allocPage();
        const pl = branchPayloadSize(split_keys.items, leaf_pages.items);
        var buf: [f2.PAGE_SIZE]u8 = undefined;
        _ = encodeBranchPayload(buf[0..pl], split_keys.items, leaf_pages.items);
        try writeNodePage(store, new_root, f2.PAGE_TYPE_BRANCH, @intCast(leaf_pages.items.len), buf[0..pl]);
        return .{ .new_root = new_root, .live_delta = live, .count_delta = count };
    }
    // Multiple branches needed — build multi-level tree
    // For now, build one level at a time
    var current_pages = leaf_pages.items;
    var current_keys = split_keys.items;
    while (current_pages.len > BRANCH_MAX_CHILDREN) {
        var new_pages = std.ArrayList(u32).empty;
        defer new_pages.deinit(allocator);
        var new_keys = std.ArrayList([]const u8).empty;
        defer new_keys.deinit(allocator);
        var i: usize = 0;
        while (i < current_pages.len) {
            const chunk_len = @min(BRANCH_MAX_CHILDREN, current_pages.len - i);
            const children = current_pages[i .. i + chunk_len];
            const keys = current_keys[i .. i + chunk_len - 1];
            const page = try store.allocPage();
            const pl = branchPayloadSize(keys, children);
            var buf: [f2.PAGE_SIZE]u8 = undefined;
            _ = encodeBranchPayload(buf[0..pl], keys, children);
            try writeNodePage(store, page, f2.PAGE_TYPE_BRANCH, @intCast(children.len), buf[0..pl]);
            try new_pages.append(allocator, page);
            if (i + chunk_len < current_pages.len) {
                try new_keys.append(allocator, current_keys[i + chunk_len - 1]);
            }
            i += chunk_len;
        }
        current_pages = new_pages.items;
        current_keys = new_keys.items;
    }
    // Final root branch
    const new_root = try store.allocPage();
    const pl = branchPayloadSize(current_keys, current_pages);
    var buf: [f2.PAGE_SIZE]u8 = undefined;
    _ = encodeBranchPayload(buf[0..pl], current_keys, current_pages);
    try writeNodePage(store, new_root, f2.PAGE_TYPE_BRANCH, @intCast(current_pages.len), buf[0..pl]);
    return .{ .new_root = new_root, .live_delta = live, .count_delta = count };
}

/// Find the range of entries that belong to a given leaf (by scanning branch keys)
fn entriesForChild(entries: []const LeafEntry, branch_keys: [][]u8, ci: usize) []const LeafEntry {
    // entries[lo..hi] belong to child ci
    // lo: first entry where key >= (ci == 0 ? -inf : branch_keys[ci-1] + 1)
    // hi: first entry where key >= branch_keys[ci] (or end)
    // Simplified: find entries whose key falls in child ci's range
    var lo: usize = 0;
    if (ci > 0) {
        // Binary search for first entry > branch_keys[ci-1]
        // (child ci holds keys > branch_keys[ci-1])
        var l: usize = 0;
        var h: usize = entries.len;
        while (l < h) {
            const mid = l + (h - l) / 2;
            if (cmpKey(entries[mid].key, branch_keys[ci - 1]) != .gt) {
                l = mid + 1;
            } else {
                h = mid;
            }
        }
        lo = l;
    }
    var hi: usize = entries.len;
    if (ci < branch_keys.len) {
        // Find first entry >= branch_keys[ci]
        // (entries >= branch_keys[ci] belong to child ci+1)
        var l: usize = lo;
        var h: usize = entries.len;
        while (l < h) {
            const mid = l + (h - l) / 2;
            switch (cmpKey(entries[mid].key, branch_keys[ci])) {
                .lt => l = mid + 1,
                .eq, .gt => h = mid,
            }
        }
        hi = l;
    }
    return entries[lo..hi];
}

/// Batch insert into leaf node
fn insertBatchIntoLeaf(
    store: PageStore,
    allocator: std.mem.Allocator,
    page_no: u32,
    entries: []const LeafEntry,
    dirty: *std.ArrayList(u32),
) !InsertSub {
    // No guard here — the caller (insertBatch) guards at the top level.
    // This function only handles batches that fit (at most one split).
    const old_page = try store.readPage(page_no);
    var old_page_buf: [f2.PAGE_SIZE]u8 = undefined;
    @memcpy(&old_page_buf, old_page[0..f2.PAGE_SIZE]);
    const old_payload = old_page_buf[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];

    var leaf = try Leaf.fromPayload(allocator, store, old_payload, dirty);
    defer leaf.deinit();

    var live_delta: i64 = 0;
    var count_delta: i64 = 0;

    for (entries) |e| {
        const pos = leaf.findPos(e.key);
        if (pos < leaf.entries.len and cmpKey(leaf.entries[pos].key, e.key) == .eq) {
            // Overwrite
            const old = leaf.entries[pos];
            live_delta -= @as(i64, @intCast(old.key.len + old.value.len + 9));
            allocator.free(old.key);
            allocator.free(old.value);
            if (!old.tombstone and e.tombstone) count_delta -= 1;
            if (old.tombstone and !e.tombstone) count_delta += 1;
            leaf.entries[pos] = .{
                .tombstone = e.tombstone,
                .key = try allocator.dupe(u8, e.key),
                .value = if (e.tombstone) try allocator.dupe(u8, "") else try allocator.dupe(u8, e.value),
            };
            live_delta += @as(i64, @intCast(e.key.len + (if (e.tombstone) @as(usize, 0) else e.value.len) + 9));
        } else {
            // Insert
            const new_entries = try allocator.alloc(LeafEntry, leaf.entries.len + 1);
            @memcpy(new_entries[0..pos], leaf.entries[0..pos]);
            new_entries[pos] = .{
                .tombstone = e.tombstone,
                .key = try allocator.dupe(u8, e.key),
                .value = if (e.tombstone) try allocator.dupe(u8, "") else try allocator.dupe(u8, e.value),
            };
            @memcpy(new_entries[pos + 1 ..], leaf.entries[pos..]);
            allocator.free(leaf.entries);
            leaf.entries = new_entries;
            live_delta += @as(i64, @intCast(e.key.len + (if (e.tombstone) @as(usize, 0) else e.value.len) + 9));
            if (!e.tombstone) count_delta += 1;
        }
    }

    // Mark old page as dirty
    dirty.append(allocator, page_no) catch {};

    // Split check
    if (leaf.entries.len <= LEAF_MAX_ENTRIES) {
        const new_page = try store.allocPage();
        const pl = leafPayloadSize(leaf.entries);
        var buf: [f2.PAGE_SIZE]u8 = undefined;
        _ = try encodeLeafPayload(buf[0..pl], leaf.entries, store, dirty);
        try writeNodePage(store, new_page, f2.PAGE_TYPE_LEAF, @intCast(leaf.entries.len), buf[0..pl]);
        return .{ .new_child = new_page, .live_delta = live_delta, .count_delta = count_delta };
    }
    // Multiple pages needed — chunk into LEAF_MAX_ENTRIES, build leaf pages + branch tree
    var leaf_pages = std.ArrayList(u32).empty;
    defer leaf_pages.deinit(allocator);
    var split_keys = std.ArrayList([]const u8).empty;
    defer split_keys.deinit(allocator);
    var pos: usize = 0;
    while (pos < leaf.entries.len) {
        const chunk_len = @min(LEAF_MAX_ENTRIES, leaf.entries.len - pos);
        const chunk = leaf.entries[pos .. pos + chunk_len];
        const page = try store.allocPage();
        const pl = leafPayloadSize(chunk);
        var buf: [f2.PAGE_SIZE]u8 = undefined;
        _ = try encodeLeafPayload(buf[0..pl], chunk, store, dirty);
        try writeNodePage(store, page, f2.PAGE_TYPE_LEAF, @intCast(chunk_len), buf[0..pl]);
        try leaf_pages.append(allocator, page);
        if (pos + chunk_len < leaf.entries.len) {
            try split_keys.append(allocator, leaf.entries[pos + chunk_len].key);
        }
        pos += chunk_len;
    }
    // Build branch tree from leaf pages
    var current_pages = leaf_pages.items;
    var current_keys = split_keys.items;
    while (current_pages.len > BRANCH_MAX_CHILDREN) {
        var new_pages = std.ArrayList(u32).empty;
        defer new_pages.deinit(allocator);
        var new_keys = std.ArrayList([]const u8).empty;
        defer new_keys.deinit(allocator);
        var i: usize = 0;
        while (i < current_pages.len) {
            const chunk_len = @min(BRANCH_MAX_CHILDREN, current_pages.len - i);
            const children = current_pages[i .. i + chunk_len];
            const keys = current_keys[i .. i + chunk_len - 1];
            const page = try store.allocPage();
            const pl = branchPayloadSize(keys, children);
            var buf: [f2.PAGE_SIZE]u8 = undefined;
            _ = encodeBranchPayload(buf[0..pl], keys, children);
            try writeNodePage(store, page, f2.PAGE_TYPE_BRANCH, @intCast(children.len), buf[0..pl]);
            try new_pages.append(allocator, page);
            if (i + chunk_len < current_pages.len) {
                try new_keys.append(allocator, current_keys[i + chunk_len - 1]);
            }
            i += chunk_len;
        }
        current_pages = new_pages.items;
        current_keys = new_keys.items;
    }
    // Final root branch
    const new_page = try store.allocPage();
    const pl = branchPayloadSize(current_keys, current_pages);
    var buf: [f2.PAGE_SIZE]u8 = undefined;
    _ = encodeBranchPayload(buf[0..pl], current_keys, current_pages);
    try writeNodePage(store, new_page, f2.PAGE_TYPE_BRANCH, @intCast(current_pages.len), buf[0..pl]);
    return .{ .new_child = new_page, .live_delta = live_delta, .count_delta = count_delta };
}

/// Fallback: when batch is too large for shared COW path, use per-entry insert.
/// Correct but slower — the shared COW optimization only applies to small batches.
fn insertBatchFallback(
    allocator: std.mem.Allocator,
    store: PageStore,
    root: u32,
    entries: []const LeafEntry,
    dirty: *std.ArrayList(u32),
) !WriteResult {
    var new_root = root;
    var live_delta: i64 = 0;
    var count_delta: i64 = 0;

    for (entries) |e| {
        const wr = try insert(allocator, store, new_root, e.key, e.value, e.tombstone, dirty);
        new_root = wr.new_root;
        live_delta += wr.live_delta;
        count_delta += wr.count_delta;
    }

    return .{ .new_root = new_root, .live_delta = live_delta, .count_delta = count_delta };
}

/// Fallback: when entries exceed leaf capacity, use per-entry insertIntoLeaf.
fn insertBatchIntoLeafFallback(
    store: PageStore,
    allocator: std.mem.Allocator,
    page_no: u32,
    entries: []const LeafEntry,
    dirty: *std.ArrayList(u32),
) !InsertSub {
    // Fallback: use per-entry insertIntoLeaf (not insert, which expects root).
    // This keeps the same COW semantics as the branch caller expects.
    var new_child = page_no;
    var live_delta: i64 = 0;
    var count_delta: i64 = 0;
    var pending_split_key: ?[]u8 = null;
    var pending_split_right: u32 = 0;

    for (entries) |e| {
        const sub = try insertIntoLeaf(store, allocator, new_child, e.key, e.value, e.tombstone, dirty);
        new_child = sub.new_child;
        live_delta += sub.live_delta;
        count_delta += sub.count_delta;
        // If this entry caused a split, we need to propagate it.
        // But insertIntoLeaf only splits within the leaf — the branch caller
        // will see the split_key/split_right from the last InsertSub.
        if (sub.split_key) |sk| {
            if (pending_split_key) |old| allocator.free(old);
            pending_split_key = sk;
            pending_split_right = sub.split_right;
        }
    }

    return .{
        .new_child = new_child,
        .split_key = pending_split_key,
        .split_right = pending_split_right,
        .live_delta = live_delta,
        .count_delta = count_delta,
    };
}

/// Batch insert into branch node
fn insertBatchIntoBranch(
    store: PageStore,
    allocator: std.mem.Allocator,
    page_no: u32,
    entries: []const LeafEntry,
    dirty: *std.ArrayList(u32),
) !InsertSub {
    const payload = try readNodePayload(store, page_no);
    var branch = try Branch.fromPayload(allocator, payload);
    defer branch.deinit();

    var live_delta: i64 = 0;
    var count_delta: i64 = 0;

    // Mark old page as dirty
    dirty.append(allocator, page_no) catch {};

    // Process each child that has entries
    var ci: usize = 0;
    while (ci < branch.children.len and entries.len > 0) {
        // Find entries for this child
        var lo: usize = 0;
        if (ci > 0) {
            // entries > branch.keys[ci-1]
            // Binary search for first entry > branch.keys[ci-1]
            var l: usize = 0;
            var h: usize = entries.len;
            while (l < h) {
                const mid = l + (h - l) / 2;
                if (cmpKey(entries[mid].key, branch.keys[ci - 1]) != .gt) {
                    l = mid + 1;
                } else {
                    h = mid;
                }
            }
            lo = l;
        }
        var hi: usize = entries.len;
        if (ci < branch.keys.len) {
            // entries < branch.keys[ci]
            var l: usize = lo;
            var h: usize = entries.len;
            while (l < h) {
                const mid = l + (h - l) / 2;
                switch (cmpKey(entries[mid].key, branch.keys[ci])) {
                    .lt => l = mid + 1,
                    .eq, .gt => h = mid,
                }
            }
            hi = l;
        }
        if (lo < hi) {
            const child_entries = entries[lo..hi];
            const child_off = branch.children[ci];

            // Check if child is leaf or branch
            const child_payload = try readNodePayloadFast(store, child_off);
            const child_is_leaf = child_payload[0] == LEAF_KIND;

            const sub = if (child_is_leaf)
                try insertBatchIntoLeaf(store, allocator, child_off, child_entries, dirty)
            else
                try insertBatchIntoBranch(store, allocator, child_off, child_entries, dirty);

            live_delta += sub.live_delta;
            count_delta += sub.count_delta;
            branch.children[ci] = sub.new_child;

            if (sub.split_key) |sk| {
                // Child split: insert new key + child
                const new_keys = try allocator.alloc([]u8, branch.keys.len + 1);
                const new_children = try allocator.alloc(u32, branch.children.len + 1);
                @memcpy(new_keys[0..ci], branch.keys[0..ci]);
                new_keys[ci] = sk;
                @memcpy(new_keys[ci + 1 ..], branch.keys[ci..]);
                @memcpy(new_children[0 .. ci + 1], branch.children[0 .. ci + 1]);
                new_children[ci + 1] = sub.split_right;
                @memcpy(new_children[ci + 2 ..], branch.children[ci + 1 ..]);
                allocator.free(branch.keys);
                allocator.free(branch.children);
                branch.keys = new_keys;
                branch.children = new_children;
            }
        }
        ci += 1;
    }

    // Check branch split
    if (branch.children.len <= BRANCH_MAX_CHILDREN) {
        const new_page = try store.allocPage();
        const keys_slice = try allocator.alloc([]const u8, branch.keys.len);
        defer allocator.free(keys_slice);
        for (branch.keys, 0..) |k, i| keys_slice[i] = k;
        const pl = branchPayloadSize(keys_slice, branch.children);
        var buf: [f2.PAGE_SIZE]u8 = undefined;
        _ = encodeBranchPayload(buf[0..pl], keys_slice, branch.children);
        try writeNodePage(store, new_page, f2.PAGE_TYPE_BRANCH, @intCast(branch.children.len), buf[0..pl]);
        return .{ .new_child = new_page, .live_delta = live_delta, .count_delta = count_delta };
    }
    // Split branch
    const mid = branch.keys.len / 2;
    const up_key = try allocator.dupe(u8, branch.keys[mid]);
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
    return .{ .new_child = left_page, .split_key = up_key, .split_right = right_page, .live_delta = live_delta, .count_delta = count_delta };
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
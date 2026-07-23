//! btree.zig — 不可变 B-tree（COW 插入/删除、查找、范围迭代）
//! M3。全部对 Store（内存或文件）操作；节点存逻辑偏移。
//! 排序按 key 字节序（memcmp）。
const std = @import("std");
const f = @import("format.zig");
const store_mod = @import("store.zig");

const Store = store_mod.Store;

/// 叶节点目标最大条目数（payload ≤ ~8KB）。粗略：每条 entry ≈ 1+4+klen+4+vlen。
/// 用条目数控制分裂，简化实现。
pub const LEAF_MAX_ENTRIES: usize = 32;
pub const LEAF_MIN_ENTRIES: usize = LEAF_MAX_ENTRIES / 2;
pub const BRANCH_MAX_CHILDREN: usize = 32;
pub const BRANCH_MIN_CHILDREN: usize = BRANCH_MAX_CHILDREN / 2;

/// 空树哨兵。不使用 0（0 是合法逻辑偏移——首条 append 返回 0）。
pub const NULL_ROOT: u64 = std.math.maxInt(u64);

pub const Error = error{
    OutOfMemory,
    Truncated,
    CorruptCrc,
    BadMagic,
    BadVersion,
    IoError,
    Empty,
} || std.mem.Allocator.Error;

/// COW 插入/删除结果
pub const WriteResult = struct {
    /// 新 root 逻辑偏移（0 表示空树）
    new_root: u64,
    /// 本次写新增的 live 字节数（正）或减少的（负，用于 dirt 统计）
    live_delta: i64,
    /// 本次写产生的垃圾字节数（旧路径节点大小之和）
    dirt_delta: u64,
    /// entry_count 变化（+1 / 0 / -1）
    count_delta: i64,
};

// ===== key 比较 =====
pub fn cmpKey(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

// ===== 临时节点解码辅助 =====
// 从 store 读一个节点记录并解码。返回 payload 切片（allocator 分配的拷贝）。

pub fn readRecord(allocator: std.mem.Allocator, s: Store, offset: u64) ![]u8 {
    // 先读 len(4)，再读完整记录。
    var len_buf: [4]u8 = undefined;
    const n = try s.read(&len_buf, offset);
    if (n < 4) return error.Truncated;
    const payload_len = std.mem.readInt(u32, &len_buf, .big);
    const total = f.REC_LEN_SIZE + payload_len + f.REC_CRC_SIZE;
    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);
    var read_total: usize = 0;
    while (read_total < total) {
        const got = try s.read(buf[read_total..], offset + @as(u64, @intCast(read_total)));
        if (got == 0) return error.Truncated;
        read_total += got;
    }
    return buf;
}

pub fn decodeNodePayload(rec: []const u8) ![]const u8 {
    return f.decodeRecord(rec) catch return error.CorruptCrc;
}

// ===== 叶节点内存表示（用于 COW 操作） =====
pub const LeafEntry = f.LeafEntry;

pub const Leaf = struct {
    entries: std.ArrayList(LeafEntry),

    pub fn init(allocator: std.mem.Allocator) Leaf {
        _ = allocator;
        return .{ .entries = .empty };
    }
    pub fn deinit(self: *Leaf, allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| {
            allocator.free(e.key);
            allocator.free(e.value);
        }
        self.entries.deinit(allocator);
    }

    pub fn fromPayload(allocator: std.mem.Allocator, payload: []const u8) !Leaf {
        if (payload.len < 3) return error.Truncated;
        if (payload[0] != @intFromEnum(f.NodeKind.leaf)) return error.CorruptCrc;
        const count = std.mem.readInt(u16, payload[1..3], .big);
        const dec = try allocator.alloc(f.DecodedLeafEntry, count);
        defer allocator.free(dec);
        f.decodeLeafPayload(payload, dec) catch return error.CorruptCrc;
        var leaf = Leaf.init(allocator);
        try leaf.entries.ensureTotalCapacity(allocator, count);
        for (dec) |e| {
            try leaf.entries.append(allocator, .{
                .tombstone = e.tombstone,
                .key = try allocator.dupe(u8, e.key),
                .value = try allocator.dupe(u8, e.value),
            });
        }
        return leaf;
    }

    pub fn toRecord(self: *const Leaf, allocator: std.mem.Allocator) ![]u8 {
        const payload_size = f.leafPayloadSize(.{ .entries = self.entries.items });
        const total = f.recordTotalSize(payload_size);
        const buf = try allocator.alloc(u8, total);
        errdefer allocator.free(buf);
        // 直接写 len + payload + crc，避免 encodeRecord 别名
        std.mem.writeInt(u32, buf[0..4], @intCast(payload_size), .big);
        _ = f.encodeLeafPayload(buf[f.REC_LEN_SIZE..][0..payload_size], .{ .entries = self.entries.items });
        var crc = f.Crc32.init();
        crc.update(buf[0 .. f.REC_LEN_SIZE + payload_size]);
        std.mem.writeInt(u32, buf[f.REC_LEN_SIZE + payload_size ..][0..4], crc.final(), .big);
        return buf;
    }

    /// 二分查找 key 应插入位置（返回第一个 >= key 的 index）。
    pub fn findPos(self: *const Leaf, key: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (cmpKey(self.entries.items[mid].key, key)) {
                .lt => lo = mid + 1,
                .eq, .gt => hi = mid,
            }
        }
        return lo;
    }
};

// ===== 内部节点内存表示 =====
pub const Branch = struct {
    keys: std.ArrayList([]u8),
    children: std.ArrayList(u64),

    pub fn init(allocator: std.mem.Allocator) Branch {
        _ = allocator;
        return .{ .keys = .empty, .children = .empty };
    }
    pub fn deinit(self: *Branch, allocator: std.mem.Allocator) void {
        for (self.keys.items) |k| allocator.free(k);
        self.keys.deinit(allocator);
        self.children.deinit(allocator);
    }

    pub fn fromPayload(allocator: std.mem.Allocator, payload: []const u8) !Branch {
        if (payload.len < 3) return error.Truncated;
        if (payload[0] != @intFromEnum(f.NodeKind.branch)) return error.CorruptCrc;
        const count = std.mem.readInt(u16, payload[1..3], .big);
        const keys_tmp = try allocator.alloc([]const u8, count - 1);
        defer allocator.free(keys_tmp);
        const children_tmp = try allocator.alloc(u64, count);
        defer allocator.free(children_tmp);
        f.decodeBranchPayload(payload, keys_tmp, children_tmp) catch return error.CorruptCrc;
        var b = Branch.init(allocator);
        try b.keys.ensureTotalCapacity(allocator, count - 1);
        try b.children.ensureTotalCapacity(allocator, count);
        for (keys_tmp) |k| try b.keys.append(allocator, try allocator.dupe(u8, k));
        for (children_tmp) |c| try b.children.append(allocator, c);
        return b;
    }

    pub fn toRecord(self: *const Branch, allocator: std.mem.Allocator) ![]u8 {
        const keys_slice = try allocator.alloc([]const u8, self.keys.items.len);
        defer allocator.free(keys_slice);
        for (self.keys.items, 0..) |k, i| keys_slice[i] = k;
        const payload_size = f.branchPayloadSize(.{ .keys = keys_slice, .children = self.children.items });
        const total = f.recordTotalSize(payload_size);
        const buf = try allocator.alloc(u8, total);
        errdefer allocator.free(buf);
        std.mem.writeInt(u32, buf[0..4], @intCast(payload_size), .big);
        _ = f.encodeBranchPayload(buf[f.REC_LEN_SIZE..][0..payload_size], .{ .keys = keys_slice, .children = self.children.items });
        var crc = f.Crc32.init();
        crc.update(buf[0 .. f.REC_LEN_SIZE + payload_size]);
        std.mem.writeInt(u32, buf[f.REC_LEN_SIZE + payload_size ..][0..4], crc.final(), .big);
        return buf;
    }

    /// 找 key 应走哪个子节点（返回 child index 0..count-1）。
    pub fn findChild(self: *const Branch, key: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = self.keys.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (cmpKey(self.keys.items[mid], key)) {
                // keys[mid] <= key → key 属于右子，上界在右
                .lt, .eq => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return lo;
    }
};

// ===== 写入 store 辅助 =====
pub fn appendLeaf(s: Store, allocator: std.mem.Allocator, leaf: *const Leaf) !u64 {
    const rec = try leaf.toRecord(allocator);
    defer allocator.free(rec);
    return s.append(rec);
}

pub fn appendBranch(s: Store, allocator: std.mem.Allocator, branch: *const Branch) !u64 {
    const rec = try branch.toRecord(allocator);
    defer allocator.free(rec);
    return s.append(rec);
}

// ===== get =====
pub fn get(allocator: std.mem.Allocator, s: Store, root: u64, key: []const u8) !?[]u8 {
    if (root == NULL_ROOT) return null;
    var cur = root;
    var depth: u32 = 0;
    while (depth < 1000) : (depth += 1) {
        const rec = try readRecord(allocator, s, cur);
        defer allocator.free(rec);
        const payload = try decodeNodePayload(rec);
        if (payload.len == 0) return error.Truncated;
        if (payload[0] == @intFromEnum(f.NodeKind.leaf)) {
            var leaf = try Leaf.fromPayload(allocator, payload);
            defer leaf.deinit(allocator);
            const pos = leaf.findPos(key);
            if (pos < leaf.entries.items.len) {
                const e = leaf.entries.items[pos];
                if (cmpKey(e.key, key) == .eq and !e.tombstone) {
                    return try allocator.dupe(u8, e.value);
                }
            }
            return null;
        } else {
            var branch = try Branch.fromPayload(allocator, payload);
            defer branch.deinit(allocator);
            const ci = branch.findChild(key);
            cur = branch.children.items[ci];
        }
    }
    return error.Truncated;
}

// ===== insert（COW） =====
// 返回新 root 偏移与 dirt/live 统计。tombstone=true 表示删除。

pub const InsertOutcome = struct {
    /// 新子树根偏移（替换旧 root/旧 child）
    new_child: u64,
    /// 若子树发生分裂，分隔 key（向上传播）+ 右子偏移；否则 null
    split_key: ?[]u8 = null,
    split_right: u64 = 0,
};

/// 子树插入/删除递归返回
const InsertSub = struct {
    outcome: InsertOutcome,
    dirt_delta: u64,
    live_delta: i64,
    count_delta: i64,
};

fn insertIntoLeaf(
    s: Store,
    allocator: std.mem.Allocator,
    leaf_off: u64,
    key: []const u8,
    value: []const u8,
    tombstone: bool,
) !InsertSub {
    const rec = try readRecord(allocator, s, leaf_off);
    defer allocator.free(rec);
    const payload = try decodeNodePayload(rec);
    var leaf = try Leaf.fromPayload(allocator, payload);
    defer leaf.deinit(allocator);

    const old_rec_size = rec.len;
    const dirt_delta: u64 = old_rec_size;
    var live_delta: i64 = 0;
    var count_delta: i64 = 0;

    const pos = leaf.findPos(key);
    if (pos < leaf.entries.items.len and cmpKey(leaf.entries.items[pos].key, key) == .eq) {
        // 覆盖/tombstone 已有 key
        const old = leaf.entries.items[pos];
        live_delta -= @as(i64, @intCast(old.key.len + old.value.len + 9));
        allocator.free(old.key);
        allocator.free(old.value);
        leaf.entries.items[pos] = .{
            .tombstone = tombstone,
            .key = try allocator.dupe(u8, key),
            .value = if (tombstone) try allocator.dupe(u8, "") else try allocator.dupe(u8, value),
        };
        live_delta += @as(i64, @intCast(key.len + (if (tombstone) 0 else value.len) + 9));
        // count 不变（覆盖）
    } else {
        // 新增：在 pos 插入
        const new_entry = LeafEntry{
            .tombstone = tombstone,
            .key = try allocator.dupe(u8, key),
            .value = if (tombstone) try allocator.dupe(u8, "") else try allocator.dupe(u8, value),
        };
        _ = try leaf.entries.addOne(allocator);
        // 把 [pos..len-2] 后移一位（len-2 是 addOne 前的末尾）
        var i: usize = leaf.entries.items.len - 1;
        while (i > pos) : (i -= 1) {
            leaf.entries.items[i] = leaf.entries.items[i - 1];
        }
        leaf.entries.items[pos] = new_entry;
        live_delta += @as(i64, @intCast(key.len + (if (tombstone) 0 else value.len) + 9));
        if (!tombstone) count_delta = 1;
    }

    // 分裂判定
    if (leaf.entries.items.len <= LEAF_MAX_ENTRIES) {
        const new_off = try appendLeaf(s, allocator, &leaf);
        return .{
            .outcome = .{ .new_child = new_off },
            .dirt_delta = dirt_delta,
            .live_delta = live_delta,
            .count_delta = count_delta,
        };
    }
    // 分裂：取中点。转移 entries 所有权到 left/right（避免 double free）。
    const mid = leaf.entries.items.len / 2;
    var right = Leaf.init(allocator);
    try right.entries.appendSlice(allocator, leaf.entries.items[mid..]);
    var left = Leaf.init(allocator);
    try left.entries.appendSlice(allocator, leaf.entries.items[0..mid]);
    // 清空原 leaf.entries 所有权（指针已转给 left/right），但不要 free 它们。
    leaf.entries.shrinkRetainingCapacity(0);
    defer right.deinit(allocator);
    defer left.deinit(allocator);

    const left_off = try appendLeaf(s, allocator, &left);
    const right_off = try appendLeaf(s, allocator, &right);
    const split_key = try allocator.dupe(u8, right.entries.items[0].key);
    return .{
        .outcome = .{ .new_child = left_off, .split_key = split_key, .split_right = right_off },
        .dirt_delta = dirt_delta,
        .live_delta = live_delta,
        .count_delta = count_delta,
    };
}

fn insertIntoBranch(
    s: Store,
    allocator: std.mem.Allocator,
    branch_off: u64,
    key: []const u8,
    value: []const u8,
    tombstone: bool,
) !InsertSub {
    const rec = try readRecord(allocator, s, branch_off);
    defer allocator.free(rec);
    const payload = try decodeNodePayload(rec);
    var branch = try Branch.fromPayload(allocator, payload);
    defer branch.deinit(allocator);

    const old_rec_size = rec.len;
    var dirt_delta: u64 = old_rec_size;
    var live_delta: i64 = 0;
    var count_delta: i64 = 0;

    const ci = branch.findChild(key);
    const child_off = branch.children.items[ci];

    // 递归插入子节点
    const child_is_leaf = blk: {
        const crec = try readRecord(allocator, s, child_off);
        defer allocator.free(crec);
        const cpayload = try decodeNodePayload(crec);
        break :blk cpayload[0] == @intFromEnum(f.NodeKind.leaf);
    };

    var sub: InsertSub = undefined;
    if (child_is_leaf) {
        sub = try insertIntoLeaf(s, allocator, child_off, key, value, tombstone);
    } else {
        sub = try insertIntoBranch(s, allocator, child_off, key, value, tombstone);
    }
    dirt_delta += sub.dirt_delta;
    live_delta += sub.live_delta;
    count_delta += sub.count_delta;

    // 替换子指针
    branch.children.items[ci] = sub.outcome.new_child;

    if (sub.outcome.split_key) |sk| {
        // 子分裂，需在 branch 插入新 key + 右子
        var new_keys = try allocator.alloc([]u8, branch.keys.items.len + 1);
        defer allocator.free(new_keys);
        var new_children = try allocator.alloc(u64, branch.children.items.len + 1);
        defer allocator.free(new_children);
        // copy [0..ci] keys, insert sk, copy [ci..]
        @memcpy(new_keys[0..ci], branch.keys.items[0..ci]);
        new_keys[ci] = sk;
        @memcpy(new_keys[ci + 1 ..], branch.keys.items[ci..]);
        @memcpy(new_children[0..ci + 1], branch.children.items[0..ci + 1]);
        new_children[ci + 1] = sub.outcome.split_right;
        @memcpy(new_children[ci + 2 ..], branch.children.items[ci + 1 ..]);
        // 转移所有权：旧 keys 指针已拷进 new_keys，不能 free。
        branch.keys.clearRetainingCapacity();
        branch.children.clearRetainingCapacity();
        try branch.keys.appendSlice(allocator, new_keys);
        try branch.children.appendSlice(allocator, new_children);
        // sk（sub.outcome.split_key）所有权已转给 branch.keys，InsertSub 不再持有。

        // 分裂判定
        if (branch.children.items.len <= BRANCH_MAX_CHILDREN) {
            const new_off = try appendBranch(s, allocator, &branch);
            // 注意：sk 被 branch.keys 持有，不能在此 free。但 branch.deinit 会 free。
            // 但 appendBranch 已序列化，branch 即将 deinit。OK。
            return .{
                .outcome = .{ .new_child = new_off },
                .dirt_delta = dirt_delta,
                .live_delta = live_delta,
                .count_delta = count_delta,
            };
        }
        // 分裂 branch
        const mid = branch.keys.items.len / 2;
        var right = Branch.init(allocator);
        const up_key = try allocator.dupe(u8, branch.keys.items[mid]);
        try right.keys.appendSlice(allocator, branch.keys.items[mid + 1 ..]);
        try right.children.appendSlice(allocator, branch.children.items[mid + 1 ..]);
        // 左 branch 缩到 mid（转移所有权）
        var left = Branch.init(allocator);
        try left.keys.appendSlice(allocator, branch.keys.items[0..mid]);
        try left.children.appendSlice(allocator, branch.children.items[0..mid + 1]);
        // mid key 被 up_key 复制，所有权转给父（up_key）；原 mid key 需释放。
        allocator.free(branch.keys.items[mid]);
        // 清空原 branch 所有权（指针已转给 left/right），不 free。
        branch.keys.shrinkRetainingCapacity(0);
        branch.children.shrinkRetainingCapacity(0);
        defer left.deinit(allocator);
        defer right.deinit(allocator);

        const left_off = try appendBranch(s, allocator, &left);
        const right_off = try appendBranch(s, allocator, &right);
        return .{
            .outcome = .{ .new_child = left_off, .split_key = up_key, .split_right = right_off },
            .dirt_delta = dirt_delta,
            .live_delta = live_delta,
            .count_delta = count_delta,
        };
    }
    // 无分裂：重写 branch
    const new_off = try appendBranch(s, allocator, &branch);
    return .{
        .outcome = .{ .new_child = new_off },
        .dirt_delta = dirt_delta,
        .live_delta = live_delta,
        .count_delta = count_delta,
    };
}

pub fn insert(
    allocator: std.mem.Allocator,
    s: Store,
    root: u64,
    key: []const u8,
    value: []const u8,
    tombstone: bool,
) !WriteResult {
    if (root == NULL_ROOT) {
        // 空树：写一个叶
        var leaf = Leaf.init(allocator);
        defer leaf.deinit(allocator);
        try leaf.entries.append(allocator, .{
            .tombstone = tombstone,
            .key = try allocator.dupe(u8, key),
            .value = if (tombstone) try allocator.dupe(u8, "") else try allocator.dupe(u8, value),
        });
        const off = try appendLeaf(s, allocator, &leaf);
        return .{
            .new_root = off,
            .live_delta = @intCast(key.len + (if (tombstone) 0 else value.len) + 9),
            .dirt_delta = 0,
            .count_delta = if (tombstone) 0 else 1,
        };
    }

    // 判断 root 是叶还是 branch
    const rec = try readRecord(allocator, s, root);
    defer allocator.free(rec);
    const payload = try decodeNodePayload(rec);
    const is_leaf = payload[0] == @intFromEnum(f.NodeKind.leaf);

    const sub = if (is_leaf)
        try insertIntoLeaf(s, allocator, root, key, value, tombstone)
    else
        try insertIntoBranch(s, allocator, root, key, value, tombstone);

    if (sub.outcome.split_key) |sk| {
        // root 分裂：建新 root branch
        var new_root = Branch.init(allocator);
        defer new_root.deinit(allocator);
        try new_root.keys.append(allocator, sk);
        try new_root.children.append(allocator, sub.outcome.new_child);
        try new_root.children.append(allocator, sub.outcome.split_right);
        const off = try appendBranch(s, allocator, &new_root);
        // sk 所有权已转给 new_root.keys（append 拷贝指针），new_root.deinit 释放之。不再 free。
        return .{
            .new_root = off,
            .live_delta = sub.live_delta,
            .dirt_delta = sub.dirt_delta,
            .count_delta = sub.count_delta,
        };
    }
    return .{
        .new_root = sub.outcome.new_child,
        .live_delta = sub.live_delta,
        .dirt_delta = sub.dirt_delta,
        .count_delta = sub.count_delta,
    };
}

// ===== 删除（tombstone） =====
pub fn remove(allocator: std.mem.Allocator, s: Store, root: u64, key: []const u8) !WriteResult {
    if (root == NULL_ROOT) {
        // 空树删：无操作
        return .{ .new_root = NULL_ROOT, .live_delta = 0, .dirt_delta = 0, .count_delta = 0 };
    }
    return insert(allocator, s, root, key, "", true);
}

// ===== 范围迭代器 =====
pub const Iterator = struct {
    allocator: std.mem.Allocator,
    s: Store,
    min: ?[]const u8,
    max: ?[]const u8,
    // 叶子栈：从 root 到当前叶的 (branch, child_index) 序列
    stack: std.ArrayList(StackFrame),
    // 当前叶的 entries 与位置
    cur_leaf: ?Leaf,
    cur_pos: usize,

    const StackFrame = struct {
        branch: Branch,
        child_idx: usize,
    };

    pub fn deinit(self: *Iterator) void {
        for (self.stack.items) |*fr| fr.branch.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        if (self.cur_leaf) |*l| l.deinit(self.allocator);
        // min/max 是外部借用，不释放
    }

    pub fn next(self: *Iterator) !?LeafEntry {
        while (true) {
            if (self.cur_leaf) |*leaf| {
                while (self.cur_pos < leaf.entries.items.len) : (self.cur_pos += 1) {
                    const e = leaf.entries.items[self.cur_pos];
                    if (e.tombstone) continue;
                    if (self.min) |m| {
                        if (cmpKey(e.key, m) == .lt) continue;
                    }
                    if (self.max) |mx| {
                        if (cmpKey(e.key, mx) != .lt) return null; // >= max
                    }
                    self.cur_pos += 1;
                    return e;
                }
                // 当前叶耗尽，回溯到下一个叶
                leaf.deinit(self.allocator);
                self.cur_leaf = null;
            }
            // 找下一个叶
            if (!try self.descendToNextLeaf()) return null;
        }
    }

    fn descendToNextLeaf(self: *Iterator) !bool {
        // 若栈顶 branch 还有下一个 child，下钻；否则弹出
        while (self.stack.items.len > 0) {
            const top_i = self.stack.items.len - 1;
            self.stack.items[top_i].child_idx += 1;
            const ci = self.stack.items[top_i].child_idx;
            if (ci < self.stack.items[top_i].branch.children.items.len) {
                // 下钻
                var cur = self.stack.items[top_i].branch.children.items[ci];
                var depth: u32 = 0;
                while (depth < 1000) : (depth += 1) {
                    const rec = try readRecord(self.allocator, self.s, cur);
                    const payload = try decodeNodePayload(rec);
                    if (payload[0] == @intFromEnum(f.NodeKind.leaf)) {
                        self.cur_leaf = try Leaf.fromPayload(self.allocator, payload);
                        self.cur_pos = 0;
                        self.allocator.free(rec);
                        return true;
                    } else {
                        const br = try Branch.fromPayload(self.allocator, payload);
                        self.allocator.free(rec);
                        const first_child = br.children.items[0];
                        try self.stack.append(self.allocator, .{ .branch = br, .child_idx = 0 });
                        cur = first_child;
                    }
                }
                return false;
            } else {
                // 弹出
                if (self.stack.pop()) |fr_val| {
                    var fr = fr_val;
                    fr.branch.deinit(self.allocator);
                }
            }
        }
        return false;
    }
};

/// 创建范围迭代器。min/max 为 null 表示无界；[min, max)。
pub fn select(allocator: std.mem.Allocator, s: Store, root: u64, min: ?[]const u8, max: ?[]const u8) !Iterator {
    var it: Iterator = .{
        .allocator = allocator,
        .s = s,
        .min = min,
        .max = max,
        .stack = .empty,
        .cur_leaf = null,
        .cur_pos = 0,
    };
    if (root == NULL_ROOT) return it;
    // 下钻到第一个 >= min 的叶
    var cur = root;
    var depth: u32 = 0;
    while (depth < 1000) : (depth += 1) {
        const rec = try readRecord(allocator, s, cur);
        const payload = try decodeNodePayload(rec);
        if (payload[0] == @intFromEnum(f.NodeKind.leaf)) {
            it.cur_leaf = try Leaf.fromPayload(allocator, payload);
            it.cur_pos = 0;
            allocator.free(rec);
            break;
        } else {
            var br = try Branch.fromPayload(allocator, payload);
            allocator.free(rec);
            var ci: usize = 0;
            if (min) |m| ci = br.findChild(m);
            const next = br.children.items[ci];
            try it.stack.append(allocator, .{ .branch = br, .child_idx = ci });
            cur = next;
        }
    }
    return it;
}

// ===== 测试 =====

const MemStore = store_mod.MemStore;

fn newStore() MemStore {
    return MemStore.init(std.testing.allocator);
}

test "btree: empty tree get -> null" {
    var ms = newStore();
    defer ms.deinit();
    const v = try get(std.testing.allocator, ms.store(), NULL_ROOT, "k");
    try std.testing.expectEqual(@as(?[]u8, null), v);
}

test "btree: single put/get roundtrip" {
    var ms = newStore();
    defer ms.deinit();
    const r = try insert(std.testing.allocator, ms.store(), NULL_ROOT, "k", "v", false);
    const v = try get(std.testing.allocator, ms.store(), r.new_root, "k");
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("v", v.?);
    std.testing.allocator.free(v.?);
}

test "btree: insert 10k random keys all readable" {
    var ms = newStore();
    defer ms.deinit();
    var root: u64 = NULL_ROOT;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var keys = std.ArrayList([]u8).empty;
    defer {
        for (keys.items) |k| std.testing.allocator.free(k);
        keys.deinit(std.testing.allocator);
    }
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const klen = rnd.uintLessThan(usize, 14) + 2;
        for (0..klen) |j| kbuf[j] = 'a' + rnd.uintLessThan(u8, 26);
        const k = try std.testing.allocator.dupe(u8, kbuf[0..klen]);
        try keys.append(std.testing.allocator, k);
    }
    // 排序去重后插入
    std.mem.sort([]u8, keys.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var unique = std.ArrayList([]u8).empty;
    defer unique.deinit(std.testing.allocator);
    for (keys.items) |k| {
        if (unique.items.len == 0 or std.mem.order(u8, unique.items[unique.items.len - 1], k) != .eq) {
            try unique.append(std.testing.allocator, k);
        }
    }
    for (unique.items) |k| {
        root = (try insert(std.testing.allocator, ms.store(), root, k, "val", false)).new_root;
    }
    // 验证全部可读
    for (unique.items) |k| {
        const v = try get(std.testing.allocator, ms.store(), root, k);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings("val", v.?);
        std.testing.allocator.free(v.?);
    }
}

test "btree: overwrite key -> new value" {
    var ms = newStore();
    defer ms.deinit();
    var root = (try insert(std.testing.allocator, ms.store(), NULL_ROOT, "k", "v1", false)).new_root;
    root = (try insert(std.testing.allocator, ms.store(), root, "k", "v2", false)).new_root;
    const v = try get(std.testing.allocator, ms.store(), root, "k");
    try std.testing.expectEqualStrings("v2", v.?);
    std.testing.allocator.free(v.?);
}

test "btree: delete key -> get null" {
    var ms = newStore();
    defer ms.deinit();
    var root = (try insert(std.testing.allocator, ms.store(), NULL_ROOT, "k", "v", false)).new_root;
    root = (try remove(std.testing.allocator, ms.store(), root, "k")).new_root;
    const v = try get(std.testing.allocator, ms.store(), root, "k");
    try std.testing.expectEqual(@as(?[]u8, null), v);
}

test "btree: COW old root still points to old version" {
    var ms = newStore();
    defer ms.deinit();
    const r1 = try insert(std.testing.allocator, ms.store(), NULL_ROOT, "k", "v1", false);
    const r2 = try insert(std.testing.allocator, ms.store(), r1.new_root, "k", "v2", false);
    // 用旧 root 读到旧值
    const oldv = try get(std.testing.allocator, ms.store(), r1.new_root, "k");
    try std.testing.expectEqualStrings("v1", oldv.?);
    std.testing.allocator.free(oldv.?);
    // 用新 root 读到新值
    const newv = try get(std.testing.allocator, ms.store(), r2.new_root, "k");
    try std.testing.expectEqualStrings("v2", newv.?);
    std.testing.allocator.free(newv.?);
}

test "btree: select null,null full ordered output" {
    var ms = newStore();
    defer ms.deinit();
    var root: u64 = NULL_ROOT;
    const keys = [_][]const u8{ "banana", "apple", "cherry" };
    for (keys) |k| {
        root = (try insert(std.testing.allocator, ms.store(), root, k, "v", false)).new_root;
    }
    var it = try select(std.testing.allocator, ms.store(), root, null, null);
    defer it.deinit();
    var got = std.ArrayList([]const u8).empty;
    defer got.deinit(std.testing.allocator);
    while (try it.next()) |e| {
        try got.append(std.testing.allocator, try std.testing.allocator.dupe(u8, e.key));
    }
    try std.testing.expectEqual(@as(usize, 3), got.items.len);
    try std.testing.expectEqualStrings("apple", got.items[0]);
    try std.testing.expectEqualStrings("banana", got.items[1]);
    try std.testing.expectEqualStrings("cherry", got.items[2]);
    for (got.items) |g| std.testing.allocator.free(g);
}

test "btree: select min,max inclusive min exclusive max" {
    var ms = newStore();
    defer ms.deinit();
    var root: u64 = NULL_ROOT;
    const keys = [_][]const u8{ "a", "b", "c", "d", "e" };
    for (keys) |k| {
        root = (try insert(std.testing.allocator, ms.store(), root, k, "v", false)).new_root;
    }
    var it = try select(std.testing.allocator, ms.store(), root, "b", "d");
    defer it.deinit();
    var got = std.ArrayList([]const u8).empty;
    defer got.deinit(std.testing.allocator);
    while (try it.next()) |e| {
        try got.append(std.testing.allocator, try std.testing.allocator.dupe(u8, e.key));
    }
    try std.testing.expectEqual(@as(usize, 2), got.items.len);
    try std.testing.expectEqualStrings("b", got.items[0]);
    try std.testing.expectEqualStrings("c", got.items[1]);
    for (got.items) |g| std.testing.allocator.free(g);
}

test "btree: select empty range min>max -> empty" {
    var ms = newStore();
    defer ms.deinit();
    var root: u64 = NULL_ROOT;
    root = (try insert(std.testing.allocator, ms.store(), NULL_ROOT, "a", "v", false)).new_root;
    var it = try select(std.testing.allocator, ms.store(), root, "z", "a");
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "btree: select skips tombstones" {
    var ms = newStore();
    defer ms.deinit();
    var root: u64 = NULL_ROOT;
    root = (try insert(std.testing.allocator, ms.store(), NULL_ROOT, "a", "va", false)).new_root;
    root = (try insert(std.testing.allocator, ms.store(), root, "b", "vb", false)).new_root;
    root = (try remove(std.testing.allocator, ms.store(), root, "a")).new_root;
    var it = try select(std.testing.allocator, ms.store(), root, null, null);
    defer it.deinit();
    var got = std.ArrayList([]const u8).empty;
    defer got.deinit(std.testing.allocator);
    while (try it.next()) |e| {
        try got.append(std.testing.allocator, try std.testing.allocator.dupe(u8, e.key));
    }
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqualStrings("b", got.items[0]);
    for (got.items) |g| std.testing.allocator.free(g);
}

test "btree: model test random ops vs StringHashMap (seed 7)" {
    const allocator = std.testing.allocator;
    var ms = newStore();
    defer ms.deinit();
    var root: u64 = NULL_ROOT;
    var model = std.StringHashMap([]u8).init(allocator);
    defer {
        var it = model.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        model.deinit();
    }
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    const ops = 2000;
    var i: usize = 0;
    while (i < ops) : (i += 1) {
        var kbuf: [8]u8 = undefined;
        const klen = 4 + rnd.uintLessThan(usize, 5);
        for (0..klen) |j| kbuf[j] = 'a' + rnd.uintLessThan(u8, 8);
        const key = kbuf[0..klen];
        if (rnd.boolean()) {
            // put
            const val = try allocator.dupe(u8, "V");
            const r = try insert(allocator, ms.store(), root, key, val, false);
            root = r.new_root;
            allocator.free(val);
            const gop = try model.getOrPut(key);
            if (gop.found_existing) {
                allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = try allocator.dupe(u8, "V");
            } else {
                gop.key_ptr.* = try allocator.dupe(u8, key);
                gop.value_ptr.* = try allocator.dupe(u8, "V");
            }
        } else {
            // delete
            const r = try remove(allocator, ms.store(), root, key);
            root = r.new_root;
            if (model.fetchRemove(key)) |kv| {
                allocator.free(kv.key);
                allocator.free(kv.value);
            }
        }
        // 验证该 key
        const mv = model.get(key);
        const bv = try get(allocator, ms.store(), root, key);
        if (mv == null) {
            try std.testing.expect(bv == null);
        } else {
            try std.testing.expect(bv != null);
            try std.testing.expectEqualStrings(mv.?, bv.?);
            allocator.free(bv.?);
        }
    }
    // 全量比对
    var it = try select(allocator, ms.store(), root, null, null);
    defer it.deinit();
    var bcount: usize = 0;
    while (try it.next()) |_| bcount += 1;
    try std.testing.expectEqual(model.count(), bcount);
}

test "btree: sequential 1000 keys all readable" {
    var ms = newStore();
    defer ms.deinit();
    var root: u64 = NULL_ROOT;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "{d}", .{i});
        root = (try insert(std.testing.allocator, ms.store(), root, k, "v", false)).new_root;
    }
    i = 0;
    while (i < 1000) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "{d}", .{i});
        const v = try get(std.testing.allocator, ms.store(), root, k);
        if (v == null) return error.TestUnexpectedResult;
        std.testing.allocator.free(v.?);
    }
}

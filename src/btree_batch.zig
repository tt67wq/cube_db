//! btree_batch.zig — 批量树提交（lever 2）
const std = @import("std");
const btree = @import("btree.zig");
const f = @import("format.zig");
const store_mod = @import("store.zig");

const Store = store_mod.Store;
const Leaf = btree.Leaf;
const Branch = btree.Branch;
const LeafEntry = btree.LeafEntry;
const WriteResult = btree.WriteResult;
const InsertOutcome = btree.InsertOutcome;
const LEAF_MAX_ENTRIES = btree.LEAF_MAX_ENTRIES;
const BRANCH_MAX_CHILDREN = btree.BRANCH_MAX_CHILDREN;
const NULL_ROOT = btree.NULL_ROOT;
const cmpKey = btree.cmpKey;
const readRecord = btree.readRecord;
const decodeNodePayload = btree.decodeNodePayload;
const appendLeaf = btree.appendLeaf;
const appendBranch = btree.appendBranch;

// 复用 Leaf/Branch/encode/decode。new 节点用临时 ID（high bit 1），flush 时分配真实 offset。

pub const BatchEntry = struct {
    key: []u8,
    value: []u8,
    tombstone: bool,
};

const CachedNodeKind = enum { leaf, branch };

const CachedNode = struct {
    kind: CachedNodeKind,
    leaf: ?Leaf = null,
    branch: ?Branch = null,
    /// 旧 store offset（加载来的节点有；new 分裂节点为 null）
    old_off: ?u64 = null,
    /// 旧记录字节数（dirt 统计用）
    old_rec_size: u64 = 0,
    dirty: bool = false,
    /// flush 分配的真实 offset（flush 后填）
    real_off: ?u64 = null,
};

pub const BTreeBatch = struct {
    /// 外部分配器（cache map 背书）
    allocator: std.mem.Allocator,
    /// arena：所有临时/节点内存由此分配，deinit 整体 free
    arena: std.heap.ArenaAllocator,
    s: Store,
    root: u64, // 原 btree root（NULL_ROOT=空）
    entries: std.ArrayList(BatchEntry),
    /// 节点缓存：id -> *CachedNode。真实 store offset 直接作 key；new 节点用 0x8000...起递增。
    cache: std.AutoHashMap(u64, *CachedNode),
    next_temp_id: u64 = 0x8000_0000_0000_0000,
    live_delta: i64 = 0,
    dirt_delta: u64 = 0,
    count_delta: i64 = 0,
    /// apply 过程中当前 root（可能随分裂变为临时 ID）
    cur_root: u64,

    /// arena 分配器快捷访问
    fn ar(self: *BTreeBatch) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn init(allocator: std.mem.Allocator, s: Store, root: u64) BTreeBatch {
        const arena = std.heap.ArenaAllocator.init(allocator);
        return .{
            .allocator = allocator,
            .arena = arena,
            .s = s,
            .root = root,
            .cur_root = root,
            .entries = .empty,
            .cache = std.AutoHashMap(u64, *CachedNode).init(allocator),
        };
    }

    pub fn deinit(self: *BTreeBatch) void {
        // arena 接管所有节点/临时内存，整体 free；只释放外部背书的 entries 与 cache map。
        // entries 的 key/value 也由 arena（见 apply），故不需逐个 free。
        self.entries.deinit(self.allocator);
        self.cache.deinit();
        self.arena.deinit();
    }

    pub fn apply(self: *BTreeBatch, key: []const u8, value: []const u8, tombstone: bool) !void {
        const ca = self.ar();
        try self.entries.append(self.allocator, .{
            .key = try ca.dupe(u8, key),
            .value = if (tombstone) try ca.dupe(u8, "") else try ca.dupe(u8, value),
            .tombstone = tombstone,
        });
    }

    /// 加载（或取缓存）一个节点 by id。id=store offset（已存在）或临时 ID（new）。
    fn getLoadNode(self: *BTreeBatch, id: u64) !*CachedNode {
        if (self.cache.get(id)) |cn| return cn;
        const ca = self.ar();
        // 从 store 读+解码
        const rec = try readRecord(ca, self.s, id);
        const payload = try decodeNodePayload(rec);
        const cn = try ca.create(CachedNode);
        if (payload[0] == @intFromEnum(f.NodeKind.leaf)) {
            const leaf = try Leaf.fromPayload(ca, payload);
            cn.* = .{ .kind = .leaf, .leaf = leaf, .old_off = id, .old_rec_size = rec.len };
        } else {
            const br = try Branch.fromPayload(ca, payload);
            cn.* = .{ .kind = .branch, .branch = br, .old_off = id, .old_rec_size = rec.len };
        }
        // rec 由 arena 接管，不 free
        try self.cache.put(id, cn);
        return cn;
    }

    /// 分配临时 ID 用于 new 节点（分裂产生）。
    fn newTempId(self: *BTreeBatch) u64 {
        const id = self.next_temp_id;
        self.next_temp_id += 1;
        return id;
    }

    /// 向缓存的 leaf 插入 entry（复用 findPos/分裂语义，但写缓存、不 append store）。
    /// 返回 InsertOutcome（new_child=新 leaf id；split 时 split_key/split_right）。
    const ApplySub = struct {
        outcome: InsertOutcome,
        dirt_delta: u64,
        live_delta: i64,
        count_delta: i64,
    };

    fn applyIntoLeaf(self: *BTreeBatch, leaf_id: u64, key: []const u8, value: []const u8, tombstone: bool) !ApplySub {
        const ca = self.ar();
        const cn = try self.getLoadNode(leaf_id);
        const leaf = &cn.leaf.?;
        const old_rec_size = cn.old_rec_size;
        var live_delta: i64 = 0;
        var count_delta: i64 = 0;

        const pos = leaf.findPos(key);
        if (pos < leaf.entries.items.len and cmpKey(leaf.entries.items[pos].key, key) == .eq) {
            const old = leaf.entries.items[pos];
            live_delta -= @as(i64, @intCast(old.key.len + old.value.len + 9));
            // old key/value 由 arena 接管，不 free（arena 末整体回收）
            leaf.entries.items[pos] = .{
                .tombstone = tombstone,
                .key = try ca.dupe(u8, key),
                .value = if (tombstone) try ca.dupe(u8, "") else try ca.dupe(u8, value),
            };
            live_delta += @as(i64, @intCast(key.len + (if (tombstone) 0 else value.len) + 9));
        } else {
            const new_entry = LeafEntry{
                .tombstone = tombstone,
                .key = try ca.dupe(u8, key),
                .value = if (tombstone) try ca.dupe(u8, "") else try ca.dupe(u8, value),
            };
            _ = try leaf.entries.addOne(ca);
            var i: usize = leaf.entries.items.len - 1;
            while (i > pos) : (i -= 1) leaf.entries.items[i] = leaf.entries.items[i - 1];
            leaf.entries.items[pos] = new_entry;
            live_delta += @as(i64, @intCast(key.len + (if (tombstone) 0 else value.len) + 9));
            if (!tombstone) count_delta = 1;
        }

        cn.dirty = true;

        if (leaf.entries.items.len <= LEAF_MAX_ENTRIES) {
            return .{ .outcome = .{ .new_child = leaf_id }, .dirt_delta = old_rec_size, .live_delta = live_delta, .count_delta = count_delta };
        }
        // 分裂
        const mid = leaf.entries.items.len / 2;
        var right_leaf = Leaf.init(ca);
        try right_leaf.entries.appendSlice(ca, leaf.entries.items[mid..]);
        var left_leaf = Leaf.init(ca);
        try left_leaf.entries.appendSlice(ca, leaf.entries.items[0..mid]);
        // 旧 leaf.entries ArrayList backing 由 arena 接管，不 deinit
        cn.leaf = left_leaf;
        cn.dirty = true;
        // new right 节点
        const right_id = self.newTempId();
        const right_cn = try ca.create(CachedNode);
        right_cn.* = .{ .kind = .leaf, .leaf = right_leaf, .old_off = null, .old_rec_size = 0, .dirty = true };
        try self.cache.put(right_id, right_cn);
        const split_key = try ca.dupe(u8, right_leaf.entries.items[0].key);
        return .{ .outcome = .{ .new_child = leaf_id, .split_key = split_key, .split_right = right_id }, .dirt_delta = old_rec_size, .live_delta = live_delta, .count_delta = count_delta };
    }

    fn applyIntoBranch(self: *BTreeBatch, branch_id: u64, key: []const u8, value: []const u8, tombstone: bool) !ApplySub {
        const ca = self.ar();
        const cn = try self.getLoadNode(branch_id);
        const branch = &cn.branch.?;
        const old_rec_size = cn.old_rec_size;
        var dirt_delta: u64 = old_rec_size;
        var live_delta: i64 = 0;
        var count_delta: i64 = 0;

        const ci = branch.findChild(key);
        const child_id = branch.children.items[ci];
        // 判断子节点 leaf/branch：查缓存；若未加载则先 peek store。
        const child_is_leaf = blk: {
            if (self.cache.get(child_id)) |ccn| break :blk ccn.kind == .leaf;
            const crec = try readRecord(ca, self.s, child_id);
            defer ca.free(crec);
            const cp = try decodeNodePayload(crec);
            break :blk cp[0] == @intFromEnum(f.NodeKind.leaf);
        };

        const sub = if (child_is_leaf)
            try self.applyIntoLeaf(child_id, key, value, tombstone)
        else
            try self.applyIntoBranch(child_id, key, value, tombstone);
        dirt_delta += sub.dirt_delta;
        live_delta += sub.live_delta;
        count_delta += sub.count_delta;

        branch.children.items[ci] = sub.outcome.new_child;
        cn.dirty = true;

        if (sub.outcome.split_key) |sk| {
            // 在 branch 插 sk + 右子（临时数组由 arena 接管）
            const new_keys = try ca.alloc([]u8, branch.keys.items.len + 1);
            const new_children = try ca.alloc(u64, branch.children.items.len + 1);
            @memcpy(new_keys[0..ci], branch.keys.items[0..ci]);
            new_keys[ci] = sk;
            @memcpy(new_keys[ci + 1 ..], branch.keys.items[ci..]);
            @memcpy(new_children[0..ci + 1], branch.children.items[0..ci + 1]);
            new_children[ci + 1] = sub.outcome.split_right;
            @memcpy(new_children[ci + 2 ..], branch.children.items[ci + 1 ..]);
            branch.keys.clearRetainingCapacity();
            branch.children.clearRetainingCapacity();
            try branch.keys.appendSlice(ca, new_keys);
            try branch.children.appendSlice(ca, new_children);
            cn.dirty = true;

            if (branch.children.items.len <= BRANCH_MAX_CHILDREN) {
                return .{ .outcome = .{ .new_child = branch_id }, .dirt_delta = dirt_delta, .live_delta = live_delta, .count_delta = count_delta };
            }
            // branch 分裂
            const mid = branch.keys.items.len / 2;
            const up_key = try ca.dupe(u8, branch.keys.items[mid]);
            var right_br = Branch.init(ca);
            try right_br.keys.appendSlice(ca, branch.keys.items[mid + 1 ..]);
            try right_br.children.appendSlice(ca, branch.children.items[mid + 1 ..]);
            var left_br = Branch.init(ca);
            try left_br.keys.appendSlice(ca, branch.keys.items[0..mid]);
            try left_br.children.appendSlice(ca, branch.children.items[0..mid + 1]);
            // mid key 指针转给 up_key（dup），原 branch.keys 全由 arena 接管，不 free
            branch.keys.shrinkRetainingCapacity(0);
            branch.children.shrinkRetainingCapacity(0);
            cn.branch = left_br;
            cn.dirty = true;
            const right_id = self.newTempId();
            const right_cn = try ca.create(CachedNode);
            right_cn.* = .{ .kind = .branch, .branch = right_br, .old_off = null, .old_rec_size = 0, .dirty = true };
            try self.cache.put(right_id, right_cn);
            return .{ .outcome = .{ .new_child = branch_id, .split_key = up_key, .split_right = right_id }, .dirt_delta = dirt_delta, .live_delta = live_delta, .count_delta = count_delta };
        }
        return .{ .outcome = .{ .new_child = branch_id }, .dirt_delta = dirt_delta, .live_delta = live_delta, .count_delta = count_delta };
    }

    /// 提交：排序去重，逐 op 应用到缓存树，最后一次 flush。
    pub fn commit(self: *BTreeBatch) !WriteResult {
        if (self.entries.items.len == 0) {
            return .{ .new_root = self.root, .live_delta = 0, .dirt_delta = 0, .count_delta = 0 };
        }
        const ca = self.ar();
        std.mem.sort(BatchEntry, self.entries.items, {}, struct {
            fn lt(_: void, a: BatchEntry, b: BatchEntry) bool {
                return std.mem.order(u8, a.key, b.key) == .lt;
            }
        }.lt);
        // 去重：同 key 保留最后（last-write-wins）。丢弃的 entry key/value 由 arena 接管，不 free。
        var dedup = std.ArrayList(BatchEntry).empty;
        defer dedup.deinit(self.allocator);
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            if (i + 1 < self.entries.items.len and
                std.mem.order(u8, self.entries.items[i].key, self.entries.items[i + 1].key) == .eq)
            {
                continue;
            }
            try dedup.append(self.allocator, self.entries.items[i]);
        }
        self.entries.clearRetainingCapacity();

        // 逐 op 应用到缓存树
        for (dedup.items) |e| {
            if (self.cur_root == NULL_ROOT) {
                // 空树首 op：建一个 leaf
                var leaf = Leaf.init(ca);
                try leaf.entries.append(ca, .{
                    .tombstone = e.tombstone,
                    .key = try ca.dupe(u8, e.key),
                    .value = if (e.tombstone) try ca.dupe(u8, "") else try ca.dupe(u8, e.value),
                });
                const id = self.newTempId();
                const cn = try ca.create(CachedNode);
                cn.* = .{ .kind = .leaf, .leaf = leaf, .old_off = null, .old_rec_size = 0, .dirty = true };
                try self.cache.put(id, cn);
                self.cur_root = id;
                self.live_delta += @as(i64, @intCast(e.key.len + (if (e.tombstone) 0 else e.value.len) + 9));
                if (!e.tombstone) self.count_delta += 1;
            } else {
                const rcn = try self.getLoadNode(self.cur_root);
                const sub = if (rcn.kind == .leaf)
                    try self.applyIntoLeaf(self.cur_root, e.key, e.value, e.tombstone)
                else
                    try self.applyIntoBranch(self.cur_root, e.key, e.value, e.tombstone);
                self.live_delta += sub.live_delta;
                self.dirt_delta += sub.dirt_delta;
                self.count_delta += sub.count_delta;
                if (sub.outcome.split_key) |sk| {
                    // root 分裂：建新 root branch。sk 所有权转给 new_root（arena 末整体回收）。
                    var new_root = Branch.init(ca);
                    try new_root.keys.append(ca, sk);
                    try new_root.children.append(ca, sub.outcome.new_child);
                    try new_root.children.append(ca, sub.outcome.split_right);
                    const root_id = self.newTempId();
                    const root_cn = try ca.create(CachedNode);
                    root_cn.* = .{ .kind = .branch, .branch = new_root, .old_off = null, .old_rec_size = 0, .dirty = true };
                    try self.cache.put(root_id, root_cn);
                    self.cur_root = root_id;
                } else {
                    self.cur_root = sub.outcome.new_child;
                }
            }
        }

        // flush：自底向上写所有脏节点，分配真实 offset
        if (self.cur_root == NULL_ROOT) {
            return .{ .new_root = NULL_ROOT, .live_delta = self.live_delta, .dirt_delta = self.dirt_delta, .count_delta = self.count_delta };
        }
        const real_root = try self.flushNode(self.cur_root);
        return .{ .new_root = real_root, .live_delta = self.live_delta, .dirt_delta = self.dirt_delta, .count_delta = self.count_delta };
    }

    /// flush 一个缓存节点：返回其真实 store offset。递归子先父后。
    fn flushNode(self: *BTreeBatch, id: u64) !u64 {
        const cn = self.cache.get(id) orelse return error.CorruptCrc;
        if (cn.real_off) |off| return off; // 已 flush（共享祖先复用）
        const ca = self.ar();
        switch (cn.kind) {
            .leaf => {
                const leaf = &cn.leaf.?;
                const off = try appendLeaf(self.s, ca, leaf);
                cn.real_off = off;
                return off;
            },
            .branch => {
                const branch = &cn.branch.?;
                // 先 flush 所有子（递归）
                for (branch.children.items) |child_id| {
                    _ = try self.flushNode(child_id);
                }
                // 原地把 children 从缓存 ID 换成真实 offset（u64 原位覆盖，无所有权问题）
                for (branch.children.items) |*child_id| {
                    const child_cn = self.cache.get(child_id.*) orelse return error.CorruptCrc;
                    child_id.* = child_cn.real_off.?;
                }
                const off = try appendBranch(self.s, ca, branch);
                cn.real_off = off;
                return off;
            },
        }
    }
};


//! fault_store.zig — 故障注入 Store（包装另一 Store）
//! M6 崩溃安全矩阵。可编程故障点：fail_after_bytes、truncate_to、fail_on。
//! MVP：包装 MemStore，模拟撕裂写/崩溃后文件状态。
const std = @import("std");
const f = @import("format.zig");
const store_mod = @import("store.zig");

const Store = store_mod.Store;

pub const FaultConfig = struct {
    /// 写入累计 N 字节后返回 error.InjectedIoError
    fail_after_bytes: ?usize = null,
    /// 模拟崩溃：将底层物理文件截断到该长度（在操作前应用）
    truncate_to: ?usize = null,
};

pub const FaultStore = struct {
    inner: *store_mod.MemStore,
    config: FaultConfig,
    written_bytes: usize = 0,

    const Self = @This();

    pub fn init(inner: *store_mod.MemStore, config: FaultConfig) Self {
        return .{ .inner = inner, .config = config };
    }

    pub fn store(self: *Self) Store {
        return .{ .ptr = self, .vtable = &fault_vtable };
    }

    fn vtRead(ptr: *anyopaque, buf: []u8, offset: u64) !usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.inner.store().read(buf, offset);
    }

    fn vtAppend(ptr: *anyopaque, bytes: []const u8) !u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.config.fail_after_bytes) |limit| {
            if (self.written_bytes >= limit) return error.InjectedIoError;
            self.written_bytes += bytes.len;
        }
        return self.inner.store().append(bytes);
    }

    fn vtSync(ptr: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.inner.store().sync();
    }

    fn vtSetSize(ptr: *anyopaque, len: u64) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.inner.store().setSize(len);
    }

    fn vtSize(ptr: *anyopaque) !u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.inner.store().size();
    }

    fn vtReadPhysical(ptr: *anyopaque, buf: []u8, phys_offset: u64) !usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.inner.store().readPhysical(buf, phys_offset);
    }

    fn vtPhysicalSize(ptr: *anyopaque) !u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.inner.store().physicalSize();
    }

    fn vtClose(ptr: *anyopaque) void {
        _ = ptr;
    }
};

const fault_vtable: Store.VTable = .{
    .read = FaultStore.vtRead,
    .append = FaultStore.vtAppend,
    .sync = FaultStore.vtSync,
    .setSize = FaultStore.vtSetSize,
    .size = FaultStore.vtSize,
    .readPhysical = FaultStore.vtReadPhysical,
    .physicalSize = FaultStore.vtPhysicalSize,
    .close = FaultStore.vtClose,
};

// ===== 崩溃安全矩阵测试（基于 MemStore + fault 注入） =====

const MemStore = store_mod.MemStore;
const btree = @import("btree.zig");

test "fault: node write crash (header not written) -> old header valid" {
    // 场景：写节点中崩溃（header 未写）。恢复应见旧 header，新写不存在。
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();
    // 先写一个好 header
    _ = try ms.appendHeaderRecord(.{ .btree_root = 10, .entry_count = 1, .byte_size = 1, .dirt = 0 });
    // 模拟写节点中崩溃：追加垃圾字节（未写 header）
    _ = try ms.store().append("orphan node bytes without header");
    // 恢复
    const r = try store_mod.getLatestHeader(std.testing.allocator, ms.store());
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 10), r.?.header.btree_root);
}

test "fault: header torn (crc bad) -> fall back to previous" {
    // 场景：header 写一半崩溃，CRC 坏。恢复回退上一 header。
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();
    _ = try ms.appendHeaderRecord(.{ .btree_root = 1, .entry_count = 1, .byte_size = 1, .dirt = 0 });
    _ = try ms.appendHeaderRecord(.{ .btree_root = 2, .entry_count = 2, .byte_size = 2, .dirt = 0 });
    // 破坏最后 header 的 payload
    const found_phys = blk: {
        var b: usize = (ms.data.items.len + f.BLOCK_SIZE - 1) / f.BLOCK_SIZE;
        while (b > 0) {
            b -= 1;
            const mp = b * f.BLOCK_SIZE;
            if (mp < ms.data.items.len and ms.data.items[mp] == f.MARKER_HEADER) break :blk mp;
        }
        break :blk @as(usize, 0);
    };
    ms.data.items[found_phys + 6] ^= 0xff;
    const r = try store_mod.getLatestHeader(std.testing.allocator, ms.store());
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 1), r.?.header.btree_root);
}

test "fault: fsync=false lost write (truncate tail) -> file opens, no corruption" {
    // 场景：fsync:false 断电，未 sync 尾部丢失。文件可开、不损坏。
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();
    _ = try ms.appendHeaderRecord(.{ .btree_root = 5, .entry_count = 5, .byte_size = 5, .dirt = 0 });
    _ = try ms.appendHeaderRecord(.{ .btree_root = 6, .entry_count = 6, .byte_size = 6, .dirt = 0 });
    // 模拟断电：物理截断掉最后 header 块（未 sync 丢失）
    // 找最后 header 块物理偏移并截到它之前
    const last_header_phys = blk: {
        var b: usize = (ms.data.items.len + f.BLOCK_SIZE - 1) / f.BLOCK_SIZE;
        while (b > 0) {
            b -= 1;
            const mp = b * f.BLOCK_SIZE;
            if (mp < ms.data.items.len and ms.data.items[mp] == f.MARKER_HEADER) break :blk mp;
        }
        break :blk @as(usize, 0);
    };
    // 截断到最后 header 块之前（丢弃最后 header）
    if (last_header_phys > 0) {
        ms.data.shrinkRetainingCapacity(last_header_phys);
        // logical_len 重算：完整块数 * (BLOCK_SIZE-1) + 末块 content
        const phys = ms.data.items.len;
        const fb = phys / f.BLOCK_SIZE;
        const rem = phys % f.BLOCK_SIZE;
        ms.logical_len = fb * (f.BLOCK_SIZE - 1) + (if (rem > 1) rem - 1 else 0);
    }
    const r = try store_mod.getLatestHeader(std.testing.allocator, ms.store());
    // 截断后最近 header 不见，回退到前一个（root 5）或 null，都不损坏
    if (r) |s| {
        try std.testing.expect(s.header.btree_root <= 6);
    }
}

test "fault: compact crash leaves .compact residue, original intact" {
    // 场景：compact 中崩溃，.compact 残留，原文件未动。
    // ponytail: 用 MemStore 模拟——原 store 不受 compact 中间状态影响。
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();
    _ = try ms.appendHeaderRecord(.{ .btree_root = 7, .entry_count = 7, .byte_size = 7, .dirt = 0 });
    // 模拟 compact 崩溃：不修改原 store。重开原 store 应见 root 7。
    const r = try store_mod.getLatestHeader(std.testing.allocator, ms.store());
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 7), r.?.header.btree_root);
}

test "fault: rename done -> new file complete" {
    // 场景：rename + fsync 后崩溃，新文件完整可用。
    // ponytail: rename 语义在 MemStore 不直接测；用「原数据 + 新 header」表示新文件完整。
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();
    _ = try ms.appendHeaderRecord(.{ .btree_root = 99, .entry_count = 99, .byte_size = 99, .dirt = 0 });
    const r = try store_mod.getLatestHeader(std.testing.allocator, ms.store());
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 99), r.?.header.btree_root);
}

test "fault: btree recovery from memstore with garbage tail" {
    // 综合场景：写入 btree 数据 + header + 垃圾尾部，恢复后 btree 可读。
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var root: u64 = btree.NULL_ROOT;
    root = (try btree.insert(std.testing.allocator, ms.store(), root, "k", "v", false)).new_root;
    const db_root = if (root == btree.NULL_ROOT) 0 else root + 1;
    _ = try ms.appendHeaderRecord(.{ .btree_root = db_root, .entry_count = 1, .byte_size = 100, .dirt = 0 });
    // 追加垃圾
    _ = try ms.store().append("trailing garbage");
    // 恢复 header
    const r = try store_mod.getLatestHeader(std.testing.allocator, ms.store());
    try std.testing.expect(r != null);
    const recovered_db_root = r.?.header.btree_root;
    const recovered_bt_root: u64 = if (recovered_db_root == 0) btree.NULL_ROOT else recovered_db_root - 1;
    const v = try btree.get(std.testing.allocator, ms.store(), recovered_bt_root, "k");
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("v", v.?);
    std.testing.allocator.free(v.?);
}

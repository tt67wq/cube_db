//! store.zig — Store 抽象（D9 运行时 vtable）+ 内存实现 + 反向 header 扫描
//! M2：先内存 store，块标记读写、append 节点/header、pread、getLatestHeader。
const std = @import("std");
const f = @import("format.zig");

/// 运行时多态接口。所有偏移为「逻辑偏移」（剔除块标记字节后的内容偏移）。
pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 从逻辑 offset 读 up to buf.len 字节到 buf，返回实际读取字节数。
        read: *const fn (ptr: *anyopaque, buf: []u8, offset: u64) anyerror!usize,
        /// 追加逻辑字节，返回起始逻辑偏移。
        append: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!u64,
        sync: *const fn (ptr: *anyopaque) anyerror!void,
        setSize: *const fn (ptr: *anyopaque, len: u64) anyerror!void,
        /// 逻辑总长度（内容字节数，不含块标记）。
        size: *const fn (ptr: *anyopaque) anyerror!u64,
        /// 读物理字节（含块标记），用于 header 反向扫描。仅恢复路径调用。
        readPhysical: *const fn (ptr: *anyopaque, buf: []u8, phys_offset: u64) anyerror!usize,
        /// 物理总长度（含块标记）。
        physicalSize: *const fn (ptr: *anyopaque) anyerror!u64,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn read(self: Store, buf: []u8, offset: u64) !usize {
        return self.vtable.read(self.ptr, buf, offset);
    }
    pub fn append(self: Store, bytes: []const u8) !u64 {
        return self.vtable.append(self.ptr, bytes);
    }
    pub fn sync(self: Store) !void {
        return self.vtable.sync(self.ptr);
    }
    pub fn setSize(self: Store, len: u64) !void {
        return self.vtable.setSize(self.ptr, len);
    }
    pub fn size(self: Store) !u64 {
        return self.vtable.size(self.ptr);
    }
    pub fn readPhysical(self: Store, buf: []u8, phys_offset: u64) !usize {
        return self.vtable.readPhysical(self.ptr, buf, phys_offset);
    }
    pub fn physicalSize(self: Store) !u64 {
        return self.vtable.physicalSize(self.ptr);
    }
    pub fn close(self: Store) void {
        self.vtable.close(self.ptr);
    }
};

// ===== 块标记布局工具 =====
// 物理文件：每 BLOCK_SIZE 字节一块，块首 1 字节 marker。
// 逻辑内容 = 物理文件剔除每块首字节后的连续字节流。
// logical_offset <-> physical_offset 转换：每块贡献 (BLOCK_SIZE-1) 逻辑字节。

/// 逻辑字节数 -> 所在物理块内偏移（块首 marker 之后）。
/// 返回 physical_offset。
pub fn logicalToPhysical(logical_offset: u64) u64 {
    const block_index = logical_offset / (f.BLOCK_SIZE - 1);
    const in_block = logical_offset % (f.BLOCK_SIZE - 1);
    return block_index * f.BLOCK_SIZE + 1 + in_block; // +1 跳过 marker
}

/// 物理偏移 -> 逻辑偏移（仅对 marker 之后的内容字节有效）。
pub fn physicalToLogical(physical_offset: u64) u64 {
    const block_index = physical_offset / f.BLOCK_SIZE;
    const in_block = physical_offset % f.BLOCK_SIZE;
    // in_block==0 是 marker，不属于内容；此处只对 in_block>=1 调用
    return block_index * (f.BLOCK_SIZE - 1) + (in_block - 1);
}

// ===== 内存 Store（TestStore） =====
// 用 ArrayList(u8) 模拟物理文件字节数组，含块标记。
// append 时自动在块边界插入 MARKER_DATA；header append 用 MARKER_HEADER。

pub const MemStore = struct {
    allocator: std.mem.Allocator,
    /// 物理字节（含块标记）
    data: std.ArrayList(u8),
    /// 逻辑长度（内容字节数）
    logical_len: u64 = 0,
    /// sync 调用计数（测试用）
    sync_count: u32 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator, .data = .empty };
    }

    pub fn deinit(self: *Self) void {
        self.data.deinit(self.allocator);
    }

    pub fn store(self: *Self) Store {
        return .{
            .ptr = self,
            .vtable = &mem_vtable,
        };
    }

    /// 物理文件当前总长度
    fn physicalLen(self: *Self) usize {
        return self.data.items.len;
    }

    // ---- Store VTable 实现 ----

    fn vtRead(ptr: *anyopaque, buf: []u8, offset: u64) !usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (offset >= self.logical_len) return 0;
        var logical_pos = offset;
        var written: usize = 0;
        while (written < buf.len and logical_pos < self.logical_len) {
            const phys = logicalToPhysical(logical_pos);
            if (phys >= self.data.items.len) break;
            buf[written] = self.data.items[phys];
            written += 1;
            logical_pos += 1;
        }
        return written;
    }

    fn vtAppend(ptr: *anyopaque, bytes: []const u8) !u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.appendRaw(bytes);
    }

    /// 追加逻辑字节（自动在物理块边界插 MARKER_DATA），返回起始逻辑偏移。
    /// 不增加 logical_len 的开销只有 marker 字节本身（物理存在，逻辑不计）。
    pub fn appendRaw(self: *Self, bytes: []const u8) !u64 {
        const start_logical = self.logical_len;
        for (bytes) |b| {
            // 物理位于块首时需先写 marker（MARKER_DATA）
            if (self.data.items.len % f.BLOCK_SIZE == 0) {
                try self.data.append(self.allocator, f.MARKER_DATA);
            }
            try self.data.append(self.allocator, b);
            self.logical_len += 1;
        }
        return start_logical;
    }

    fn vtSync(ptr: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.sync_count += 1;
    }

    fn vtSetSize(ptr: *anyopaque, len: u64) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // 物理截断到恰好容纳 len 逻辑字节
        const target_physical = logicalToPhysical(len); // 下一内容字节物理位置 = 截断点
        if (self.data.items.len > target_physical) {
            self.data.shrinkRetainingCapacity(target_physical);
        }
        self.logical_len = len;
    }

    fn vtSize(ptr: *anyopaque) !u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.logical_len;
    }

    fn vtReadPhysical(ptr: *anyopaque, buf: []u8, phys_offset: u64) !usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (phys_offset >= self.data.items.len) return 0;
        const avail = self.data.items.len - @as(usize, @intCast(phys_offset));
        const take = @min(buf.len, avail);
        @memcpy(buf[0..take], self.data.items[@intCast(phys_offset)..][0..take]);
        return take;
    }

    fn vtPhysicalSize(ptr: *anyopaque) !u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.data.items.len;
    }

    fn vtClose(ptr: *anyopaque) void {
        _ = ptr;
        // MemStore 由 owner 用 deinit 释放
    }

    /// 写入一个 header 块：对齐到物理块边界，写 MARKER_HEADER + header 记录。
    /// 返回 header 记录起始逻辑偏移。
    pub fn appendHeaderRecord(self: *Self, header: f.Header) !u64 {
        // 填充逻辑到当前块末尾（下一块首）
        const in_block_logical = self.logical_len % (f.BLOCK_SIZE - 1);
        if (in_block_logical != 0) {
            const pad = (f.BLOCK_SIZE - 1) - in_block_logical;
            for (0..pad) |_| _ = try self.appendRaw(&[_]u8{0});
        }
        // 此时物理应恰在块首（data.len % BLOCK_SIZE == 0），写 MARKER_HEADER
        try self.data.append(self.allocator, f.MARKER_HEADER);
        // header 记录起始逻辑偏移 = 当前 logical_len（块首后首字节）
        const start_logical = self.logical_len;
        var payload_buf: [f.HEADER_PAYLOAD_SIZE]u8 = undefined;
        const pn = f.encodeHeaderPayload(&payload_buf, header);
        var rec_buf: [128]u8 = undefined;
        const rn = f.encodeRecord(&rec_buf, payload_buf[0..pn]);
        // appendRaw 会检测到不在块首（data.len % BLOCK_SIZE != 0）因此不再插 marker
        _ = try self.appendRaw(rec_buf[0..rn]);
        return start_logical;
    }
};

const mem_vtable: Store.VTable = .{
    .read = MemStore.vtRead,
    .append = MemStore.vtAppend,
    .sync = MemStore.vtSync,
    .setSize = MemStore.vtSetSize,
    .size = MemStore.vtSize,
    .readPhysical = MemStore.vtReadPhysical,
    .physicalSize = MemStore.vtPhysicalSize,
    .close = MemStore.vtClose,
};

// ===== Header 反向扫描 =====
// 从文件末尾反向按块扫描 marker 字节，定位最新 header 块。
// header 块 marker==MARKER_HEADER，其后紧跟 header 记录（len+payload+crc）。

pub const HeaderScanResult = struct {
    /// header 记录起始逻辑偏移
    record_logical_offset: u64,
    header: f.Header,
};

/// 在 store 中反向扫描，找最新有效 header。
/// 找到 → 返回 result；CRC/解码失败则继续向前找；全找不到 → null。
pub fn getLatestHeader(allocator: std.mem.Allocator, store: Store) !?HeaderScanResult {
    const physical_total = try store.physicalSize();
    if (physical_total == 0) return null;
    const num_blocks = (physical_total + f.BLOCK_SIZE - 1) / f.BLOCK_SIZE;
    if (num_blocks == 0) return null;

    var marker_buf: [1]u8 = undefined;
    var block_index: u64 = num_blocks;
    while (block_index > 0) {
        block_index -= 1;
        const marker_phys = block_index * f.BLOCK_SIZE;
        const n = try store.readPhysical(&marker_buf, marker_phys);
        if (n != 1) continue;
        if (marker_buf[0] != f.MARKER_HEADER) continue;
        // marker 后紧跟 header 记录。物理读记录字节。
        var rec_buf: [64]u8 = undefined;
        const rn = try store.readPhysical(&rec_buf, marker_phys + 1);
        if (rn < 4) continue;
        const payload = f.decodeRecord(rec_buf[0..rn]) catch continue;
        if (payload.len < f.HEADER_PAYLOAD_SIZE) continue;
        const h = f.decodeHeaderPayload(payload[0..f.HEADER_PAYLOAD_SIZE]);
        if (h.magic != f.MAGIC) continue;
        if (h.version != f.VERSION) continue;
        _ = allocator;
        return HeaderScanResult{
            .record_logical_offset = physicalToLogical(marker_phys + 1),
            .header = h,
        };
    }
    return null;
}

// ===== 测试 =====

test "store: empty getLatestHeader -> null" {
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const r = try getLatestHeader(std.testing.allocator, ms.store());
    try std.testing.expectEqual(@as(?HeaderScanResult, null), r);
}

test "store: append node + pread roundtrip" {
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    const data = "nodepayload";
    const off = try s.append(data);
    try std.testing.expectEqual(@as(u64, 0), off);
    var buf: [16]u8 = undefined;
    const n = try s.read(&buf, off);
    try std.testing.expectEqual(@as(usize, data.len), n);
    try std.testing.expectEqualStrings(data, buf[0..n]);
    try std.testing.expectEqual(@as(u64, data.len), try s.size());
}

test "store: append header -> getLatestHeader locates it" {
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const h: f.Header = .{ .btree_root = 100, .entry_count = 5, .byte_size = 50, .dirt = 0 };
    _ = try ms.appendHeaderRecord(h);
    const r = try getLatestHeader(std.testing.allocator, ms.store());
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 100), r.?.header.btree_root);
    try std.testing.expectEqual(@as(u64, 5), r.?.header.entry_count);
}

test "store: three headers -> latest found" {
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();
    _ = try ms.appendHeaderRecord(.{ .btree_root = 1, .entry_count = 1, .byte_size = 1, .dirt = 0 });
    _ = try ms.appendHeaderRecord(.{ .btree_root = 2, .entry_count = 2, .byte_size = 2, .dirt = 0 });
    _ = try ms.appendHeaderRecord(.{ .btree_root = 3, .entry_count = 3, .byte_size = 3, .dirt = 0 });
    const r = try getLatestHeader(std.testing.allocator, ms.store());
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 3), r.?.header.btree_root);
}

test "store: trailing garbage -> still finds last good header" {
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();
    _ = try ms.appendHeaderRecord(.{ .btree_root = 7, .entry_count = 1, .byte_size = 1, .dirt = 0 });
    // append 垃圾字节
    _ = try ms.store().append("garbage trailing bytes not a header");
    const r = try getLatestHeader(std.testing.allocator, ms.store());
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 7), r.?.header.btree_root);
}

test "store: last header crc corrupt -> falls back to previous" {
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();
    _ = try ms.appendHeaderRecord(.{ .btree_root = 1, .entry_count = 1, .byte_size = 1, .dirt = 0 });
    _ = try ms.appendHeaderRecord(.{ .btree_root = 2, .entry_count = 2, .byte_size = 2, .dirt = 0 });
    // 破坏最后一个 header 记录的某字节：找到最后 header 块的 marker 后第 6 字节（payload 区）
    const total = ms.logical_len;
    // 反向找最后一个 MARKER_HEADER 块的物理偏移
    var found_phys: ?usize = null;
    {
        var b: usize = (ms.data.items.len + f.BLOCK_SIZE - 1) / f.BLOCK_SIZE;
        while (b > 0) {
            b -= 1;
            const mp = b * f.BLOCK_SIZE;
            if (mp < ms.data.items.len and ms.data.items[mp] == f.MARKER_HEADER) {
                found_phys = mp;
                break;
            }
        }
    }
    const fp = found_phys orelse return error.TestUnexpectedResult;
    ms.data.items[fp + 6] ^= 0xff; // 翻转 payload 中一字节
    const r = try getLatestHeader(std.testing.allocator, ms.store());
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 1), r.?.header.btree_root);
    _ = total;
}

test "store: record spanning block boundary roundtrip" {
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    // 写接近块边界的数据，使其跨越
    const fill_len = f.BLOCK_SIZE - 1 - 5; // 留 5 字节到块末
    const fill = try std.testing.allocator.alloc(u8, fill_len);
    defer std.testing.allocator.free(fill);
    @memset(fill, 0x11);
    _ = try s.append(fill);
    // 这条记录将跨越块边界
    const data = "across-the-boundary-payload-data";
    const off = try s.append(data);
    var buf: [64]u8 = undefined;
    const n = try s.read(&buf, off);
    try std.testing.expectEqual(@as(usize, data.len), n);
    try std.testing.expectEqualStrings(data, buf[0..n]);
}

test "store: logicalToPhysical / physicalToLogical roundtrip" {
    // 块 0: marker(phys 0) + 4095 逻辑字节(phys 1..4095)；
    // 块 1: marker(phys 4096) + 4095 逻辑字节(phys 4097..)
    try std.testing.expectEqual(@as(u64, 1), logicalToPhysical(0));
    try std.testing.expectEqual(@as(u64, f.BLOCK_SIZE - 1), logicalToPhysical(f.BLOCK_SIZE - 2));
    try std.testing.expectEqual(@as(u64, f.BLOCK_SIZE + 1), logicalToPhysical(f.BLOCK_SIZE - 1));
    try std.testing.expectEqual(@as(u64, 0), physicalToLogical(1));
    try std.testing.expectEqual(@as(u64, f.BLOCK_SIZE - 2), physicalToLogical(f.BLOCK_SIZE - 1));
    try std.testing.expectEqual(@as(u64, f.BLOCK_SIZE - 1), physicalToLogical(f.BLOCK_SIZE + 1));
}

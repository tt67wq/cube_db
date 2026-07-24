//! store.zig — Store 抽象（运行时 vtable）+ 内存实现 + header 正向扫描
//! 去 marker：appendRaw 写连续逻辑字节（逻辑==物理），readBorrow 借用切片零拷贝。
const std = @import("std");
const f = @import("format.zig");

/// 运行时多态接口。所有偏移为「逻辑偏移」（去 marker 后逻辑==物理）。
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
        /// 逻辑总长度（内容字节数，== 物理长度，去 marker 后）。
        size: *const fn (ptr: *anyopaque) anyerror!u64,
        /// 读物理字节（逻辑==物理，保留供兼容）。仅恢复路径调用。
        readPhysical: *const fn (ptr: *anyopaque, buf: []u8, phys_offset: u64) anyerror!usize,
        /// 物理总长度（== 逻辑长度，去 marker 后）。
        physicalSize: *const fn (ptr: *anyopaque) anyerror!u64,
        /// 借用切片：返指向 mmap/ArrayList 的只读切片（不 alloc 不 memcpy，零拷贝）。
        /// bounds-check：offset <= logical_len；返 min(max, logical_len-offset) 字节。
        readBorrow: *const fn (ptr: *anyopaque, offset: u64, max: usize) anyerror![]const u8,
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
    /// 借用只读切片（零拷贝）。
    pub fn readBorrow(self: Store, offset: u64, max: usize) ![]const u8 {
        return self.vtable.readBorrow(self.ptr, offset, max);
    }
    pub fn close(self: Store) void {
        self.vtable.close(self.ptr);
    }
};

// ===== offset 转换（去 marker 后逻辑==物理，identity） =====

/// 逻辑 offset -> 物理 offset（去 marker 后 identity）。
pub fn logicalToPhysical(logical_offset: u64) u64 {
    return logical_offset;
}

/// 物理 offset -> 逻辑 offset（去 marker 后 identity）。
pub fn physicalToLogical(physical_offset: u64) u64 {
    return physical_offset;
}

// ===== 内存 Store（TestStore） =====
// 去 marker：appendRaw 写连续逻辑字节（逻辑==物理）。header append 不再对齐/写 marker。

pub const MemStore = struct {
    allocator: std.mem.Allocator,
    /// 字节（逻辑==物理，去 marker）
    data: std.ArrayList(u8),
    /// 逻辑长度（== 物理长度，去 marker）
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
        const avail = self.logical_len - offset;
        const take = @min(buf.len, avail);
        @memcpy(buf[0..take], self.data.items[@intCast(offset)..][0..take]);
        return take;
    }

    fn vtAppend(ptr: *anyopaque, bytes: []const u8) !u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.appendRaw(bytes);
    }

    /// 追加连续逻辑字节（去 marker，逻辑==物理），返回起始逻辑偏移。
    pub fn appendRaw(self: *Self, bytes: []const u8) !u64 {
        const start_logical = self.logical_len;
        try self.data.appendSlice(self.allocator, bytes);
        self.logical_len += bytes.len;
        return start_logical;
    }

    fn vtSync(ptr: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.sync_count += 1;
    }

    fn vtSetSize(ptr: *anyopaque, len: u64) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // 去 marker 后物理截断 == 逻辑截断
        const target: usize = @intCast(len);
        if (self.data.items.len > target) {
            self.data.shrinkRetainingCapacity(target);
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

    fn vtReadBorrow(ptr: *anyopaque, offset: u64, max: usize) ![]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (offset >= self.logical_len) return &[_]u8{};
        const start: usize = @intCast(offset);
        const avail = self.logical_len - offset;
        const take = @min(max, avail);
        return self.data.items[start..][0..take];
    }

    fn vtClose(ptr: *anyopaque) void {
        _ = ptr;
        // MemStore 由 owner 用 deinit 释放
    }

    /// 写入 header 记录（去 marker：不再对齐/写 MARKER_HEADER，直接 appendRaw）。
    /// 返回 header 记录起始逻辑偏移。
    pub fn appendHeaderRecord(self: *Self, header: f.Header) !u64 {
        const start_logical = self.logical_len;
        var payload_buf: [f.HEADER_PAYLOAD_SIZE]u8 = undefined;
        const pn = f.encodeHeaderPayload(&payload_buf, header);
        var rec_buf: [128]u8 = undefined;
        const rn = f.encodeRecord(&rec_buf, payload_buf[0..pn]);
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
    .readBorrow = MemStore.vtReadBorrow,
    .close = MemStore.vtClose,
};

// ===== Header 正向扫描（去 marker 后） =====
// 从 offset 0 按记录长度一条条走，记最后一个有效 header（payload 有 magic+version）。
// 文件尾写一半（crash，crc 不对或 len 超 EOF）→ 解析失败，停在最后一个有效 header。

pub const HeaderScanResult = struct {
    /// header 记录起始逻辑偏移
    record_logical_offset: u64,
    header: f.Header,
};

/// 在 store 中正向扫描，找最新有效 header。
/// 按 [len(4)][payload(len)][crc(4)] 记录结构走；判别 header 靠 payload magic+version。
/// 遇解析失败（truncated/crc 错）则停，返回最后一个有效 header；全找不到 → null。
pub fn getLatestHeader(allocator: std.mem.Allocator, store: Store) !?HeaderScanResult {
    _ = allocator;
    const total = try store.physicalSize();
    if (total == 0) return null;
    var last: ?HeaderScanResult = null;
    var off: u64 = 0;
    while (off < total) {
        // 读 len(4)
        const len_slice = store.readBorrow(off, 4) catch break;
        if (len_slice.len < 4) break;
        const payload_len = std.mem.readInt(u32, len_slice[0..4], .big);
        const rec_total = f.REC_LEN_SIZE + payload_len + f.REC_CRC_SIZE;
        // 整记录越界 → crash 半写，停
        if (off + rec_total > total) break;
        // 借用整记录
        const rec = store.readBorrow(off, rec_total) catch break;
        if (rec.len < rec_total) break;
        const payload = f.decodeRecord(rec) catch break; // crc 错则停
        // 判别 header：payload 长度 == HEADER_PAYLOAD_SIZE 且 magic/version 对
        if (payload.len >= f.HEADER_PAYLOAD_SIZE) {
            const h = f.decodeHeaderPayload(payload[0..f.HEADER_PAYLOAD_SIZE]);
            if (h.magic == f.MAGIC and h.version == f.VERSION) {
                last = .{ .record_logical_offset = off, .header = h };
            }
        }
        off += rec_total;
    }
    return last;
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
    // append 垃圾字节（不是合法记录结构）——正扫解析失败停在最后一个有效 header
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
    // 破坏最后 header 记录的 payload 区一字节（len 在前 4、payload 从第 5 起；翻第 6 字节）
    const total = ms.logical_len;
    ms.data.items[@intCast(total - 6)] ^= 0xff;
    const r = try getLatestHeader(std.testing.allocator, ms.store());
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 1), r.?.header.btree_root);
}

test "store: large append roundtrip (no marker, logical==physical)" {
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    const N: usize = 8192;
    const data = try std.testing.allocator.alloc(u8, N);
    defer std.testing.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @intCast(i % 251);
    _ = try s.append(data);
    try std.testing.expectEqual(@as(u64, N), try s.size());
    try std.testing.expectEqual(try s.size(), try s.physicalSize()); // logical==physical
    const got = try std.testing.allocator.alloc(u8, N);
    defer std.testing.allocator.free(got);
    var rt: usize = 0;
    while (rt < N) {
        const n = try s.read(got[rt..], @intCast(rt));
        try std.testing.expect(n > 0);
        rt += n;
    }
    try std.testing.expectEqualSlices(u8, data, got);
}

test "store: logicalToPhysical / physicalToLogical identity" {
    // 去 marker 后逻辑==物理
    try std.testing.expectEqual(@as(u64, 0), logicalToPhysical(0));
    try std.testing.expectEqual(@as(u64, 4096), logicalToPhysical(4096));
    try std.testing.expectEqual(@as(u64, 0), physicalToLogical(0));
    try std.testing.expectEqual(@as(u64, 4096), physicalToLogical(4096));
}

test "store: readBorrow returns borrowed slice" {
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    const data = "borrowed-data";
    const off = try s.append(data);
    const got = try s.readBorrow(off, data.len);
    try std.testing.expectEqualStrings(data, got);
    const empty = try s.readBorrow(try s.size(), 10);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

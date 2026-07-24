//! file_store.zig — FileStore：真文件 Store（zio.File）+ mmap 零拷贝读
//! 去 marker：appendRaw 写连续逻辑字节（逻辑==物理）；readBorrow 借用 mmap 切片零拷贝。
const std = @import("std");
const zio = @import("zio");
const f = @import("format.zig");
const store_mod = @import("store.zig");
const mmap_mod = @import("mmap.zig");

const Store = store_mod.Store;

/// 预留 mmap 虚拟区大小（1 TB，sparse 几乎不占资源）。
/// append-only COW 下 reader 沿 root 有效 offset ≤ backing，不越界。
const MMAP_REGION: usize = 1 << 40;

pub const FileStore = struct {
    allocator: std.mem.Allocator,
    file: zio.File,
    /// 逻辑长度（== 物理长度，去 marker）
    logical_len: u64,
    /// 物理写入游标（== 逻辑长度，去 marker）
    physical_len: u64,
    sync_count: u32 = 0,
    /// mmap 预留区基指针（null = mmap 失败/未用，回退 pread）
    mmap_base: ?[*]align(mmap_mod.PAGE_SIZE) u8 = null,
    /// mmap 预留区长度
    mmap_region_len: usize = 0,

    const Self = @This();

    /// 创建/打开数据文件。exclusive=false 允许已存在。
    pub fn create(allocator: std.mem.Allocator, path: []const u8) !Self {
        const cwd = zio.Dir.cwd();
        const file = try cwd.createFile(path, .{ .read = true, .truncate = false, .exclusive = false });
        // 取现有大小（去 marker 后物理==逻辑）
        const phys = file.size() catch 0;
        var self: Self = .{
            .allocator = allocator,
            .file = file,
            .logical_len = phys,
            .physical_len = phys,
        };
        // mmap 预留大区只读 MAP_SHARED。失败则保持 mmap_base=null 回退 pread。
        if (mmap_mod.mapReadOnly(@intCast(file.fd), MMAP_REGION)) |ptr| {
            self.mmap_base = ptr;
            self.mmap_region_len = MMAP_REGION;
        } else |_| {
            // 回退 pread 路径（功能不退化，但非零拷贝）
        }
        return self;
    }

    pub fn store(self: *Self) Store {
        return .{ .ptr = self, .vtable = &file_vtable };
    }

    fn vtRead(ptr: *anyopaque, buf: []u8, offset: u64) !usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (offset >= self.logical_len) return 0;
        // 去 marker：逻辑==物理，mmap 直 memcpy 或 pread（无 marker 跳转）
        if (self.mmap_base) |base| {
            const avail = self.logical_len - offset;
            const take = @min(buf.len, avail);
            const src = base + offset;
            @memcpy(buf[0..take], src[0..take]);
            return take;
        }
        // 回退 pread（无 marker，一次读到位）
        const avail = self.logical_len - offset;
        const take = @min(buf.len, avail);
        var read_total: usize = 0;
        while (read_total < take) {
            const n = try self.file.read(buf[read_total..take], offset + read_total);
            if (n == 0) break;
            read_total += n;
        }
        return read_total;
    }

    fn vtReadBorrow(ptr: *anyopaque, offset: u64, max: usize) ![]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (offset >= self.logical_len) return &[_]u8{};
        const avail = self.logical_len - offset;
        const take = @min(max, avail);
        if (self.mmap_base) |base| {
            // 零拷贝：返回指向 mmap 的切片
            const src = base + offset;
            return src[0..take];
        }
        // 无 mmap：回退 pread 到内部小缓存（FileStore 默认有 mmap，此路径极少）
        // ponytail: 回退时借用不可行（pread 需 caller buf），返错误让 readRecord 回退 alloc。
        return error.NoMmapBorrow;
    }

    /// 追加连续逻辑字节（去 marker，逻辑==物理），返回起始逻辑偏移。
    pub fn appendRaw(self: *Self, bytes: []const u8) !u64 {
        const start_logical = self.logical_len;
        var i: usize = 0;
        while (i < bytes.len) {
            const n = try self.file.write(bytes[i..], self.physical_len);
            self.physical_len += n;
            self.logical_len += n;
            i += n;
        }
        return start_logical;
    }

    fn vtAppend(ptr: *anyopaque, bytes: []const u8) !u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.appendRaw(bytes);
    }

    fn vtSync(ptr: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.file.sync(.{ .only_data = false });
        self.sync_count += 1;
    }

    fn vtSetSize(ptr: *anyopaque, len: u64) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // 去 marker 后物理截断 == 逻辑截断
        try self.file.setSize(len);
        self.physical_len = len;
        self.logical_len = len;
    }

    fn vtSize(ptr: *anyopaque) !u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.logical_len;
    }

    fn vtReadPhysical(ptr: *anyopaque, buf: []u8, phys_offset: u64) !usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.file.read(buf, phys_offset);
    }

    fn vtPhysicalSize(ptr: *anyopaque) !u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.physical_len;
    }

    fn vtClose(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.mmap_base) |base| {
            mmap_mod.unmap(base, self.mmap_region_len);
            self.mmap_base = null;
        }
        self.file.close();
    }

    pub fn close(self: *Self) void {
        if (self.mmap_base) |base| {
            mmap_mod.unmap(base, self.mmap_region_len);
            self.mmap_base = null;
        }
        self.file.close();
    }
};

const file_vtable: Store.VTable = .{
    .read = FileStore.vtRead,
    .append = FileStore.vtAppend,
    .sync = FileStore.vtSync,
    .setSize = FileStore.vtSetSize,
    .size = FileStore.vtSize,
    .readPhysical = FileStore.vtReadPhysical,
    .physicalSize = FileStore.vtPhysicalSize,
    .readBorrow = FileStore.vtReadBorrow,
    .close = FileStore.vtClose,
};

// ===== header append（去 marker：直接 appendRaw，不对齐/不写 marker） =====
pub fn appendHeaderRecord(self: *FileStore, header: f.Header) !u64 {
    const start_logical = self.logical_len;
    var payload_buf: [f.HEADER_PAYLOAD_SIZE]u8 = undefined;
    const pn = f.encodeHeaderPayload(&payload_buf, header);
    var rec_buf: [128]u8 = undefined;
    const rn = f.encodeRecord(&rec_buf, payload_buf[0..pn]);
    _ = try self.appendRaw(rec_buf[0..rn]);
    return start_logical;
}

// ===== 测试 =====
const store = store_mod;

test "file_store: open create + append + pread roundtrip" {
    const path = "cube_db_filestore_test.db";
    const cwd = zio.Dir.cwd();
    cwd.deleteFile(path) catch {};

    var fs = try FileStore.create(std.testing.allocator, path);
    defer fs.close();
    defer cwd.deleteFile(path) catch {};
    const s = fs.store();
    const data = "hello-file-store";
    const off = try s.append(data);
    try std.testing.expectEqual(@as(u64, 0), off);
    var buf: [32]u8 = undefined;
    const n = try s.read(&buf, off);
    try std.testing.expectEqual(@as(usize, data.len), n);
    try std.testing.expectEqualStrings(data, buf[0..n]);
    try std.testing.expectEqual(@as(u64, data.len), try s.size());
    // 去 marker：物理==逻辑
    try std.testing.expectEqual(try s.size(), try s.physicalSize());
}

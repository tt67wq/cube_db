//! file_store.zig — FileStore：真文件 Store（zio.File）+ 块标记
//! 复用 store.zig 的逻辑偏移/marker 语义。append/read/sync/setSize/size 走 zio.File 位置 IO。
//! M2 集成（真文件路径）。
const std = @import("std");
const zio = @import("zio");
const f = @import("format.zig");
const store_mod = @import("store.zig");

const Store = store_mod.Store;

pub const FileStore = struct {
    allocator: std.mem.Allocator,
    file: zio.File,
    /// 逻辑长度（内容字节数，不含块标记）
    logical_len: u64,
    /// 物理写入游标（含块标记）
    physical_len: u64,
    sync_count: u32 = 0,

    const Self = @This();

    /// 创建/打开数据文件。exclusive=false 允许已存在。
    pub fn create(allocator: std.mem.Allocator, path: []const u8) !Self {
        const cwd = zio.Dir.cwd();
        const file = try cwd.createFile(path, .{ .read = true, .truncate = false, .exclusive = false });
        // 取现有大小
        const phys = file.size() catch 0;
        // 从物理大小反推逻辑长度：每块 BLOCK_SIZE 字节含 1 marker + (BLOCK_SIZE-1) 内容
        // 完整块数 * (BLOCK_SIZE-1) + 末块内容数（末块物理字节 - marker）
        const full_blocks = phys / f.BLOCK_SIZE;
        const rem = phys % f.BLOCK_SIZE;
        var logical: u64 = full_blocks * (f.BLOCK_SIZE - 1);
        if (rem > 0) {
            // 末块至少 1 字节 marker；若 rem==1 仅 marker 无内容
            if (rem > 1) logical += rem - 1;
        }
        return .{
            .allocator = allocator,
            .file = file,
            .logical_len = logical,
            .physical_len = phys,
        };
    }

    pub fn store(self: *Self) Store {
        return .{ .ptr = self, .vtable = &file_vtable };
    }

    fn vtRead(ptr: *anyopaque, buf: []u8, offset: u64) !usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (offset >= self.logical_len) return 0;
        var logical_pos = offset;
        var written: usize = 0;
        while (written < buf.len and logical_pos < self.logical_len) {
            const phys = store_mod.logicalToPhysical(logical_pos);
            const remain_logical = self.logical_len - logical_pos;
            const want = @min(buf.len - written, remain_logical);
            const block_content_pos = logical_pos % (f.BLOCK_SIZE - 1);
            const block_remaining = (f.BLOCK_SIZE - 1) - block_content_pos;
            const take = @min(want, block_remaining);
            const n = try self.file.read(buf[written .. written + take], phys);
            written += n;
            logical_pos += n;
            if (n == 0) break;
        }
        return written;
    }

    /// 追加逻辑字节（自动插 MARKER_DATA），返回起始逻辑偏移。
    pub fn appendRaw(self: *Self, bytes: []const u8) !u64 {
        const start_logical = self.logical_len;
        var i: usize = 0;
        while (i < bytes.len) {
            if (self.physical_len % f.BLOCK_SIZE == 0) {
                // 写 marker
                _ = try self.file.write(&[_]u8{f.MARKER_DATA}, self.physical_len);
                self.physical_len += 1;
            }
            // 同块内连续写
            const block_remaining = f.BLOCK_SIZE - (self.physical_len % f.BLOCK_SIZE);
            const take = @min(bytes.len - i, block_remaining);
            const n = try self.file.write(bytes[i .. i + take], self.physical_len);
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
        // 物理截断到恰好容纳 len 逻辑字节
        const target_physical = store_mod.logicalToPhysical(len);
        try self.file.setSize(target_physical);
        self.physical_len = target_physical;
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
        self.file.close();
    }

    pub fn close(self: *Self) void {
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
    .close = FileStore.vtClose,
};

// ===== header append（复用 store.zig 语义，但写物理） =====
pub fn appendHeaderRecord(self: *FileStore, header: f.Header) !u64 {
    // 填充到块末尾
    const in_block_logical = self.logical_len % (f.BLOCK_SIZE - 1);
    if (in_block_logical != 0) {
        const pad = (f.BLOCK_SIZE - 1) - in_block_logical;
        const padding = try self.allocator.alloc(u8, pad);
        defer self.allocator.free(padding);
        @memset(padding, 0);
        _ = try self.appendRaw(padding);
    }
    // 写 MARKER_HEADER
    _ = try self.file.write(&[_]u8{f.MARKER_HEADER}, self.physical_len);
    self.physical_len += 1;
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
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const Tmp = struct {
        fn run() !void {
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
        }
    };
    var h = try rt.spawn(Tmp.run, .{});
    h.join() catch {};
}

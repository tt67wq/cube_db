//! src/wal.zig — Write-Ahead Log for LSM memtable persistence.
//! Append-only, CRC32-validated, checkpoint/truncate for compaction.
//!
//! Uses raw POSIX file I/O (no zio/std.io event loop dependency).
//!
//! Format:
//!   [header: magic(8) + version(4)]
//!   [entry: type(1) + key_len(4) + val_len(4) + key(N) + val(M) + crc32(4)]
const std = @import("std");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

pub const MAGIC: [8]u8 = .{ 'C', 'U', 'B', 'E', 'W', 'A', 'L', 0 };
pub const VERSION: u32 = 1;

pub const EntryType = enum(u8) {
    put = 0,
    delete = 1,
};

pub const Entry = struct {
    entry_type: EntryType,
    key: []const u8,
    value: []const u8,
};

fn tot(offset: u64) c.off_t {
    return @as(c.off_t, @intCast(offset));
}

fn toVoidPtr(ptr: anytype) ?*const anyopaque {
    return @ptrCast(ptr);
}

fn toVoidMutPtr(ptr: anytype) ?*anyopaque {
    return @ptrCast(ptr);
}

pub const Wal = struct {
    allocator: std.mem.Allocator,
    fd: i32,
    path: []const u8,
    append_pos: u64,
    checkpoint_pos: u64,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Wal {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const fd = c.open(path_z.ptr, c.O_RDWR | c.O_CREAT, @as(c.mode_t, 0o664));
        if (fd == -1) return error.OpenFailed;
        errdefer _ = c.close(fd);

        const file_len = c.lseek(fd, 0, c.SEEK_END);
        var append_pos: u64 = @intCast(@as(i64, @intCast(file_len)));

        if (file_len == 0) {
            _ = c.pwrite(fd, &MAGIC, 8, 0);
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, VERSION, .little);
            _ = c.pwrite(fd, &buf, 4, 8);
            append_pos = 12;
        } else if (file_len < 12) {
            _ = c.ftruncate(fd, 0);
            _ = c.pwrite(fd, &MAGIC, 8, 0);
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, VERSION, .little);
            _ = c.pwrite(fd, &buf, 4, 8);
            append_pos = 12;
        } else {
            var magic_buf: [8]u8 = undefined;
            _ = c.pread(fd, &magic_buf, 8, 0);
            if (!std.mem.eql(u8, &magic_buf, &MAGIC)) {
                _ = c.ftruncate(fd, 0);
                _ = c.pwrite(fd, &MAGIC, 8, 0);
                var buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &buf, VERSION, .little);
                _ = c.pwrite(fd, &buf, 4, 8);
                append_pos = 12;
            }
        }

        return Wal{
            .allocator = allocator,
            .fd = fd,
            .path = try allocator.dupe(u8, path),
            .append_pos = append_pos,
            .checkpoint_pos = 12,
        };
    }

    pub fn deinit(self: *Wal) void {
        _ = c.close(self.fd);
        self.allocator.free(self.path);
    }

    pub fn append(self: *Wal, entry_type: EntryType, key: []const u8, value: []const u8) !u64 {
        const pos = self.append_pos;

        var hdr: [9]u8 = undefined;
        hdr[0] = @intFromEnum(entry_type);
        std.mem.writeInt(u32, hdr[1..][0..4], @as(u32, @intCast(key.len)), .little);
        std.mem.writeInt(u32, hdr[5..][0..4], @as(u32, @intCast(value.len)), .little);

        var crc = std.hash.Crc32.init();
        crc.update(hdr[0..9]);
        crc.update(key);
        crc.update(value);
        const crc_val = crc.final();

        var crc_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_buf, @as(u32, crc_val), .little);

        _ = c.pwrite(self.fd, &hdr, 9, tot(pos));
        _ = c.pwrite(self.fd, key.ptr, key.len, tot(pos + 9));
        _ = c.pwrite(self.fd, value.ptr, value.len, tot(pos + 9 + key.len));
        _ = c.pwrite(self.fd, &crc_buf, 4, tot(pos + 9 + key.len + value.len));

        self.append_pos = pos + 9 + key.len + value.len + 4;
        return pos;
    }

    pub fn replay(self: *Wal) ![]Entry {
        var entries = std.ArrayList(Entry).empty;
        errdefer {
            for (entries.items) |e| {
                self.allocator.free(e.key);
                self.allocator.free(e.value);
            }
            entries.deinit(self.allocator);
        }

        const file_size = c.lseek(self.fd, 0, c.SEEK_END);
        if (file_size <= 12) return entries.toOwnedSlice(self.allocator);

        const payload_len: usize = @intCast(file_size - 12);
        const buf = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(buf);
        _ = c.pread(self.fd, buf.ptr, buf.len, 12);

        var offset: usize = 0;
        while (offset + 9 <= buf.len) {
            const type_byte = buf[offset];
            const key_len = std.mem.readInt(u32, buf[offset + 1 ..][0..4], .little);
            const val_len = std.mem.readInt(u32, buf[offset + 5 ..][0..4], .little);

            if (key_len > 1_000_000 or val_len > 100_000_000) break;

            const entry_size = 9 + key_len + val_len + 4;
            if (offset + entry_size > buf.len) break;

            var crc = std.hash.Crc32.init();
            crc.update(buf[offset .. offset + 9]);
            crc.update(buf[offset + 9 .. offset + 9 + key_len]);
            crc.update(buf[offset + 9 + key_len .. offset + 9 + key_len + val_len]);
            const computed_crc = @as(u32, crc.final());
            const stored_crc = std.mem.readInt(u32, buf[offset + entry_size - 4 ..][0..4], .little);

            if (computed_crc != stored_crc) {
                offset += 1;
                continue;
            }

            const key = try self.allocator.dupe(u8, buf[offset + 9 .. offset + 9 + key_len]);
            const value = try self.allocator.dupe(u8, buf[offset + 9 + key_len .. offset + 9 + key_len + val_len]);

            try entries.append(self.allocator, Entry{
                .entry_type = @as(EntryType, @enumFromInt(type_byte & 0x01)),
                .key = key,
                .value = value,
            });

            offset += entry_size;
        }

        return entries.toOwnedSlice(self.allocator);
    }

    pub fn checkpoint(self: *Wal) !void {
        self.checkpoint_pos = self.append_pos;
    }

    pub fn truncate(self: *Wal) !void {
        _ = c.close(self.fd);
        const path_z = try self.allocator.dupeZ(u8, self.path);
        defer self.allocator.free(path_z);
        _ = c.unlink(path_z.ptr);
        const fd = c.open(path_z.ptr, c.O_RDWR | c.O_CREAT, @as(c.mode_t, 0o664));
        if (fd == -1) return error.OpenFailed;
        _ = c.pwrite(fd, &MAGIC, 8, 0);
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, VERSION, .little);
        _ = c.pwrite(fd, &buf, 4, 8);
        self.fd = fd;
        self.append_pos = 12;
        self.checkpoint_pos = 12;
    }

    pub fn pendingBytes(self: *Wal) u64 {
        if (self.append_pos > self.checkpoint_pos) {
            return self.append_pos - self.checkpoint_pos;
        }
        return 0;
    }
};
//! CountStore — wraps a Store to count append calls (test-only, drives cache optimization).
const std = @import("std");
const store_mod = @import("cube_db").store;

const Store = store_mod.Store;

pub const CountStore = struct {
    inner: Store,
    append_count: u64 = 0,
    sync_count: u64 = 0,

    const Self = @This();

    pub fn init(inner: Store) Self {
        return .{ .inner = inner };
    }

    pub fn store(self: *Self) Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn vtRead(ptr: *anyopaque, buf: []u8, offset: u64) !usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.inner.read(buf, offset);
    }
    fn vtAppend(ptr: *anyopaque, bytes: []const u8) !u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.append_count += 1;
        return self.inner.append(bytes);
    }
    fn vtSync(ptr: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.sync_count += 1;
        return self.inner.sync();
    }
    fn vtSetSize(ptr: *anyopaque, len: u64) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.inner.setSize(len);
    }
    fn vtSize(ptr: *anyopaque) !u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.inner.size();
    }
    fn vtReadPhysical(ptr: *anyopaque, buf: []u8, phys: u64) !usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.inner.readPhysical(buf, phys);
    }
    fn vtPhysicalSize(ptr: *anyopaque) !u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.inner.physicalSize();
    }
    fn vtReadBorrow(ptr: *anyopaque, offset: u64, max: usize) ![]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.inner.readBorrow(offset, max);
    }
    fn vtClose(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.inner.close();
    }
};

const vtable: Store.VTable = .{
    .read = CountStore.vtRead,
    .append = CountStore.vtAppend,
    .sync = CountStore.vtSync,
    .setSize = CountStore.vtSetSize,
    .size = CountStore.vtSize,
    .readPhysical = CountStore.vtReadPhysical,
    .physicalSize = CountStore.vtPhysicalSize,
    .readBorrow = CountStore.vtReadBorrow,
    .close = CountStore.vtClose,
};

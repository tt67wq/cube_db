//! mmap.zig — libc mmap wrapper（跨平台 macOS+Linux）
//! T1：只读读路径用。MAP_SHARED 预留大区 + pwrite 写一致。
//! 严格 TDD：先 stub 返回 error.NotImplemented（RED），再实现（GREEN）。
const std = @import("std");

const c = @cImport({
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
});

pub const PAGE_SIZE: usize = std.heap.page_size_min;
pub const MapError = error{ MapFailed, InvalidLen };

/// mmap 只读 MAP_SHARED 预留区。fd 为已打开文件描述符。len 向上页对齐。
/// 失败返回 MapError。
pub fn mapReadOnly(fd: c_int, len: usize) MapError![*]align(PAGE_SIZE) u8 {
    if (len == 0) return error.InvalidLen;
    const aligned = pageAlignUp(len);
    const ptr = c.mmap(null, aligned, @as(c_int, c.PROT_READ), @as(c_int, c.MAP_SHARED), fd, 0);
    if (ptr == c.MAP_FAILED) return error.MapFailed;
    return @alignCast(@ptrCast(ptr));
}

/// munmap。
pub fn unmap(ptr: [*]align(PAGE_SIZE) u8, len: usize) void {
    _ = c.munmap(@ptrCast(ptr), pageAlignUp(len));
}

/// 页对齐向上取整。
pub fn pageAlignUp(len: usize) usize {
    return std.mem.alignForward(usize, len, PAGE_SIZE);
}

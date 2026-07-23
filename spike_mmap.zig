//! T0 spike — 验证 macOS: file-backed MAP_SHARED 预留大区 + 文件增长后 reader 可见 + 无 SIGBUS
//! scheme I 承重假设去险。独立程序，不经 cube_db build。
//! zig build-exe spike_mmap.zig -lc && ./spike_mmap
const std = @import("std");
const c = @cImport({
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const REGION: usize = 1 << 40; // 1 TB 预留虚拟区

fn check(name: []const u8, ok: bool) void {
    std.debug.print("{s}: {s}\n", .{ name, if (ok) "PASS" else "FAIL" });
}

pub fn main() !void {
    const path = "spike_mmap_test.db";
    // 建文件 + ftruncate 到 4KB
    const fd = c.open(path, @as(c_int, c.O_RDWR | c.O_CREAT | c.O_TRUNC), @as(c.mode_t, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    defer _ = c.unlink(path);
    if (c.ftruncate(fd, 4096) != 0) return error.TruncateFailed;

    // mmap 1TB MAP_SHARED 只读预留区
    const base = c.mmap(null, REGION, @as(c_int, c.PROT_READ), @as(c_int, c.MAP_SHARED), fd, 0);
    if (base == c.MAP_FAILED) {
        check("mmap 1TB", false);
        return error.MmapFailed;
    }
    defer _ = c.munmap(base, REGION);
    check("mmap 1TB file-backed", true);

    const ptr: [*]const u8 = @ptrCast(base);

    // 初始 4KB 应可读（已 backing）
    _ = ptr[0];
    _ = ptr[4095];
    check("initial 4KB readable no SIGBUS", true);

    // 增长文件到 8KB + pwrite 已知字节到 offset 6000
    if (c.ftruncate(fd, 8192) != 0) return error.GrowFailed;
    const magic: [4]u8 = .{ 0xDE, 0xAD, 0xBE, 0xEF };
    const written = c.pwrite(fd, @ptrCast(&magic[0]), 4, 6000);
    if (written != 4) return error.PwriteFailed;

    // 读 base[6000] 验证可见刚写字节（核心假设）
    var ok_visible = true;
    ok_visible = ok_visible and ptr[6000] == 0xDE;
    ok_visible = ok_visible and ptr[6001] == 0xAD;
    ok_visible = ok_visible and ptr[6002] == 0xBE;
    ok_visible = ok_visible and ptr[6003] == 0xEF;
    check("grown page (6000) visible after pwrite", ok_visible);

    // 8KB 内任意点无 SIGBUS
    _ = ptr[8191];
    check("grown 8KB readable no SIGBUS", true);

    std.debug.print("\n结论: macOS growth-vis = {s}\n", .{if (ok_visible) "OK (scheme I 可行)" else "FAIL (回退 II/III)"});
}

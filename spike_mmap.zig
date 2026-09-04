//! T0 spike — verify on macOS: file-backed MAP_SHARED large reserved region + post-growth reader visibility + no SIGBUS
//! De-risks the load-bearing assumption of scheme I. Standalone program, not built via cube_db.
//! zig build-exe spike_mmap.zig -lc && ./spike_mmap
const std = @import("std");
const c = @cImport({
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const REGION: usize = 1 << 40; // 1 TB reserved virtual region

fn check(name: []const u8, ok: bool) void {
    std.debug.print("{s}: {s}\n", .{ name, if (ok) "PASS" else "FAIL" });
}

pub fn main() !void {
    const path = "spike_mmap_test.db";
    // Create file + ftruncate to 4KB
    const fd = c.open(path, @as(c_int, c.O_RDWR | c.O_CREAT | c.O_TRUNC), @as(c.mode_t, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    defer _ = c.unlink(path);
    if (c.ftruncate(fd, 4096) != 0) return error.TruncateFailed;

    // mmap a 1TB read-only MAP_SHARED reserved region
    const base = c.mmap(null, REGION, @as(c_int, c.PROT_READ), @as(c_int, c.MAP_SHARED), fd, 0);
    if (base == c.MAP_FAILED) {
        check("mmap 1TB", false);
        return error.MmapFailed;
    }
    defer _ = c.munmap(base, REGION);
    check("mmap 1TB file-backed", true);

    const ptr: [*]const u8 = @ptrCast(base);

    // Initial 4KB must be readable (already backed)
    _ = ptr[0];
    _ = ptr[4095];
    check("initial 4KB readable no SIGBUS", true);

    // Grow file to 8KB + pwrite known bytes at offset 6000
    if (c.ftruncate(fd, 8192) != 0) return error.GrowFailed;
    const magic: [4]u8 = .{ 0xDE, 0xAD, 0xBE, 0xEF };
    const written = c.pwrite(fd, @ptrCast(&magic[0]), 4, 6000);
    if (written != 4) return error.PwriteFailed;

    // Read base[6000] to verify the just-written bytes are visible (core assumption)
    var ok_visible = true;
    ok_visible = ok_visible and ptr[6000] == 0xDE;
    ok_visible = ok_visible and ptr[6001] == 0xAD;
    ok_visible = ok_visible and ptr[6002] == 0xBE;
    ok_visible = ok_visible and ptr[6003] == 0xEF;
    check("grown page (6000) visible after pwrite", ok_visible);

    // No SIGBUS anywhere within 8KB
    _ = ptr[8191];
    check("grown 8KB readable no SIGBUS", true);

    std.debug.print("\nConclusion: macOS growth-vis = {s}\n", .{if (ok_visible) "OK (scheme I viable)" else "FAIL (fall back to II/III)"});

}

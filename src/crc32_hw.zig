//! crc32_hw.zig — Hardware-accelerated CRC32 for page checksums
//!
//! ARM64: uses ARMv8 CRC32 instructions (crc32x/crc32w/crc32h/crc32b)
//! Other platforms: falls back to software table-driven CRC32
//!
//! The ARMv8 CRC32 instruction uses the same IEEE 802.3 polynomial as
//! std.hash.crc.Crc32 (0x04C11DB7, reflected 0xEDB88320), so results
//! are bit-identical.
const std = @import("std");
const builtin = @import("builtin");

const Crc32 = std.hash.crc.Crc32;

/// Software CRC32 (table-driven, same as format.computePageChecksum)
/// init=0 means standard CRC32 (init 0xFFFFFFFF, final XOR 0xFFFFFFFF)
pub fn crc32Sw(init: u32, data: []const u8) u32 {
    var crc = Crc32.init();
    crc.crc = init ^ 0xFFFFFFFF;
    crc.update(data);
    return crc.final();
}

/// Hardware CRC32 (ARM64 inline asm, or software fallback).
/// Note: x86 SSE4.2 crc32 uses Castagnoli polynomial (CRC-32C), not IEEE 802.3.
/// So x86_64 falls back to software. ARM64 uses hardware CRC32 (IEEE polynomial).
pub fn crc32Hw(init: u32, data: []const u8) u32 {
    return switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => crc32HwArm64(init, data),
        else => crc32Sw(init, data),
    };
}

/// Compute page checksum using hardware acceleration (if available).
/// Covers bytes [0..PAGE_SIZE-4), same as format.computePageChecksum.
pub fn computePageChecksumHw(page: *const [4096]u8) u32 {
    const payload = page[0 .. 4096 - 4];
    return crc32Hw(0, payload);
}

// ===== ARM64 hardware implementation =====

fn crc32HwArm64(init: u32, data: []const u8) u32 {
    var crc: u32 = init ^ 0xFFFFFFFF;
    var i: usize = 0;

    // Process 64 bytes at a time (8 × crc32x) to reduce loop overhead
    while (i + 64 <= data.len) : (i += 64) {
        inline for (0..8) |j| {
            const word = std.mem.readInt(u64, data[i + j * 8 ..][0..8], .little);
            crc = crc32x(crc, word);
        }
    }

    // Process remaining 8-byte chunks
    while (i + 8 <= data.len) : (i += 8) {
        const word = std.mem.readInt(u64, data[i..][0..8], .little);
        crc = crc32x(crc, word);
    }

    // Process remaining 4-byte chunk
    if (i + 4 <= data.len) {
        const word = std.mem.readInt(u32, data[i..][0..4], .little);
        crc = crc32w(crc, word);
        i += 4;
    }

    // Process remaining 2-byte chunk
    if (i + 2 <= data.len) {
        const half = std.mem.readInt(u16, data[i..][0..2], .little);
        crc = crc32h(crc, half);
        i += 2;
    }

    // Process remaining 1 byte
    if (i < data.len) {
        crc = crc32b(crc, data[i]);
        i += 1;
    }

    return crc ^ 0xFFFFFFFF;
}

// ===== ARMv8 CRC32 instruction wrappers =====
// Use explicit register constraints to force w-registers (32-bit).
// crc32x needs Wd, Wn, Xm — output and crc are w-regs, data is x-reg.
// crc32w/h/b need Wd, Wn, Wm — all w-regs.
//
// We use w0/w1/w2 for most instructions, and w0/w1/x2 for crc32x.
// The compiler handles register allocation around these constraints.

inline fn crc32x(crc: u32, data: u64) u32 {
    var res: u32 = undefined;
    asm volatile ("crc32x w0, w1, x2"
        : [res] "={w0}" (res),
        : [crc] "{w1}" (crc),
          [data] "{x2}" (data),
    );
    return res;
}

inline fn crc32w(crc: u32, data: u32) u32 {
    var res: u32 = undefined;
    asm volatile ("crc32w w0, w1, w2"
        : [res] "={w0}" (res),
        : [crc] "{w1}" (crc),
          [data] "{w2}" (data),
    );
    return res;
}

inline fn crc32h(crc: u32, data: u16) u32 {
    var res: u32 = undefined;
    asm volatile ("crc32h w0, w1, w2"
        : [res] "={w0}" (res),
        : [crc] "{w1}" (crc),
          [data] "{w2}" (data),
    );
    return res;
}

inline fn crc32b(crc: u32, data: u8) u32 {
    var res: u32 = undefined;
    asm volatile ("crc32b w0, w1, w2"
        : [res] "={w0}" (res),
        : [crc] "{w1}" (crc),
          [data] "{w2}" (data),
    );
    return res;
}

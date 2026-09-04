//! bench/crc32_bench.zig — CRC32 hardware (ARMv8) vs software (table-driven) single-page latency comparison
//!
//! Run: zig build crc32-bench -Doptimize=ReleaseFast
const std = @import("std");
const builtin = @import("builtin");
const cube = @import("cube_db");

const PAGE_SIZE: usize = 4096;
const PAGE_PAYLOAD: usize = PAGE_SIZE - 4;

const SEED: u64 = 0xC0DE_32;

fn monoNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

fn median(values: []const u64) u64 {
    var buf: [64]u64 = undefined;
    const n = @min(values.len, buf.len);
    @memcpy(buf[0..n], values[0..n]);
    const arr = buf[0..n];
    std.mem.sort(u64, arr, {}, std.sort.asc(u64));
    return arr[arr.len / 2];
}

fn genRandPages(alloc: std.mem.Allocator, n: usize) ![]align(16) [PAGE_SIZE]u8 {
    const pages = try alloc.alignedAlloc([PAGE_SIZE]u8, .@"16", n);
    var prng = std.Random.DefaultPrng.init(SEED);
    const rnd = prng.random();
    for (pages) |*p| rnd.bytes(p);
    return pages;
}

/// Hand-rolled software CRC32: table generated at runtime + volatile reads,
/// to keep LLVM from auto-vectorizing
fn crc32TrueSw(init: u32, data: []const u8) u32 {
    var table: [256]u32 = undefined;
    for (&table, 0..) |*entry, i| {
        var crc: u32 = @intCast(i);
        inline for (0..8) |_| {
            crc = if (crc & 1 != 0) (crc >> 1) ^ 0xEDB88320 else crc >> 1;
        }
        entry.* = crc;
    }
    var crc: u32 = init ^ 0xFFFFFFFF;
    for (data) |b| {
        const idx = (crc ^ b) & 0xFF;
        const tbl_val = @as(*volatile u32, @constCast(&table[idx])).*;
        crc = tbl_val ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
}

const Result = struct {
    name: []const u8,
    ns_per_page: u64,
    gbps: f64,
};

fn benchModFn(name: []const u8, comptime f: fn (u32, []const u8) u32, pages: []align(16) [PAGE_SIZE]u8, iters: usize, trials: usize) !Result {
    var times: [32]u64 = undefined;
    for (0..trials) |t| {
        var acc: u32 = 0;
        const t0 = monoNs();
        for (0..iters) |_| {
            for (pages) |*p| acc +%= f(0, p[0..PAGE_PAYLOAD]);
        }
        const t1 = monoNs();
        std.mem.doNotOptimizeAway(acc);
        times[t] = @intCast(t1 - t0);
    }
    const total_pages = @as(u64, @intCast(pages.len)) * iters;
    const med = median(times[0..trials]);
    const ns = @divFloor(med, total_pages);
    return .{ .name = name, .ns_per_page = ns, .gbps = @as(f64, @floatFromInt(PAGE_PAYLOAD)) / @as(f64, @floatFromInt(ns)) };
}

fn benchFormatFn(name: []const u8, comptime f: fn (*const [PAGE_SIZE]u8) u32, pages: []align(16) [PAGE_SIZE]u8, iters: usize, trials: usize) !Result {
    var times: [32]u64 = undefined;
    for (0..trials) |t| {
        var acc: u32 = 0;
        const t0 = monoNs();
        for (0..iters) |_| {
            for (pages) |*p| acc +%= f(p);
        }
        const t1 = monoNs();
        std.mem.doNotOptimizeAway(acc);
        times[t] = @intCast(t1 - t0);
    }
    const total_pages = @as(u64, @intCast(pages.len)) * iters;
    const med = median(times[0..trials]);
    const ns = @divFloor(med, total_pages);
    return .{ .name = name, .ns_per_page = ns, .gbps = @as(f64, @floatFromInt(PAGE_PAYLOAD)) / @as(f64, @floatFromInt(ns)) };
}

fn trueSwWrapper(init: u32, data: []const u8) u32 {
    _ = init;
    return crc32TrueSw(0, data);
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const n_pages: usize = 256;
    const iters: usize = 1000;
    const trials: usize = 7;

    const pages = try genRandPages(alloc, n_pages);
    defer alloc.free(pages);

    std.debug.print("=== cube_db CRC32: hardware (ARMv8) vs software, single-page latency ===\n\n", .{});
    std.debug.print("Config: {d} pages x {d} rounds x {d} trials · payload={d}B · host {s}\n\n", .{
        n_pages, iters, trials, PAGE_PAYLOAD, @tagName(builtin.cpu.arch),
    });

    // Correctness check
    {
        var ok = true;
        for (pages) |*p| {
            const s = cube.crc32_hw.crc32Sw(0, p[0..PAGE_PAYLOAD]);
            const h = cube.crc32_hw.crc32Hw(0, p[0..PAGE_PAYLOAD]);
            const t = crc32TrueSw(0, p[0..PAGE_PAYLOAD]);
            if (s != h) { ok = false; std.debug.print("❌ module crc32Sw != crc32Hw\n", .{}); }
            if (t != h) { ok = false; std.debug.print("❌ trueSw != crc32Hw\n", .{}); }
        }
        std.debug.print("Correctness: {s}\n\n", .{if (ok) "✅ all match" else "❌ mismatch found"});
        if (!ok) std.process.exit(1);
    }

    // === Benchmarks ===
    inline for (.{
        .{ "crc32Sw  (module, table-driven)", cube.crc32_hw.crc32Sw },
        .{ "crc32Hw  (module, ARMv8 inline asm)", cube.crc32_hw.crc32Hw },
        .{ "crc32TrueSw (hand-rolled, volatile table, anti-LLVM)", trueSwWrapper },
    }) |spec| {
        const r = try benchModFn(spec.@"0", spec.@"1", pages, iters, trials);
        std.debug.print("  {s:<46} {d:>8} ns/page {d:>5.2} GB/s\n", .{ r.name, r.ns_per_page, r.gbps });

    }

    inline for (.{
        .{ "format.computePageChecksumSw (software)", cube.format.computePageChecksumSw },
        .{ "format.computePageChecksum (auto hardware)", cube.format.computePageChecksum },
    }) |spec| {
        const r = try benchFormatFn(spec.@"0", spec.@"1", pages, iters, trials);
        std.debug.print("  {s:<46} {d:>8} ns/page {d:>5.2} GB/s\n", .{ r.name, r.ns_per_page, r.gbps });

    }

    // Speedups
    const hw = try benchModFn("hw", cube.crc32_hw.crc32Hw, pages, iters, 3);
    const sw = try benchModFn("sw", trueSwWrapper, pages, iters, 3);
    std.debug.print("\nSpeedup: hardware vs true-software = {d:.1}x\n", .{
        @as(f64, @floatFromInt(sw.ns_per_page)) / @as(f64, @floatFromInt(hw.ns_per_page)),
    });
    std.debug.print("\nNotes:\n", .{});
    std.debug.print("  - crc32Sw: LLVM under ReleaseFast may auto-vectorize table-driven CRC32 into hardware instructions\n", .{});
    std.debug.print("  - crc32TrueSw: volatile table accesses defeat LLVM pattern recognition, reflecting pure software performance\n", .{});
    std.debug.print("  - On non-ARM64 platforms, crc32Hw falls back to software and matches crc32Sw performance\n", .{});

}
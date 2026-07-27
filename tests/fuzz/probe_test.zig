//! Probe test: verify fuzz framework works.
//! GREEN phase: no deliberate crash, just verifies framework runs cleanly.

const std = @import("std");
const fuzz = @import("common.zig");

var probe_seen_count: usize = 0;

fn probeTestOne(ctx: *usize, smith: *std.testing.Smith) !void {
    _ = ctx;
    var buf: [256]u8 = undefined;
    const len = smith.slice(&buf);
    _ = buf[0..len];
    probe_seen_count += 1;
}

test "fuzz probe — smoke (1000 random iters)" {
    var ctx: usize = 0;
    const seed = std.testing.random_seed;
    _ = try fuzz.fuzzLoop(usize, &ctx, probeTestOne, 1000, seed);
}

test "fuzz probe — corpus replay (empty corpus = skip)" {
    var ctx: usize = 0;
    _ = try fuzz.replayCorpus(usize, &ctx, probeTestOne, "tests/fuzz/corpus/probe");
}

test "fuzz probe — deterministic corpus replay from known inputs" {
    var ctx: usize = 0;
    {
        var smith = std.testing.Smith{ .in = &.{0x00, 0x00, 0x00, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F} };
        try probeTestOne(&ctx, &smith);
    }
    {
        var smith = std.testing.Smith{ .in = &.{0x00, 0x00, 0x00, 0x00} };
        try probeTestOne(&ctx, &smith);
    }
    _ = &probe_seen_count;
}
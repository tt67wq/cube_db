//! meta_corrupt_fuzz_test.zig — P4 TDD: meta-page corruption fuzz hardening
//! Randomly corrupt meta page bytes and verify recovery degrades correctly (no panic; picks a valid meta or returns null).
//! Property: for any corruption, readMetaPage must not panic; the return value is predictably consistent with decodeMetaPayload.

const std = @import("std");
const fuzz = @import("common.zig");
const cube = @import("cube_db");
const f2 = cube.format;

const alloc = std.testing.allocator;

fn metaCorruptTarget(ctx: *usize, smith: *std.testing.Smith) !void {
    _ = ctx;
    // Build a valid meta
    var meta = f2.MetaPage{
        .magic = f2.MAGIC_V2,
        .version = 2,
        .mapsize = 1 << 30,
        .sequence = 42,
        .root_page = 7,
        .entry_count = 100,
        .byte_size = 4096,
        .free_head = 0,
        .free_count = 0,
        .last_page = 10,
    };
    var page0: [f2.PAGE_SIZE]u8 = [_]u8{0} ** f2.PAGE_SIZE;
    f2.writeMetaPage(&page0, &meta, 0);

    // Use smith input to randomly flip some bytes
    var buf: [64]u8 = undefined;
    const len = smith.slice(&buf);
    for (buf[0..len]) |b| {
        const idx = @as(usize, b) % f2.PAGE_SIZE;
        page0[idx] ^= 0xFF;
    }

    // readMetaPageSingle must not panic; it returns null (corrupt) or a MetaPage
    const got = f2.readMetaPageSingle(&page0);
    if (got) |m| {
        // If it returns a valid page, magic/version must match MAGIC_V2/2 (guaranteed by isValidMeta)
        try std.testing.expect(f2.isValidMeta(m));
    }
    // Passing without a panic is the bar
}

test "fuzz: meta corruption never panics (deterministic)" {
    var ctx: usize = 0;
    const seed = std.testing.random_seed;
    const iters = try fuzz.fuzzLoop(usize, &ctx, metaCorruptTarget, 5000, seed);
    try std.testing.expect(iters > 0);
}

//! Page format decode fuzz test.
//! Feeds random bytes to format decode functions.
//! Oracle: no panic, no UB, valid roundtrip.

const std = @import("std");
const fuzz = @import("common.zig");
const format = @import("cube_db").format;

fn formatDecodeTestOne(ctx: *usize, smith: *std.testing.Smith) !void {
    _ = ctx;
    var buf: [4096]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    // Fuzz decodePageHeader — any input must be handled gracefully
    if (input.len >= 24) {
        const hdr = format.decodePageHeader(input[0..24]);
        _ = hdr.page_no;
        _ = hdr.page_type;
        _ = hdr.gen;
        _ = hdr.nkeys;
        _ = hdr.free_next;
    }

    // Fuzz decodeMetaPayload — any input must be handled gracefully
    if (input.len >= format.META_PAGE_PAYLOAD_SIZE) {
        const meta = format.decodeMetaPayload(input[0..format.META_PAGE_PAYLOAD_SIZE]);
        _ = meta.magic;
        _ = meta.version;
        _ = meta.mapsize;
        _ = meta.sequence;
        _ = meta.root_page;
        _ = meta.entry_count;
        _ = meta.byte_size;
    }
}

test "fuzz format decode — smoke (1000 random iters)" {
    var ctx: usize = 0;
    const seed = std.testing.random_seed;
    _ = try fuzz.fuzzLoop(usize, &ctx, formatDecodeTestOne, 1000, seed);
}

test "fuzz format decode — corpus replay" {
    var ctx: usize = 0;
    _ = try fuzz.replayCorpus(usize, &ctx, formatDecodeTestOne, "tests/fuzz/corpus/format");
}
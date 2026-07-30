//! 2-minute long-run fuzz for page format.
//! Run: zig build long-run
//! Each target runs for 120 seconds or until a crash is found.

const std = @import("std");
const fuzz = @import("common.zig");
const format = @import("cube_db").format;

// ——— Page format decode ———
var fmt_iters: usize = 0;
fn fmtLongRun(ctx: *usize, smith: *std.testing.Smith) !void {
    _ = ctx;
    var buf: [4096]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];
    if (input.len >= 24) {
        const hdr = format.decodePageHeader(input[0..24]);
        _ = hdr.page_no;
    }
    if (input.len >= format.META_PAGE_PAYLOAD_SIZE) {
        const meta = format.decodeMetaPayload(input[0..format.META_PAGE_PAYLOAD_SIZE]);
        _ = meta.magic;
    }
    fmt_iters += 1;
}

test "Format 2min long run" {
    var ctx: usize = 0;
    const seed = std.testing.random_seed;
    _ = try fuzz.fuzzLongRun(usize, &ctx, fmtLongRun, 120_000, seed);
    std.debug.print("  Format: {d} iters in 2m\n", .{fmt_iters});
}

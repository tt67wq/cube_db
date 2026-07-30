//! meta_corrupt_fuzz_test.zig — P4 TDD: meta 页损坏 fuzz 加固
//! 随机损坏 meta 页字节，验证 recovery 降级正确（不 panic、选有效 meta 或返回 null）。
//! 属性：对任意损坏，readMetaPage 不 panic；返回值与 decodeMetaPayload 一致性可预测。

const std = @import("std");
const fuzz = @import("common.zig");
const cube = @import("cube_db");
const f2 = cube.format;

const alloc = std.testing.allocator;

fn metaCorruptTarget(ctx: *usize, smith: *std.testing.Smith) !void {
    _ = ctx;
    // 构造一个有效 meta
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

    // 用 smith 输入随机翻转若干字节
    var buf: [64]u8 = undefined;
    const len = smith.slice(&buf);
    for (buf[0..len]) |b| {
        const idx = @as(usize, b) % f2.PAGE_SIZE;
        page0[idx] ^= 0xFF;
    }

    // readMetaPageSingle 不得 panic；返回 null（损坏）或一个 MetaPage
    const got = f2.readMetaPageSingle(&page0);
    if (got) |m| {
        // 若返回有效，magic/version 必须匹配 MAGIC_V2/2（isValidMeta 保证）
        try std.testing.expect(f2.isValidMeta(m));
    }
    // 无 panic 即通过
}

test "fuzz: meta corruption never panics (deterministic)" {
    var ctx: usize = 0;
    const seed = std.testing.random_seed;
    const iters = try fuzz.fuzzLoop(usize, &ctx, metaCorruptTarget, 5000, seed);
    try std.testing.expect(iters > 0);
}

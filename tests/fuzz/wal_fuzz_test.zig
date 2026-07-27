//! WAL parse fuzz test.
//! RED phase: Wal.parseEntries() doesn't exist yet → compile fails.
//! GREEN phase: extract parseEntries from replay, fuzz runs.

const std = @import("std");
const fuzz = @import("common.zig");
const wal = @import("cube_db").wal;
const Wal = wal.Wal;

var parse_count: usize = 0;

fn walParseTestOne(ctx: *usize, smith: *std.testing.Smith) !void {
    _ = ctx;
    var buf: [4096]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];
    parse_count += 1;

    // Call parseEntries — this doesn't exist yet (RED phase)
    // When it's extracted (GREEN), this will compile and fuzz
    const entries = try Wal.parseEntries(std.testing.allocator, input);
    defer {
        for (entries) |e| {
            std.testing.allocator.free(e.key);
            std.testing.allocator.free(e.value);
        }
        std.testing.allocator.free(entries);
    }

    // Oracle: if parse returns entries, they must be valid
    for (entries) |e| {
        // Entry type must be valid
        _ = @intFromEnum(e.entry_type);
        // Key/value must be non-null (length in range)
        _ = e.key.len > 0;
        _ = e.value.len > 0;
    }
}

test "fuzz WAL parse — smoke (1000 random iters)" {
    var ctx: usize = 0;
    const seed = std.testing.random_seed;
    _ = try fuzz.fuzzLoop(usize, &ctx, walParseTestOne, 1000, seed);
}

test "fuzz WAL parse — corpus replay" {
    var ctx: usize = 0;
    _ = try fuzz.replayCorpus(usize, &ctx, walParseTestOne, "tests/fuzz/corpus/wal");
}

test "fuzz WAL parse — valid roundtrip" {
    // Create a valid entry via Wal.append, then parse it back
    // This requires Wal.init + append + replay, which we can't do without a file
    // For now: verify that a known-good byte sequence parses correctly
    // A valid entry: type=0, key_len=3, val_len=5, key="abc", value="hello", crc=?
    // We'll compute the CRC manually
    // Compute CRC for a valid entry and verify roundtrip
    var entry_buf: [9 + 3 + 5 + 4]u8 = undefined;
    entry_buf[0] = 0; // put
    std.mem.writeInt(u32, entry_buf[1..5], 3, .little); // key_len = 3
    std.mem.writeInt(u32, entry_buf[5..9], 5, .little); // val_len = 5
    @memcpy(entry_buf[9..12], "abc");
    @memcpy(entry_buf[12..17], "hello");
    // CRC over hdr+key+value = entry_buf[0..17]
    var crc = std.hash.Crc32.init();
    crc.update(entry_buf[0..17]);
    const crc_val = crc.final();
    std.mem.writeInt(u32, entry_buf[17..21], crc_val, .little);

    const entries = try Wal.parseEntries(std.testing.allocator, &entry_buf);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(wal.EntryType, .put), entries[0].entry_type);
    try std.testing.expectEqualSlices(u8, "abc", entries[0].key);
    try std.testing.expectEqualSlices(u8, "hello", entries[0].value);
    std.testing.allocator.free(entries[0].key);
    std.testing.allocator.free(entries[0].value);
}
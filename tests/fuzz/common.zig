//! Common fuzz framework for cube_db.
//! Provides:
//! - fuzzLoop: loop over random Smith inputs (random property test)
//! - replayCorpus: replay known inputs from files
//!
//! Zig 0.16.0 compiler bug: `-ffuzz` causes `builtin.StackTrace != debug.StackTrace`
//! in the test runner. We work around by using `Smith.in = random_bytes` directly,
//! which is exactly what the coverage-guided fuzzer does internally.
//! Once the compiler bug is fixed, switch to `zig test -ffuzz` for coverage guidance.

const std = @import("std");
const Io = std.Io;
/// Maximum iterations for a smoke fuzz run (CI: 30s ≈ 100k iterations).
pub const SMOKE_ITERS: usize = 100_000;

/// Maximum bytes for a single fuzz input.
pub const MAX_INPUT_BYTES: usize = 4096;

/// Run a fuzz target with random Smith inputs.
/// `target` is a function `fn(context: *C, smith: *std.testing.Smith) !void`
/// `context` is user-defined state.
/// `max_iters` limits iterations.
/// `seed` is the random seed. Same seed = same sequence.
///
/// Returns the number of iterations run, or an error if the target panics/returns error.
pub fn fuzzLoop(
    comptime Context: type,
    context: *Context,
    comptime target: fn (context: *Context, smith: *std.testing.Smith) anyerror!void,
    max_iters: usize,
    seed: u64,
) !usize {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var input_buf: [MAX_INPUT_BYTES]u8 = undefined;
    var i: usize = 0;
    while (i < max_iters) : (i += 1) {
        const len = rand.intRangeAtMost(usize, 0, MAX_INPUT_BYTES);
        rand.bytes(input_buf[0..len]);

        var smith = std.testing.Smith{ .in = input_buf[0..len] };
        try target(context, &smith);
    }
    return i;
}

/// Replay corpus files from a directory.
/// Each file is fed to the target as a Smith input.
/// Returns count of corpus files replayed, or an error if any file causes a crash.
pub fn replayCorpus(
    comptime Context: type,
    context: *Context,
    comptime target: fn (context: *Context, smith: *std.testing.Smith) anyerror!void,
    corpus_dir_path: []const u8,
) !usize {
    const io = Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd();
    const sub_dir = dir.openDir(io, corpus_dir_path, .{ .iterate = true }) catch |e| {
        std.debug.print("  fuzz: no corpus dir '{s}' ({s})\n", .{ corpus_dir_path, @errorName(e) });
        return 0;
    };
    defer sub_dir.close(io);

    var count: usize = 0;
    var iter = sub_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;

        const data = try sub_dir.readFileAlloc(io, entry.name, std.testing.allocator, Io.Limit.limited(MAX_INPUT_BYTES));
        defer std.testing.allocator.free(data);

        var smith = std.testing.Smith{ .in = data };
        try target(context, &smith);
        count += 1;
    }
    return count;
}

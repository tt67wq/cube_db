//! Common fuzz framework for cube_db.
//! Provides:
//! - fuzzLoop: loop over random Smith inputs (random property test)
//! - fuzzLongRun: time-budgeted loop (ms deadline)
//! - replayCorpus: replay known inputs from files
//!
//! Zig 0.16.0 compiler bug: `-ffuzz` causes `builtin.StackTrace != debug.StackTrace`
//! in the test runner. We work around by using `Smith.in = random_bytes` directly,
//! which is exactly what the coverage-guided fuzzer does internally.
//! Once the compiler bug is fixed, switch to `zig test -ffuzz` for coverage guidance.

const std = @import("std");
const Io = std.Io;

// ===== T-61-1: 真 fuzz seed（区别于 zig build --seed 的图遍历随机） =====
//
// CUBE_FUZZ_SEED 环境变量优先（build.zig 的 -Dfuzz-seed=<n> 转发，或手动
// export）；支持 0x 前缀 hex 与十进制。未设/非法时回退 std.testing.random_seed。
//
// 打印策略（T-54-B/T-61-1 R2 裁决：listen 模式下测试二进制任何 stderr 输出都会被
// build_runner 当作 result_stderr 回显成 "failed command:" 行，绿 run 也算——
// 无条件回显会炸掉所有 fc=0 门）——
//   - 显式设 seed：回显 `fuzz seed=0x…` 仅在 CUBE_TEST_VERBOSE=1 下（tdiag 同款
//     约定；与 `-Dfuzz-seed` + 跑门并用时必须零噪音，B1 修复）
//   - 非法 seed：verbose 门控告警（NB1：用户以为固定了其实没有）
//   - 未设（CI 默认）：成功路径零输出；失败时由 fuzzLoop/fuzzLongRun 打
//     `fuzz seed=0x…` + 复现提示 —— 红的时候 CI 日志可直接抄。
// （契约原文「stdout + 每次开跑都印」在 --listen=- 下物理不可实现：stdout 是
// runner IPC 协议通道，stderr 必撞 fc 噪音 —— 见 T-61-1 review B1 裁决。）
var seed_printed = false;
var cached_verbose: ?bool = null;

/// CUBE_TEST_VERBOSE（test_diag.zig 同款约定：值非空且非 "0" 即开，进程内缓存）。
fn verbose() bool {
    if (cached_verbose) |v| return v;
    const v = if (std.c.getenv("CUBE_TEST_VERBOSE")) |s| blk: {
        const val = std.mem.span(s);
        break :blk val.len > 0 and !std.mem.eql(u8, val, "0");
    } else false;
    cached_verbose = v;
    return v;
}

pub fn resolveSeed() u64 {
    if (std.c.getenv("CUBE_FUZZ_SEED")) |raw| {
        const v = std.mem.span(raw);
        if (parseSeed(v)) |s| {
            if (verbose()) printSeed(s); // B1: 显式回显仅 verbose 门控
            return s;
        }
        if (verbose()) std.debug.print("T-61-1: ignoring invalid CUBE_FUZZ_SEED='{s}' — using random seed\n", .{v}); // NB1
    }
    return std.testing.random_seed;
}

/// 失败路径复现提示：fuzzLoop/fuzzLongRun 的 target 出错时调用（进程内一次）。
pub fn printSeedOnFailure(seed: u64) void {
    if (seed_printed) return;
    seed_printed = true;
    std.debug.print("fuzz seed=0x{x} — replay with: CUBE_FUZZ_SEED=0x{x}\n", .{ seed, seed });
}

fn printSeed(seed: u64) void {
    if (seed_printed) return;
    seed_printed = true;
    std.debug.print("fuzz seed=0x{x}\n", .{seed});
}

fn parseSeed(v: []const u8) ?u64 {
    if (v.len == 0) return null;
    if (std.mem.startsWith(u8, v, "0x") or std.mem.startsWith(u8, v, "0X")) {
        return std.fmt.parseInt(u64, v[2..], 16) catch null;
    }
    return std.fmt.parseInt(u64, v, 10) catch null;
}

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
        target(context, &smith) catch |e| {
            printSeedOnFailure(seed); // T-61-1: 红 run 的 CI 日志可直接抄 seed
            return e;
        };
    }
    return i;
}

/// Run a fuzz target with a time budget (milliseconds).
/// Uses monotonic clock (.awake) for deadline, checks every 64 iterations.
/// Returns the number of iterations run, or an error if the target panics.
pub fn fuzzLongRun(
    comptime Context: type,
    context: *Context,
    comptime target: fn (context: *Context, smith: *std.testing.Smith) anyerror!void,
    max_time_ms: u64,
    seed: u64,
) !usize {
    const io = Io.Threaded.global_single_threaded.io();
    const start_ns = Io.Timestamp.now(io, .awake).nanoseconds;
    const budget: i96 = @intCast(@as(i96, max_time_ms) * std.time.ns_per_ms);
    const deadline_ns = start_ns + budget;
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var input_buf: [MAX_INPUT_BYTES]u8 = undefined;
    var i: usize = 0;
    while (true) {
        if (i & 63 == 0) {
            if (Io.Timestamp.now(io, .awake).nanoseconds >= deadline_ns) break;
        }
        const len = rand.intRangeAtMost(usize, 0, MAX_INPUT_BYTES);
        rand.bytes(input_buf[0..len]);
        var smith = std.testing.Smith{ .in = input_buf[0..len] };
        target(context, &smith) catch |e| {
            printSeedOnFailure(seed); // T-61-1: 红 run 的 CI 日志可直接抄 seed
            return e;
        };
        i += 1;
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
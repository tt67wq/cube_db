const std = @import("std");
// T-54-G：递归发现 tests/**/*.zig，每个含 test 的文件一个二进制；已删 6 个纯聚合器与 18 个
// per-module step（重复编译 77→0）；迭代入口统一为 test-one -Dfilter=<测试名子串>。
// 例外（不进默认门）：long_run_2min→long-run（裁决1）；freelist_amp_red→test-t39-red（裁决2，RED#1 本来就红）；spike→test-rangetomb-probe。

/// bench/工具 exe 表驱动注册（T-54-G：~350 行逐个 addExecutable 压缩而来）。
const Tool = struct {
    step: []const u8, name: []const u8, root: []const u8, desc: []const u8,
    db: bool = true, // import cube_db + zio
    libc: bool = false,
    args: bool = false, // 透传 `zig build -- ...` 参数
    install_dep: bool = false, // 运行前依赖 install（run 步骤语义）
};

fn addTool(b: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, mod: *std.Build.Module, zio: *std.Build.Module, tool: Tool) *std.Build.Step.Compile {
    const m = b.createModule(.{
        .root_source_file = b.path(tool.root),
        .target = t,
        .optimize = o,
        .imports = if (tool.db) &.{ .{ .name = "cube_db", .module = mod }, .{ .name = "zio", .module = zio } } else &[_]std.Build.Module.Import{},
    });
    if (tool.libc) m.link_libc = true;
    const exe = b.addExecutable(.{ .name = tool.name, .root_module = m });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (tool.install_dep) run.step.dependOn(b.getInstallStep());
    b.step(tool.step, tool.desc).dependOn(&run.step);
    if (tool.args) if (b.args) |a| run.addArgs(a);
    return exe;
}

fn walk(b: *std.Build, io: std.Io, dir: []const u8, out: *std.ArrayList([]const u8)) void {
    var d = b.build_root.handle.openDir(io, b.fmt("tests/{s}", .{dir}), .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        const rel = if (dir.len == 0) b.dupe(e.name) else b.fmt("{s}/{s}", .{ dir, e.name });
        switch (e.kind) {
            .directory => walk(b, io, rel, out),
            .file => if (std.mem.endsWith(u8, e.name, ".zig")) out.append(b.allocator, rel) catch @panic("oom"),
            else => {},
        }
    }
}

const Verdict = enum { helper, skip, hit }; // helper=无测试；skip=有测试但未命中 filter；hit=命中（或未给 filter）
/// 扫源码：是否有测试 + 是否有测试名命中 filter 子串（本仓全是 `test "名"` 形态；
/// test {/ident 无静态名，不可被 filter 命中——与 zig --test-filter 一致）。
fn scan(src: []const u8, rel: []const u8, filter: ?[]const u8) Verdict {
    var has = false;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (!std.mem.startsWith(u8, line, "test ")) continue;
        const rest = std.mem.trimStart(u8, line["test ".len..], " \t");
        has = true;
        if (rest.len > 1 and rest[0] == '"' and filter != null) {
            const body = rest[1..];
            if (std.mem.indexOfScalar(u8, body, '"')) |end| {
                if (std.mem.indexOf(u8, body[0..end], filter.?) != null) return .hit;
            }
        }
    }
    if (!has) return .helper;
    if (filter == null) return .hit;
    return if (std.mem.indexOf(u8, rel, filter.?) != null) .hit else .skip;
}
/// 一个测试文件 = 一个二进制（统一三 import，未被 @import 的多余 import 无害）。
fn testRun(b: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, mod: *std.Build.Module, zio: *std.Build.Module, chk: *std.Build.Module, part: *std.Build.Module, path: []const u8) *std.Build.Step.Run {
    return b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = t,
        .optimize = o,
        .imports = &.{ .{ .name = "cube_db", .module = mod }, .{ .name = "zio", .module = zio }, .{ .name = "cube_check", .module = chk }, .{ .name = "page_partition", .module = part } },
    }) }));
}
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bench_scale = b.option([]const u8, "bench-scale", "Bench scale filter: all|small|large") orelse "all";
    // T-61-1: 真 fuzz seed（区别于 zig build 自身的 --seed 图遍历选项）。
    // 设置时以 CUBE_FUZZ_SEED 环境变量转发给所有测试二进制；fuzz 测试优先读它，
    // 未设则随机并在测试开始时打印实际 seed。不设时行为完全不变。
    const fuzz_seed = b.option([]const u8, "fuzz-seed", "Fix the fuzz seed (hex like 0xc0ffee or decimal); forwarded as CUBE_FUZZ_SEED");
    const zio_mod = b.dependency("zio", .{ .target = target, .optimize = optimize }).module("zio");
    const mod = b.addModule("cube_db", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    mod.addImport("zio", zio_mod);
    mod.link_libc = true; // T1: mmap wrapper uses @cImport libc
    const cube_check_mod = b.addModule("cube_check", .{ .root_source_file = b.path("src/cube_check.zig"), .target = target, .optimize = optimize });
    cube_check_mod.addImport("cube_db", mod);
    cube_check_mod.addImport("zio", zio_mod);
    cube_check_mod.link_libc = true; // FilePageStore: libc mmap/flock

    // T-35 Part B: cube_check 离线完整性工具（模块被测试侧 @import("cube_check") 共享）。
    const check_exe = b.addExecutable(.{ .name = "cube_check", .root_module = cube_check_mod });
    b.installArtifact(check_exe);
    const check_cmd = b.addRunArtifact(check_exe);
    b.step("cube-check", "Run cube_check (args after -- : scrub <db-path>)").dependOn(&check_cmd.step);
    if (b.args) |a| check_cmd.addArgs(a);

    const exe = addTool(b, target, optimize, mod, zio_mod, .{ .step = "run", .name = "cube_db", .root = "src/main.zig", .desc = "Run the app", .args = true, .install_dep = true });
    const bench_opts = b.addOptions();
    bench_opts.addOption([]const u8, "scale_filter", bench_scale);
    addTool(b, target, optimize, mod, zio_mod, .{ .step = "bench", .name = "cube_bench", .root = "bench/bench.zig", .desc = "Run benchmark matrix (20 cells)", .args = true }).root_module.addOptions("bench_opts", bench_opts);
    _ = addTool(b, target, optimize, mod, zio_mod, .{ .step = "fps-bench", .name = "fps_bench", .root = "bench/fps_bench.zig", .desc = "Run FilePageStore benchmark (2x2 matrix)", .libc = true, .args = true });
    _ = addTool(b, target, optimize, mod, zio_mod, .{ .step = "bench-get-profile", .name = "get_profile", .root = "bench/get_profile.zig", .desc = "Run get phase-by-phase timing breakdown" });
    _ = addTool(b, target, optimize, mod, zio_mod, .{ .step = "perf-batch", .name = "perf_batch", .root = "bench/perf_batch.zig", .desc = "Run putBatch performance measurement" });
    _ = addTool(b, target, optimize, mod, zio_mod, .{ .step = "profile-commit", .name = "profile_commit", .root = "bench/profile_commit.zig", .desc = "Run commit path phase profiling (#35)" });
    _ = addTool(b, target, optimize, mod, zio_mod, .{ .step = "mmap-vs-pwrite", .name = "mmap_vs_pwrite", .root = "bench/mmap_vs_pwrite.zig", .desc = "Discriminating experiment: mmap vs pwrite 100MB (#41)", .db = false, .libc = true });
    _ = addTool(b, target, optimize, mod, zio_mod, .{ .step = "profile-fps", .name = "profile_fps", .root = "bench/profile_fps.zig", .desc = "FPS write path counters (#41)", .libc = true });
    _ = addTool(b, target, optimize, mod, zio_mod, .{ .step = "crc32-bench", .name = "crc32_bench", .root = "bench/crc32_bench.zig", .desc = "CRC32 hardware vs software single-page timing" });
    _ = addTool(b, target, optimize, mod, zio_mod, .{ .step = "bench-baseline", .name = "bench_baseline", .root = "bench/bench_baseline.zig", .desc = "Check benchmark regression baseline", .libc = true });

    // ===== 测试接线（T-54-G）：递归发现，单一清单——test 与 test-one 共用，零漂移 =====
    const test_step = b.step("test", "Run all tests (recursive discovery of tests/)");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step); // src/ 单测
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);
    const test_one_step = b.step("test-one", "Fast iteration: -Dfilter=<substr> runs files with matching test names");
    const fuzz_step = b.step("test-fuzz", "Run fuzz corpus replay tests (deterministic)");
    const long_run_step = b.step("long-run", "Run 2-minute long-run fuzz tests");
    const t39_red_step = b.step("test-t39-red", "T-39 RED tests (RED #1 red by design — NOT in the default gate)");
    const probe_step = b.step("test-rangetomb-probe", "Run T-38-P range-tombstone probe (spike)");

    const part_mod = b.createModule(.{ .root_source_file = b.path("tests/core_format/page_partition.zig"), .target = target, .optimize = optimize });
    part_mod.addImport("cube_db", mod);
    const io = b.graph.io;
    var rels: std.ArrayList([]const u8) = .empty;
    walk(b, io, "", &rels);
    const filter = b.option([]const u8, "filter", "test-one: 只跑测试名含该子串的文件（不带 = 跑除例外/分片外全部）");
    var one_hits: usize = 0;
    for (rels.items) |rel| {
        const path = b.fmt("tests/{s}", .{rel});
        const src = b.build_root.handle.readFileAlloc(io, path, b.allocator, .limited(8 << 20)) catch continue;
        const verdict = scan(src, rel, filter);
        if (verdict == .helper) continue; // 纯 helper（test_diag/common/…）不建二进制
        const is_long_run = std.mem.eql(u8, rel, "fuzz/long_run_2min.zig"); // 裁决 1
        const is_freelist = std.mem.eql(u8, rel, "core_format/freelist_amp_red_test.zig"); // 裁决 2
        const is_shard = std.mem.startsWith(u8, rel, "insertbatch_sweep_"); // T-54-C 分片 ~45s×4
        const run = testRun(b, target, optimize, mod, zio_mod, cube_check_mod, part_mod, path);
        if (fuzz_seed) |s| run.setEnvironmentVariable("CUBE_FUZZ_SEED", s); // T-61-1
        if (!is_long_run and !is_freelist) test_step.dependOn(&run.step);
        if (std.mem.startsWith(u8, rel, "fuzz/") and !is_long_run) fuzz_step.dependOn(&run.step);
        if (is_long_run) long_run_step.dependOn(&run.step);
        if (is_freelist) t39_red_step.dependOn(&run.step);
        if (!is_long_run and !is_shard and verdict == .hit) {
            test_one_step.dependOn(&run.step); // freelist 仍参与：-Dfilter=T-39 可迭代 RED（T-54-F 语义）
            one_hits += 1;
        }
    }
    if (filter != null and one_hits == 0) test_one_step.dependOn(&b.addFail(b.fmt("test-one: filter '{s}' 未命中任何测试名（insertbatch_sweep 分片与 long_run_2min 不参与 test-one；用 `zig build test` 跑它们）", .{filter.?})).step);

    // spike 在 tests/ 之外，保留独立入口（能力不丢失）。
    probe_step.dependOn(&testRun(b, target, optimize, mod, zio_mod, cube_check_mod, part_mod, "spike/rangetomb_probe.zig").step);
}

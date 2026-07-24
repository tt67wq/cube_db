const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ponytail: bench scale 过滤（smoke/small-only）；默认 all 跑全 20 格。
    const bench_scale = b.option([]const u8, "bench-scale", "Bench scale filter: all|small|large") orelse "all";

    const zio_dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });
    const zio_mod = zio_dep.module("zio");

    const mod = b.addModule("cube_db", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("zio", zio_mod);
    mod.link_libc = true; // T1: mmap wrapper 用 @cImport libc

    const exe = b.addExecutable(.{
        .name = "cube_db",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Benchmark 可执行 + step（zig build bench -Doptimize=ReleaseFast）
    const bench_opts = b.addOptions();
    bench_opts.addOption([]const u8, "scale_filter", bench_scale);
    const bench_exe = b.addExecutable(.{
        .name = "cube_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    bench_exe.root_module.addOptions("bench_opts", bench_opts);
    b.installArtifact(bench_exe);

    const bench_step = b.step("bench", "Run benchmark matrix (20 cells)");
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_cmd.step);
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    // Library unit tests (test blocks inside src/).
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Executable tests.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // ponytail: auto-discover tests/*.zig so RED-phase test files run without
    // editing build.zig. Each gets the cube_db + zio imports.
    const io = b.graph.io;
    var tests_dir = b.build_root.handle.openDir(io, "tests", .{ .iterate = true }) catch {
        return;
    };
    defer tests_dir.close(io);
    var tests_iter = tests_dir.iterate();
    while (tests_iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tests/{s}", .{entry.name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "cube_db", .module = mod },
                    .{ .name = "zio", .module = zio_mod },
                },
            }),
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }

    // ponytail: per-test steps for faster iteration
    // zig build test-format2 只跑 format2 测试
    const format2_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/format2_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_format2_test = b.addRunArtifact(format2_test);
    const format2_test_step = b.step("test-format2", "Run format2 tests only");
    format2_test_step.dependOn(&run_format2_test.step);

    // ponytail: zig build test-ps 只跑 page_store 测试
    const ps_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/page_store_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_ps_test = b.addRunArtifact(ps_test);
    const ps_test_step = b.step("test-ps", "Run page_store tests only");
    ps_test_step.dependOn(&run_ps_test.step);
}

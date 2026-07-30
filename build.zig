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

    // ponytail: bench step — v2 bench
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
    // zig build test-format 只跑 format 测试
    const format_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/format_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_format_test = b.addRunArtifact(format_test);
    const format_test_step = b.step("test-format", "Run format tests only");
    format_test_step.dependOn(&run_format_test.step);

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

    // ponytail: zig build test-btree 只跑 btree 测试
    const btree_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/btree_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_btree_test = b.addRunArtifact(btree_test);
    const btree_test_step = b.step("test-btree", "Run btree tests only");
    btree_test_step.dependOn(&run_btree_test.step);

    // ponytail: zig build test-writer 只跑 writer 测试
    const writer_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/writer_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_writer_test = b.addRunArtifact(writer_test);
    const writer_test_step = b.step("test-writer", "Run writer tests only");
    writer_test_step.dependOn(&run_writer_test.step);

    // ponytail: zig build test-mvcc 只跑 MVCC 测试
    const mvcc_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/mvcc_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_mvcc_test = b.addRunArtifact(mvcc_test);
    const mvcc_test_step = b.step("test-mvcc", "Run MVCC reader tests only");
    mvcc_test_step.dependOn(&run_mvcc_test.step);

    // ponytail: zig build test-db 只跑 db 测试
    const db_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/db_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_db_test = b.addRunArtifact(db_test);
    const db_test_step = b.step("test-db", "Run db tests only");
    db_test_step.dependOn(&run_db_test.step);

    // ponytail: zig build test-compact 只跑 compact 测试
    const compact_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/compact_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_compact_test = b.addRunArtifact(compact_test);
    const compact_test_step = b.step("test-compact", "Run compact tests only");
    compact_test_step.dependOn(&run_compact_test.step);

    // ponytail: zig build test-overflow 只跑 overflow 测试
    const overflow_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/overflow_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_overflow_test = b.addRunArtifact(overflow_test);
    const overflow_test_step = b.step("test-overflow", "Run overflow tests only");
    overflow_test_step.dependOn(&run_overflow_test.step);

    // Once fixed, add `test-fuzz-coverage` with `-ffuzz` for coverage-guided fuzzing.
    // CI: `zig build test-fuzz` = determinant regression + smoke (~2s total).
    const fuzz_probe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/probe_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });
    const run_fuzz_probe = b.addRunArtifact(fuzz_probe);

    const fuzz_api = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/api_fuzz_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_fuzz_api = b.addRunArtifact(fuzz_api);

    const fuzz_format = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/format_fuzz_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_fuzz_format = b.addRunArtifact(fuzz_format);

    // ponytail: long-run fuzz (not included in test-fuzz, run on demand)
    const fuzz_long = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/long_run_2min.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_fuzz_long = b.addRunArtifact(fuzz_long);
    const fuzz_long_step = b.step("long-run", "Run 2-minute long-run fuzz tests");
    fuzz_long_step.dependOn(&run_fuzz_long.step);
    const fuzz_step = b.step("test-fuzz", "Run fuzz corpus replay tests (deterministic)");
    fuzz_step.dependOn(&run_fuzz_probe.step);
    fuzz_step.dependOn(&run_fuzz_api.step);
    fuzz_step.dependOn(&run_fuzz_format.step);
}
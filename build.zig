const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ponytail: bench scale filter (smoke/small-only); default "all" runs the full 20 cells.
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
    mod.link_libc = true; // T1: mmap wrapper uses @cImport libc

    // T-35 Part B: cube_check offline integrity tool — module shared by the
    // executable below and the tests/ auto-discovery (tests import "cube_check"
    // to reach cube_check.scrub without going through the CLI).
    const cube_check_mod = b.addModule("cube_check", .{
        .root_source_file = b.path("src/cube_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    cube_check_mod.addImport("cube_db", mod);
    cube_check_mod.addImport("zio", zio_mod);
    cube_check_mod.link_libc = true; // FilePageStore: libc mmap/flock

    // T-35 Part B: cube_check executable — `cube_check scrub <db-path>`.
    // Exit codes: 0 = all pages pass, 1 = usage/open/no-meta error, 2 = corruption found.
    const cube_check_exe = b.addExecutable(.{
        .name = "cube_check",
        .root_module = cube_check_mod,
    });
    b.installArtifact(cube_check_exe);

    const cube_check_step = b.step("cube-check", "Run cube_check (args after -- : scrub <db-path>)");
    const cube_check_cmd = b.addRunArtifact(cube_check_exe);
    cube_check_step.dependOn(&cube_check_cmd.step);
    if (b.args) |args| {
        cube_check_cmd.addArgs(args);
    }

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

    // ponytail: fps-bench — FilePageStore benchmark (2x2 matrix: no-fsync/fsync)
    const fps_bench_exe = b.addExecutable(.{
        .name = "fps_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/fps_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    fps_bench_exe.root_module.link_libc = true;
    b.installArtifact(fps_bench_exe);

    const fps_bench_step = b.step("fps-bench", "Run FilePageStore benchmark (2x2 matrix)");
    const fps_bench_cmd = b.addRunArtifact(fps_bench_exe);
    fps_bench_step.dependOn(&fps_bench_cmd.step);
    if (b.args) |args| {
        fps_bench_cmd.addArgs(args);
    }

    // ponytail: bench-get-profile — phase-by-phase get latency breakdown
    const get_profile_exe = b.addExecutable(.{
        .name = "get_profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/get_profile.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    b.installArtifact(get_profile_exe);

    const get_profile_step = b.step("bench-get-profile", "Run get phase-by-phase timing breakdown");
    const get_profile_cmd = b.addRunArtifact(get_profile_exe);
    get_profile_step.dependOn(&get_profile_cmd.step);

    // perf-batch — putBatch performance measurement
    const perf_batch_exe = b.addExecutable(.{
        .name = "perf_batch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/perf_batch.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    b.installArtifact(perf_batch_exe);
    const perf_batch_step = b.step("perf-batch", "Run putBatch performance measurement");
    const perf_batch_cmd = b.addRunArtifact(perf_batch_exe);
    perf_batch_step.dependOn(&perf_batch_cmd.step);

    // profile-commit — commit path phase profiling (#35)
    const profile_commit_exe = b.addExecutable(.{
        .name = "profile_commit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/profile_commit.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    b.installArtifact(profile_commit_exe);
    const profile_commit_step = b.step("profile-commit", "Run commit path phase profiling (#35)");
    const profile_commit_cmd = b.addRunArtifact(profile_commit_exe);
    profile_commit_step.dependOn(&profile_commit_cmd.step);

    // mmap-vs-pwrite — FPS discriminating experiment (#41): mmap MAP_SHARED vs pwrite sequential 100MB writes
    const mmap_pwrite_exe = b.addExecutable(.{
        .name = "mmap_vs_pwrite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/mmap_vs_pwrite.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(mmap_pwrite_exe);
    mmap_pwrite_exe.root_module.link_libc = true; // @cImport sys/mman.h
    const mmap_pwrite_step = b.step("mmap-vs-pwrite", "Discriminating experiment: mmap vs pwrite 100MB (#41)");
    const mmap_pwrite_cmd = b.addRunArtifact(mmap_pwrite_exe);
    mmap_pwrite_step.dependOn(&mmap_pwrite_cmd.step);

    // profile-fps — FPS write-path counter profiling (#41)
    const profile_fps_exe = b.addExecutable(.{
        .name = "profile_fps",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/profile_fps.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    b.installArtifact(profile_fps_exe);
    profile_fps_exe.root_module.link_libc = true; // @cImport libc
    const profile_fps_step = b.step("profile-fps", "FPS write path counters (#41)");
    const profile_fps_cmd = b.addRunArtifact(profile_fps_exe);
    profile_fps_step.dependOn(&profile_fps_cmd.step);

    // crc32-bench — CRC32 hardware (ARMv8) vs software (table-driven) single-page latency comparison
    const crc32_bench_exe = b.addExecutable(.{
        .name = "crc32_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/crc32_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    b.installArtifact(crc32_bench_exe);
    const crc32_bench_step = b.step("crc32-bench", "CRC32 hardware vs software single-page timing");
    const crc32_bench_cmd = b.addRunArtifact(crc32_bench_exe);
    crc32_bench_step.dependOn(&crc32_bench_cmd.step);

    // ponytail: bench-baseline — benchmark regression baseline check
    const baseline_exe = b.addExecutable(.{
        .name = "bench_baseline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench_baseline.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    b.installArtifact(baseline_exe);
    baseline_exe.root_module.link_libc = true; // @cImport libc

    const baseline_step = b.step("bench-baseline", "Check benchmark regression baseline");
    const baseline_cmd = b.addRunArtifact(baseline_exe);
    baseline_step.dependOn(&baseline_cmd.step);

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
        // T-54-F: test-one's root closure runs ONLY under its own step (with
        // -Dfilter); auto-discovering it here would double-execute every test
        // it aggregates.
        if (std.mem.eql(u8, entry.name, "test_one_aggregator.zig")) continue;
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tests/{s}", .{entry.name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "cube_db", .module = mod },
                    .{ .name = "zio", .module = zio_mod },
                    .{ .name = "cube_check", .module = cube_check_mod },
                },
            }),
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }

    // ponytail: per-test steps for faster iteration

    // crc32_hw_test — hardware CRC32 vs software CRC32 consistency tests
    const crc32_hw_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/core_format/crc32_hw_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_crc32_hw_test = b.addRunArtifact(crc32_hw_test);
    const crc32_hw_test_step = b.step("test-crc32", "Run crc32_hw tests only");
    crc32_hw_test_step.dependOn(&run_crc32_hw_test.step);

    // zig build test-format runs only format tests
    const format_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/core_format/format_test.zig"),
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

    // T-38-1: range-tombstone format tests (RED first) ride the test-format step
    const tomb_format_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/core_format/range_tombstone_format_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_tomb_format_test = b.addRunArtifact(tomb_format_test);
    format_test_step.dependOn(&run_tomb_format_test.step);

    // ponytail: zig build test-ps runs only page_store tests
    const ps_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/core_format/page_store_test.zig"),
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

    // slab_page_store_test — MemPageStore slab page-pool rework tests
    const slab_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/core_format/slab_page_store_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_slab_test = b.addRunArtifact(slab_test);
    const slab_test_step = b.step("test-slab", "Run slab page store tests only");
    slab_test_step.dependOn(&run_slab_test.step);

    // ponytail: zig build test-btree runs only btree tests
    const btree_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/btree_storage/btree_test.zig"),
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

    // T-38-P: range-tombstone probe (spike, no src/ changes) — design doc
    // docs/design/T-38-range-tombstone-probe.md. Exit 0 = all assertions pass.
    const rangetomb_probe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("spike/rangetomb_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_rangetomb_probe = b.addRunArtifact(rangetomb_probe);
    const rangetomb_probe_step = b.step("test-rangetomb-probe", "Run T-38-P range-tombstone probe (spike)");
    rangetomb_probe_step.dependOn(&run_rangetomb_probe.step);

    // T-38-2: range-tombstone read-path shadowing tests (RED first)
    const rangetomb_read_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/range_tombstone_read_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_rangetomb_read_test = b.addRunArtifact(rangetomb_read_test);
    const rangetomb_read_test_step = b.step("test-rangetomb-read", "Run T-38-2 range-tombstone read-path tests");
    rangetomb_read_test_step.dependOn(&run_rangetomb_read_test.step);

    // T-52: tomb-chain ring guard on FilePageStore (RED first, conductor-authored)
    const tomb_guard_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/tomb_chain_guard_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_tomb_guard_test = b.addRunArtifact(tomb_guard_test);
    const tomb_guard_test_step = b.step("test-tombguard", "Run T-52 tomb-chain ring-guard tests");
    tomb_guard_test_step.dependOn(&run_tomb_guard_test.step);
    test_step.dependOn(&run_tomb_guard_test.step);

    // T-53 (T-49 + T-50): open path must distinguish invalid-meta from fresh DB
    // (RED first, conductor-authored)
    const open_meta_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/open_meta_guard_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_open_meta_test = b.addRunArtifact(open_meta_test);
    const open_meta_test_step = b.step("test-openmeta", "Run T-53 invalid-meta vs fresh-DB tests");
    open_meta_test_step.dependOn(&run_open_meta_test.step);
    test_step.dependOn(&run_open_meta_test.step);

    // T-38-3 (stage 3 write path): deleteRange writes a range-tombstone chain
    // (RED first, conductor-authored). test-t38-3-write = flow/version/count;
    // test-t38-3-punch = punch-hole/split (INV-RT1, F1).
    const t38_3_write_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/t38_3_write_path_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_t38_3_write_test = b.addRunArtifact(t38_3_write_test);
    const t38_3_write_test_step = b.step("test-t38-3-write", "Run T-38-3 stage-3 write-path tests");
    t38_3_write_test_step.dependOn(&run_t38_3_write_test.step);
    test_step.dependOn(&run_t38_3_write_test.step);

    const t38_3_punch_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/t38_3_punch_hole_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_t38_3_punch_test = b.addRunArtifact(t38_3_punch_test);
    const t38_3_punch_test_step = b.step("test-t38-3-punch", "Run T-38-3 punch-hole/split tests");
    t38_3_punch_test_step.dependOn(&run_t38_3_punch_test.step);
    test_step.dependOn(&run_t38_3_punch_test.step);

    // ponytail: zig build test-writer runs only writer tests
    const writer_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/writer_test.zig"),
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

    // ponytail: zig build test-mvcc runs only MVCC tests
    const mvcc_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/mvcc_test.zig"),
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

    // ponytail: zig build test-db runs only db tests
    const db_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/db_test.zig"),
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

    // ponytail: zig build test-treedepth runs only the T-37 tree-depth tests
    // (deterministic RED regression + depth-invariant bound). Registered here
    // (not auto-discovered — auto-discovery only scans top-level tests/*.zig)
    // so `zig build test` includes it.
    const tree_depth_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/tree_depth_regression_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_tree_depth_test = b.addRunArtifact(tree_depth_test);
    const tree_depth_test_step = b.step("test-treedepth", "Run T-37 tree-depth tests only");
    tree_depth_test_step.dependOn(&run_tree_depth_test.step);
    test_step.dependOn(&run_tree_depth_test.step);

    // closed_state_test — applyBatch closed-branch tests (T-4)
    const closed_state_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/closed_state_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_closed_state_test = b.addRunArtifact(closed_state_test);
    db_test_step.dependOn(&run_closed_state_test.step);

    // lock_failure_test — putBatch lock failure / concurrency correctness tests (T-13)
    const lock_failure_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/lock_failure_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_lock_failure_test = b.addRunArtifact(lock_failure_test);
    db_test_step.dependOn(&run_lock_failure_test.step);

    // close_flush_failure_test — close-time flush failure tests (T-19)
    const close_flush_failure_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/close_flush_failure_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_close_flush_failure_test = b.addRunArtifact(close_flush_failure_test);
    db_test_step.dependOn(&run_close_flush_failure_test.step);

    // compact_strong_assert_test — compact strong-assertion tests (T-22)
    const compact_strong_assert_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/compact_strong_assert_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_compact_strong_assert_test = b.addRunArtifact(compact_strong_assert_test);
    db_test_step.dependOn(&run_compact_strong_assert_test.step);

    // txn_arena_test — WriteTxn staging arena tests
    const txn_arena_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/txn_arena_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_txn_arena_test = b.addRunArtifact(txn_arena_test);
    const txn_arena_step = b.step("test-txn-arena", "Run txn arena tests only");
    txn_arena_step.dependOn(&run_txn_arena_test.step);

    // ponytail: zig build test-compact runs only compact tests
    const compact_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/compact_test.zig"),
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

    // ponytail: zig build test-overflow runs only overflow tests
    const overflow_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/overflow_test.zig"),
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

    // batch_payload_chunking_test — T-40 RED: count-vs-payload-size batch chunking
    const batch_payload_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/batch_payload_chunking_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_batch_payload_test = b.addRunArtifact(batch_payload_test);
    const batch_payload_test_step = b.step("test-batchpayload", "Run batch payload chunking tests only");
    batch_payload_test_step.dependOn(&run_batch_payload_test.step);
    test_step.dependOn(&run_batch_payload_test.step);

    // mvcc_concurrent_flush_test — MVCC concurrent flush stress test (T-16)
    const mvcc_concurrent_flush_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/mvcc_concurrent_flush_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_mvcc_concurrent_flush_test = b.addRunArtifact(mvcc_concurrent_flush_test);
    db_test_step.dependOn(&run_mvcc_concurrent_flush_test.step);

    // delete_range_concurrent_test — deleteRange concurrency tests (T-20)
    const delete_range_concurrent_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/delete_range_concurrent_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_delete_range_concurrent_test = b.addRunArtifact(delete_range_concurrent_test);
    db_test_step.dependOn(&run_delete_range_concurrent_test.step);

    // deleterange_mem_budget_test — T-38-B RED: deleteRange internal
    // allocation peak must not grow linearly with the range (O(1) chunking).
    const deleterange_mem_budget_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/deleterange_mem_budget_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_deleterange_mem_budget_test = b.addRunArtifact(deleterange_mem_budget_test);
    db_test_step.dependOn(&run_deleterange_mem_budget_test.step);

    // applybatch_single_vs_multi_test — applyBatch single vs multi entry consistency tests (T-21)

    const applybatch_single_vs_multi_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/txn_writer_db/applybatch_single_vs_multi_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_applybatch_single_vs_multi_test = b.addRunArtifact(applybatch_single_vs_multi_test);
    db_test_step.dependOn(&run_applybatch_single_vs_multi_test.step);

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

    const fuzz_api_batch = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/api_batch_fuzz_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_fuzz_api_batch = b.addRunArtifact(fuzz_api_batch);

    const fuzz_range_delete = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/range_delete_fuzz_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_fuzz_range_delete = b.addRunArtifact(fuzz_range_delete);

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

    const fuzz_meta_corrupt = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/meta_corrupt_fuzz_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    const run_fuzz_meta = b.addRunArtifact(fuzz_meta_corrupt);

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
    fuzz_step.dependOn(&run_fuzz_api_batch.step);
    fuzz_step.dependOn(&run_fuzz_range_delete.step);
    fuzz_step.dependOn(&run_fuzz_format.step);
    fuzz_step.dependOn(&run_fuzz_meta.step);

    // ===== T-54-F (P3a): wire orphan tests into the default gate =====
    // Append-only: reuse the run artifacts that already power the named steps
    // (test-db / test-format / test-rangetomb-read / test-fuzz) — the build graph
    // runs a step once no matter how many steps depend on it, so this adds zero
    // duplicate compilation and zero duplicate execution (freelist_amp_red
    // gets a new artifact but NOT test_step — see its comment below).
    // long_run_2min stays OUT of the default gate by adjudication
    // (2-min soak; keeps its own long-run step).
    // freelist_amp_red_test.zig is NOT wired into test_step: its RED #1
    // ("small commit must not rewrite the whole FREE chain") is RED **by
    // design on main** — T-39-C proved incremental freelist persistence
    // cannot close safely under the current crash model and was downgraded
    // (issues/T-39-C-followup-append-only-freelist.md; RED #2/#3 are green
    // via T-39-B). Wiring it in would make `zig build test` permanently
    // exit 1. It gets a named step instead (on-demand, like long-run).
    // → adjudication request in docs/design/T-54-F-*.md §3.
    const freelist_amp_red_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/core_format/freelist_amp_red_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
            },
        }),
    });
    const run_freelist_amp_red_test = b.addRunArtifact(freelist_amp_red_test);
    const freelist_amp_red_step = b.step("test-t39-red", "T-39 RED tests (RED #1 red by design — T-39-C downgraded; NOT in the default gate)");
    freelist_amp_red_step.dependOn(&run_freelist_amp_red_test.step);

    // txn_writer_db orphans (artifacts exist; they rode db_test_step only)
    test_step.dependOn(&run_rangetomb_read_test.step);
    test_step.dependOn(&run_applybatch_single_vs_multi_test.step);
    test_step.dependOn(&run_delete_range_concurrent_test.step);
    test_step.dependOn(&run_deleterange_mem_budget_test.step);
    test_step.dependOn(&run_mvcc_concurrent_flush_test.step);
    // core_format orphans (range_tombstone_format rode test-format only)
    test_step.dependOn(&run_tomb_format_test.step);
    // fuzz orphans (artifacts exist; they rode test-fuzz only)
    test_step.dependOn(&run_fuzz_probe.step);
    test_step.dependOn(&run_fuzz_api.step);
    test_step.dependOn(&run_fuzz_api_batch.step);
    test_step.dependOn(&run_fuzz_range_delete.step);
    test_step.dependOn(&run_fuzz_format.step);
    test_step.dependOn(&run_fuzz_meta.step);

    // ===== T-54-F (P2): test-one — fast iteration entry with compile-time filter =====
    // Zig 0.16 has no runtime --test-filter; Compile.filters prunes at compile
    // time (cached per filter value). Root closure = tests/test_one_aggregator.zig
    // (everything the default gate covers on the tests/ side EXCEPT the 4
    // insertbatch sweep shards — each is a ~46s fault sweep that would serialize
    // in a single binary). src/ unit tests (mod_tests/exe_tests) are separate.
    // Usage: zig build test-one -Dfilter=T-42   (always pass -Dfilter; without
    // it this runs the whole aggregated suite in ONE serial binary — slow.)
    const test_one_filter = b.option([]const u8, "filter", "test-one: 只跑名字含该子串的测试");
    const test_one = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_one_aggregator.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cube_db", .module = mod },
                .{ .name = "zio", .module = zio_mod },
                .{ .name = "cube_check", .module = cube_check_mod },
            },
        }),
    });
    // NOTE: not `&.{f}` — that takes the address of a stack temporary whose
    // lifetime ends with this statement; Compile.reads it later during make()
    // and zig's build runner segfaults (getZigArgs arg iteration). Dupe onto
    // the build-runner arena so it lives for the whole build.
    if (test_one_filter) |f| test_one.filters = b.allocator.dupe([]const u8, &.{f}) catch @panic("oom");
    const run_test_one = b.addRunArtifact(test_one);
    const test_one_step = b.step("test-one", "Run filtered tests in one binary (use -Dfilter=<substr>)");
    test_one_step.dependOn(&run_test_one.step);
}
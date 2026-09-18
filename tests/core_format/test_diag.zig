//! test_diag.zig — T-54-B: 测试诊断输出静默化（core_format 目录）
//!
//! 背景：zig 的 build_runner（lib/compiler/build_runner.zig）对**成功**的 step 也回显
//! stderr（"No matter the result, we want to display error/warning messages"），
//! 于是测试里无条件 std.debug.print 的诊断会让全绿的 `zig build test` 输出
//! `failed command:` 行，被误读为失败。
//!
//! 约定：
//!   - 成功/信息路径的诊断 → 本模块 `print`/`verbose()`（默认静默）
//!   - 紧跟 `return error.X` 的失败上下文打印 → 保留原样 `std.debug.print`
//!     （失败时运行本来就是红的，回显 stderr 正是想要的）
//!
//! 打开方式：`CUBE_TEST_VERBOSE=1 zig build test`（值非空且非 "0" 即开）。
const std = @import("std");

var cached: ?bool = null;

/// 是否处于 verbose 模式（进程内缓存一次；fork 子进程继承同值，行为一致）。
pub fn verbose() bool {
    if (cached) |v| return v;
    const v = if (std.c.getenv("CUBE_TEST_VERBOSE")) |s|
        blk: {
            const val = std.mem.span(s);
            break :blk val.len > 0 and !std.mem.eql(u8, val, "0");
        }
    else
        false;
    cached = v;
    return v;
}

/// 信息路径诊断：默认不写 stderr，`CUBE_TEST_VERBOSE=1` 时输出。
pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (!verbose()) return;
    std.debug.print(fmt, args);
}

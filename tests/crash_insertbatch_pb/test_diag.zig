//! test_diag.zig — T-54-B: 测试诊断输出静默化（crash_insertbatch_pb 目录）
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

// ===== T-62: Linux flock reopen 卫生（crash 系列共用） =====
//
// macOS/BSD 的 flock 是按进程关联的：同进程经新 fd 再次 flock 会转换成功；
// Linux 严格按 open file description 判冲突（同进程双开、或锁持有者死后仍有
// 继承者存活，都会 EWOULDBLOCK）。CI（ubuntu）上 crash 系列的
// 「fork 子进程操作同一路径 → 子进程退出/SIGKILL → parent reopen」模式在
// 并行 suite（-j2，多二进制同时跑）下反复撞上 error.FileLocked。
//
// 两个卫生措施（tests/ 侧，零 src/ 改动）：
//   1. reopen 站点用 openWithRetry：持有者（本测试的子进程）退出/被杀后锁
//      必然释放（POSIX 语义），瞬态窗口（子进程崩溃 trace 打印、fsync 尾巴、
//      并行 suite 的调度延迟）内有界重试即可收敛。断言不变。
//   2. 子进程入口先 closeInheritedFds：fork 复制整个 fd 表，子进程会替其他
//      测试/兄弟执行「续命」它们已退出的锁（锁经继承的 OFD 存活）——关掉
//      继承 fd 后锁的生命周期严格归属于真正的持有者。
//
// 见 issues/T-62-macos-flock-reopen-ci-red.md。

const td_c = @cImport({
    @cInclude("unistd.h");
});

/// 带界重试的 FilePageStore 初始化：仅对 error.FileLocked 重试（最多
/// `attempts` 次 × 50ms），其他错误立即返回；重试耗尽时由调用方自行处理。
pub fn initStoreWithRetry(
    comptime Fps: type,
    allocator: @TypeOf(std.testing.allocator),
    path: []const u8,
    attempts: usize,
) !Fps {
    var attempt: usize = 0;
    while (true) {
        if (Fps.init(allocator, path)) |fps| {
            return fps;
        } else |e| {
            if (e != error.FileLocked or attempt >= attempts) return e;
            var req: std.c.timespec = .{ .sec = 0, .nsec = 50_000_000 };
            _ = std.c.nanosleep(&req, null);
            attempt += 1;
        }
    }
}

/// 子进程入口卫生：关闭继承的 fd（0/1/2 保留，3..1023 逐个 close，EBADF 忽略）。
/// `except` 为需保留的额外 fd（如 pipe 写端）。
pub fn closeInheritedFds(except: []const c_int) void {
    var fd: c_int = 3;
    while (fd < 1024) : (fd += 1) {
        var keep = false;
        for (except) |x| {
            if (x == fd) keep = true;
        }
        if (!keep) _ = td_c.close(fd);
    }
}

//! Minimal raw libc bindings for the file-backed page store.
//!
//! Zig 0.17 removed `@cImport` (C translation moved to the external translate-c package).
//! `std.c` covers most of what we used, but it types `mmap`/`ftruncate` with `PROT`/`MAP`
//! bitflag structs, has no `flock`/`mmap`-style int constants (`O_*`, `PROT_*`, `MAP_*`,
//! `LOCK_*`), and leaves `fstat` unavailable on Linux. Declaring the handful of externs we
//! actually call keeps every call site byte-identical to the pre-0.17 `@cImport` version —
//! no new dependency and no translate-c build step.
//!
//! POSIX-only by construction (same as the old `@cImport` block): `FilePageStore` needs
//! `mmap` + `flock`, so this module is only meaningful where those exist.
const std = @import("std");
const builtin = @import("builtin");

pub const off_t = std.c.off_t;
pub const mode_t = std.c.mode_t;
pub const struct_stat = std.c.Stat;
pub const timespec = std.c.timespec;
pub const clock_gettime = std.c.clock_gettime;
pub const MAP_FAILED: *anyopaque = @ptrFromInt(std.math.maxInt(usize));

pub const PROT_READ: c_int = 1;
pub const PROT_WRITE: c_int = 2;
pub const MAP_SHARED: c_int = 1;
pub const O_RDWR: c_int = 2;

// BSD/macOS and Linux disagree on these bit values.
pub const O_CREAT: c_int = if (builtin.target.os.tag.isDarwin()) 0x200 else 0o100;
pub const O_TRUNC: c_int = if (builtin.target.os.tag.isDarwin()) 0x400 else 0o1000;

// LOCK_SH/LOCK_EX/LOCK_NB are 1/2/4 on both Linux and the BSDs.
pub const LOCK_EX: c_int = 2;
pub const LOCK_NB: c_int = 4;

/// EWOULDBLOCK and EAGAIN are the same value on every platform we support; derive both from
/// `std.c.E` so we never hand-maintain a per-OS errno table.
pub const EAGAIN: c_int = @intFromEnum(std.c.E.AGAIN);
pub const EWOULDBLOCK: c_int = EAGAIN;

pub extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: mode_t) c_int;
pub extern "c" fn close(fd: c_int) c_int;
pub extern "c" fn unlink(path: [*:0]const u8) c_int;
pub extern "c" fn flock(fd: c_int, operation: c_int) c_int;
pub extern "c" fn fstat(fd: c_int, buf: *struct_stat) c_int;
pub extern "c" fn stat(path: [*:0]const u8, buf: *struct_stat) c_int;
pub extern "c" fn ftruncate(fd: c_int, length: off_t) c_int;
pub extern "c" fn fsync(fd: c_int) c_int;
pub extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: off_t) *anyopaque;
pub extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
pub extern "c" fn pwrite(fd: c_int, buf: *const anyopaque, count: usize, offset: off_t) isize;
pub extern "c" fn pread(fd: c_int, buf: *anyopaque, count: usize, offset: off_t) isize;
pub extern "c" fn write(fd: c_int, buf: *const anyopaque, count: usize) isize;
pub extern "c" fn read(fd: c_int, buf: *anyopaque, count: usize) isize;
pub extern "c" fn pipe(fds: *[2]c_int) c_int;
pub const O_RDONLY: c_int = 0;

// ===== process control (crash-injection test harness: fork + kill -9 + waitpid) =====
pub const pid_t = std.c.pid_t;
pub extern "c" fn fork() pid_t;
pub extern "c" fn waitpid(pid: pid_t, status: *c_int, options: c_int) pid_t;
pub extern "c" fn kill(pid: pid_t, sig: c_int) c_int;
pub extern "c" fn _exit(status: c_int) noreturn;
pub extern "c" fn usleep(usecs: c_uint) c_int;
pub extern "c" fn nanosleep(rqtp: *const timespec, rmtp: ?*timespec) c_int;

/// Identical on Linux and Darwin/BSD, so no per-OS branch needed.
pub const SIGKILL: c_int = 9;
pub const SIGABRT: c_int = 6;

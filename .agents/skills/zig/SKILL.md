---
name: zig
description: >
  Zig language reference for coding agent. Use when writing Zig code, reading
  Zig projects, fixing Zig errors, or explaining Zig concepts. Covers 0.16.0
  syntax, types, memory, comptime, build system, and standard library patterns.
metadata:
  version: 0.16.0
  source: https://ziglang.org/documentation/0.16.0/
---

# Zig Language Skill

Quick reference for Zig 0.16.0. Full docs: `references/language-reference.md`

## Syntax Quick Reference

### Variables & Types

```zig
const x: i32 = 42;        // immutable
var y: u32 = 0;           // mutable
const s = "hello";        // *const [5:0]u8
const slice: []const u8 = "hello";  // coerce to slice
```

**Basic types**: `i8..i128`, `u8..u128`, `f16..f128`, `bool`, `void`, `noreturn`, `type`, `anyerror`

### Functions

```zig
fn add(a: i32, b: i32) i32 {
    return a + b;
}

// Error return
fn parse(input: []const u8) !u64 {
    return std.fmt.parseInt(u64, input, 10);
}

// Generic via comptime
fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}
```

### Error Handling

```zig
const result = try dangerousCall();      // propagate error
const value = dangerousCall() catch 0;   // default on error
const v2 = dangerousCall() catch |err| switch (err) {
    error.OutOfMemory => return err,
    else => 0,
};
```

### Structs, Enums, Unions

```zig
const Point = struct {
    x: f32,
    y: f32,
    
    pub fn init(x: f32, y: f32) Point {
        return .{ .x = x, .y = y };
    }
};

const Direction = enum { north, south, east, west };

const Value = union(enum) {
    int: i64,
    float: f64,
    text: []const u8,
};
```

### Arrays & Slices

```zig
const arr = [5]i32{ 1, 2, 3, 4, 5 };    // fixed array
const slice = arr[1..3];                  // []const i32, [2, 3]
var buf: [1024]u8 = undefined;            // uninitialized
```

### Pointers & Optionals

```zig
const ptr: *i32 = &x;          // single-item pointer
const opt: ?i32 = null;        // optional
const val = opt.?;             // unwrap (panic if null)
const val2 = opt orelse 0;    // unwrap with default
```

## Memory Management

**No default allocator** — pass `std.mem.Allocator` explicitly:

```zig
fn process(allocator: std.mem.Allocator) ![]u8 {
    const buf = try allocator.alloc(u8, 1024);
    defer allocator.free(buf);
    // use buf...
    return buf;
}
```

**Common allocators**:
- `std.heap.page_allocator` — page-sized allocations
- `std.heap.ArenaAllocator` — bulk free at end
- `std.heap.FixedBufferAllocator` — stack buffer
- `std.heap.c_allocator` — wraps malloc (when linking libc)

**Pattern for CLI apps**:
```zig
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // use allocator, no manual free needed
}
```

## Comptime

Zig's compile-time execution — no runtime overhead:

```zig
// Compile-time parameters (generics)
fn List(comptime T: type) type {
    return struct {
        items: []T,
        len: usize,
    };
}

// Compile-time string concatenation
const greeting = "hello" ++ " " ++ "world";

// Compile-time if
fn foo(comptime x: bool) void {
    if (x) {
        // only compiled if x is true
    }
}
```

## Build System

**build.zig** structure:
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    
    const run_cmd = b.addRunArtifact(exe);
    b.step("run", "Run the app").dependOn(&run_cmd.step);
}
```

**Commands**: `zig build`, `zig build run`, `zig build test`, `zig build -Doptimize=ReleaseFast`

## Testing

```zig
const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "basic math" {
    try expect(1 + 1 == 2);
    try expectEqual(4, 2 * 2);
}

test "alloc leak detect" {
    const allocator = std.testing.allocator;
    const ptr = try allocator.alloc(u8, 10);
    defer allocator.free(ptr);  // leak detected if missing
}
```

**Run**: `zig test file.zig` or `zig build test`

## Standard Library Essentials

```zig
const std = @import("std");

// Debug print
std.debug.print("val: {d}, str: {s}\n", .{ 42, "hello" });

// File I/O
const file = try std.fs.cwd().openFile("data.txt", .{});
defer file.close();
const content = try file.readToEndAlloc(allocator, 1024 * 1024);

// JSON
const parsed = try std.json.parseFromSlice(MyType, allocator, json_str, .{});
defer parsed.deinit();

// Strings
const result = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ name, id });

// HashMap
var map = std.StringHashMap(i32).init(allocator);
try map.put("key", 42);
```

## Common Patterns

### Defer for cleanup
```zig
const resource = try acquire();
defer release(resource);
```

### Error unions with switch
```zig
const result = riskyOperation() catch |err| switch (err) {
    error.NotFound => handleNotFound(),
    error.AccessDenied => handleAccessDenied(),
    else => return err,
};
```

### Tagged union dispatch
```zig
switch (value) {
    .int => |i| handleInt(i),
    .float => |f| handleFloat(f),
    .text => |t| handleText(t),
}
```

## Pitfalls

1. **No string type** — use `[]const u8`, string literals are `*const [N:0]u8`
2. **No null pointers** — use `?T` optionals
3. **No exceptions** — use error unions `!T`
4. **No runtime** — no GC, no hidden allocations
5. **Pass allocators explicitly** — no global allocator

## See Also

- [Full Language Reference](references/language-reference.md) — detailed syntax and semantics
- [Standard Library Docs](https://ziglang.org/documentation/0.16.0/std/) — API reference

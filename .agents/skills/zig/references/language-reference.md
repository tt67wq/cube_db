# Zig 0.16.0 Language Reference

Complete reference extracted from https://ziglang.org/documentation/0.16.0/

## Table of Contents

- [Variables](#variables)
- [Types](#types)
- [Functions](#functions)
- [Control Flow](#control-flow)
- [Errors](#errors)
- [Memory](#memory)
- [Comptime](#comptime)
- [Build System](#build-system)
- [Testing](#testing)

---

## Variables

### Container Level Variables

Static lifetime, order-independent, lazily analyzed. Init value is implicitly comptime.

```zig
var y: i32 = add(10, x);  // order doesn't matter
const x: i32 = add(12, 34);

// Can be inside structs/unions/enums for namespacing
const S = struct {
    var x: i32 = 1234;
};
```

### Local Variables

Inside functions, comptime blocks, and @cImport blocks.

```zig
const x: i32 = 42;      // const after init
var y: u32 = 0;          // mutable

// comptime variable - evaluated at compile time
comptime var z: i32 = 1;
```

### Static Local Variables

Use struct inside function for static lifetime:

```zig
fn counter() i32 {
    const S = struct {
        var x: i32 = 0;
    };
    S.x += 1;
    return S.x;
}
```

---

## Types

### Primitive Types

| Type | Description |
|------|-------------|
| `i8..i128` | Signed integers |
| `u8..u128` | Unsigned integers |
| `f16..f128` | Floating point |
| `bool` | true/false |
| `void` | Zero-bit type |
| `noreturn` | Type of break, return, unreachable |
| `type` | The type of types |
| `anyerror` | The global error set |
| `usize`, `isize` | Pointer-sized integers |

### Strings

No string type. Use `[]const u8`:

```zig
const s1 = "hello";                    // *const [5:0]u8
const s2: []const u8 = "hello";        // slice
const s3 =
    \\multiline
    \\string literal
;                                       // no escapes, preserves newlines
```

### Arrays

```zig
const arr = [5]i32{ 1, 2, 3, 4, 5 };
const arr2: [5]i32 = .{ 1, 2, 3, 4, 5 };  // result location syntax
const len = arr.len;                       // comptime known

// Concatenation (comptime)
const a = [_]u8{ 1, 2 };
const b = [_]u8{ 3, 4 };
const c = a ++ b;                          // [4]u8{ 1, 2, 3, 4 }

// Repeat
const pattern = "ab" ** 3;                 // "ababab"

// Zero-init
const zeros = [_]u8{0} ** 10;
```

### Slices

```zig
var array: [10]u8 = undefined;
const slice: []u8 = array[0..5];           // runtime bounds
const slice2 = array[0..5];                // compile-time bounds: *[5]u8
```

### Pointers

```zig
var x: i32 = 42;
const ptr: *i32 = &x;          // single-item pointer
const cptr: *const i32 = &x;   // const pointer
const mptr: [*]i32 = &array;   // many-item pointer
```

### Optionals

```zig
var opt: ?i32 = null;
opt = 42;

// Unwrap
const val = opt.?;              // panic if null
const val2 = opt orelse 0;     // default value
const val3 = opt orelse return; // early return

// if capture
if (opt) |v| {
    use(v);
} else {
    handleNull();
}
```

### Structs

```zig
const Point = struct {
    x: f32,
    y: f32,
    
    // Methods
    pub fn distance(self: Point) f32 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }
};

const p = Point{ .x = 1.0, .y = 2.0 };
const d = p.distance();
```

### Enums

```zig
const Direction = enum {
    north,
    south,
    east,
    west,
};

const d = Direction.north;
const i: u2 = @intFromEnum(d);

// Non-exhaustive (allows unknown values)
const Number = enum(u8) {
    one = 1,
    two = 2,
    _,
};
```

### Tagged Unions

```zig
const Value = union(enum) {
    int: i64,
    float: f64,
    text: []const u8,
    
    pub fn format(self: Value) void {
        switch (self) {
            .int => |i| std.debug.print("{d}", .{i}),
            .float => |f| std.debug.print("{d}", .{f}),
            .text => |t| std.debug.print("{s}", .{t}),
        }
    }
};

const v = Value{ .int = 42 };
```

### Tuples

```zig
const tuple = .{ 1, "hello", 3.14 };
const x = tuple[0];           // i32
const s = tuple[1];           // *const [5:0]u8
```

---

## Functions

### Basic

```zig
fn add(a: i32, b: i32) i32 {
    return a + b;
}
```

### Error Return

```zig
fn parse(input: []const u8) !u64 {
    return std.fmt.parseInt(u64, input, 10);
}
```

### Generic (comptime parameters)

```zig
fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

// Usage
const result = max(f32, 1.0, 2.0);
```

### Pass-by-value / Pass-by-reference

Zig decides automatically. Parameters are immutable:

```zig
fn process(point: Point) f32 {
    // point could be copy or reference
    // taking address is unsafe
    return point.x + point.y;
}
```

### Inline Functions

```zig
inline fn fast(x: i32) i32 {
    return x * 2;
}
```

---

## Control Flow

### if

```zig
// Boolean
if (x > 0) {
    // ...
} else {
    // ...
}

// Optional capture
if (optional_value) |val| {
    use(val);
} else {
    handleNull();
}

// Error union capture
if (error_union) |val| {
    use(val);
} else |err| {
    handleErr(err);
}
```

### switch

```zig
switch (value) {
    0 => handleZero(),
    1...9 => handleDigit(),
    10, 20, 30 => handleSpecial(),
    else => handleOther(),
}

// Capture
switch (union_val) {
    .int => |i| useInt(i),
    .float => |f| useFloat(f),
    else => unreachable,
}
```

### while

```zig
var i: usize = 0;
while (i < 10) : (i += 1) {
    doSomething(i);
}

// With optional capture
while (getNext()) |item| {
    process(item);
} else {
    // executed when null
}

// With error capture
while (readByte()) |byte| {
    process(byte);
} else |err| {
    handleErr(err);
}
```

### for

```zig
const items = [_]i32{ 1, 2, 3 };
for (items) |item| {
    process(item);
}

// With index
for (items, 0..) |item, i| {
    process(i, item);
}

// Mutable slice
for (&array) |*item| {
    item.* *= 2;
}
```

### defer / errdefer

```zig
fn process() !void {
    const resource = try acquire();
    defer release(resource);           // always runs
    
    const data = try allocate();
    errdefer free(data);               // runs only on error
    
    try riskyOperation();
    return data;                       // defer runs, errdefer doesn't
}
```

### Blocks

```zig
const result = blk: {
    const x = compute();
    break :blk x * 2;
};
```

---

## Errors

### Error Sets

```zig
const MyError = error{
    OutOfMemory,
    InvalidInput,
    NotFound,
};

const global_errors: MyError || error{Timeout} = ...;
```

### Error Unions

```zig
const result: !i32 = riskyOperation();

// try - propagate error
const value = try result;

// catch - handle error
const value = result catch 0;
const value = result catch |err| switch (err) {
    error.OutOfMemory => return err,
    else => 0,
};
```

### Error Return Traces

In Debug/ReleaseSafe builds, errors include stack traces.

---

## Memory

### Allocators

No default allocator. Pass `std.mem.Allocator`:

```zig
fn process(allocator: std.mem.Allocator) ![]u8 {
    const buf = try allocator.alloc(u8, 1024);
    defer allocator.free(buf);
    // use buf
    return try allocator.dupe(u8, buf);
}
```

### Choosing an Allocator

1. **Library?** Accept `Allocator` parameter
2. **Linking libc?** `std.heap.c_allocator`
3. **Fixed size known at comptime?** `std.heap.FixedBufferAllocator`
4. **CLI app?** `std.heap.ArenaAllocator`

```zig
// CLI pattern
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // use allocator, no manual free needed
}
```

### Available Allocators

| Allocator | Use Case |
|-----------|----------|
| `std.heap.page_allocator` | Page-sized allocations |
| `std.heap.ArenaAllocator` | Bulk free at end |
| `std.heap.FixedBufferAllocator` | Stack buffer |
| `std.heap.c_allocator` | Wraps malloc (libc) |
| `std.testing.allocator` | Detects leaks in tests |

---

## Comptime

### Compile-Time Parameters

```zig
fn List(comptime T: type) type {
    return struct {
        items: []T,
        len: usize,
    };
}

var list = List(i32){ .items = &buf, .len = 0 };
```

### Compile-Time Expressions

```zig
const x = comptime blk: {
    var sum: i32 = 0;
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        sum += i;
    }
    break :blk sum;
};
```

### Compile-Time If

```zig
fn foo(comptime debug: bool) void {
    if (debug) {
        std.debug.print("debug mode\n", .{});
    }
}
```

### Inline Loops

```zig
inline for (.{ 1, 2, 3 }) |i| {
    // unrolled at compile time
}

inline while (i < 10) : (i += 1) {
    // unrolled
}
```

### Type Reflection

```zig
const info = @typeInfo(MyStruct);
switch (info) {
    .Struct => |s| {
        for (s.fields) |field| {
            std.debug.print("{s}: {s}\n", .{ field.name, @typeName(field.type) });
        }
    },
    else => {},
}
```

---

## Build System

### build.zig Structure

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    // Library
    const lib = b.addStaticLibrary(.{
        .name = "mylib",
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);
    
    // Executable
    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    
    // Run step
    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    
    // Tests
    const lib_tests = b.addTest(.{
        .root_module = lib.root_module,
    });
    const run_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
```

### Commands

```bash
zig build                          # default build
zig build run                      # run executable
zig build test                     # run tests
zig build -Doptimize=ReleaseFast   # optimized build
zig build -Dtarget=aarch64-linux   # cross compile
```

### Optimization Modes

| Mode | Performance | Safety | Binary Size |
|------|-------------|--------|-------------|
| Debug | Low | Full | Large |
| ReleaseSafe | Medium | Full | Medium |
| ReleaseFast | High | None | Medium |
| ReleaseSmall | Medium | None | Small |

---

## Testing

### Basic Test

```zig
const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "basic test" {
    try expect(1 + 1 == 2);
    try expectEqual(4, 2 * 2);
}
```

### Leak Detection

```zig
test "no leaks" {
    const allocator = std.testing.allocator;
    const ptr = try allocator.alloc(u8, 100);
    defer allocator.free(ptr);  // leak if missing
}
```

### Test Files

```bash
zig test src/myfile.zig           # test single file
zig build test                    # all tests via build system
```

### Fuzz Testing

```zig
test "fuzz test" {
    try std.testing.fuzz({}, testFn, .{});
}

fn testFn(_: void, input: *std.testing.FuzzInput) !void {
    const data = input.bytes(0, 100);
    try process(data);
}
```

---

## Built-in Functions

### Type Conversion

```zig
@intCast(value)           // integer cast with safety checks
@floatCast(value)         // float cast
@ptrCast(ptr)             // pointer cast
@alignCast(ptr)           // alignment cast
@intFromEnum(enum_val)    // enum to int
@enumFromInt(int_val)     // int to enum
@intFromPtr(ptr)          // pointer to int
@ptrFromInt(int_val)      // int to pointer
```

### Type Information

```zig
@TypeOf(value)            // get type of value
@typeName(T)              // type as string
@typeInfo(T)              // detailed type info
@sizeOf(T)                // size in bytes
@alignOf(T)               // alignment
@offsetOf(T, "field")     // field offset
```

### Math

```zig
@sqrt(x)                  // square root
@sin(x), @cos(x)          // trig
@exp(x), @log(x)          // exponential/log
@min(a, b), @max(a, b)    // min/max
@abs(x)                   // absolute value
@popCount(x)              // population count
@clz(x)                   // count leading zeros
@ctz(x)                   // count trailing zeros
@byteSwap(x)              // byte swap
```

### Memory

```zig
@memcpy(dest, src)        // copy memory
@memset(dest, value)      // set memory
@wasmMemorySize(0)        // wasm memory size
@wasmMemoryGrow(0, delta) // wasm memory grow
```

### Compilation

```zig
@import("module")         // import module
@embedFile("path")        // embed file contents
@compileError("msg")      // compile error
@panic("msg")             // runtime panic
@breakpoint()             // debugger breakpoint
@returnAddress()          // return address
```

### Arithmetic (Overflow-Safe)

```zig
a +% b                    // wrapping add
a -% b                    // wrapping sub
a *% b                    // wrapping mul
a +| b                    // saturating add
a -| b                    // saturating sub
a *| b                    // saturating mul
```

---

## Operator Precedence

```
x() x[] x.y x.* x.?     // postfix
a!b                       // unwrap
x{}                       // struct init
!x -x -%x ~x &x ?x      // unary
* / % ** *% *| ||        // multiplicative
+ - ++ +% -% +| -|       // additive
<< >> <<|                 // shift
& ^ | orelse catch        // bit/orelse/catch
== != < > <= >=           // comparison
and                       // logical and
or                        // logical or
= op=                     // assignment
```

---

## Common Pitfalls

1. **No string type** - use `[]const u8`
2. **No null pointers** - use `?T` optionals
3. **No exceptions** - use `!T` error unions
4. **No default allocator** - pass explicitly
5. **No runtime** - no GC, no hidden allocations
6. **Comptime vs runtime** - know the difference
7. **Slice vs array** - `[]T` vs `[N]T`
8. **const vs var** - const is default
9. **Pass allocators** - functions need them
10. **defer for cleanup** - always use it

# cube_db 使用手册（v2）

cube_db 是一个用 Zig 0.16.0 编写的嵌入式键值存储引擎。固定页（4KB） + freelist 页面复用 + COW B-tree：

- **O(1) compact**：只写 meta page，不重写数据
- **~1× 写放大**：旧页进 freelist 原地复用
- **O(1) 恢复**：读两个 meta page
- **MVCC reader 安全**：脏页持有到读者释放
- **溢出页**：大 value 自动走溢出页链

纯同步 API，调用方无需准备 runtime。

---

## 目录

1. [安装与构建](#1-安装与构建)
2. [v2 快速开始](#2-v2-快速开始)
3. [v2 API](#3-v2-api)
4. [错误处理](#4-错误处理)
5. [并发与 MVCC](#5-并发与-mvcc)
6. [常见配方](#6-常见配方)
7. [API 速查](#7-api-速查)

---

## 1. 安装与构建

依赖：
- Zig 0.16.0
- 本地 `../zio` 仓库（`build.zig.zon` 的 path 依赖）

```bash
zig build test          # 跑全部测试
zig build -Doptimize=ReleaseFast   # 编译库
zig build bench -Doptimize=ReleaseFast   # 跑基准测试
```

作为依赖引入：

```zig
// build.zig
const cube_dep = b.dependency("cube_db", .{ .target = target, .optimize = optimize });
const cube_mod = cube_dep.module("cube_db");
exe.root_module.addImport("cube_db", cube_mod);
```

代码中导入：

```zig
const cube = @import("cube_db");
const Db = cube.Db;
const Entry = cube.Entry;
const Options = cube.Options;
```

---

## 2. v2 快速开始

v2 使用固定大小页（4KB）和 freelist 页面复用，无需全量 rewrite。

### 内存模式（测试/原型）

```zig
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const Db = cube.Db;
const MemPageStore = cube.page_store.MemPageStore;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var ms = MemPageStore.init(allocator, 1 << 20); // 1M 页
    defer ms.deinit();

    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();

    try db.put("hello", "world");
    const v = try db.get("hello");
    defer allocator.free(v.?);
    std.debug.print("got: {s}\n", .{v.?});
}
```

### 文件模式（持久化）

```zig
var fps = try cube.file_page_store.create(allocator, "my_v2.db", 1 << 30); // 1GB mapsize
defer fps.deinit();
var db = try Db.open(allocator, fps.store(), .{});
defer db.close();

try db.put("hello", "world");
```

v2 的 `open` 从 meta page（page 1/2）恢复状态：root、sequence、entry_count、byte_size。恢复无需扫全文件，O(1)。

---

## 3. v2 API

### 3.1 打开与关闭

```zig
// 内存模式
var ms = MemPageStore.init(allocator, mapsize_pages);
defer ms.deinit();
var db = try Db.open(allocator, ms.store(), .{});
defer db.close();
```

```zig
// 文件模式（mmap）
var fps = try cube.file_page_store.create(allocator, "path.db", 1 << 30);
defer fps.deinit();
var db = try Db.open(allocator, fps.store(), .{});
defer db.close();
```

### 3.2 读：get

```zig
const v = try db.get("hello");
if (v) |value| {
    defer allocator.free(value); // ⚠️ 返回值由 allocator 分配，调用方负责 free
    std.debug.print("hello = {s}\n", .{value});
} else {
    std.debug.print("(missing)\n", .{});
}
```

- 返回 `!?[]u8`：`null` = key 不存在（或被 delete）。
- 非 null 的 value 是新分配的拷贝，必须 `free`。
- get 无锁、无 fsync，读原子 root 快照。

### 3.3 写：put / putBatch / delete

```zig
try db.put("hello", "world");   // 单条，1 次 commit
try db.delete("hello");         // tombstone
```

批量写（推荐）：

```zig
const entries = [_]Entry{
    .{ .key = "a", .value = "1" },
    .{ .key = "b", .value = "2" },
    .{ .key = "c", .value = "3" },
};
try db.putBatch(&entries); // 整批 1 次 commit
```

Entry 结构：

```zig
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
    tombstone: bool = false, // true 表示删除该 key
};
```

- 同 key 后者胜：批内多个相同 key，最后一个生效。
- key/value 是借用切片，在 `putBatch` 返回前必须保持有效。

批量删除：

```zig
const dels = [_]Entry{
    .{ .key = "a", .value = "", .tombstone = true },
    .{ .key = "b", .value = "", .tombstone = true },
};
try db.putBatch(&dels);
```

### 3.4 范围查询：select

```zig
var it = try db.select("b", "d"); // [min, max)
defer it.deinit();

while (try it.next()) |entry| {
    std.debug.print("{s} = {s}\n", .{ entry.key, entry.value });
}
```

- 区间是 **[min, max)**：min 包含、max 不包含。
- `null` 表示无界：`db.select(null, null)` 遍历全部。
- 自动跳过 tombstone。
- `entry.key`/`entry.value` 借用迭代器内部缓冲，**下次 `next()` 后失效**。

保留 entry 内容：

```zig
var keys = std.ArrayList([]u8).empty;
defer {
    for (keys.items) |k| allocator.free(k);
    keys.deinit(allocator);
}
var it = try db.select(null, null);
defer it.deinit();
while (try it.next()) |e| {
    try keys.append(allocator, try allocator.dupe(u8, e.key));
}
```

### 3.5 压缩：compact

v2 compact 是 **O(1)** 的——只写 meta page，不重写数据。

```zig
try db.compact(); // 立即回收所有脏页（需要无活跃 reader）
```

- 有活跃 reader 时，脏页会留在 pending_free 中直到 reader 结束。
- compact 会自动 flush 所有可 flush 的 pending_free。

### 3.6 选项：Options

```zig
var db = try Db.open(allocator, store, .{
    .fsync = true,   // 每次写入后 fsync
});
```

| 字段 | 类型 | 默认 | 含义 |
|---|---|---|---|
| `fsync` | `bool` | `true` | 写操作是否 fsync 落盘。`false` = 更快但 crash 丢数据 |

v2 compact 是 O(1) 的，无需 v1 的 `auto_compact_*` 参数。

---

## 4. 错误处理

所有写/读操作返回 `!T`（错误联合）。常见错误：

| 错误 | 含义 |
|---|---|
| `OutOfMemory` | 分配失败 |
| `PageNotFound` | 页号无效（文件损坏） |
| `MapFull` | 页空间耗尽（mapsize 不足） |

```zig
db.put("k", "v") catch |err| switch (err) {
    error.PageNotFound => { /* 存储损坏 */ },
    else => return err,
};
```

---

## 5. 并发与 MVCC

- **多线程读**：安全。`get`/`select` 读原子 root 快照，无锁无 fsync。
- **MVCC reader**：写入器在 reader 活跃时延迟回收脏页：

```zig
const reader_seq = db.beginRead(); // 开始读，返回当前序列号
const v = try db.get("k");          // 读一致性快照
db.endRead();                        // 结束读，释放脏页
```

- **没有活跃 reader 时**：脏页在每次 commit 后自动回收。
- **不要跨线程共享一个迭代器**；每个线程各开各的 `select`。

---

## 6. 常见配方

### 6.1 计数器（read-modify-write）

```zig
fn incr(db: *Db, key: []const u8) !void {
    const cur = try db.get(key);
    const n: u64 = if (cur) |c| blk: { defer allocator.free(c); break :blk std.fmt.parseInt(u64, c, 10) catch 0; } else 0;
    var buf: [20]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{n + 1});
    try db.put(key, s);
}
```

> 注意：单 key 的 read-modify-write **非原子**（get 与 put 之间有窗口）。

### 6.2 批量导入

```zig
fn import(db: *Db, items: []const struct { k: []const u8, v: []const u8 }) !void {
    var entries = try allocator.alloc(Entry, items.len);
    defer allocator.free(entries);
    for (items, 0..) |it, i| entries[i] = .{ .key = it.k, .value = it.v };
    try db.putBatch(entries);
}
```

### 6.3 全量遍历

```zig
var it = try db.select(null, null);
defer it.deinit();
var count: usize = 0;
while (try it.next()) |_| count += 1;
std.debug.print("total entries: {d}\n", .{count});
```

### 6.4 删除一批 key

```zig
fn deleteKeys(db: *Db, keys: []const []const u8) !void {
    var entries = try allocator.alloc(Entry, keys.len);
    defer allocator.free(entries);
    for (keys, 0..) |k, i| entries[i] = .{ .key = k, .value = "", .tombstone = true };
    try db.putBatch(entries);
}
```

---

## 7. API 速查

```zig
const cube = @import("cube_db");
const Db = cube.Db;
const Entry = cube.Entry;
const Options = cube.Options;

// 打开
var ms = cube.page_store.MemPageStore.init(allocator, 1 << 20);
defer ms.deinit();
var db = try Db.open(allocator, ms.store(), .{});
defer db.close();

// 读
const v = try db.get(key);            // !?[]u8，调用方 free

// 写
try db.put(key, value);               // 单条
try db.putBatch(&entries);            // 批量（推荐）
try db.delete(key);                   // tombstone

// 范围 [min, max)
var it = try db.select(min, max);     // min/max 可 null
defer it.deinit();
while (try it.next()) |e| { /* e.key, e.value 借用 */ }

// 压缩
try db.compact();                     // O(1) meta 切换

// MVCC reader
db.beginRead();
db.endRead();
```

### 类型

| 类型 | 定义 |
|---|---|
| `Db` | 数据库句柄，所有操作的入口 |
| `Entry` | `struct { key: []const u8, value: []const u8, tombstone: bool = false }` |
| `Options` | `struct { fsync: bool = true }` |
| `Iterator` | `select` 返回，有 `.next() !?LeafEntry` 与 `.deinit()` |

### 所有权规则速记

- `get` 返回的 `[]u8`：**调用方 free**。
- `put`/`putBatch`/`delete` 的 key/value：**借用**，返回前有效。
- `select` 的 min/max：**借用**，迭代器存活期间有效。
- 迭代器 `entry.key`/`entry.value`：**借用迭代器内部**，下次 `next()` 前有效。
- `db`：`open` 分配，`close` 释放。

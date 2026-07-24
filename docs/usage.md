# cube_db 使用手册

cube_db 是一个用 Zig 0.16.0 编写的嵌入式键值存储，参考 [CubDB](https://github.com/lucaong/cubdb) 架构：append-only 数据文件、不可变 B-tree（Copy-on-Write）、compaction 回收旧版本。纯同步 API，调用方无需准备 runtime。

本手册覆盖全部公开 API 与常见用法。

---

## 目录

1. [安装与构建](#1-安装与构建)
2. [打开与关闭](#2-打开与关闭)
3. [读：get](#3-读get)
4. [写：put / putBatch / delete](#4-写put--putbatch--delete)
5. [范围查询：select](#5-范围查询select)
6. [压缩：compact](#6-压缩compact)
7. [选项：Options](#7-选项options)
8. [错误处理](#8-错误处理)
9. [并发](#9-并发)
10. [持久化与崩溃恢复](#10-持久化与崩溃恢复)
11. [常见配方](#11-常见配方)
12. [API 速查](#12-api-速查)

---

## 1. 安装与构建

依赖：
- Zig 0.16.0
- 本地 `../zio` 仓库（`build.zig.zon` 的 path 依赖）

在你的项目 `build.zig.zon` 中添加依赖，或直接 clone 本仓库并在其目录下操作：

```bash
zig build test          # 跑全部测试
zig build -Doptimize=ReleaseFast   # 编译库与可执行
```

作为依赖引入时，把 `cube_db` 模块加入你的可执行：

```zig
// build.zig（节选）
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

## 2. 打开与关闭

```zig
const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const path = "my.db";

    // open 会创建文件（若不存在）或恢复已有数据
    const db = try Db.open(allocator, path, .{}); // 默认 Options
    defer db.close() catch {};

    // ... 操作 db ...
}
```

要点：
- `open` 自动恢复：扫描文件末尾的 header 记录，定位最新 B-tree root。
- `close` 会 `fsync` 并关闭文件句柄。务必用 `defer db.close() catch {}` 确保释放。
- `db` 是堆分配的 `*Db`，`close` 时释放（包括内部 dup 的 path 字符串）。
- 同一路径不要同时打开两个 `Db` 实例（无文件锁，并发写会损坏数据）。

---

## 3. 读：get

```zig
const v = try db.get("hello");
if (v) |value| {
    defer db.allocator.free(value); // ⚠️ 返回值由 allocator 分配，调用方负责 free
    std.debug.print("hello = {s}\n", .{value});
} else {
    std.debug.print("(missing)\n", .{});
}
```

要点：
- 返回 `!?[]u8`：`null` = key 不存在（或被 delete）。
- **非 null 的 value 是新分配的拷贝**，必须 `allocator.free(value)`。`db.allocator` 就是 `open` 时传入的 allocator。
- get 无锁、无 fsync，读原子 root 快照，可与并发写共存（读到最近一次已提交的值）。

---

## 4. 写：put / putBatch / delete

### 4.1 单条写：put

```zig
try db.put("hello", "world");   // 1 次 fsync
try db.put("hello", "world2");  // 覆盖，1 次 fsync
```

每次 `put` 走一次完整的 COW 提交 + 一次 `fsync`。单线程下约 400–700us/op（fsync 主导）。

### 4.2 批量写：putBatch（推荐）

```zig
const entries = [_]Entry{
    .{ .key = "a", .value = "1" },
    .{ .key = "b", .value = "2" },
    .{ .key = "c", .value = "3" },
};
try db.putBatch(&entries); // 整批 1 次 fsync + COW 路径重写摊薄
```

- 一次 `putBatch` 把 N 个 op 合并到**一次** B-tree 提交：1 次 header append + 1 次 fsync + 节点缓存摊薄 COW。
- benchmark 实测 **~1000× 单线程吞吐**（0.15us/op vs put 498us/op，100B value）。
- **同 key 后者胜**：批内多个相同 key，最后一个生效（last-write-wins），但**不保证调用方入队顺序**的可见性语义——批内是原子提交。
- `Entry` 结构：

  ```zig
  pub const Entry = struct {
      key: []const u8,
      value: []const u8,
      tombstone: bool = false, // true 表示删除该 key
  };
  ```

- `key`/`value` 是借用切片，在 `putBatch` 返回前必须保持有效（函数内不异步持有）。

> 何时用 putBatch：写多条时永远优先用 `putBatch`。单条写用 `put` 即可（等价于 1 元素 batch，但有栈 future 快路径）。

### 4.3 删除：delete

```zig
try db.delete("hello"); // 写一条 tombstone，1 次 fsync
// 之后 db.get("hello") 返回 null
```

- `delete` = 插入 tombstone 记录（同 put 路径），不是物理删除。
- 真正回收空间靠 [`compact`](#6-压缩compact)。

### 4.4 批量删除

```zig
const dels = [_]Entry{
    .{ .key = "a", .value = "", .tombstone = true },
    .{ .key = "b", .value = "", .tombstone = true },
};
try db.putBatch(&dels);
```

---

## 5. 范围查询：select

```zig
// 查 [min, max) 范围内所有 key（min 含、max 不含）
var it = try db.select("b", "d");
defer it.deinit();

while (try it.next()) |entry| {
    std.debug.print("{s} = {s}\n", .{ entry.key, entry.value });
    // ⚠️ entry.key / entry.value 借用迭代器内部缓冲，
    //    在下一次 next() 或 deinit() 前有效。需保留请自行 dupe。
}
```

- 区间是 **[min, max)**：min 包含、max 不包含。
- `null` 表示无界：`db.select(null, null)` 遍历全部；`db.select("m", null)` 从 "m" 到末尾。
- 自动跳过 tombstone（已删除的 key 不出现）。
- **min/max 借用调用方切片**，迭代器存活期间不能释放。
- `entry.key`/`entry.value` 指向迭代器内部解码的 leaf，**下次 `next()` 后失效**。

### 5.1 保留 entry 内容

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

---

## 6. 压缩：compact

append-only + COW 会产生垃圾（旧版本节点）。`compact` 做一次**全量重写**：遍历全部 live entry，写到临时文件，原子 rename 切换，dirt 归零。

### 手动 compact

```zig
try db.compact(); // 回收所有垃圾，物理文件缩到 live 大小
```

- 持有写锁，与 put/delete 串行（compact 期间写会等待）。
- 耗时 ≈ 顺序读 + 顺序写全部 live 数据（~2.9 MB/s，受单线程重写限制）。

### 自动 compact

`Db.open` 传入 `Options` 可启用自动后台 compact。当文件 dirt 比例达到阈值时，自动在后台线程中执行压缩：

```zig
const db = try Db.open(allocator, "my.db", .{
    .auto_compact_dirt_ratio = 0.30,    // dirt/(dirt+live) ≥ 30% 时触发
    .auto_compact_min_bytes = 16 << 20, // 文件至少 16MB 才触发
});
```

自动 compact 分两阶段：
1. **阶段 1（无锁扫描）**：基于初始 `old_root` 快照遍历全部活 entry 写入临时文件。全程不持写锁，与在线写入并行。
2. **阶段 2（持锁 diff + 切换）**：获取写锁后对比 `old_root` 与当前 `final_root`，用 merge diff 补齐阶段 1 期间的增量写入，然后原子切换。

阶段 2 持锁时间 ≈ O(树全量) 只读 merge（无写入时 O(1) 捷径），典型毫秒级。

失败处理：指数退避重试（默认 5 次，1s→2s→4s→8s→16s cap 60s），`null = 完全禁用自动 compact`。

### 何时 compact

- 自动 compact 在 dirt 超阈值时自动回收，无需手动干预。
- 手动 `compact()` 仍适用：想在特定时机强制执行，或用于无 dirt 变化的精确 dirt 归零。

---

## 7. 选项：Options

```zig
const opts = cube.Options{
    .fsync = true,                      // 每次 put/putBatch/delete 是否 fsync（默认 true）
    .auto_compact_dirt_ratio = 0.30,    // 触发阈值（stub，见上）
    .auto_compact_min_bytes = 16 << 20, // 触发下限（stub）
};
const db = try Db.open(allocator, "my.db", opts);
```

| 字段 | 类型 | 默认 | 含义 |
|---|---|---|---|
| `fsync` | `bool` | `true` | 写操作是否 `fsync` 落盘。`false` = 只 append 不 sync（快但 crash 丢未 sync 数据，需自行 `db.close()` 或后续 sync） |
| `auto_compact_dirt_ratio` | `?f32` | `0.30` | dirt/(live+dirt) 达到该值触发自动后台 compact。`null` = 禁用 |
| `auto_compact_min_bytes` | `u64` | 16MB | 自动 compact 检查的 live+dirt 下限（避免小文件频繁触发） |
| `compact_time_slice_ms` | `u64` | 10 | 阶段 1 单批扫描时间片（毫秒），越小限流越频繁 |
| `compact_scan_sleep_ms` | `u64` | 0 | 阶段 1 批间 I/O 限流睡眠（毫秒）。0 = 只 yield（SSD 默认）；HDD 场景调大 |
| `compact_max_retries` | `u32` | 5 | 失败重试次数，达到后放弃等下次触发 |
| `compact_retry_base_ms` | `u64` | 1000 | 重试退避基数（毫秒），第 n 次退避 = base << (n-1)，cap 60s |

> `putNoFsync` 当前是 stub（与 `put` 行为一致）。若要跳过 fsync，用 `Options{ .fsync = false }` 开库 + 普通 `put`。

---

## 8. 错误处理

所有写/读操作返回 `!T`（错误联合）。常见错误：

| 错误 | 含义 |
|---|---|
| `OutOfMemory` | 分配失败 |
| `IoError` | 文件读写失败 |
| `CorruptCrc` | 记录 CRC 校验失败（文件损坏） |
| `Truncated` | 读取被截断 |
| `BadMagic`/`BadVersion` | 文件头 magic/版本不匹配 |

```zig
db.put("k", "v") catch |err| switch (err) {
    error.IoError => { /* 磁盘问题 */ },
    else => return err,
};
```

- 写失败（如 fsync 失败）后，该批数据**未落盘**，但内存状态可能已推进——视为未定义，建议关闭 db 重开。
- 读 `get` 出错通常是文件损坏，返回 `CorruptCrc`/`Truncated`。

---

## 9. 并发

- **多线程读**：安全。`get`/`select` 读原子 root 快照，无锁无 fsync，可与写并发。
- **多线程写**：安全，且**自动合并**。`put`/`delete` 经 leader/follower group commit：并发调用者入共享队列，无 leader 的线程负责清空队列合并成一次 `applyBatch`（1 fsync），其余当 follower 阻塞在自己的 Future 等唤醒。16 线程 × 50 put 实测合并 ~6.8×（800 op → ~117 次 fsync）。`putBatch` 本身已是单次提交；`compact` 经写互斥锁与写串行。
- 想要最高吞吐单线程写：用 `putBatch`（~1000×，1 fsync 摊到 N op + COW 摊薄）；并发写则 group commit 自动叠乘数。
- **不要跨线程共享一个迭代器**；每个线程各开各的 `select`。

```zig
// 安全：多线程并发 get + 单线程 putBatch
const db = try Db.open(allocator, "my.db", .{});
defer db.close() catch {};

// 写线程
const Writer = struct {
    fn run(d: *Db) !void {
        const entries = [_]Entry{ .{ .key = "x", .value = "1" } };
        try d.putBatch(&entries);
    }
};
// 读线程
const Reader = struct {
    fn run(d: *Db) !void {
        const v = try d.get("x");
        if (v) |val| d.allocator.free(val);
    }
};
```

---

## 10. 持久化与崩溃恢复

- 每次 `put`/`putBatch`/`delete`（`fsync=true` 时）返回后，数据已 fsync 落盘。
- **崩溃恢复**：`open` 扫描文件末尾 header，定位最后一个有效 header（CRC 校验通过），其 `btree_root` 即恢复点。尾部不完整的记录被截断丢弃。
- `fsync=false` 时，未 sync 的 append 在 crash 后可能丢失（append-only 保证不损坏，只丢尾部）。
- **compact 的原子性**：写到 `{path}.compact` 临时文件，sync 后 `rename` 原子替换。crash 在 rename 前则旧文件完整保留；rename 后新文件生效。父目录 fsync 当前跳过（极端 crash 下 rename 可能不持久，已知限制）。

---

## 11. 常见配方

### 11.1 计数器（read-modify-write）

```zig
fn incr(db: *Db, key: []const u8) !void {
    const cur = try db.get(key);
    const n: u64 = if (cur) |c| blk: { defer db.allocator.free(c); break :blk std.fmt.parseInt(u64, c, 10) catch 0; } else 0;
    var buf: [20]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{n + 1});
    try db.put(key, s);
}
```

> 注意：单 key 的 read-modify-write **非原子**（get 与 put 之间有窗口）。并发自增会丢更新。需要原子计数请用 `putBatch` 单条 + 应用层协调，或加自己的锁。

### 11.2 批量导入

```zig
fn import(db: *Db, items: []const struct { k: []const u8, v: []const u8 }) !void {
    var entries = try db.allocator.alloc(Entry, items.len);
    defer db.allocator.free(entries);
    for (items, 0..) |it, i| entries[i] = .{ .key = it.k, .value = it.v };
    try db.putBatch(entries); // 一次提交，最快
}
```

### 11.3 全量遍历

```zig
var it = try db.select(null, null);
defer it.deinit();
var count: usize = 0;
while (try it.next()) |_| count += 1;
std.debug.print("total entries: {d}\n", .{count});
```

### 11.4 定期压缩

```zig
// 每写 N 批后压缩一次，控制文件膨胀
const N = 1000;
var i: usize = 0;
while (i < N) : (i += 1) {
    try db.putBatch(&some_entries);
}
try db.compact();
```

### 11.5 删除一批 key

```zig
fn deleteKeys(db: *Db, keys: []const []const u8) !void {
    var entries = try db.allocator.alloc(Entry, keys.len);
    defer db.allocator.free(entries);
    for (keys, 0..) |k, i| entries[i] = .{ .key = k, .value = "", .tombstone = true };
    try db.putBatch(entries);
}
```

---

## 12. API 速查

```zig
const cube = @import("cube_db");
const Db = cube.Db;
const Entry = cube.Entry;
const Options = cube.Options;

// 生命周期
const db = try Db.open(allocator, path, .{});
defer db.close() catch {};

// 读（返回值调用方 free）
const v = try db.get(key);          // !?[]u8

// 写
try db.put(key, value);             // 单条，1 fsync
try db.putBatch(&entries);          // 批量，1 fsync + COW 摊薄（推荐）
try db.delete(key);                 // tombstone

// 范围 [min, max)
var it = try db.select(min, max);   // min/max 可 null
defer it.deinit();
while (try it.next()) |e| { /* e.key, e.value（借用，next 后失效） */ }

// 压缩
try db.compact();

// 选项
const opts = Options{ .fsync = true };  // fsync / auto_compact_*(stub)
const db2 = try Db.open(allocator, path, opts);
```

### 类型

| 类型 | 定义 |
|---|---|
| `Db` | 数据库句柄，所有操作的入口 |
| `Entry` | `struct { key: []const u8, value: []const u8, tombstone: bool = false }` |
| `Options` | `struct { fsync: bool = true, auto_compact_dirt_ratio: ?f32 = 0.30, auto_compact_min_bytes: u64 = 16MB }` |
| `Iterator` | `select` 返回，有 `.next() !?LeafEntry` 与 `.deinit()` |

### 所有权规则速记

- `get` 返回的 `[]u8`：**调用方 free**（用 `db.allocator`）。
- `put`/`putBatch`/`delete` 的 key/value：**借用**，返回前有效。
- `select` 的 min/max：**借用**，迭代器存活期间有效。
- 迭代器 `entry.key`/`entry.value`：**借用迭代器内部**，下次 `next()` 前有效。
- `db`：`open` 分配，`close` 释放。

---

更多实现细节见 [`docs/tutorial/`](tutorial/)。

# cube_db 使用手册

cube_db 是一个用 Zig 0.16.0 编写的嵌入式键值存储引擎。固定页（4KB） + freelist 页面复用 + COW B-tree：

- **O(1) compact**：只写 meta page，不重写数据
- **~1× 写放大**：旧页进 freelist 原地复用
- **O(1) 恢复**：读两个 meta page
- **MVCC reader 安全**：脏页持有到读者释放
- **溢出页**：大 value 自动走溢出页链

纯同步 API，调用方无需准备 runtime。

> 相关工具：离线完整性校验 **`cube_check`** 使用见 [cube-check.md](cube-check.md)。

---

## 目录

1. [安装与构建](#1-安装与构建)
2. [快速开始](#2-快速开始)
3. [API](#3-api)
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

## 2. 快速开始

cube_db 使用固定大小页（4KB）和 freelist 页面复用，无需全量 rewrite。

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
var fps = try cube.file_page_store.FilePageStore.init(allocator, "my.db"); // LMDB 式 1TB 预留 mmap
defer fps.deinit();
var db = try Db.open(allocator, fps.store(), .{});
defer db.close();

try db.put("hello", "world");
```

`open` 从 meta page（page 1/2）恢复状态：root、sequence、entry_count、byte_size。恢复无需扫全文件，O(1)。

**FilePageStore 特性：**
- **mmap 1TB 预留区**：64-bit 系统虚拟地址空间充裕，文件按需 `ftruncate` 增长
- **零拷贝读**：reader 直接经 mmap 指针读，无需 `read()` 系统调用
- **双 meta 页交替**：meta 写入 page 1 和 page 2 交替进行，崩溃后取 sequence 较大者恢复
- **fsync 落盘**：`commit` 后自动 `fsync`，保证崩溃安全

---

## 3. API

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
var fps = try cube.file_page_store.FilePageStore.init(allocator, "path.db");
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
- **读路径优化**：跳过 CRC 校验，get 100B ~2.7µs（接近 LMDB 级）
- **高频读选型**：逐次 alloc/free 有成本，热路径（缓存/索引层）用 `getInto`（见 3.2.1）。

#### 3.2.1 无拷贝读：getInto（T-29）

```zig
var buf: [4096]u8 = undefined; // 调用方持有 buffer，可复用
const n = (try db.getInto("hello", &buf)) orelse return; // null = key 不存在
std.debug.print("hello = {s}\n", .{buf[0..n]});
```

- `getInto(key, buffer) !?usize`：value 拷入 buffer，返回写入字节数；
  `ReadTxn.getInto` 同款（快照 pin 于 txn root）。
- `null` 唯一保留给 **key 不存在**（含 tombstone）——与 T-23 移除的旧 borrowed
  API 的 null 多义性彻底解耦（拷贝语义，无借用失效来源）。
- buffer 不足返回 `error.BufferTooSmall`，且 **buffer 不被写入/不清空**（无部分
  写入，可安全换大 buffer 重试）。
- 精确边界：buffer 恰好等长成功；溢出值（>3800B）经溢出页链逐页直拷，
  与 get() 逐字节一致。
- 全链路零分配：分配权归调用方，高频读摆脱 per-call alloc/free。

> **迁移说明**：零拷贝 borrowed 读 API（Db 层与 ReadTxn 层）已于 T-23 移除 — 其 null 返回值存在多义性（溢出值 / 墓碑 / 不存在三种语义不可区分）。T-29 以 `getInto`（拷贝入调用方 buffer + 显式 BufferTooSmall 错误）解决同一问题：null 语义唯一，分配权归调用方。读取可用 `get()` / `getInto()`，语义等价、性能特性不同。

### 3.3 写：put / putBatch / delete / flush

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

**Micro-batching（自动批量提交）：**

```zig
var db = try Db.open(allocator, store, .{
    .micro_batch = .{ .batch_threshold = 100 },
});
// 前 99 次 put 暂存，第 100 次自动 flush
try db.put("k1", "v1");
try db.put("k2", "v2");
// ... 第 100 次 put 触发批量提交

// 强制提交暂存数据
try db.flush();

// 跳过 batching，立即提交
try db.putDirect("urgent", "now");
```

- `batch_threshold = 0`（默认）：禁用 batching，`put`/`delete` 立即提交
- `batch_threshold > 0`：暂存到 pending，达到阈值自动 `flush()`
- `flush()`：强制提交所有 pending entries
- `putDirect()`/`deleteDirect()`：跳过 batching，立即提交
- `close()`：自动 flush 残留 entries

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

范围删除（`deleteRange`）：按 `[min, max)` 半开区间批量删除 key，边界语义与 `select` 完全一致——`null` min/max 表示该侧无界，`(null, null)` 清空全库。内部基于 `select` 迭代器 + tombstone 批量提交实现，micro-batch 下会先 flush 暂存项再删除，保证 pending 的 key 也在删除范围内。

```zig
// 删除 [b, d)：删 b、c，保留 a、d、e
try db.deleteRange("b", "d");

// null 边界 = 无界
try db.deleteRange(null, "c");  // 删所有 < c 的 key
try db.deleteRange("m", null);  // 删所有 >= m 的 key
try db.deleteRange(null, null); // 清空全库
```

- 半开区间 `[min, max)`：`max` 本身不被删除（同 `select`）。
- 反向/空区间（`min >= max`，均非 null）：no-op 成功，不报错。
- 对已不存在的 key 幂等：再次删除同一区间仍成功。
- 删除后 `entryCount()` 相应减少（与单条 `delete` 记账一致）。

### 3.4 显式事务（LMDB 式）

`put`/`putBatch`/`delete` 是便捷 API（内部包隐式 WriteTxn，立即提交）。需多步原子或 abort 时用显式事务：

```zig
// 写事务：单写者互斥，commit = applyBatch + meta 切换 + fsync；abort 丢弃不落盘
var w = try db.beginWriteTxn();
defer w.deinit(); // 未 commit/abort 时 deinit 自动 abort
try w.put("k", "v");
try w.delete("old");
try w.commit(); // 原子提交

// 读事务：MVCC 快照（持有开 txn 时的 root），不阻塞写者
var r = try db.beginReadTxn();
defer r.end();
const v = try r.get("k");
defer if (v) |val| allocator.free(val);
```

- WriteTxn：单写者互斥（同一时刻仅一个活跃）；`commit` 后原子可见，`abort` 丢弃。
- ReadTxn：快照隔离，写者提交新版本后 reader 仍读旧快照，直到 `end`。
- 跨 `beginWriteTxn`/`commit` 的 key/value 须保持有效（借用切片）。
### 3.5 范围查询：select

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
- **借用契约（T-29 Phase B）**：`entry.key`/`entry.value` 为借用切片，**仅到
  下次 `next()` 或 `deinit()` 前有效**。内联 value/key 直接借自 mmap 页（零拷贝）；
  溢出 value（>3800B）经迭代器内部复用缓冲拼接——连续迭代溢出条目时，前一
  entry 的 value 会被新条目覆盖（借用契约的可观察面）。
- **快照 pin（T-29 Phase B）**：迭代器生命周期持有 MVCC 读者名额——迭代中途
  写者提交（COW）不影响已借用页，迭代器始终看到 select 时刻的快照；脏页延迟
  到 `deinit()`（末位读者退出）才回收。**忘记 deinit 会滞留读者名额**（脏页
  不回收、`dirt` 计数不降），务必 `defer it.deinit()`。`ReadTxn.select` 的
  迭代器持有独立 pin（与 txn 的 pin 可叠加），同样须 deinit。
- 直接用 `btree.select`（raw 页存储层）时无 pin，调用方自行保证 Store 稳定性。
- 扫描性能（T-29 Phase B 借用化）：下推栈 O(深度)（无每节点 dupe 副本），
  内联值扫描零分配，溢出值每迭代器惰性分配一次复用缓冲。

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

### 3.6 压缩：compact

compact 是 **O(1)** 的——只写 meta page，不重写数据。

```zig
try db.compact(); // 立即回收所有脏页（需要无活跃 reader）
```

- 有活跃 reader 时，脏页会留在 pending_free 中直到 reader 结束。
- compact 会自动 flush 所有可 flush 的 pending_free。

### 3.7 选项：Options

```zig
var db = try Db.open(allocator, store, .{
    .fsync = true,   // 每次写入后 fsync
});
```

| 字段 | 类型 | 默认 | 含义 |
|---|---|---|---|
| `fsync` | `bool` | `true` | 写操作是否 fsync 落盘。`false` = 更快但 crash 丢数据 |

compact 是 O(1) 的（meta 页切换，不重写数据）。

---

## 4. 错误处理

所有写/读操作返回 `!T`（错误联合）。常见错误：

| 错误 | 含义 |
|---|---|
| `OutOfMemory` | 分配失败 |
| `PageNotFound` | 页号无效（文件损坏） |
| `MapFull` | 页空间耗尽（mapsize 不足） |
| `FileLocked` | 文件已被另一个打开者锁定（T-34 多进程防护，见下节） |

```zig
db.put("k", "v") catch |err| switch (err) {
    error.PageNotFound => { /* 存储损坏 */ },
    else => return err,
};
```

---

## 5. 并发与 MVCC

- **多线程读**：安全。`get`/`select` 读原子 root 快照，无锁无 fsync。点读（`get`/`getInto`）与 `select` 一样在读取期间持有 MVCC reader pin（register-then-capture），在途读取引用的 COW 旧页不会被并发提交回收。
- **MVCC reader**：写入器在 reader 活跃时延迟回收脏页：

```zig
const reader = db.beginRead(); // 开始读，返回显式 Reader 句柄（携带快照）
const v = try db.get("k");     // 读一致性快照
db.endRead(reader);            // 结束读（带句柄注销），释放脏页
```

> `beginRead` 返回的是 **Reader 句柄**（不是序列号）；`endRead` 必须传入同一句柄以配对注销。

- **没有活跃 reader 时**：脏页在每次 commit 后自动回收。
- **不要跨线程共享一个迭代器**；每个线程各开各的 `select`。

### 多进程语义（T-34）

- **同一数据库文件同时只允许一个打开者**：`FilePageStore.init` 在 open 后立即取 advisory
  排他锁（`flock(fd, LOCK_EX | LOCK_NB)`）。第二个进程（或同进程的另一个 fd）对同一路径
  open 将得到 `error.FileLocked`。
- 锁随持有者的 fd 关闭释放：正常 `deinit()`/进程退出，或持有进程崩溃/被 kill —— 内核关闭
  fd，锁自动消失，无死锁残留。fork 出的子进程继承父进程 fd（共享同一 open file description），
  不会与父进程自冲突；若子进程自己重新 open 同一路径，则按第二个打开者被拒。
- **NFS 等网络文件系统上 flock 语义不保证**，仅支持本地文件系统。

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
const n = (try db.getInto(key, &buf)) orelse 0; // !?usize 零拷贝入 buf；null=key 不存在

// 写
try db.put(key, value);               // 单条
try db.putBatch(&entries);            // 批量（推荐）
try db.delete(key);                   // tombstone

// 范围 [min, max)
var it = try db.select(min, max);     // min/max 可 null
defer it.deinit();
while (try it.next()) |e| { /* e.key, e.value 借用，next() 后失效；it pin 快照，勿忘 deinit */ }

// 压缩
try db.compact();                     // O(1) meta 切换

// MVCC reader（显式句柄配对）
const reader = db.beginRead();
db.endRead(reader);

// 显式事务（LMDB 式）
var w = try db.beginWriteTxn();          // 单写者互斥
defer w.deinit();                       // 未 commit/abort 自动 abort
try w.put(key, value);                  // 暂存
try w.commit();                         // applyBatch + meta 切换 + fsync
// w.abort();                          // 丢弃

var r = try db.beginReadTxn();          // MVCC 快照，不阻写者
defer r.end();
const rv = try r.get(key);              // 借用快照
// try r.select(min, max);

try db.sync();                          // async 模式下显式冲刷
```

### 类型

| 类型 | 定义 |
|---|---|
| `Db` | 数据库句柄，所有操作的入口 |
| `Entry` | `struct { key: []const u8, value: []const u8, tombstone: bool = false }` |
| `Options` | `struct { fsync: bool = true }`（fsync=false 开 async 模式） |
| `WriteTxn` | `db.beginWriteTxn()`，单写者互斥，`commit`/`abort`/`deinit` |
| `ReadTxn` | `db.beginReadTxn()`，MVCC 快照，`get`/`select`/`end`/`deinit` |
| `Iterator` | `select` 返回，有 `.next() !?LeafEntry` 与 `.deinit()` |

### 所有权规则速记

- `get` 返回的 `[]u8`：**调用方 free**。
- `put`/`putBatch`/`delete` 的 key/value：**借用**，返回前有效。
- `select` 的 min/max：**借用**，迭代器存活期间有效。
- 迭代器 `entry.key`/`entry.value`：**借用迭代器内部**，下次 `next()` 前有效。
- `db`：`open` 分配，`close` 释放。

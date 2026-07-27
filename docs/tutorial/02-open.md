# 02 Open：读 meta 灌 state + attach 模式

> 数据流第一步：数据库怎么「醒」过来

---

本章对应 `src/db.zig` 的第 35-55 行：`Db.open`。

---

## 全景

`Db.open` 做的事情非常少——只有两件：

1. **创建 `State`**（初始化 COW B-tree 的元数据）
2. **读 meta 页**（如果存在，把上次关闭时的状态灌回来）

**它不创建 LSM 相关的任何东西**：不创建 memtable、不打开 WAL、不启动 compactor、不创建 rwlock。这些全是调用方在 `open` 之后自己 attach 的。

---

## 函数签名

```zig
// src/db.zig:35
pub fn open(allocator: std.mem.Allocator, store: PageStore, opts: wrt.Options) !*Db
```

参数：

| 参数 | 类型 | 什么意思 |
|------|------|----------|
| `allocator` | `std.mem.Allocator` | Zig 的内存分配器。谁创建谁销毁 |
| `store` | `PageStore` | 页存储接口。内存版（测试）或文件版（生产） |
| `opts` | `wrt.Options` | 配置：`{.fsync = true}`（默认刷盘） |

返回：堆分配的 `*Db`（调用方负责 `db.close()`）。

---

## 逐段拆解

### 1. 创建 State

```zig
const state = try allocator.create(State);
state.* = State.init(allocator, store, opts);
```

`State`（`src/writer.zig:42`）是 COW B-tree 的核心状态：

| 字段 | 初始值 | 含义 |
|------|--------|------|
| `root` | `NULL_ROOT` (0) | B-tree 根页号。0 = 空树 |
| `sequence` | 0 | 版本序号，每次 `applyBatch` 递增 |
| `entry_count` | 0 | 总 KV 条目数 |
| `byte_size` | 0 | 总数据字节数 |
| `dirt` | 0 | 脏页计数 |
| `reader_count` | 0 | 活跃读者数（MVCC） |
| `pending_free` | 空 | 等待回收的脏页列表（等读者归零） |
| `meta_index` | 0 | 下一个写哪个 meta 页（0 或 1） |

> **Zig 注意**：`allocator.create(T)` 在堆上分配一个 T 的空间，返回 `*T`。然后 `.* = ...` 解引用赋值。这是 Zig 常见的手动分配模式——没有 GC，创建和销毁都得显式。

### 2. 读 meta 页

```zig
if (try store.readMeta()) |meta| {
    state.root.store(meta.root_page, .release);
    state.sequence.store(meta.sequence, .release);
    state.entry_count.store(meta.entry_count, .release);
    state.byte_size.store(meta.byte_size, .release);
    state.dirt.store(0, .release);
}
```

`store.readMeta()` 做了什么：

- 读页号 1（meta0）和页号 2（meta1）的内容
- 比较两个 meta 页的 `sequence`，**取更大的那个**（更新那个是「正在写」的，旧的才是完整的）
- 返回 `?MetaPage`——如果是空数据库（两页都是 0/未初始化），返回 `null`

如果读到 meta 页，就把它的字段灌回 `State`。特别注意 **`dirt` 初始化为 0**——因为 meta 页记录的已经是上次刷盘后的干净状态。

### 3. 创建 Db 句柄

```zig
const db = try allocator.create(Db);
db.* = .{
    .allocator = allocator,
    .state = state,
    .store = store,
    .store_owned = false,
};
return db;
```

LSM 字段（`mt` / `wal` / `rwlock` / `compactor`）**不在 open 里赋值**——它们有默认值 `null`，调用方自己 attach。

---

## LSM 字段 attach 模式

这是理解 cube_db 设计的关键。

**为什么 `open` 不创建 LSM 字段？**

因为 LSM 是可选的。`Db` 是「通用句柄」，同一个 `Db` 可以走 COW 路径（没有 LSM 字段）或 LSM 路径（attach 后）。这是组合式设计：

```
Db.open(store)
  │
  ├→ COW 路径：直接 db.put / db.get
  │
  └→ LSM 路径：open 后手动 attach
       db.mt = &mt;
       db.wal = &wal;
       db.rwlock = &rwlock;
       db.compactor = &compactor;
       // 现在 put/get/delete 走 LSM 分支
```

**真实代码中的 attach 示例**（来自 `bench/bench_lsm.zig` 和测试）：

```zig
var ms = MemPageStore.init(allocator, 1 << 16);
var db = try Db.open(allocator, ms.store(), .{});

// LSM 字段全是调用方创建并 attach
var mt = Memtable.init(allocator, 1024 * 1024);
var wal = try Wal.init(allocator, ".wal_file");
db.mt = &mt;
db.wal = &wal;
// db.rwlock 可选，用于并发读安全
// db.compactor 可选，后台刷盘
```

**优点**：
1. 解耦——Db 不关心 LSM 组件的生命周期，由调用方管理
2. 可选——COW 路径不创建任何额外对象
3. 灵活——可以只 attach memtable 和 wal，不加 compactor

**缺点**：
1. 调用方要多写几行模板
2. 如果忘记 attach，`put` 会优雅地退化为 COW 路径（而不是报错）——可能隐藏 bug

---

## Mermaid：open 时序

```mermaid
sequenceDiagram
    participant Caller as 调用方
    participant Db as Db.open
    participant State as State.init
    participant PS as PageStore

    Caller->>Db: open(allocator, store, opts)
    Db->>State: init(allocator, store, opts)
    State-->>Db: state 指针
    Db->>PS: readMeta()
    alt 有 meta
        PS-->>Db: MetaPage
        Db->>State: 灌 root/sequence/entry_count/byte_size
    else 空库
        PS-->>Db: null
    end
    Db->>Db: create Db 句柄（所有 LSM 字段 = null）
    Db-->>Caller: *Db

    Note over Caller: 调用方手动 attach LSM 字段
    Caller->>Db: db.mt = &mt; db.wal = &wal;
```

---

## 关键核真事实

- `Db.open` **不读 WAL、不建 memtable**——这些是调用方 attach 的
- LSM 字段全是 `optional` 指针，默认 `null`——`if (self.mt)` 分流
- `State.root` 是 `std.atomic.Value(u32)`——原子操作，支持并发读写
- `readMeta()` 的 O(1) 恢复是 COW 路径的核心保证：最多读 2 个 4KB 页 = 8KB 就能恢复到一致状态

---

## 读完本章能回答

- `Db.open` 之后数据库处于什么状态？（B-tree 元数据就绪，LSM 未接）
- 谁负责创建 memtable 和 WAL？（调用方，open 之后 attach）
- 如果忘记 attach mt，调 `db.put` 会怎样？（走 COW 分支，不报错）

---

下一步：[03 Put——WAL + memtable + flush 信号](03-put.md)

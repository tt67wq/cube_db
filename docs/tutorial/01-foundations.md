# 01 基础概念黑盒

> 把共享基础设施当工具箱认一遍——知道每个工具干嘛、输入输出，不钻内部

---

本教程追 LSM 路径，但 LSM 路径**依赖几个共享基础设施**：`page_store.zig`、`format.zig`、`btree.zig`、`writer.zig`。

按照**按需钻**策略：本章只讲接口签名 + 概念 + 数据流角色，**不进内部实现**。后续章节只在 LSM 路径真正依赖时（`get` 兜底 `btree.get`、compaction 走 `state.applyBatch`）才下钻关键点。

---

## page（页面）

cube_db 里**所有数据都存在页里**。页是固定大小的块：

```zig
pub const PAGE_SIZE: usize = 4096;  // 4KB
pub const PAGE_HEADER_SIZE: usize = 24;  // 页头
```

每页结构：

```
[0..24)    页头 (PageHeader)
[24..4092) payload（数据）
[4092..4096) CRC32 校验
```

页头（`src/format.zig`）：

```zig
pub const PageHeader = struct {
    page_no: u32,       // 页号
    page_type: u8,      // 类型（free=0 / meta=1 / branch=2 / leaf=3 / overflow=4）
    gen: u64,           // 代号（版本管理）
    nkeys: u16,         // 键数
    free_next: u32,     // freelist 链下一页
};
```

**特殊页号**：

```zig
pub const NULL_PAGE: u32 = 0;     // 空指针
pub const META_PAGE_0: u32 = 1;   // meta 页 0
pub const META_PAGE_1: u32 = 2;   // meta 页 1（交替写）
pub const FIRST_DATA_PAGE: u32 = 3; // 第一个数据页
```

**概念精要**：所有持久化数据——B-tree 节点、meta 信息、溢出值——都在 page 里。page 是 KV 引擎的「字节单位」。

---

## PageStore（页存储接口）

`PageStore` 是**运行时多态接口**（vtable 模式）。它定义了对页的所有操作，不关心底层是内存还是文件。

```zig
// src/page_store.zig
pub const PageStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        allocPage: *const fn (ptr: *anyopaque) anyerror!u32,
        freePage:  *const fn (ptr: *anyopaque, page_no: u32) void,
        readPage:  *const fn (ptr: *anyopaque, page_no: u32) anyerror![]const u8,
        writePage: *const fn (ptr: *anyopaque, page_no: u32) anyerror![]u8,
        readMeta:  *const fn (ptr: *anyopaque) anyerror!?f2.MetaPage,
        writeMeta: *const fn (ptr: *anyopaque, meta: *const f2.MetaPage) anyerror!void,
        sync:      *const fn (ptr: *anyopaque) anyerror!void,
        mapsize:   *const fn (ptr: *anyopaque) u64,
    };
};
```

**接口说明**：

| 方法 | 干嘛 | 输出 |
|------|------|------|
| `allocPage()` | 读加一个页（取 freelist 或 bump） | 页号 u32 |
| `freePage(page_no)` | 回收页（LIFO freelist） | void |
| `readPage(page_no)` | 读页（零拷贝，借用切片） | 字节切片 |
| `writePage(page_no)` | 写页（返回可写切片） | 可变字节切片 |
| `readMeta()` | 读 meta 页（双页交替恢复） | `?MetaPage` |
| `writeMeta(meta)` | 写 meta 页（交替写 0/1） | void |
| `sync()` | fsync 刷盘 | void |
| `mapsize()` | 页数上限 | u64 |

**两个实现**：

```zig
// 内存实现（测试用）
MemPageStore.init(allocator, max_pages);
// 文件实现（生产用，mmap）
FilePageStore.init(allocator, path, max_pages);
```

**LSM 里怎么用它**：Db 持有 `store: PageStore`，compaction 通过它写入 B-tree（`readPage`/`writePage`/`allocPage`/`freePage`），open 通过它读 meta 页（`readMeta`），get 兜底通过它读 B-tree 页（`readPage`）。

---

## MetaPage（元数据页）

meta 页存储数据库的**全局状态**。有两个 meta 页（页号 1 和 2），交替写入——这样即使写一半崩溃，另一个 meta 页还是完整的（O(1) 恢复的保障）。

```zig
// src/format.zig
pub const MetaPage = struct {
    magic: u32,         // 魔数 "CUB2" = 0x4355_4232
    version: u16,       // 版本
    mapsize: u64,       // 页数上限
    sequence: u64,      // 序列号
    root_page: u32,     // B-tree 根页号
    entry_count: u64,   // 总条目数
    byte_size: u64,     // 数据字节数
};
```

**LSM 里怎么用它**：`Db.open` 用 `store.readMeta()` 读 meta 页，把 `root_page` / `sequence` / `entry_count` / `byte_size` 灌进 `State`。LSM 的 WAL replay 恢复 memtable 后，meta 页自然包含已 compaction 的数据。

---

## B-tree（黑盒视角）

B-tree 是页面上的**有序键值树**。所有数据最终存在 B-tree 的叶节点里。

对本教程而言，B-tree 对外暴露两个核心操作（其他几个是内部细节）：

### btree.get：读取

```zig
// src/btree.zig
pub fn get(allocator: Allocator, store: PageStore, root: u32, key: []const u8) !?[]u8
```

- **输入**：root 页号、key
- **输出**：找到 → 分配新内存的 value；找不到 → null
- **这是 `Db.get` 的兜底**：memtable 没命中 → 到 B-tree 找
- 内部：从 root 页开始逐层页内二分查找，直到叶节点

### btree.select：范围遍历

```zig
pub fn select(allocator: Allocator, store: PageStore, root: u32, min: ?[]const u8, max: ?[]const u8) !Iterator
```

- 返回一个 Iterator，按 key 顺序遍历 [min, max) 范围

### writer.applyBatch：批量写入

```zig
// src/writer.zig (State 的方法)
pub fn applyBatch(self: *State, batch: []const Request) !void

pub const Request = struct {
    key: []const u8,
    value: []const u8,
    tombstone: bool,
    future: *zio.Future(OpResult),
};
```

- **这是 LSM compaction 的落盘路径**：Compactor 把 memtable snapshot 转为 Request[]，调 `state.applyBatch(reqs)` 一口气写入 B-tree
- 内部（按需钻，第 06 章展开）：COW 页复制、meta 交替写、freelist 复用、MVCC dirty 页持有到 reader drain

---

## 核心概念速查

| 概念 | 是什么 | LSM 里谁用它 |
|------|--------|-------------|
| page | 4KB 定长块，存一切 | 所有模块 |
| PageStore | 页的读写分配接口 | Db、State、B-tree |
| MetaPage | 全局状态（根页/条目数等） | Db.open、State.compact |
| B-tree.get | 按 key 读 | Db.get 兜底 |
| applyBatch | 批量写 B-tree | Compactor.flush |

---

## 记住一句话

**B-tree 是「持久化存储」**：所有 compaction 完的数据都进 B-tree。

**PageStore 是「B-tree 和磁盘之间的管道」**：B-tree 不关心文件还是内存，只管调 `readPage`/`writePage`。

**Meta 页是「数据库的遥控器」**：切换 meta 页指针 = O(1) 提交或回滚。

---

下一步：[02 Open——读 meta 灌 state + attach 模式](02-open.md)

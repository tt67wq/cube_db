# cube_db 架构设计文档

> 本文档描述 cube_db 的核心架构设计：COW B-tree、MVCC 快照隔离、freelist 页复用、崩溃恢复机制。
> 
> 对应代码版本：commit `57e18cd` (2026-07-30)

---

## 目录

1. [整体架构](#1-整体架构)
2. [页格式](#2-页格式)
3. [COW B-tree](#3-cow-b-tree)
4. [MVCC 与快照隔离](#4-mvcc-与快照隔离)
5. [Freelist 与页复用](#5-freelist-与页复用)
6. [崩溃恢复](#6-崩溃恢复)
7. [写路径优化](#7-写路径优化)
8. [模块关系](#8-模块关系)

---

## 1. 整体架构

cube_db 是一个纯 COW（Copy-on-Write）B-tree 嵌入式键值存储引擎，LMDB 风格架构：

```
┌─────────────────────────────────────────┐
│              公开 API (db.zig)            │
│  Db.get / put / putBatch / select / ...  │
├─────────────────────────────────────────┤
│           显式事务 (db.zig)               │
│  WriteTxn (单写者)  /  ReadTxn (MVCC)    │
├─────────────────────────────────────────┤
│           状态管理 (writer.zig)           │
│  applyBatch + meta 交替 + MVCC reader    │
├─────────────────────────────────────────┤
│           COW B-tree (btree.zig)          │
│  insert / get / select (页号寻址)         │
├─────────────────────────────────────────┤
│           页存储抽象 (page_store.zig)      │
│  PageStore vtable: alloc/read/write/free │
├─────────────────────────────────────────┤
│     MemPageStore    │   FilePageStore    │
│    (内存 HashMap)   │  (mmap, 待上线)    │
└─────────────────────────────────────────┘
```

**核心设计决策：**
- **无 WAL**：COW + 原子 meta 页切换保证崩溃安全
- **单写者**：WriteTxn 互斥，简化并发控制
- **MVCC 读**：ReadTxn 持有快照，不阻塞写者
- **页号寻址**：所有节点引用用 `u32` 页号，支持内存/文件多后端

---

## 2. 页格式

固定页大小 **4096 字节**，每页结构：

```
┌─────────────────┬─────────────────────────────┬──────────┐
│   页头 (24B)    │        Payload 区            │ CRC (4B) │
│                 │   (最大 4068B = 4096-24-4)   │          │
└─────────────────┴─────────────────────────────┴──────────┘
```

### 页头 (24 bytes)

| 字段 | 偏移 | 大小 | 说明 |
|------|------|------|------|
| `page_no` | 0 | 4B | 页号（little-endian） |
| `page_type` | 4 | 1B | 0=free, 1=meta, 2=branch, 3=leaf, 4=overflow |
| `gen` | 5 | 8B | 代数（meta 页用 sequence） |
| `nkeys` | 13 | 2B | 键/子节点数量 |
| `free_next` | 15 | 4B | freelist 链下一页号 |
| padding | 19 | 5B | 保留 |

### Meta 页 (58 bytes payload)

```
┌──────────┬─────────┬──────────┬───────────┬───────────┬─────────────┬─────────────┬───────────┬─────────────┬──────────┐
│ magic(4) │ ver(2)  │ mapsz(8) │ seq(8)    │ root(4)   │ entries(8)  │ bytes(8)    │ free(4)   │ freecnt(8)  │ last(4)  │
│ 0x43554232│   2     │          │           │           │             │             │           │             │          │
└──────────┴─────────┴──────────┴───────────┴───────────┴─────────────┴─────────────┴───────────┴─────────────┴──────────┘
```

**双 meta 页交替**：meta 写入 page 1 和 page 2 交替进行，崩溃后取 sequence 较大者恢复。

---

## 3. COW B-tree

### 3.1 节点结构

**Leaf 节点**（页类型 = 3）：
```
┌────────┬─────────┬──────────────────────────────────────┐
│ kind(1)│ count(2)│ entry[]                              │
│   0x02  │   N     │ tombstone(1) + klen(4) + key +      │
│         │         │ vlen(4) + flags(1) + value/ov_page  │
└────────┴─────────┴──────────────────────────────────────┘
```

- `LEAF_MAX_ENTRIES = 32`
- `MAX_INLINE_VALUE = 3800`（超过走溢出页链）
- `flags & 1` = 溢出页标志，此时 value 区存 4 字节溢出页首页号

**Branch 节点**（页类型 = 2）：
```
┌────────┬─────────┬──────────────────────┬─────────────────┐
│ kind(1)│ count(2)│ keys[]               │ children[]      │
│   0x01  │   N     │ klen(4) + key × (N-1)│ u32 × N         │
└────────┴─────────┴──────────────────────┴─────────────────┘
```

- `BRANCH_MAX_CHILDREN = 64`

### 3.2 COW 写路径

每次 `put` 沿 B-tree 路径（depth 3-5）逐页复制修改：

```
         ┌─────────┐
         │  Root   │ ──COW──→ ┌─────────┐
         │ Branch  │          │ Branch' │
         └────┬────┘          └────┬────┘
              │                    │
         ┌────┴────┐          ┌────┴────┐
         │ Branch  │ ──COW──→ │ Branch' │
         └────┬────┘          └────┬────┘
              │                    │
         ┌────┴────┐          ┌────┴────┐
         │  Leaf   │ ──COW──→ │  Leaf'  │ ← 修改 entry
         └─────────┘          └─────────┘
```

**旧页不修改**，新页写入后旧页标记为 dirty，待 reader 释放后回收。

### 3.3 写路径优化（三阶段）

| Phase | 优化 | 效果 |
|-------|------|------|
| Phase 1 | Arena allocator | 消除 ~145 次 mmap/munmap，505us → 122us |
| Phase 2 | Branch in-place COW | Branch 无分裂时直接 copy 页 + patch 4 字节 |
| Phase 3 | Leaf in-place COW | Leaf 无分裂时 stack buffer 直接拼 payload |

**最终效果**：put 100B 505us → 108us（4.7× 提速）

---

## 4. MVCC 与快照隔离

### 4.1 读者计数

```zig
reader_count: Atomic(u32)  // 活跃 ReadTxn 数量
```

- `beginReadTxn()` → `reader_count++`
- `endReadTxn()` → `reader_count--`，若归零则 `flushPendingFree()`

### 4.2 脏页延迟回收

```
写者提交 ──→ 旧页进 pending_free ──→ 等待 reader_count == 0 ──→ 回收进 freelist
                    ↑                                    │
                    └──── reader 活跃时持有旧页快照 ──────┘
```

**关键保证**：reader 持有的快照 root 对应的整棵 B-tree 页不会被回收，直到该 reader 结束。

### 4.3 写事务流程

```
beginWriteTxn() ──→ [单写者互斥锁定] ──→ put/delete 暂存 ──→ commit()
                                                          │
                                                          ▼
                                              ┌───────────────────────┐
                                              │ 1. 快照当前 root      │
                                              │ 2. Arena alloc        │
                                              │ 3. btree.insert COW   │
                                              │ 4. 脏页 → pending_free│
                                              │ 5. 写 meta 页         │
                                              │ 6. fsync (if sync)    │
                                              │ 7. 原子更新 root      │
                                              │ 8. reader==0 ? 回收   │
                                              └───────────────────────┘
```

---

## 5. Freelist 与页复用

### 5.1 页分配策略

```
allocPage():
  1. freelist 非空？pop() 复用
  2. 否则 bump next_free++
```

### 5.2 页回收时机

- **安全回收**：`reader_count == 0` 时，`flushPendingFree()` 全部释放
- **延迟回收**：reader 活跃时，脏页积累在 `pending_free` 中

### 5.3 页复用优势

- **~1× 写放大**：旧页直接复用，不额外分配
- **O(1) compact**：只需切换 meta 页标记脏页可回收，不移动数据

---

## 6. 崩溃恢复

### 6.1 恢复流程

```
启动 ──→ 读 meta page 1 & 2 ──→ 取 sequence 较大者 ──→ 恢复 root、entry_count、byte_size
            │
            ▼
      校验 magic + version + CRC
      失败则尝试另一页
      两页都失败 → 空数据库
```

### 6.2 崩溃安全保证

| 场景 | 行为 |
|------|------|
| 写 meta 前崩溃 | 旧 meta 完整有效，数据未变 |
| 写 meta 后 fsync 前崩溃 | 取旧 meta（sequence 较小），新数据不可见 |
| fsync 后崩溃 | 新 meta 有效，数据完整 |

**关键**：未提交的 COW 路径页不被任何 meta 引用，自然成为垃圾，不影响数据一致性。

---

## 7. 写路径优化

### 7.1 优化前瓶颈

单次 put 深度 4 的 B-tree 路径：
- Branch 层：32 个 key → 32 次 `allocator.dupe` + decode/encode
- Leaf 层：16 个 entry → 32 次 `allocator.dupe`（key + value）
- 总计：~145 次 heap alloc + free
- benchmark 用 `page_allocator`（每次 alloc = mmap syscall）
- 145 次 mmap/munmap ≈ 435us，完美解释 put 505us

### 7.2 Phase 1：Arena Allocator

```zig
var arena = std.heap.ArenaAllocator.init(self.allocator);
defer arena.deinit();
const arena_alloc = arena.allocator();
// btree.insert 全部临时分配走 arena bump-pointer
```

- 消除 ~145 次 mmap/munmap → 1 次 arena 分配
- put 100B：505us → 122us（4.1×）

### 7.3 Phase 2：Branch In-place COW

Branch 无分裂时（常见 case）：
- 不 decode Branch.fromPayload（不分配 key 数组）
- 直接 `copy 整页` + `patch 4 字节 child 指针` + `重新 checksum`
- 零堆分配

### 7.4 Phase 3：Leaf In-place COW

Leaf 无分裂时（常见 case）：
- 不 decode Leaf.fromPayload（不分配 entry 数组）
- 扫描 raw payload 定位 entry 位置
- 在 stack buffer 中拼新 payload：`copy before + new entry + copy after`
- 零堆分配
- 10KB put 额外收益：避免大 value 的 decode/re-encode

---

## 8. 模块关系

```
                    ┌─────────────┐
                    │   db.zig    │
                    │  公开 API   │
                    │ Db/WriteTxn/│
                    │   ReadTxn   │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
        ┌─────────┐  ┌─────────┐  ┌─────────┐
        │writer.zig│  │btree.zig│  │format.zig│
        │状态管理  │  │COW B-tree│  │页格式   │
        │MVCC     │  │get/insert│  │编解码   │
        └────┬────┘  └────┬────┘  └────┬────┘
             │            │            │
             └────────────┼────────────┘
                          ▼
                    ┌─────────────┐
                    │page_store.zig│
                    │  PageStore   │
                    │   vtable     │
                    └──────┬──────┘
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
        ┌─────────────┐           ┌─────────────┐
        │MemPageStore │           │FilePageStore│
        │ 内存 HashMap │           │ mmap (TODO) │
        └─────────────┘           └─────────────┘
```

### 模块职责

| 模块 | 职责 |
|------|------|
| `db.zig` | 公开 API、WriteTxn/ReadTxn 封装、便捷函数 |
| `writer.zig` | applyBatch、MVCC reader 管理、meta 交替、脏页回收 |
| `btree.zig` | COW B-tree 核心：get/insert/select、页编码解码 |
| `format.zig` | 页头/meta/freelist 编解码、CRC32 校验 |
| `page_store.zig` | PageStore vtable 抽象、MemPageStore 实现 |
| `file_page_store.zig` | FilePageStore（mmap，待完成）|

---

## 附录：关键常量

| 常量 | 值 | 说明 |
|------|-----|------|
| `PAGE_SIZE` | 4096 | 固定页大小 |
| `PAGE_HEADER_SIZE` | 24 | 页头字节数 |
| `LEAF_MAX_ENTRIES` | 32 | 叶子节点最大 entry 数 |
| `BRANCH_MAX_CHILDREN` | 64 | 分支节点最大子节点数 |
| `MAX_INLINE_VALUE` | 3800 | 最大内联 value 大小 |
| `META_PAGE_0` | 1 | meta 页 0 页号 |
| `META_PAGE_1` | 2 | meta 页 1 页号 |
| `FIRST_DATA_PAGE` | 3 | 首个数据页号 |
| `MAGIC_V2` | 0x4355_4232 | "CUB2" |

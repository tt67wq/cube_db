# cube_db 代码学习教程

> 目标：从零开始，逐层读懂这个 Zig 嵌入式 KV 引擎的代码。

## cube_db 是什么？

`cube_db` 是一个用 **Zig 0.16.0** 写的嵌入式键值存储引擎，基于 **freelist 页面复用** 架构：

- **嵌入式**：不是独立服务器，而是一个库，直接创建数据库对象。
- **KV 数据库**：提供 `get` / `put` / `delete` / `select` 基础操作。
- **固定页（4KB）**：数据按页组织，页可以复用。
- **B-tree 索引**：所有 key 组织成 B-tree，查询速度快。
- **Copy-on-Write**：每次写产生新版本的 B-tree，旧版本不破坏。
- **freelist**：旧版本页进入 freelist，复用空间。

## 架构特点

| 特性 | 说明 |
|---|---|
| 文件格式 | 固定 4KB 页 + 页头（page type, gen, nkeys, free_next） |
| B-tree | 页号寻址（u32）COW B-tree |
| compact | O(1)：只写 meta page，不重写数据 |
| 恢复 | O(1)：读 2 个 meta page |
| 写放大 | ~1×（页复用） |
| 大 value | 溢出页链，支持任意大小 |

## 源文件

| 文件 | 说明 |
|------|------|
| `src/format.zig` | 页格式常量与编解码（页头、meta、freelist、CRC） |
| `src/page_store.zig` | 页 Store 抽象（vtable）+ MemPageStore 内存实现 |
| `src/file_page_store.zig` | 文件页 Store（mmap 读写） |
| `src/btree.zig` | 页号寻址 COW B-tree（u32 子指针） |
| `src/writer.zig` | applyBatch + MVCC pending_free + meta 交替 |
| `src/db.zig` | Db 句柄与公开 API |
| `src/main.zig` | 可执行入口 |
| `src/root.zig` | 库入口 |

## 测试文件

| 文件 | 测试内容 | 数量 |
|------|----------|------|
| `tests/format_test.zig` | 页头/meta/freelist 编解码 | 21 |
| `tests/page_store_test.zig` | 页分配/回收/mmap 恢复 | 11 |
| `tests/btree_test.zig` | B-tree 全套（插入/查找/范围） | 13 |
| `tests/writer_test.zig` | applyBatch/meta 交替 | 8 |
| `tests/mvcc_test.zig` | MVCC reader 安全回收 | 6 |
| `tests/db_test.zig` | Db 公开 API 集成 | 11 |
| `tests/compact_test.zig` | O(1) compact | 6 |
| `tests/overflow_test.zig` | 大 value 溢出页链 | 6 |

> **共 82 单测**，全部通过。

## 你需要准备什么？

- Zig 0.16.0（`zig version` 确认）。
- 本项目依赖本地 `../zio` 仓库（`build.zig.zon` 的 path 依赖）。
- 一个终端，能跑以下命令：

```bash
zig build test                # 跑全部测试
zig build bench -Doptimize=ReleaseFast  # 基准测试
```

## 项目目录

```
cube_db/
├── build.zig              # 构建脚本
├── build.zig.zon          # 包元信息
├── docs/
│   ├── usage.md           # 使用手册
│   └── tutorial/          # 本教程
├── src/
│   ├── root.zig           # 库入口
│   ├── main.zig           # 可执行入口
│   ├── format.zig         # 页格式编解码
│   ├── page_store.zig     # 页 Store 抽象 + MemPageStore
│   ├── file_page_store.zig # 文件页 Store（mmap）
│   ├── btree.zig          # COW B-tree
│   ├── writer.zig         # applyBatch + meta 交替
│   └── db.zig             # Db 句柄与公开 API
├── tests/                 # 82 单元测试
└── bench/
    └── bench.zig          # 基准矩阵
```

## 教程章节

教程共 5 章，按概念递进，层叠深入。每章先讲设计原理，再贴核心源码逐段讲解，结尾附可运行示例。

| 章节 | 内容 | 源码 |
|------|------|------|
| [01 — 页格式](01-page-format.md) | 固定 4KB 页、页头、meta/freelist 页、CRC | `format.zig`、`page_store.zig` |
| [02 — B-tree](02-btree.md) | 页号寻址 COW B-tree、leaf/branch、点查/范围/插入 | `btree.zig` |
| [03 — COW 写入](03-cow-write.md) | applyBatch、COW 新页、双 meta 交替、O(1) compact | `writer.zig` |
| [04 — MVCC 读者安全](04-mvcc.md) | 读者代次、脏页延迟回收、并发读写 | `writer.zig`、`db.zig` |
| [05 — 溢出页](05-overflow.md) | 大 value 溢出页链、写/读/回收 | `btree.zig` |

## 读完本教程你能学到什么？

- 一个真实嵌入式 KV 引擎的完整数据流。
- 固定页 + freelist 架构的设计思路。
- O(1) compact 的实现原理。
- MVCC reader 安全回收机制。
- 怎么用 Zig 写模块化、可测试的系统代码。

好，开始。从 [第 01 章：页格式](01-page-format.md) 出发，运行 `zig build test` 确保一切正常。

# cube_db 代码学习教程

> 目标：从零开始，逐层读懂这个 Zig 嵌入式 KV 引擎的代码。

## 这个教程适合谁？

- 你听说过 KV 数据库、B-tree、append-only 文件，但还没亲手看过实现。
- 你想学 Zig，但希望结合一个完整的真实项目来学。
- 你读完代码后总觉得“知道每个函数，但不知道它们为什么这样组合”。

如果你是经验丰富的存储引擎开发者，这篇教程的废话可能偏多；但对小白来说，每个概念都会尽量讲清楚。

## cube_db 是什么？

`cube_db` 是一个用 **Zig 0.16.0** 写的嵌入式键值存储，参考 Elixir 的 [CubDB](https://github.com/lucaong/cubdb) 架构：

- **嵌入式**：不是一个独立服务器，而是一个库，你的程序里直接创建数据库对象。
- **KV 数据库**：只提供 `get` / `put` / `delete` / `select` 这类基础操作。
- **append-only**：数据文件一旦写入，后面的内容永远不修改，只追加。
- **B-tree 索引**：所有 key 组织成 B-tree，查询速度快。
- **Copy-on-Write**：每次写都产生新版本的 B-tree，旧版本不破坏。
- **compaction**：旧版本积累多了，会被回收空间。

## 本教程的结构

| 章节 | 内容 | 核心文件 |
|------|------|----------|
| 01 | 项目结构与构建 | `build.zig`, `build.zig.zon`, `src/root.zig` |
| 02 | 文件格式与编解码 | `src/format.zig` |
| 03 | Store 抽象与实现（含 mmap） | `src/store.zig`, `src/file_store.zig`, `src/mmap.zig`, `src/fault_store.zig` |
| 04 | 不可变 B-tree（含零拷贝读） | `src/btree.zig` |
| 05 | Writer 与状态管理（含 BTreeBatch） | `src/writer.zig`, `src/btree_batch.zig`, `src/db.zig`（部分） |
| 06 | DB 公开 API（含 group commit） | `src/db.zig` |
| 07 | Compaction | `src/db.zig` 的 `doCompact` |
| 08 | 崩溃安全（header 正向扫描） | `src/fault_store.zig`, `src/store.zig` |
| 09 | 测试体系 | `tests/`, `src/*.zig` 里的测试块 |
| 10 | 动手实验 | 基于本项目的练习 |

## 建议怎么读？

1. 先通读 `01` 和 `02`，建立项目骨架和文件格式概念。
2. 再读 `03` 和 `04`，理解存储层和索引层。这两章是核心。
3. 接着 `05`/`06`/`07`，把写路径、读路径、压缩串起来。
4. 最后看 `08`/`09` 的测试与故障恢复，体会为什么代码要这么写。
5. 每章末尾都有练习，建议至少做前 5 个。

## 你需要准备什么？

- Zig 0.16.0（`zig version` 确认）。
- 本项目依赖本地 `../zio` 仓库（`build.zig.zon` 的 path 依赖）。
- 一个终端，能跑以下命令：

```bash
zig build test                          # 跑全部测试
zig build -Doptimize=ReleaseSafe         # 检查 ReleaseSafe 无警告
```

## V2 (freelist 架构) — 新引擎

v2 从 v1 的 append-only 改为固定页 + freelist 复用。核心差异：

| 维度 | v1 (append-only) | v2 (freelist) |
|---|---|---|
| 文件格式 | 变长记录 + marker | 固定 4KB 页 + 页头 |
| B-tree | 字节偏移寻址（u64） | 页号寻址（u32） |
| 写放大 | ~33× | ~1×（页复用） |
| compact | 全量重写（2.9 MB/s） | O(1) meta 切换 |
| 恢复 | 扫全文件 | 读 2 meta 页 |
| 大 value | 内联（受页大小限制） | 溢出页链 |

v2 源文件（`src/`）：

| 文件 | 对应 v1 | 说明 |
|------|---------|------|
| `format2.zig` | `format.zig` | v2 页格式：页头、meta page、freelist 页、CRC |
| `page_store.zig` | `store.zig` | 页 Store 抽象（vtable）+ MemPageStore 实现 |
| `btree2.zig` | `btree.zig` | 页号寻址 COW B-tree（u32 子指针） |
| `writer2.zig` | `writer.zig` | applyBatch + MVCC pending_free + meta 交替 |
| `db2.zig` | `db.zig` | Db2 句柄与公开 API |
| `file_page_store.zig` | `file_store.zig` | 文件的页 Store（mmap 读写） |

v2 测试文件（`tests/`）：

| 文件 | 测试内容 |
|------|----------|
| `format2_test.zig` | 页头/meta/freelist 编解码（21 测试） |
| `page_store_test.zig` | 页分配/回收/mmap 恢复（11 测试） |
| `btree2_test.zig` | B-tree 全套（13 测试） |
| `writer2_test.zig` | applyBatch/meta 交替（8 测试） |
| `mvcc_test.zig` | MVCC reader 安全回收（6 测试） |
| `db2_test.zig` | Db2 公开 API 集成（11 测试） |
| `compact2_test.zig` | O(1) compact（6 测试） |
| `overflow_test.zig` | 大 value 溢出页链（6 测试） |

> 共 82 单测，全部通过。建议读完 v1 核心章节后对照 v2 代码，
> 理解从 append-only 到 freelist 的架构演进。

---

## 项目目录速览（v2 补充）

```
cube_db/
├── build.zig              # 构建脚本：告诉 Zig 怎么编译
├── build.zig.zon          # 包元信息：名字、版本、依赖
├── docs/
│   ├── usage.md           # 使用手册（API 用法）
│   ├── *-design.md        # 各优化阶段设计文档（mmap 读、零拷贝读等）
│   └── tutorial/          # 本教程
├── src/
│   ├── root.zig           # 库入口
│   ├── main.zig           # 可执行入口（占位）
│   ├── format.zig         # 文件格式、编解码、CRC
│   ├── store.zig          # Store 抽象 + 内存 Store + header 正向扫描
│   ├── file_store.zig     # 真实文件 Store（含 mmap 零拷贝读）
│   ├── mmap.zig           # libc mmap wrapper（跨平台）
│   ├── fault_store.zig    # 故障注入 Store
│   ├── btree.zig          # 不可变 B-tree（读路径零拷贝）
│   ├── btree_batch.zig    # BTreeBatch 批量树提交
│   ├── writer.zig         # 写请求、状态、batch 应用
│   └── db.zig             # DB 句柄与公开 API（group commit）
└── tests/
    └── 各类集成/崩溃/性能测试
```

## 读完本教程你能学到什么？

- 一个真实嵌入式 KV 引擎的完整数据流。
- append-only 文件、COW B-tree、compaction 的设计思路。
- **读路径真零拷贝**：mmap + `readBorrow` 借用切片 + `findInLeaf`/`findInBranchPayload` 跳过解码，追平 LMDB。
- **写路径 group commit**：leader/follower 把并发写合并成 1 次 fsync。
- 怎么用 Zig 写模块化、可测试的系统代码。
- 为什么测试要分层，怎么做模型测试、故障注入测试。

好，开始读第一章。

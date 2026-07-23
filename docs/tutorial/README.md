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
| 03 | Store 抽象与实现 | `src/store.zig`, `src/file_store.zig`, `src/fault_store.zig` |
| 04 | 不可变 B-tree | `src/btree.zig` |
| 05 | Writer 与状态管理 | `src/writer.zig`, `src/db.zig`（部分） |
| 06 | DB 公开 API | `src/db.zig` |
| 07 | Compaction | `src/db.zig` 的 `doCompact` |
| 08 | 崩溃安全 | `src/fault_store.zig`, `src/store.zig` |
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

## 项目目录速览

```
cube_db/
├── build.zig              # 构建脚本：告诉 Zig 怎么编译
├── build.zig.zon          # 包元信息：名字、版本、依赖
├── docs/
│   ├── DESIGN.md          # 原始设计文档（决策很详细）
│   ├── PROGRESS.md        # 实现进度与偏离设计的地方
│   └── tutorial/          # 本教程
├── src/
│   ├── root.zig           # 库入口
│   ├── main.zig           # 可执行入口（占位）
│   ├── format.zig         # 文件格式、编解码、CRC
│   ├── store.zig          # Store 抽象 + 内存 Store
│   ├── file_store.zig     # 真实文件 Store
│   ├── fault_store.zig    # 故障注入 Store
│   ├── btree.zig          # 不可变 B-tree
│   ├── writer.zig         # 写请求、状态、batch 应用
│   └── db.zig             # DB 句柄与公开 API
└── tests/
    ├── db_test.zig        # 集成测试
    └── compact_test.zig   # compaction 测试
```

## 读完本教程你能学到什么？

- 一个真实嵌入式 KV 引擎的完整数据流。
- append-only 文件、COW B-tree、compaction 的设计思路。
- 怎么用 Zig 写模块化、可测试的系统代码。
- 为什么测试要分层，怎么做模型测试、故障注入测试。

好，开始读第一章。

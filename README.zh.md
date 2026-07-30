# cube_db

嵌入式键值存储，用 Zig 0.16.0 编写，LMDB 式架构：纯 COW B-tree + freelist 页面复用，无 WAL，
通过原子 meta 页切换实现崩溃安全。

- 嵌入式 KV 引擎：`get` / `put` / `delete` / `select`
- **页号寻址 COW B-tree** + freelist 页面复用（页不原地修改）
- **LMDB 式 1TB 预留 mmap 读路径** — reader 零拷贝直接指针读，文件增长无需重 mmap
- **显式事务** — `beginWriteTxn` / `beginReadTxn`（`commit` / `abort` / `end`），
  单写者互斥，MVCC 快照 reader 不阻塞写者
- **O(1) compact** — 只写 meta page，不重写数据
- **O(1) 恢复** — 读两个 meta page，不扫全文件，无 WAL 回放
- **无 WAL 崩溃安全** — COW + 原子 meta 页切换：未提交写入永不污染已提交数据
- **MVCC reader 安全** — 脏页持有到读者释放
- **溢出页** — 大 value 自动走溢出页链
- **异步/同步持久化** — `Options{fsync}`（默认 commit 即 fsync）+ async 模式下显式 `Db.sync()`
- 纯同步 API，无需准备 runtime

**使用手册：[`docs/usage.md`](docs/usage.md)。** · **Benchmark 数据：[`bench/results/`](bench/results/)。**

> 英文版见 [README.md](README.md)。

## 依赖

- Zig 0.16.0
- 本地 `../zio` 仓库（`build.zig.zon` 的 path 依赖）

## 构建与测试

```bash
zig build test          # 全部单元 + 集成测试
zig build test-fuzz     # 确定性 fuzz 回归
zig build long-run      # 2 分钟长时 fuzz（按需）
zig build bench -Doptimize=ReleaseFast  # 基准测试矩阵
```

## 快速开始

```zig
const cube = @import("cube_db");
const Db = cube.Db;
const MemPageStore = cube.page_store.MemPageStore;

var ms = MemPageStore.init(allocator, 1 << 20);
defer ms.deinit();
var db = try Db.open(allocator, ms.store(), .{});
defer db.close();

// 便捷 API（内部包隐式 WriteTxn，立即提交）
try db.put("hello", "world");
const v = try db.get("hello");
defer allocator.free(v.?);
```

### 显式事务（LMDB 式）

```zig
// 写事务：单写者互斥，commit = applyBatch + meta 切换 + fsync；abort 丢弃
var w = try db.beginWriteTxn();
defer w.deinit(); // 未 commit/abort 时 deinit 自动 abort
try w.put("k", "v");
try w.delete("old");
try w.commit(); // 原子提交

// 读事务：MVCC 快照，不阻写者
var r = try db.beginReadTxn();
defer r.end();
const v = try r.get("k");
defer if (v) |val| allocator.free(val);
```

文件模式（`FilePageStore` — LMDB 式 1TB 预留 mmap 区）及完整 API、recipes 见
**[docs/usage.md](docs/usage.md)**。

## Benchmark

小规模，10k ops，MemPageStore（内存），无 fsync。
`zig build bench -Doptimize=ReleaseFast -Dbench-scale=small`：

```
op      scale  value  ops          time_ms      ops/s        avg_us/op
put     small  100B         10000       5053.0         1979       505.30
put     small  10KB         10000      20047.5          499      2004.75
putbatch small  100B         10000        725.5        13783        72.55
putbatch small  10KB         10000        403.2        24801        40.32
get     small  100B         10000        355.3        28148        35.53
get     small  10KB         10000        464.0        21550        46.40
delete  small  100B         10000       3963.9         2523       396.39
select  small  100B           100         98.1         1019       981.02
select  small  10KB           100        309.9          323      3098.99
compact small  100B             1          0.0            -        11.00
```

> 读 = mmap 零拷贝（get 100B ~35µs，近常数，不随 value 线性涨）。
> 写受 COW 逐页分配+拷贝主导（put 100B ~505µs）；
> `putBatch` 摊薄 COW 路径 ~7×（100B）。
> 完整矩阵 + large scale 说明：[`bench/results/20260730_bench.md`](bench/results/20260730_bench.md)。
> 对标 LMDB/LevelDB（SQLite/RocksDB 对比）：[`benchcmp/COMPARISON.md`](benchcmp/COMPARISON.md)。

## 测试

121 测试，15 个模块 + 4 个 fuzz target，全部通过：

| 模块 | 数量 | 文件 |
|------|------|------|
| Format | 21 | `tests/format_test.zig` |
| Page store | 11 | `tests/page_store_test.zig` |
| B-tree | 13 | `tests/btree_test.zig` |
| Writer | 8 | `tests/writer_test.zig` |
| MVCC | 6 | `tests/mvcc_test.zig` |
| Db API | 11 | `tests/db_test.zig` |
| Compact | 6 | `tests/compact_test.zig` |
| Overflow | 6 | `tests/overflow_test.zig` |
| 事务 | 7 | `tests/txn_test.zig` |
| mmap 区 | 4 | `tests/mmap_region_test.zig` |
| 崩溃恢复 | 5 | `tests/crash_recovery_test.zig` |
| 崩溃 harness (fork+kill) | 2 | `tests/crash_harness_test.zig` |
| 压力 (1k keys) | 2 | `tests/stress_test.zig` |
| 教程 smoke | 5 | `tests/tutorial_smoke_test.zig` |
| Fuzz (probe/api/format/meta-corrupt) | 9 | `tests/fuzz/*` |

```bash
zig build test test-fuzz        # 全部单元/集成 + fuzz 回归
zig build test-format test-ps test-btree test-writer test-mvcc test-db test-compact test-overflow  # 分模块
```

## 项目结构

```
cube_db/
├── build.zig              # 构建脚本
├── build.zig.zon          # 包元信息
├── docs/
│   ├── usage.md           # 使用手册
│   ├── fuzz-testing.md    # fuzz 测试指南
│   └── tutorial/          # 教程（5 章）
├── src/
│   ├── root.zig           # 库入口（导出 Db, WriteTxn, ReadTxn, ...）
│   ├── main.zig           # 可执行入口
│   ├── format.zig         # 页格式编解码
│   ├── page_store.zig     # 页 Store 抽象 + MemPageStore
│   ├── file_page_store.zig # 文件页 Store（LMDB 式 1TB 预留 mmap）
│   ├── btree.zig          # 页号寻址 COW B-tree
│   ├── writer.zig         # applyBatch + MVCC + meta 交替
│   └── db.zig             # Db 句柄、WriteTxn、ReadTxn（公开 API）
├── tests/                 # 单元 + 集成测试
│   └── fuzz/              # fuzz target（probe/api/format/meta-corrupt + long-run）
├── bench/
│   ├── bench.zig          # 基准矩阵（put/putbatch/get/delete/select/compact）
│   └── results/           # 基准数据快照
└── benchcmp/
    └── COMPARISON.md      # 对比 SQLite/RocksDB
```

> 注：曾存在 LSM 层（memtable + WAL + compactor），已删除。现引擎为纯 COW B-tree（LMDB 式）：
> 无 WAL 崩溃安全，reader 为 mmap 零拷贝，写经显式 `WriteTxn`（单写者）。

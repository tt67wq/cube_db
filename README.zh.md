# cube_db

嵌入式键值存储，用 Zig 0.16.0 编写，基于 freelist 页面复用架构：

- 嵌入式 KV 引擎：`get` / `put` / `delete` / `select`
- **页号寻址 COW B-tree** + freelist 页面复用
- **O(1) compact** — 只写 meta page，不重写数据
- **O(1) 恢复** — 读两个 meta page，不扫全文件
- **MVCC reader 安全** — 脏页持有到读者释放
- **溢出页** — 大 value 自动走溢出页链
- 纯同步 API，无需准备 runtime

**使用手册：[`docs/usage.md`](docs/usage.md)。**

> 英文版见 [README.md](README.md)。

## 依赖

- Zig 0.16.0
- 本地 `../zio` 仓库（`build.zig.zon` 的 path 依赖）

## 构建与测试

```bash
zig build test          # 全部测试
zig build bench -Doptimize=ReleaseFast  # 基准测试
```

## Benchmark (v2 small, MemPageStore)

```bash
zig build bench -Dbench-scale=small -Doptimize=ReleaseFast
```

```
op      scale  value  ops          time_ms      ops/s        avg_us/op
put     small  100B         10000       4498.5         2223       449.85
put     small  10KB         10000      17769.7          563      1776.97
putbatch small  100B         10000        496.9        20125        49.69
putbatch small  10KB         10000        392.5        25476        39.25
get     small  100B         10000        349.1        28645        34.91
get     small  10KB         10000        445.8        22431        44.58
delete  small  100B         10000       3629.9         2755       362.99
select  small  100B           100         99.6         1004       995.78
select  small  10KB           100        269.6          371      2695.88
```

> 运行于 MemPageStore（内存），无 fsync。实际磁盘性能取决于 FilePageStore 实现。
> v2 COW 页分配驱动 put/delete 成本。putBatch 摊薄 COW ~9× vs 单条 put。
> get 读取 mmap 页，100B 与 10KB 均在 50µs 以内。

## 快速开始

```zig
const cube = @import("cube_db");
const Db = cube.Db;
const MemPageStore = cube.page_store.MemPageStore;

var ms = MemPageStore.init(allocator, 1 << 20);
defer ms.deinit();
var db = try Db.open(allocator, ms.store(), .{});
defer db.close();

try db.put("hello", "world");
const v = try db.get("hello");
defer allocator.free(v.?);
```

文件模式（FilePageStore）及完整 API 见 **[docs/usage.md](docs/usage.md)**。

## 测试

82 测试，8 个测试文件，全部通过：

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

```bash
zig build test-format test-ps test-btree test-writer test-mvcc test-db test-compact test-overflow
```

## 项目结构

```
cube_db/
├── build.zig              # 构建脚本
├── build.zig.zon          # 包元信息
├── docs/
│   ├── usage.md           # 使用手册
│   └── tutorial/          # 教程
├── src/
│   ├── root.zig           # 库入口
│   ├── main.zig           # 可执行入口
│   ├── format.zig         # 页格式编解码
│   ├── page_store.zig     # 页 Store 抽象 + MemPageStore
│   ├── file_page_store.zig # 文件页 Store（mmap）
│   ├── btree.zig          # 页号寻址 COW B-tree
│   ├── writer.zig         # applyBatch + MVCC + meta 交替
│   └── db.zig             # Db 句柄与公开 API
├── tests/                 # 82 单元测试
└── bench/
    └── bench.zig          # 基准矩阵
```

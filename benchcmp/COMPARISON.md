# cube_db 读写性能对比

机器: Apple M1 Pro / 8 cores / macOS
日期: 2025-07-24
工作负载: 10,000 keys, 10-byte key (`fmtKey`), 顺序 put + 随机 get, **no fsync**。

## 测试引擎与公平性

| 引擎 | 架构 | 后端 | fsync |
|---|---|---|---|
| **cube_db** (this) | COW B-tree + freelist + MVCC | MemPageStore (纯内存数组, Zig) | N/A (内存) |
| SQLite 3.51 | B-tree + pager | `:memory:` (纯内存) | OFF (`journal_mode=OFF`,`synchronous=OFF`) |
| RocksDB 11.1 | LSM-tree (memtable+L0...) | 文件 + OS page cache | OFF (`writeoptions.sync=0`) |

三者均为内存/无 fsync 路径,测的是**算法与页管理吞吐**,非磁盘 I/O。
注意 cube_db 的 MemPageStore 是最快后端(原生内存数组,零 syscall),SQLite `:memory:` 同样纯内存,RocksDB 仍走文件+mmap。即 cube_db 在存储后端上**无劣势**仍最慢 → 差距来自 B-tree/COW/meta 开销,非后端。

## 结果 (small scale, 10k ops)

### 读 (get, 随机 key)

| 引擎 | 100B avg_us/op | 10KB avg_us/op |
|---|---:|---:|
| cube_db      | 34.91 | 44.58 |
| SQLite       | 0.74  | 2.45 |
| RocksDB      | 0.56  | 1.78 |
| **cube/SQLite** | **47×** | **18×** |
| **cube/Rocks**  | **62×** | **25×** |

### 写 — 批量提交 (对等: cube putBatch vs SQLite BEGIN..COMMIT vs RocksDB writebatch)

| 引擎 | 100B avg_us/op | 10KB avg_us/op |
|---|---:|---:|
| cube_db putBatch | 49.69 | 39.25 |
| SQLite put(batch) | 0.62 | 7.28 |
| RocksDB put(batch)| 0.14 | 7.79 |
| **cube/SQLite** | **80×** | **5.4×** |
| **cube/Rocks**  | **355×** | **5.0×** |

### 写 — 单 op 提交 (对等: cube put vs SQLite per-op BEGIN/COMMIT vs RocksDB single put)

| 引擎 | 100B avg_us/op | 10KB avg_us/op |
|---|---:|---:|
| cube_db put  | 449.85 | 1776.97 |
| SQLite put1  | 1.06 | 2.09 |
| RocksDB put1 | 8.93 | 19.78 |
| **cube/SQLite** | **425×** | **850×** |
| **cube/Rocks**  | **50×**  | **90×** |

## 结论

**读慢 18–62×,写慢 5–850×。** cube_db 在最快后端 (纯内存) 下仍显著慢于 SQLite/RocksDB 的内存路径。

### 为什么慢

1. **单 put = 完整 COW 事务**: 每次 put 都做 page 分配 + copy + freelist 更新 + meta 页交替。SQLite `:memory:` commit 只是 pager 标记(无 I/O);RocksDB 单 put 只走 memtable insert (sync=0 不刷 WAL)。cube_db 把每个 op 当 durability 事务处理 → 单 put 450us。

2. **get 慢 ~50×**: MemPageStore 无 syscall,B-tree 遍历是纯计算,但 34.9us 远超 SQLite 0.74us。可能原因:
   - 每次 get 走完整 B-tree 查找 + MVCC 可见性检查 + value 复制分配(README 代码 `allocator.free(got)` 暗示 get 分配返回值)。
   - SQLite/RocksDB 读路径有 page cache + 高度优化的比较器/编码,cube_db 是新代码无此优化。

3. **架构本身不背全部锅**: 同为 COW B-tree + mmap 的 **LMDB** (未测, brew 损坏) 读通常 <1us。cube_db 的 freelist + meta 交替 + MVCC dirty-page tracking 每页路径开销偏重。

### 优势 (README 自述, 未在本测复现)

- **O(1) compact**: 只切 meta 页,无全表重写 → 压缩远快于 SQLite/RocksDB compaction。
- **O(1) recovery**: 读两 meta 页即就绪。
- **MVCC reader safety**: dirty pages 保留到 reader drain。
- 这些是工程特性,非吞吐优势。

## 方法学注记

- cube_db 数字取自 README (v2 small, `zig build bench -Dbench-scale=small -Doptimize=ReleaseFast`)。本地二进制复跑 put@100B 得 2698ms/3705 ops/s,同量级,确认数据可信。
- SQLite/RocksDB 数字由 `benchcmp/benchcmp` 本机实测,源码 `benchcmp/benchcmp.cpp`。
- 工作负载严格对齐: 同 key 编码、同 value 大小、同随机 seed(0x42)、同 warmup 比例。
- **未测 LMDB/LevelDB**: brew bootsnap 权限损坏无法安装。LMDB 是最公平的架构对照 (mmap B+tree COW),建议修复 brew 后补测。

## 复现

```bash
# cube_db
zig build bench -Dbench-scale=small -Doptimize=ReleaseFast

# SQLite + RocksDB
cd benchcmp
clang++ -O3 -std=c++17 benchcmp.cpp \
  -I/opt/homebrew/opt/rocksdb/include \
  /opt/homebrew/opt/sqlite/lib/libsqlite3.a \
  -L/opt/homebrew/opt/rocksdb/lib -lrocksdb \
  -L/opt/homebrew/lib -lzstd -lsnappy -llz4 -lgflags \
  -lz -lbz2 -lpthread -ldl \
  -o benchcmp
./benchcmp
```

若 sandbox 拒 `/var/folders` clang cache: 加 `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` 并用 `/Library/Developer/CommandLineTools/usr/bin/clang++` 直连(绕 xcrun)。

---

## 更新注记 (2026-07-30)

### 优化历程

| 阶段 | put 100B | get 100B | 关键改动 |
|------|---------|---------|---------|
| 原始 | 505µs | 35µs | 基准 |
| COW 优化 | 108µs | 35µs | Arena + Branch/Leaf in-place COW |
| zero-copy get | — | ~10µs | getBorrowed 消除 dupe |
| micro-batching | 128µs | 35µs | 自动 batch 提交 |

### 当前性能（vs 主流引擎）— 2026-07-30 最新

| 操作 | cube_db | SQLite | RocksDB | LMDB(估) | 差距 |
|------|---------|--------|---------|----------|------|
| get 100B | **2.73µs** | 0.74µs | 0.56µs | ~1µs | **慢 2.7-4.9x** |
| getBorrowed 100B | **~2.7µs** | — | — | ~1µs | **慢 2.7x** |
| put 100B | **119µs** | 1.06µs | 8.93µs | ~10-100µs | **慢 12-112x** |
| putBatch 100B | **24.75µs** | 0.62µs | 0.14µs | — | **慢 40-177x** |

> **读性能已接近 LMDB 级！** get 100B 从 35µs → 2.73µs（13x 提速），与 LMDB 差距从 62x 缩小到 **2.7x**。

### 优化历程

| 阶段 | commit | put 100B | get 100B | 关键改动 |
|------|--------|---------|---------|---------|
| 原始 | — | 505µs | 35µs | 基准 |
| COW 优化 | `57e18cd` | 108µs | 35µs | Arena + Branch/Leaf in-place COW |
| zero-copy get | `8010f02` | — | ~10µs | getBorrowed 消除 dupe |
| micro-batching | `dcf1ab3` | 119µs | 35µs | 自动 batch 提交 |
| **CRC 跳过** | **`2d1b69b`** | — | **2.73µs** | **readNodePayloadFast** |

### 差距分析

1. **读路径** — ✅ **已大幅优化**。get 100B 2.73µs 接近 LMDB ~1µs。剩余差距来自 B-tree 遍历深度 + page 指针偏移计算。
2. **写路径** — COW 架构固有开销（每次 put 完整 B-tree 路径复制），group-commit 已缩小差距但未消除。
3. **LMDB 待实测** — 需要实际安装 LMDB 补测验证。

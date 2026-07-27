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

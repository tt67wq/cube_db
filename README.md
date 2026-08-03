# cube_db

An embedded key-value store written in Zig 0.16.0, LMDB-style architecture: pure COW B-tree
with freelist page reuse, no WAL, crash-safe via atomic meta-page switch.

- Embedded KV engine: `get` / `put` / `delete` / `select`
- **Page-based COW B-tree** with page reuse via freelist (in-place pages never mutated)
- **LMDB-style 1TB reserved mmap** read path — readers are zero-copy page pointers, no remmap on growth
- **Explicit transactions** — `beginWriteTxn` / `beginReadTxn` (`commit` / `abort` / `end`),
  single-writer mutex, MVCC snapshot readers that don't block the writer
- **O(1) compact** — just meta page switch, no full rewrite
- **O(1) recovery** — reads two meta pages, no full-file scan, no WAL replay
- **Crash-safe without WAL** — COW + atomic meta-page switch: uncommitted writes never corrupt committed data
- **MVCC reader safety** — dirty pages held until readers drain
- **Overflow pages** — values up to any size via overflow page chains
- **Async/sync durability** — `Options{fsync}` (default sync-on-commit) + explicit `Db.sync()` for async mode
- Pure synchronous API — no runtime setup needed

**Usage manual: [`docs/usage.md`](docs/usage.md).** · **Benchmark data: [`bench/results/`](bench/results/).**

## Dependencies

- Zig 0.16.0
- Local `../zio` repo (`build.zig.zon` path dependency)

## Build & Test

```bash
zig build test          # all unit + integration tests
zig build test-fuzz     # deterministic fuzz regression
zig build long-run      # 2-minute long-run fuzz (on demand)
zig build bench -Doptimize=ReleaseFast  # benchmark matrix
```

## Quick start

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

### Explicit transactions (LMDB-style)

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

For file-backed usage (`FilePageStore` — LMDB-style 1TB reserved mmap region),
full API, and recipes see **[docs/usage.md](docs/usage.md)**.

## Benchmark

最新 benchmark 数据见 [`bench/results/`](bench/results/)：

| 文档 | 内容 |
|------|------|
| [`20260803_arena_opt.md`](bench/results/20260803_arena_opt.md) | WriteTxn staging arena 化 — putBatch 10K **0.6µs（27× 提升）** |
| [`20260730_shared_cow.md`](bench/results/20260730_shared_cow.md) | Shared COW path — putBatch 100B **619× 提速，超越 LMDB** |
| [`20260730_read_crc_skip.md`](bench/results/20260730_read_crc_skip.md) | 读路径 CRC 跳过 — get 100B 13× 提速 |
| [`20260730_micro_batch.md`](bench/results/20260730_micro_batch.md) | micro-batching / group-commit — put 100B 4.0× 提速 |
| [`20260730_zero_copy.md`](bench/results/20260730_zero_copy.md) | zero-copy get + bug fix 数据 |
| [`20260730_cow_opt.md`](bench/results/20260730_cow_opt.md) | COW 写路径优化 — put 100B 4.7× 提速 |
| [`20260730_bench.md`](bench/results/20260730_bench.md) | 优化前基准数据（small scale 全矩阵） |
| [`20260727_wal_opt.md`](bench/results/20260727_wal_opt.md) | 历史 WAL 优化（LSM 层，已移除） |

> 与 SQLite/RocksDB 对比：[`benchcmp/COMPARISON.md`](benchcmp/COMPARISON.md)

## Tests

~200 tests across 25+ modules (auto-discovered), all passing:

| Module | Tests | File |
|--------|-------|------|
| Format | 21 | `tests/format_test.zig` |
| Page store | 11 | `tests/page_store_test.zig` |
| B-tree | 13 | `tests/btree_test.zig` |
| Writer | 8 | `tests/writer_test.zig` |
| MVCC | 6 | `tests/mvcc_test.zig` |
| Db API | 11 | `tests/db_test.zig` |
| Compact | 6 | `tests/compact_test.zig` |
| Overflow | 6 | `tests/overflow_test.zig` |
| Transactions | 7 | `tests/txn_test.zig` |
| mmap region | 4 | `tests/mmap_region_test.zig` |
| Crash recovery | 5 | `tests/crash_recovery_test.zig` |
| Crash harness (fork+kill) | 2 | `tests/crash_harness_test.zig` |
| Stress (1k keys) | 2 | `tests/stress_test.zig` |
| Tutorial smoke | 5 | `tests/tutorial_smoke_test.zig` |
| Fuzz (probe/api/format/meta-corrupt) | 9 | `tests/fuzz/*` |
| Zero-copy | 7 | `tests/zero_copy_test.zig` |
| COW fast path | 5 | `tests/cow_fast_test.zig` |
| Crash recovery framework | 4 | `tests/crash_recovery_framework.zig` |
| Group commit | 10 | `tests/group_commit_test.zig` |
| Group commit ext | 11 | `tests/group_commit_ext_test.zig` |
| Shared COW | 8 | `tests/shared_cow_test.zig` |
| putBatch correctness | 4 | `tests/putbatch_correctness_test.zig` |
| insertBatch overflow | 5 | `tests/insertbatch_overflow_test.zig` |
| insertBatch capaware | 7 | `tests/insertbatch_capaware_test.zig` |
| crash putBatch | 5 | `tests/crash_putbatch_test.zig` |
| **Txn arena** | **7** | `tests/txn_arena_test.zig` |
| **Txn abort arena** | **4** | `tests/txn_abort_arena_test.zig` |
| 3-state | 3 | `tests/pb_3state_test.zig` |

```bash
zig build test test-fuzz        # all unit/integration + fuzz regression
zig build test-format test-ps test-btree test-writer test-mvcc test-db test-compact test-overflow  # per-module
```

## Project structure

```
cube_db/
├── build.zig              # Build script
├── build.zig.zon          # Package metadata
├── docs/
│   ├── usage.md           # Usage manual
│   ├── fuzz-testing.md    # Fuzz testing guide
│   └── tutorial/          # Tutorial (5 chapters)
├── src/
│   ├── root.zig           # Library entry (exports Db, WriteTxn, ReadTxn, ...)
│   ├── main.zig           # Executable entry
│   ├── format.zig         # Page format encoding/decoding
│   ├── page_store.zig     # Page store interface + MemPageStore
│   ├── file_page_store.zig # File-backed page store (LMDB-style 1TB reserved mmap)
│   ├── btree.zig          # Page-addressable COW B-tree
│   ├── writer.zig         # Batch apply + MVCC + meta alternation
│   └── db.zig             # Db handle, WriteTxn, ReadTxn (public API)
├── tests/                 # unit + integration tests
│   └── fuzz/              # fuzz targets (probe/api/format/meta-corrupt + long-run)
├── bench/
│   ├── bench.zig          # Benchmark matrix (put/putbatch/get/delete/select/compact)
│   └── results/           # benchmark data snapshots
└── benchcmp/
    └── COMPARISON.md      # vs SQLite/RocksDB comparison
```

> Note: an LSM layer (memtable + WAL + compactor) previously existed and was removed.
> The engine is now pure COW B-tree (LMDB-style): crash-safe without a WAL, readers are
> mmap zero-copy, writes go through explicit `WriteTxn` (single-writer).

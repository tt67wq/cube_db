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

Small scale, 10k ops, MemPageStore (memory), no fsync.
`zig build bench -Doptimize=ReleaseFast -Dbench-scale=small`:

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

> Read = mmap zero-copy (get 100B ~35µs, near-constant vs value size).
> Write dominated by COW per-op page alloc+copy (put 100B ~505µs);
> `putBatch` amortizes the COW path ~7× (100B).
> Full matrix + large-scale notes: [`bench/results/20260730_bench.md`](bench/results/20260730_bench.md).
> vs LMDB/LevelDB (SQLite/RocksDB comparison): [`benchcmp/COMPARISON.md`](benchcmp/COMPARISON.md).

## Tests

121 tests across 15 modules + 4 fuzz targets, all passing:

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

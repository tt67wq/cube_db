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

// Convenience API (implicit WriteTxn under the hood, commits immediately)
try db.put("hello", "world");
const v = try db.get("hello");
defer allocator.free(v.?);
```

### Explicit transactions (LMDB-style)

```zig
// Write txn: single-writer mutex; commit = applyBatch + meta switch + fsync; abort discards
var w = try db.beginWriteTxn();
defer w.deinit(); // deinit auto-aborts if not committed/aborted
try w.put("k", "v");
try w.delete("old");
try w.commit(); // atomic commit

// Read txn: MVCC snapshot, does not block writers
var r = try db.beginReadTxn();
defer r.end();
const v = try r.get("k");
defer if (v) |val| allocator.free(val);
```

For file-backed usage (`FilePageStore` — LMDB-style 1TB reserved mmap region),
full API, and recipes see **[docs/usage.md](docs/usage.md)**.

## Benchmark

Latest benchmark data: [`bench/results/`](bench/results/)

| Doc | Highlight |
|------|------|
| [`20260803_ordered_fastpath.md`](bench/results/20260803_ordered_fastpath.md) | 🏆 Write-path finale — ordered fast path, 1M **0.47µs (1.27× LMDB)** |
| [`20260803_arena_opt.md`](bench/results/20260803_arena_opt.md) | WriteTxn staging arena — putBatch 10K **0.6µs (27× improvement)** |
| [`20260730_shared_cow.md`](bench/results/20260730_shared_cow.md) | Shared COW path — putBatch 100B **619× faster, beats LMDB** |
| [`20260730_read_crc_skip.md`](bench/results/20260730_read_crc_skip.md) | Read-path CRC skip — get 100B 13× faster |
| [`20260730_micro_batch.md`](bench/results/20260730_micro_batch.md) | micro-batching / group-commit — put 100B 4.0× faster |
| [`20260730_zero_copy.md`](bench/results/20260730_zero_copy.md) | zero-copy get + bug fix data |
| [`20260730_cow_opt.md`](bench/results/20260730_cow_opt.md) | COW write-path optimization — put 100B 4.7× faster |
| [`20260730_bench.md`](bench/results/20260730_bench.md) | Pre-optimization baseline (small-scale full matrix) |
| [`20260727_wal_opt.md`](bench/results/20260727_wal_opt.md) | Legacy WAL optimization (LSM layer, removed) |

> vs SQLite/RocksDB: [`benchcmp/COMPARISON.md`](benchcmp/COMPARISON.md)

## Tests

~230 tests across 30+ modules (auto-discovered, grouped into 4 domain files), all passing:

| Module | Tests | File |
|--------|-------|------|
| Format | 21 | `tests/core_format/format_test.zig` |
| Page store | 11 | `tests/core_format/page_store_test.zig` |
| B-tree | 13 | `tests/btree_storage/btree_test.zig` |
| Writer | 8 | `tests/txn_writer_db/writer_test.zig` |
| MVCC | 6 | `tests/txn_writer_db/mvcc_test.zig` |
| Db API | 11 | `tests/txn_writer_db/db_test.zig` |
| Compact | 6 | `tests/txn_writer_db/compact_test.zig` |
| Overflow | 6 | `tests/txn_writer_db/overflow_test.zig` |
| Transactions | 7 | `tests/txn_writer_db/txn_test.zig` |
| mmap region | 4 | `tests/core_format/mmap_region_test.zig` |
| Crash recovery | 5 | `tests/crash_insertbatch_pb/crash_recovery_test.zig` |
| Crash harness (fork+kill) | 2 | `tests/crash_insertbatch_pb/crash_harness_test.zig` |
| Stress (1k keys) | 2 | `tests/crash_insertbatch_pb/stress_test.zig` |
| Tutorial smoke | 5 | `tests/txn_writer_db/tutorial_smoke_test.zig` |
| Fuzz (probe/api/format/meta-corrupt) | 9 | `tests/fuzz/*` |
| Zero-copy | 7 | `tests/core_format/zero_copy_test.zig` |
| COW fast path | 5 | `tests/core_format/cow_fast_test.zig` |
| Crash recovery framework | 4 | `tests/crash_insertbatch_pb/crash_recovery_framework.zig` |
| Group commit | 10 | `tests/txn_writer_db/group_commit_test.zig` |
| Group commit ext | 11 | `tests/txn_writer_db/group_commit_ext_test.zig` |
| Shared COW | 8 | `tests/btree_storage/shared_cow_test.zig` |
| putBatch correctness | 4 | `tests/crash_insertbatch_pb/putbatch_correctness_test.zig` |
| insertBatch overflow | 5 | `tests/crash_insertbatch_pb/insertbatch_overflow_test.zig` |
| insertBatch capaware | 7 | `tests/crash_insertbatch_pb/insertbatch_capaware_test.zig` |
| crash putBatch | 5 | `tests/crash_insertbatch_pb/crash_putbatch_test.zig` |
| **Txn arena** | **7** | `tests/txn_writer_db/txn_arena_test.zig` |
| **Txn abort arena** | **4** | `tests/txn_writer_db/txn_abort_arena_test.zig` |
| range delete | 13 | `tests/crash_insertbatch_pb/range_delete_test.zig` |

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
│   ├── btree_storage_test.zig      # aggregator: btree/readtxn/shared-cow
│   ├── core_format_test.zig        # aggregator: format/page-store/crc/zero-copy
│   ├── crash_insertbatch_pb_test.zig # aggregator: crash/insertBatch/putBatch
│   ├── txn_writer_db_test.zig      # aggregator: txn/writer/db/compact/mvcc
│   ├── btree_storage/              # btree + readtxn-fuzz + shared-cow
│   ├── core_format/                # format/page-store/crc/zero-copy/cow
│   ├── crash_insertbatch_pb/       # crash/insertBatch/putBatch/range-delete
│   ├── txn_writer_db/              # txn/writer/db/compact/mvcc/overflow
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

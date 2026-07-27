# cube_db

An embedded key-value store written in Zig 0.16.0, based on freelist page reuse architecture:

- Embedded KV engine: `get` / `put` / `delete` / `select`
- **Page-based COW B-tree** with page reuse via freelist
- **O(1) compact** — just meta page switch, no full rewrite
- **O(1) recovery** — reads two meta pages, no full-file scan
- **MVCC reader safety** — dirty pages held until readers drain
- **Overflow pages** — values up to any size via overflow page chains
- Pure synchronous API — no runtime setup needed

**Usage manual: [`docs/usage.md`](docs/usage.md).**

## Dependencies

- Zig 0.16.0
- Local `../zio` repo (`build.zig.zon` path dependency)

## Build & Test

```bash
zig build test          # all tests
zig build bench -Doptimize=ReleaseFast  # benchmark
```

## Benchmark

### Legacy (COW B-tree, v2 `bench/bench.zig`, MemPageStore, no fsync)

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

> Legacy COW path: each `put` allocates + copies pages (COW). `putBatch` amortizes COW ~9×.

### LSM mode (`bench/bench_lsm.zig`, MemPageStore, no fsync)

LSM mode uses memtable + WAL + optional background compaction. Single put goes to
memtable + WAL (no per-op COW).

#### Before WAL optimization (4 separate `pwrite` syscalls per op)

```
op            stage              us/op     %
put (total)                     29.1    100%
├─ WAL append (4×pwrite)        24.8     85%
├─ Memtable put (dupe+HashMap)   4.1     14%
└─ fmtKey + shouldFlush          0.1     ~0%

get (total)                      2.5    100%
├─ dupe value return             1.7     68%
├─ db.get() wrapper overhead     0.6     24%
└─ HashMap lookup + fmtKey       0.1      4%
```

#### After WAL optimization (single `pwrite` — contiguous buffer assembly)

```
op            stage              us/op     %
put (total)                      9.7    100%
├─ WAL append (single pwrite)    6.4     66%
├─ Memtable put (dupe+HashMap)   3.2     33%
└─ fmtKey + shouldFlush          0.1     ~1%

get (total)                      2.5    100%
├─ dupe value return             1.7     68%
├─ db.get() wrapper overhead     0.6     24%
└─ HashMap lookup + fmtKey       0.1      4%
```

| Metric | COW (baseline) | LSM (before opt) | LSM (after opt) | Δ vs baseline |
|--------|:-:|:-:|:-:|:-:|
| Single put 100B | 449.85 us | 29.1 us | **9.7 us** | **46× faster** |
| Random get 100B | 34.91 us | 2.5 us | **2.5 us** | **14× faster** |

> `zig build bench-lsm -Doptimize=ReleaseFast` — profiling bench with per-stage decomposition.
> WAL optimization: 4 separate `pwrite` syscalls (hdr/key/value/crc) merged into 1,
> using stack buffer for small entries (zero alloc) and heap for large.
> Tested on Apple M1 Pro, 1000 ops, warmup 100.
## Quick start

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

For file-backed usage (`FilePageStore`), full API, and recipes see **[docs/usage.md](docs/usage.md)**.

## Tests

82 tests across 8 test files, all passing:

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

```bash
zig build test-format test-ps test-btree test-writer test-mvcc test-db test-compact test-overflow
```

## Project structure

```
cube_db/
├── build.zig              # Build script
├── build.zig.zon          # Package metadata
├── docs/
│   ├── usage.md           # Usage manual
│   └── tutorial/          # Tutorial
├── src/
│   ├── root.zig           # Library entry
│   ├── main.zig           # Executable entry
│   ├── format.zig         # Page format encoding/decoding
│   ├── page_store.zig     # Page store interface + MemPageStore
│   ├── file_page_store.zig # File-backed page store (mmap)
│   ├── btree.zig          # Page-addressable COW B-tree
│   ├── writer.zig         # Batch apply + MVCC + meta alternation
│   └── db.zig             # Db handle and public API
├── tests/                 # 82 unit tests
└── bench/
    └── bench.zig          # Benchmark matrix
```

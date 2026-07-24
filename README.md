# cube_db

An embedded key-value store written in Zig 0.16.0, modeled after the [CubDB](https://github.com/lucaong/cubdb) architecture:

- Embedded KV engine: `get` / `put` / `delete` / `select`
- **v2 (freelist)**: page-based COW B-tree with page reuse — O(1) compact, ~1× write amplification
- **v1 (append-only)**: original format — append-only data file, auto-compaction in background thread
- Immutable B-tree (Copy-on-Write)

Full implementation notes in [`docs/tutorial/`](docs/tutorial/). **Usage manual: [`docs/usage.md`](docs/usage.md).**

> 中文版见 [README.zh.md](README.zh.md).

## Dependencies

- Zig 0.16.0
- Local `../zio` repo (`build.zig.zon` path dependency)

## Build & Test

```bash
zig build test
```

## Benchmark

20-cell matrix (5 ops × 2 scales × 2 value sizes). **Must use ReleaseFast** — Debug numbers are meaningless.

```bash
zig build bench -Doptimize=ReleaseFast                     # full matrix
zig build bench -Dbench-scale=small -Doptimize=ReleaseFast  # smoke / quick run
```

`-Dbench-scale` takes `all`|`small`|`large` (default `all`).

### Findings (NVMe, ReleaseFast)

> **Note:** v2 benchmark requires FilePageStore (disk-backed) implementation.
> Current v2 performance numbers are from MemPageStore (in-memory) — not comparable.
> The structural advantages (O(1) compact, ~1× write amplification via freelist) are
> verified by unit tests but full benchmark comparison is pending FilePageStore.

Key numbers and interpretation from the v1 benchmark matrix:

| Dimension | small | large | Conclusion |
|---|---|---|---|
| put 100B | 498 us/op | 706 us/op | fsync dominates (~400us/op fixed cost), B-tree depth secondary |
| **putBatch 100B** | **0.15 us/op** | — | **~1000× faster than put** — BTreeBatch amortizes COW path rewrite + 1 fsync for N ops |
| **putBatch 10KB** | **2.5 us/op** | — | ~1400× faster; fsync + COW both amortized across the batch |
| put 10KB | 3.9 ms/op | 3.8 ms/op | barely scales with size → I/O bandwidth dominates (~10KB/fsync) |
| get 100B | 251 → 133 → **~3 us/op** | 494 → ~360 us/op | mmap zero-copy: remove marker + readRecord borrows mmap slice (no alloc/memcpy) + findInLeaf/findInBranchPayload skip full decode → ~85× small, **LMDB-level (~2us)** |
| get 10KB | 786 → 174 → **~5–13 us/op** | 1.3 ms → ~480 us/op | same zero-copy path, branch+leaf direct seek → ~60–136× small, LMDB-level (波动随 mmap 缺页) |
| delete 100B | 416 us/op | — | same path as put (tombstone + fsync), cost ≈ put |

Key points:

1. **fsync-per-op was the absolute hotspot** (put ~400–700us/op ≈ fsync latency). **Solved**: `putBatch([]Entry)` + `BTreeBatch` (node cache + dirty set + one flush) amortize both fsync and COW path rewrite → **~1000× single-thread throughput** (0.15us/op vs 498us/op).
2. **put 10KB vs 100B delta ≈ write-to-disk time**: 3.8ms − 0.7ms ≈ 3.1ms/10KB ≈ ~3.2 MB/s flush bandwidth — serial fsync was the drag; `putBatch` collapses it.
3. **get is far faster than put** (251→**~3us**, no fsync) — **LMDB-level** (~2us). Zero-copy read path: remove marker (mmap bytes contiguous) + `Store.readBorrow` (borrowed mmap slice, no alloc/memcpy) + `readRecord` returns borrowed slice + `findInLeaf`/`findInBranchPayload` skip full leaf/branch decode + read-no-CRC on hot path. ~85× improvement; matches LMDB mmap reads.
4. **compact**: small 100B ~4s / 10KB ~35s, full rewrite (seq read + write + sync), ~100MB in 35s ≈ ~2.9 MB/s — single-threaded rewrite is the bottleneck; multi-threaded rewrite / streaming sync is the fix (still open).
5. **COW dirt amplification**: large×100B preload (1M puts) yields ~4.7GB physical file (live ~120MB, ~33×); **auto-compact** now reclaims upon threshold (`auto_compact_dirt_ratio` + `auto_compact_min_bytes`). Background thread does lock-free phase-1 scan + phase-2 tree diff merge under write mutex. See `docs/auto-compact-design.md`.

> **Implemented (single-thread)**: `putBatch` + `BTreeBatch` → ~1000× put throughput by amortizing fsync + COW. Uses `arena` allocator for batch-node lifetime; node cache + bottom-up flush (children-first offset assignment).
>
> **Implemented (concurrent group commit, lever 3)**: implicit batching of *concurrent* `put`/`delete` via leader/follower in `sendRequest`. A thread that finds no active leader drains the request queue into one `applyBatch` (1 fsync); followers enqueue and block on their `zio.Future` (kernel futex, works on raw threads). Leader keeps serving while the queue is non-empty, then steps down. `writer.applyBatch` already set all futures, so no extra plumbing. Verified by `tests/group_commit_test.zig`: 16 threads × 50 puts (800 ops) merge to ~117 `applyBatch` calls (~6.8× fewer fsyncs) with all 800 keys readable; concurrent delete merge test too. Measured merge ratio via an `apply_count` counter on `writer.State`.

> **Implemented (read path, lever — get)**: two-phase。**Phase 1**（`docs/mmap-read-design.md`）：mmap整文件（预留大 sparse 区、append-only MVCC、永不 remap）+ get skip-decode（`findInLeaf`）+ 热读跳 CRC → 252→133us。**Phase 2**（`docs/zero-copy-read-design.md`，真零拷贝）：去 marker（mmap 字节天然连续）+ `Store.readBorrow`（返 mmap 借用切片，不 alloc 不 memcpy）+ `readRecord` 返借用 + ~8 调用点去 free + `getLatestHeader` 正向扫全文件记最后有效 header（去 marker 后替代扫 marker）+ `findInBranchPayload`（get 跳 branch 全解码）。结果：get 100B **~3us**（~85×）、get 10KB **~5–13us**（~60–136×），**追平 LMDB mmap 读**（~2–5us）。

> **Implemented (auto-compact)**: background thread with two-phase compaction — lock-free phase-1 scan of old-root snapshot, then phase-2 tree-diff merge under write mutex. Configurable dirt ratio threshold (`auto_compact_dirt_ratio`) and minimum file size (`auto_compact_min_bytes`). Retry with exponential backoff on failure. See [`docs/auto-compact-design.md`](docs/auto-compact-design.md).

> Note: delete large / select large / compact large cells are long-running (1M fsyncs or full rewrite of 1GB+); not run to completion. Their shape mirrors small, scaling linearly with size.

## Usage Example

A minimal open→put→get→close:

```zig
const cube = @import("cube_db");
const Db = cube.Db;

const db = try Db.open(allocator, "my.db", .{});
defer db.close() catch {};

try db.put("hello", "world");
const v = try db.get("hello");
if (v) |value| {
    // value is allocator-allocated; free when done
    allocator.free(value);
}
```

For the full API (`putBatch`, `select` range queries, `compact`, `Options`, error handling, concurrency, recipes) see the **[usage manual](docs/usage.md)**.

## V2 (freelist-based) — Preview

A page-based B-tree with page reuse via freelist (LMDB-style). Currently in-memory only (MemPageStore); FilePageStore pending.

```zig
const Db2 = cube.Db2;
const ps = cube.page_store;

var ms = ps.MemPageStore.init(allocator, 1 << 20);
defer ms.deinit();
var db = try Db2.open(allocator, ms.store(), .{});
defer db.close();

try db.put("hello", "world");
const v = try db.get("hello");
defer allocator.free(v.?);
```

**Key advantages over v1:**
- **O(1) compact** — no full rewrite, just meta page switch (vs v1's 2.9 MB/s rewrite)
- **~1× write amplification** — page reuse via freelist (vs v1's ~33×)
- **O(1) recovery** — reads two meta pages (vs v1's full-file scan)
- **MVCC reader safety** — dirty pages held until readers drain
- **Overflow pages** — values up to any size via overflow page chains

`Db.open` is a **purely synchronous API** — callers don't need to set up a `zio.Runtime`.

## Test Coverage

Zig 0.16.0 has no built-in coverage; we use [kcov](https://simonkagstrom.github.io/kcov/).

### 1. Install kcov

```bash
brew install kcov
```

### 2. Temporary options module

The `zig test` CLI doesn't generate the `zio_options` module that `build.zig` does, so write a temp file:

```bash
cat > /tmp/zio_options.zig <<'EOF'
pub const backend: ?[]const u8 = null;
pub const ResolveBeneathMode = enum { strict, best_effort };
pub const resolve_beneath_mode = ResolveBeneathMode.best_effort;
pub const no_hacks = false;
pub const task_migration = true;
EOF
```

### 3. Collect src unit-test coverage

```bash
rm -rf /tmp/cov_src
zig test --test-cmd kcov \
  --test-cmd --include-pattern="$PWD" \
  --test-cmd /tmp/cov_src --test-cmd-bin \
  --dep zio -Mroot=src/root.zig \
  --dep zio_options -Mzio=../zio/src/zio.zig \
  -Mzio_options=/tmp/zio_options.zig
```

### 4. Collect integration-test coverage

```bash
rm -rf /tmp/cov_db /tmp/cov_compact

zig test --test-cmd kcov \
  --test-cmd --include-pattern="$PWD" \
  --test-cmd /tmp/cov_db --test-cmd-bin \
  --dep cube_db --dep zio -Mroot=tests/db_test.zig \
  --dep zio_options -Mzio=../zio/src/zio.zig \
  --dep zio -Mcube_db=src/root.zig \
  -Mzio_options=/tmp/zio_options.zig

zig test --test-cmd kcov \
  --test-cmd --include-pattern="$PWD" \
  --test-cmd /tmp/cov_compact --test-cmd-bin \
  --dep cube_db --dep zio -Mroot=tests/compact_test.zig \
  --dep zio_options -Mzio=../zio/src/zio.zig \
  --dep zio -Mcube_db=src/root.zig \
  -Mzio_options=/tmp/zio_options.zig
```

### 5. Merge and view the report

```bash
rm -rf /tmp/cov_merged
kcov --merge /tmp/cov_merged /tmp/cov_src /tmp/cov_db /tmp/cov_compact
open /tmp/cov_merged/kcov-merged/index.html
```

### Current Coverage

All 42 tests pass; project code coverage is **96.9%** (1436 / 1482 lines).

| File | Coverage |
|------|--------|
| `src/format.zig` | 100.0% |
| `src/btree.zig` | 99.3% |
| `src/fault_store.zig` | 97.3% |
| `src/db.zig` | 95.3% |
| `src/store.zig` | 92.9% |
| `src/file_store.zig` | 91.8% |
| `src/writer.zig` | 80.4% |
| `src/root.zig` | 50.0% |

The main uncovered areas are the placeholder export functions in `src/root.zig` and some error branches in `src/writer.zig`.

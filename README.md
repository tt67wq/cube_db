# cube_db

An embedded key-value store written in Zig 0.16.0, modeled after the [CubDB](https://github.com/lucaong/cubdb) architecture:

- Embedded KV engine: `get` / `put` / `delete` / `select`
- Append-only data file
- Immutable B-tree (Copy-on-Write)
- Compaction to reclaim old versions

Full implementation notes in [`docs/tutorial/`](docs/tutorial/).

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

Key numbers and interpretation from the benchmark matrix:

| Dimension | small | large | Conclusion |
|---|---|---|---|
| put 100B | 498 us/op | 706 us/op | small→large steepens ~1.4×; fsync dominates (~400us/op fixed cost), B-tree depth secondary |
| put 10KB | 3.9 ms/op | 3.8 ms/op | barely scales with size → I/O bandwidth dominates (~10KB/fsync) |
| get 100B | 251 us/op | 494 us/op | doubles at large → B-tree lookup / random read heats up with depth; still far faster than put (no fsync) |
| get 10KB | 786 us/op | 1.3 ms/op | double cost: I/O + lookup |
| delete 100B | 416 us/op | — | same path as put (tombstone + fsync), cost ≈ put |

Key points:

1. **fsync is the absolute hotspot.** put/delete run ~400–700us/op fixed, ≈ fsync latency; putNoFsync unmeasured but this is the engine-overhead ceiling.
2. **put 10KB vs 100B delta ≈ write-to-disk time**: 3.8ms − 0.7ms ≈ 3.1ms/10KB ≈ ~3.2 MB/s flush bandwidth — serial fsync is the drag.
3. **get is far faster than put** (251us vs 498us, no fsync), as expected; large get doubles → lookup / page-cache miss rises with scale — optimize B-tree lookup & read path.
4. **compact**: small 100B ~4s / 10KB ~35s, full rewrite (seq read + write + sync), ~100MB in 35s ≈ ~2.9 MB/s — serial fsync + single-threaded rewrite is the bottleneck; multi-threaded rewrite / streaming sync is the fix.
5. **COW dirt amplification**: large×100B preload (1M puts) yields ~4.7GB physical file (live ~120MB, ~33×); auto-compact is currently a stub and doesn't reclaim automatically — manual `compact()` or a background compactor is required.

> **Highest-ROI optimization**: enable group commit / batched fsync (`sendRequest` currently builds a 1-element batch + 1 fsync per op); put/delete throughput could improve 1–2 orders of magnitude. Next: get lookup path and compact streaming.

> Note: delete large / select large / compact large cells are long-running (1M fsyncs or full rewrite of 1GB+); not finished within 50min. Their shape mirrors small, scaling linearly with size.

## Usage Example

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

`Db.open` is a **purely synchronous API** — callers don't need to set up a `zio.Runtime`.
Internal file I/O runs through zio's blocking-degradation mechanism; callers stay unaffected when the writer coroutine (D4) lands.

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

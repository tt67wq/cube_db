# U5-8 — delete-churn → compactFull cell (results)

- Branch: `U5-8-docs` (from main `7078cf3`), cell added to `bench/perf_batch.zig`
- Machine: Apple M1 Pro / macOS · Zig 0.16.0, `-Doptimize=ReleaseFast`
- Scenario (U5-1 baseline shape): put N=100,000 (10B keys `%010d`, `"v"` value, one putBatch)
  → one `deleteRange` over `[0000000000, 0000090000)` (90%) → metrics → `compactFull(.{})` → metrics.
- Reproduce: `zig build perf-batch -Doptimize=ReleaseFast` (also green without optimize; Debug timings noisier).
- `file_pages` = MemPageStore page high-water (`next_free`), the same file-size proxy as the
  U5-1 baseline (`bench/results/U5-1-churn-baseline.md`, branch `U5-1-bench`).

## Raw output (ReleaseFast, 3 runs)

```
churn_compactfull n=100000 deleteRange_ms=1.6
churn_compactfull before file_pages=3179 visible=10000 get_avg_us=3.612
churn_compactfull stats entries_copied=10000 live_bytes=210000 old_pages_retired=3176 batches=40 chain_dropped=true compactFull_ms=118.6
churn_compactfull after reclaimed_pages=3176 file_pages=3939 visible=10000 get_avg_us=2.850

run2: get 3.492 → 2.892 µs, compactFull_ms=125.9
run3: get 3.805 → 2.907 µs, compactFull_ms=121.8
```

## Reading notes

| claim | evidence |
|---|---|
| dead 90% is really reclaimed | `old_pages_retired=3176` (of file_pages 3179: old tree 3125 leaves + ~50 branches + COW victims + chain page); visible 10000 preserved; `entries_copied == entryCount` |
| tomb chain dropped | `chain_dropped=true` (had_chain captured pre-copy; new tree published with tomb_head=0) |
| read tax cleared | survivor `get` 3.49–3.81µs → **~2.85–2.91µs** across 3 runs (shadow-walk gone). Not back to U5-1's pre-delete 1.368µs — that sample ran with 100k live keys in shallower cache state; the honest comparison for THIS cell is before→after on identical keys: consistent −25% |
| §3.3: online never shrinks the file | `file_pages` 3179 → **3939** (grew, did not shrink): `next_free` is a monotonic bump; the new tree is written while the old tree is still live (copy-phase peak ≈ old + new), then the 3176 retired pages return to the freelist for **reuse** (future writes stop bumping). To shrink the actual file: offline `cube_check vacuum` |
| counters drift-reset | `live_bytes=210000` = 10,000 × (10 + 1 + 10) — exact B formula |

## vs U5-1 baseline anchors

- U5-1 range variant: survivor get 1.368 → 4.346µs after one deleteRange (chain tax 3.2×); O(1) `compact()` left `dead_entries=90000` and file_pages unchanged.
- This cell: same shape, but `compactFull` instead of `compact()` — dead pages actually retired (3176), chain dropped, get tax reduced ~25% on identical survivors, at a one-time cost of ~120ms for the full rewrite (vs `compact_ms=0.002` in the U5-1 baseline — that's the trade).

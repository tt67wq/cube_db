# Review: rangedelete

- **Task:** Implement `Db.deleteRange(min, max)`
- **Author:** impl/pi (excluded from reviewing)
- **Branch:** `feature/delete-range`
- **Reviewed SHA:** `39dc22fc86e48ced27ab73c6d1c041778d3bc266`
- **Base SHA:** `2cb49e7b77f1d5bdd9fe8fef646a2a23eb87de63`
- **Verdict:** `approve`

## Findings

No findings.

## Contract-point check

| # | Point | Status | Evidence |
|---|-------|--------|----------|
| 1 | Deletes live keys `min <= k < max` (byte order) | Pass | `src/db.zig:182-193` uses `select(min, max)` then tombstones every returned key. |
| 2 | Boundary semantics identical to `select` (`[min, max)`, null = unbounded) | Pass | Delegates directly to `select` (`src/db.zig:182`); tests cover `(null,null)`, `null` min, `null` max, and byte-order edge case. |
| 3 | Deleted keys return `null`; outside keys untouched | Pass | `tests/range_delete_test.zig:53-162` checks exact survival/deletion sets. |
| 4 | Inverted/empty range (`min >= max`) is no-op success | Pass | `src/db.zig:167-171` returns early; `tests/range_delete_test.zig:126-141` verifies no change. |
| 5 | Idempotent on already-missing/tombstoned keys | Pass | `tests/range_delete_test.zig:214-235` deletes missing keys and repeats on same range. |
| 6 | Micro-batch: pending puts/deletes inside range are deleted | Pass | `src/db.zig:174` flushes pending before iterating; `tests/range_delete_test.zig:164-212` cover pending puts inside range and pending deletes + outside put. |
| 7 | `entryCount()` reflects deletions | Pass | Tombstones go through `putBatch` -> `applyBatch`; `tests/range_delete_test.zig:237-253` verifies counts `5 -> 3 -> 2 -> 0`. |
| 8 | Works identically on `MemPageStore` and `FilePageStore` | Pass | `tests/range_delete_test.zig:255-275` exercises `FilePageStore` with same assertions. |
| 9 | No new public types; returns `!void` | Pass | `src/db.zig:165` signature is `pub fn deleteRange(...) !void`; no new types introduced. |

## Correctness / ownership notes

- **Borrowed iterator handling:** `src/db.zig:184-186` duplicates each key before `it.next()` invalidates the previous entry; all dupes are freed in the defer at `src/db.zig:177-181`.
- **Micro-batch flush:** `deleteRange` flushes pending entries first (`src/db.zig:174`) so the committed-tree iterator sees them; final deletions commit immediately via `putBatch` (bypasses micro-batch).
- **Ownership compliance:** Only the three allowed paths changed: `src/db.zig`, `tests/range_delete_test.zig`, `docs/usage.md`. No modifications to `btree.zig`, `writer.zig`, or `build.zig`.
- **Acceptance command:** `zig build test` exits `0` at the reviewed SHA.

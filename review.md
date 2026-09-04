# Review: T-32 Reader handle API

Reviewed SHA: a539736 (combined RED 3f9e158 + GREEN a539736, diff base a7c2db2)
Verdict: **approve**

## Primary decision: cross-state `endRead` — guarded no-op ACCEPTED

task.md specified UB/panic for `endRead(state, reader)` with `reader.state != self`;
RED (tests/reader_handle_test.zig:256) and GREEN (src/writer.zig:295) chose a
guarded no-op. **I accept the guarded no-op.** Reasoning:

1. **Cannot corrupt either State.** The guard (writer.zig:295) reads only
   `reader.state` and returns before taking any lock, touching any atomic, or
   mutating any list. The foreign State's registry, free list, and
   `reader_count` are untouched; the owning State's registration is untouched.
   There is no interleaving with `reclaimPendingFree`/`flushPendingFree`
   because the misdirected call never enters a critical section.
2. **The guard cannot be bypassed by a stale state.** `Reader.state` is
   rewritten on every pool reuse inside `beginRead`'s critical section
   (writer.zig:272-280, `r.* = .{ .state = self, ... }`), and the pool is
   per-State (embedded array + heap readers never migrate between States), so
   a handle always reports its true owner. A recycled handle therefore cannot
   defeat the check; it is simply a handle of the (correct) allocating State.
3. **Failure mode is contained and observable, not silent corruption.** If a
   caller misroutes and never releases properly, the reader stays registered:
   `reader_count` stays > 0, the watermark stays pinned, `pendingFreeCount()`
   and `dirtCount()` stay elevated. This is exactly the state a caller who
   *forgot* `endRead` produces — a leak detectable via existing public
   counters, not a data-corrupting or crashing path.
4. **Panic is the harsher option inside the MVCC critical path** (task.md's
   own concern), and Zig 0.16 has no in-process `expectPanics`, so a panic
   contract would be untestable in the standard harness without a child-process
   rig. The no-op semantics is directly testable (test 7) and documented at
   the API (writer.zig:290-293) and in the test (reader_handle_test.zig:13-16,
   257-260).

Optional future hardening (not required): a `builtin.mode == .Debug` assert on
mismatch would add development-time loudness without changing release
semantics.

## Correctness invariants (all verified)

1. **No reclamation race — holds.** `reader_count` is incremented (acquire)
   *before* `pending_free_mu` is taken in `beginRead` (writer.zig:249-251), so
   `applyBatch`'s lock-free `reader_count==0` fast path (writer.zig:462, 667)
   can never observe 0 for an in-flight begin. The snapshot `seq` is loaded
   and the reader inserted into the active set in one critical section, so
   `readerWatermark` (called under the same lock from `reclaimPendingFree`,
   writer.zig:399-414) can never exclude a reader whose seq is below a pending
   `release_seq`: every page currently in `pending_free` has
   `release_seq <= current sequence` at the time reclaim holds the lock, and a
   reader registering afterwards loads `seq >= current sequence`, takes its
   root after registration (post-commit root never references COW'd-out
   pages). The `release_seq = new_sequence` semantics (writer.zig:615) plus
   `release_seq < watermark` strict-keep rule conservatively retains pages a
   pre-commit snapshot may still reference.
2. **Watermark correctness — holds.** `readerWatermark` (writer.zig:432-442)
   is min-seq over the intrusive active list under the lock; empty set with
   `reader_count > 0` (mid-registration reader) returns 0 = pin everything —
   conservative floor, correct direction. The old overflow-counter /
   64-slot-array conservative paths are gone entirely (grep-verified: no
   READER_SLOTS/CLAIM_BIT/TlsEntry/overflow_readers remain).
3. **Snapshot isolation between readers — holds.** `endRead` unlinks exactly
   one node (writer.zig:300-308); watermark is recomputed per reclaim from the
   remaining set. mvcc_test "multiple readers all release before pages freed"
   and the new nested/FIFO test (reader_handle_test.zig:69-121) encode it.
4. **Pool safety — holds for the documented contract.** Handles come from an
   embedded array (8) + heap fallback tracked in `reader_pool` for deinit
   (writer.zig:229); bounded by peak concurrency, recycled through the free
   list under the lock. Sequential double-end is a no-op via `.active`
   (writer.zig:296). See finding F1 for the concurrent double-end window.
5. **reader_count fast path — holds.** `applyBatch` step 0/9 flush when
   `reader_count==0`; last reader's exit drives count to 0 under the lock,
   then `reclaimPendingFree` re-checks under its own lock acquisition and
   full-flushes. dirt is stored together with the append under the lock
   (writer.zig:608-619) — no lost-update window with reader reclamation.
6. **Cross-state misuse — adjudicated above: accept.**

## API/migration correctness

7. `ReadTxn.reader` field added, `end`/`deinit` release it
   (db.zig:376, 405-409); `Db.beginRead/endRead` wrappers take/return the
   handle (db.zig:276-282); iterator `pin_ctx` carries the `*wrt.Reader`
   (db.zig:231, 400) and `endReadPin` dispatches through `reader.state`
   (db.zig:422) — owner-correct even if the pin outlives intermediate objects.
   `btree.zig` pin signature unchanged (as required). errdefer pairs are
   correct (db.zig:228, 398).
8. No bare `endRead()` remains anywhere in `src/` or `tests/` (grep-verified).
   No unpaired begin in normal paths; the storm test (100 overlapping
   handles) asserts exact `reader_count` after each release.

## RED test quality

9. Good. Tests are type-anchored (`wrt.Reader`, `.state/.seq/.active`), so
   they cannot compile against a non-handle stub. Test 2's FIFO (non-LIFO)
   release would catch any TLS/LIFO pairing regression; test 3 exceeds the
   old 64-slot design and asserts count exactness; test 7 pins the adjudicated
   misuse semantics with counter checks on both States. No false-green paths
   found.

## Acceptance

`zig build test` → exit 0, 329/329 tests passed (18/18 build steps). All seven
required behaviors covered by tests/reader_handle_test.zig.

## Findings

- [minor] src/writer.zig:295-296 — the `state != self` and `!active` guards
  run *outside* `pending_free_mu`. Sequential double-end (the documented
  contract) is safe, but two threads racing `endRead` on the same handle can
  both pass `!active`, then double-unlink (idempotent) and double-push the
  handle onto `reader_free` (self-loop) and double-decrement `reader_count`
  (u32 underflow). Concurrent double-end of one handle is arguably as
  out-of-contract as use-after-recycle, but the fix is one line: move the
  `.active` check inside the critical section (the `state != self` check can
  stay first). Recommend as a follow-up; not blocking.
- [minor] src/writer.zig:294 — `reader.state` is read without
  synchronization. Benign in practice: it is immutable while the handle is
  owned and only rewritten on pool reuse under the same State's lock. A
  comment noting the read's informality would suffice; no change required.
- [minor] src/writer.zig:264-268 — `beginRead` OOM panics while holding
  `pending_free_mu`. Process is aborting anyway, so the stuck lock is
  irrelevant; noted only for completeness.
- [info] Use-after-recycle (ending a handle after the pool handed it to a new
  reader) is undetectable without a generation counter; correctly documented
  as outside the contract (tests/reader_handle_test.zig:244-248). If it ever
  matters, add a `gen: u32` bumped on reuse and checked in `endRead`.
- [info] task.md divergence: "misuse panic" acceptance item implemented as a
  documented guarded no-op — adjudicated ACCEPTED above (semantics documented
  at writer.zig:290-293 and in the RED test header).

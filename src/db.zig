//! db.zig — Db handle: v2 public API (open/close/put/get/delete/select/putBatch)
//! Wraps PageStore + wrt + btree. Fully synchronous interface.
const std = @import("std");
const zio = @import("zio");
const f2 = @import("format.zig");
const ps = @import("page_store.zig");
const btree = @import("btree.zig");
const wrt = @import("writer.zig");
const PageStore = ps.PageStore;
const State = wrt.State;
const Mutex = zio.Mutex;

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
    tombstone: bool = false,
};

/// T-33 (U-6): key size gate. Keys beyond the single-leaf minimum encoding
/// (see btree.MAX_KEY_SIZE derivation) are rejected before any staging or
/// allocation, with error.KeyTooLarge — never an assert, never a page-buffer
/// overflow. Tombstones carry the key too, so deletes use the same limit
/// (a tombstone could theoretically be 4B shorter; one uniform bound keeps
/// the user contract simple). deleteRange needs no gate: its min/max are
/// select bounds only (never stored) and its tombstone keys come from
/// already-stored keys (already <= MAX_KEY_SIZE).
fn checkKeySize(key: []const u8) !void {
    if (key.len > btree.MAX_KEY_SIZE) return error.KeyTooLarge;
}

pub const Db = struct {
    allocator: std.mem.Allocator,
    state: *State,
    store: PageStore,
    store_owned: bool,
    write_mutex: Mutex,
    /// T-34 (U-13): staging lock — protects `pending` append / steal / threshold
    /// decision ONLY. Lock discipline (zio.Mutex is non-recursive):
    ///   - never hold staging_mutex while acquiring write_mutex (flush steals
    ///     under staging_mutex, releases it, THEN commits via putBatch) — no
    ///     nesting, no self-deadlock when threshold-triggered flush runs inside
    ///     a staging critical section's aftermath;
    ///   - put/delete: append + threshold check under staging_mutex, then call
    ///     flush() AFTER releasing it;
    ///   - flush: atomically steal the whole pending list under staging_mutex
    ///     (swap in a fresh empty list), release, then commit the stolen batch
    ///     via write_mutex. Concurrent flushes are safe: one steals, the rest
    ///     no-op — no duplicate commits, no lost entries.
    staging_mutex: Mutex,

    /// Micro-batching: staged entries pending commit
    batch_threshold: usize,
    pending: std.ArrayList(Entry),

    pub fn open(allocator: std.mem.Allocator, store: PageStore, opts: wrt.Options) !*Db {
        const state = try allocator.create(State);
        state.* = State.init(allocator, store, opts);
        // T-53: invalid meta / read errors propagate from below; errdefer
        // covers them: State.init allocates nothing, so destroy suffices
        // (also covers a failed Db allocation further down).
        errdefer allocator.destroy(state);

        // T-53 (T-49/T-50): store.readMeta() now fails with error.InvalidMeta
        // when a meta slot is CRC-valid but unrecognized (bad magic / v1 / v4+)
        // — readMetaPage keeps torn/zeroed slots null (crash-safe fallback to
        // the other slot), so "null" still means fresh. Invalid is never
        // treated as fresh — that was the T-49/T-50 silent-empty-open +
        // data-overwrite bug. FilePageStore's vtReadMeta re-syncs its meta
        // buffers from the mmap first, so cross-process writers land too.
        if (try store.readMeta()) |meta| {
            // T-38-3 (R1): root + tomb_head publish as ONE packed word —
            // deleteRange swaps tomb_head from now on, so the phase-2
            // "immutable after open" argument is dead; readers capture the
            // pair from state.root_tomb (tear-free by construction).
            state.publishSnapshot(meta.root_page, meta.tomb_head);
            state.meta_version.store(meta.version, .release);
            state.sequence.store(meta.sequence, .release);
            state.entry_count.store(meta.entry_count, .release);
            state.byte_size.store(meta.byte_size, .release);
            state.dirt.store(0, .release);
        }

        const db = try allocator.create(Db);
        db.* = .{
            .allocator = allocator,
            .state = state,
            .store = store,
            .store_owned = false,
            .write_mutex = .{},
            .staging_mutex = .{},
            .batch_threshold = opts.micro_batch.batch_threshold,
            .pending = .empty,
        };
        return db;
    }

    pub fn close(self: *Db) void {
        // Auto-flush any pending entries before closing (thread-safe steal, T-34)
        self.flush() catch {};
        // If flush failed, still free any residual pending under the staging
        // lock to avoid a leak / racing free (T-34). lockUncancelable: close is
        // a void destructor path — there is nothing to cancel into.
        self.staging_mutex.lockUncancelable();
        for (self.pending.items) |e| {
            self.allocator.free(e.key);
            if (!e.tombstone) self.allocator.free(e.value);
        }
        self.pending.clearRetainingCapacity();
        self.staging_mutex.unlock();
        self.pending.deinit(self.allocator);
        _ = self.state.deinit();
        self.allocator.destroy(self.state);
        self.allocator.destroy(self);
    }

    pub fn getRoot(self: *Db) u32 {
        return self.state.getRoot();
    }

    /// T-37-B: root→leaf height of the CURRENT COMMITTED root (consistent
    /// with getRoot()/select). 0 = empty tree, 1 = single-leaf tree, else
    /// branch levels + 1. Deep or unreadable trees are reported honestly
    /// (btree.treeDepth returns its 1000 guard count) — this exists to
    /// observe/monitor the depth invariant (T-37), not to validate it.
    /// Holds an MVCC read pin for the walk so a concurrent commit cannot
    /// recycle the snapshot's pages mid-descent.
    pub fn treeDepth(self: *Db) usize {
        const reader = self.state.beginRead();
        defer self.state.endRead(reader);
        return btree.treeDepth(self.store, self.state.getRoot());
    }

    pub fn entryCount(self: *Db) u64 {
        return self.state.entry_count.load(.acquire);
    }

    // ---- Implicit-txn convenience API (wraps an implicit WriteTxn) ----

    /// Put with optional micro-batching: if batch_threshold > 0, stages the entry;
    /// auto-flushes when threshold reached. Use flush() to force commit.
    /// Use putDirect() to bypass micro-batching entirely.
    pub fn put(self: *Db, key: []const u8, value: []const u8) !void {
        try checkKeySize(key); // T-33: reject before staging (micro-batch too)
        if (self.batch_threshold == 0) return self.putDirect(key, value);
        // Copy key and value — caller's slices may not live until flush
        const k = try self.allocator.dupe(u8, key);
        const v = try self.allocator.dupe(u8, value);
        // T-34: append + threshold decision under staging_mutex; the flush runs
        // AFTER the lock is released (never inside — see staging_mutex doc).
        var do_flush = false;
        {
            self.staging_mutex.lock() catch return error.LockFailed;
            defer self.staging_mutex.unlock();
            try self.pending.append(self.allocator, .{ .key = k, .value = v, .tombstone = false });
            do_flush = self.pending.items.len >= self.batch_threshold;
        }
        if (do_flush) try self.flush();
    }
    pub fn delete(self: *Db, key: []const u8) !void {
        try checkKeySize(key); // T-33: tombstone carries the key
        if (self.batch_threshold == 0) return self.deleteDirect(key);
        const k = try self.allocator.dupe(u8, key);
        // T-34: same staging_mutex discipline as put (see above).
        var do_flush = false;
        {
            self.staging_mutex.lock() catch return error.LockFailed;
            defer self.staging_mutex.unlock();
            try self.pending.append(self.allocator, .{ .key = k, .value = "", .tombstone = true });
            do_flush = self.pending.items.len >= self.batch_threshold;
        }
        if (do_flush) try self.flush();
    }
    /// Direct put — bypasses micro-batching, commits immediately.
    pub fn putDirect(self: *Db, key: []const u8, value: []const u8) !void {
        var txn = try self.beginWriteTxn();
        defer txn.deinit();
        try txn.put(key, value);
        try txn.commit();
    }

    /// Direct delete — bypasses micro-batching, commits immediately.
    pub fn deleteDirect(self: *Db, key: []const u8) !void {
        var txn = try self.beginWriteTxn();
        defer txn.deinit();
        try txn.delete(key);
        try txn.commit();
    }

    /// Flush pending staged entries via a single batch commit.
    /// No-op if nothing pending. Frees copied key/value strings after commit.
    /// T-34: thread-safe. Atomically STEALS the pending list under staging_mutex
    /// (swap in a fresh empty list), releases the lock, then commits the stolen
    /// batch via putBatch (write_mutex). Concurrent flushers are safe: exactly
    /// one of them gets each batch — no duplicate commits, no lost entries.
    /// The stolen entries' key/value slices are owned here, so they stay valid
    /// for the whole putBatch call (which only borrows them).
    pub fn flush(self: *Db) !void {
        var stolen: std.ArrayList(Entry) = undefined;
        {
            self.staging_mutex.lock() catch return error.LockFailed;
            defer self.staging_mutex.unlock();
            if (self.pending.items.len == 0) return;
            stolen = self.pending;
            self.pending = .empty;
        }
        defer {
            for (stolen.items) |e| {
                self.allocator.free(e.key);
                if (!e.tombstone) self.allocator.free(e.value);
            }
            stolen.deinit(self.allocator);
        }
        try self.putBatch(stolen.items);
    }

    /// Batch put: commit all entries in one WriteTxn (bypasses micro-batching).
    /// Keys and values are copied internally, so caller's slices only need to be
    /// valid during the putBatch call itself (not after).
    pub fn putBatch(self: *Db, entries: []const Entry) !void {
        // T-33: validate the whole batch first — atomic reject, nothing applied.
        for (entries) |e| try checkKeySize(e.key);
        // Build the batch directly: skip per-entry staging + arena dupe.
        // Requests reference the caller's key/value slices directly (insertBatch
        // inside applyBatch dupes them into the leaf), so the slices only need
        // to be valid for the duration of the putBatch call (value semantics are
        // the caller's job).
        self.write_mutex.lock() catch return error.LockFailed;
        defer self.write_mutex.unlock();

        const reqs = try self.allocator.alloc(wrt.Request, entries.len);
        defer self.allocator.free(reqs);
        var futures = try self.allocator.alloc(zio.Future(wrt.OpResult), entries.len);
        defer self.allocator.free(futures);

        const prof = wrt.ProfileStats.enable;
        const t0 = if (prof) wrt.ProfileStats.now() else 0;

        for (entries, 0..) |e, i| {
            futures[i] = .{};
            reqs[i] = .{ .key = e.key, .value = e.value, .tombstone = e.tombstone, .future = &futures[i] };
        }

        if (prof) wrt.ProfileStats.db_staging_ns += @intCast(wrt.ProfileStats.now() - t0);
        // T-38-3 (C2, INV-RT1): if any live-entry key falls inside an existing
        // tombstone, plan the split (same-commit swap — a put can never land
        // under a tomb that still covers it). No chain → null swap, zero cost.
        var punch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer punch_arena.deinit();
        const swap = try planTombPunch(self, punch_arena.allocator(), reqs);
        try self.state.applyBatchSwap(reqs, swap);
        for (futures) |*f| try (try f.wait()).value;
    }

    /// Delete all keys k in [min, max) — half-open, same boundary semantics as select.
    /// null min/max = unbounded (null, null) deletes every key.
    /// Idempotent on already-missing keys. No-op (success) when range is inverted/empty.
    ///
    /// T-38-3 (C1, design §4.1): the range becomes a persisted range-tombstone
    /// chain (one chain write + one meta swap — root untouched, covered
    /// entries stay physical and shadowed). Memory is O(#tombstones), never
    /// O(range). entryCount is fixed by a streaming O(1)-memory pass over the
    /// visible in-range keys (C4). Envelope-fallback: a range whose two bounds
    /// together exceed the single-entry tombstone envelope (both near
    /// MAX_KEY_SIZE) materializes per-key tree tombstones instead (O(range),
    /// this corner only) — the old chunked path, unchanged semantics.
    pub fn deleteRange(self: *Db, min: ?[]const u8, max: ?[]const u8) !void {
        // Inverted/empty range → no-op success, no side effects (don't even flush).
        if (min) |m| {
            if (max) |mx| {
                if (btree.cmpKey(m, mx) != .lt) return;
            }
        }
        // Micro-batch: the tombstone covers committed state; staged puts must
        // be flushed first (punch-hole at their later commit handles anything
        // staged after this point — INV-RT1 is maintained by the put path).
        try self.flush();

        const min_stored: usize = if (min) |m| m.len else 0;
        const max_stored: usize = if (max) |m| m.len else 0;
        if (f2.TOMB_ENTRY_SIZE + min_stored + max_stored > f2.TOMB_PAYLOAD_SIZE) {
            // Double-long bounds: not representable as a single entry — the
            // documented materialization fallback (design §4.3).
            return self.deleteRangeMaterialized(min, max);
        }

        // Single-writer: the streaming count, chain merge and the meta swap
        // must see one consistent committed state (no interleaved commit).
        self.write_mutex.lock() catch return error.LockFailed;
        defer self.write_mutex.unlock();

        // Idempotent short-circuit (design §4.4): if [min,max) is already
        // covered by the existing chain, this deleteRange changes nothing
        // observable — skip the count pass, chain rewrite AND the commit.
        // Probe on a STACK FixedBufferAllocator: the heap ArenaAllocator's
        // minimum block (~1KB) would alone exceed the T-38-B idempotent
        // re-delete budget (peak2 <= peak). A chain too big for the probe
        // falls back to the general heap path below.
        {
            var sbuf: [1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&sbuf);
            var p_tobs: std.ArrayList(f2.RangeTombstone) = .empty;
            var p_pages: std.ArrayList(u32) = .empty;
            if (loadTombChainInto(self, fba.allocator(), &p_tobs, &p_pages)) {
                if (rangeCoveredBy(p_tobs.items, min, max)) return;
            } else |err| switch (err) {
                error.OutOfMemory => {}, // probe too small — general path
                else => return err, // real read/decode error propagates
            }
        }

        // General path: load the chain into a heap arena for the merge.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        var tobs: std.ArrayList(f2.RangeTombstone) = .empty;
        var old_pages: std.ArrayList(u32) = .empty;
        try loadTombChainInto(self, aa, &tobs, &old_pages);

        // C4: stream-count the VISIBLE in-range keys (shadow-aware select) +
        // their live-byte contribution (key.len + value.len + 10 — matches
        // btree's live_delta for a live→tombstone replacement). O(1) memory.
        var count: i64 = 0;
        var live_bytes: i64 = 0;
        {
            var it = try self.select(min, max);
            defer it.deinit();
            while (try it.next()) |e| {
                count += 1;
                live_bytes += @intCast(e.key.len + e.value.len + 10);
            }
        }

        // T-38-4 (C1, P1): count == 0 ⟹ every physical entry in [min,max) is
        // already shadowed by the existing chain ⟹ one more covering layer
        // changes no read result — the new interval is provably redundant.
        // commitTombSwap's deltas would both be 0 anyway, so returning here
        // is semantically identical AND zero-side-effect: no chain page, no
        // meta write, no sequence bump, no counter change.
        if (count == 0) return;

        try tobs.append(aa, .{
            .min = if (min) |m| .{ .bytes = m } else null,
            .max = if (max) |m| .{ .bytes = m } else null,
        });
        // T-38-4 (C2): the chain is canonicalized at its single publish point
        // (commitTombSwap) — sort/merge/dedup happens there for ALL paths, so
        // nothing to do locally.
        try self.state.commitTombSwap(tobs.items, old_pages.items, -count, -live_bytes);
    }

    /// T-38-3 fallback: per-key tree tombstones in fixed chunks (the pre-
    /// stage-3 deleteRange, kept verbatim for the unrepresentable-envelope
    /// corner). O(CHUNK) memory. Multi-commit is fine here — no range tomb is
    /// involved, INV-RT1 does not apply.
    fn deleteRangeMaterialized(self: *Db, min: ?[]const u8, max: ?[]const u8) !void {
        const CHUNK = 256;
        var keys: [CHUNK][]const u8 = undefined;
        var entries: [CHUNK]Entry = undefined;
        var n: usize = 0;
        defer {
            for (keys[0..n]) |k| self.allocator.free(k);
        }
        var it = try self.select(min, max);
        defer it.deinit();
        while (try it.next()) |e| {
            keys[n] = try self.allocator.dupe(u8, e.key);
            entries[n] = .{ .key = keys[n], .value = "", .tombstone = true };
            n += 1;
            if (n == CHUNK) {
                try self.putBatch(entries[0..n]);
                for (keys[0..n]) |k| self.allocator.free(k);
                n = 0;
            }
        }
        if (n > 0) try self.putBatch(entries[0..n]);
    }

    // ---- Read path (default snapshot = current root) ----

    // ---- T-38-2: range-tombstone shadowing (design §3.1/§1.4) ----

    /// (root, tomb_head) captured as one logical snapshot. T-38-3 (R1/R3):
    /// ONE packed-atomic load from wrt.State — deleteRange now swaps
    /// tomb_head, so the phase-2 "immutable after open" argument is dead;
    /// both tear directions were unsafe (stale tomb hides re-put keys; fresh
    /// tomb leaks a future delete into an old snapshot). This fn is the only
    /// capture point for all five read entrypoints.
    const ReadSnapshot = struct { root: u32, tomb_head: u32 };

    fn captureSnapshot(self: *Db) ReadSnapshot {
        const rt = self.state.captureRootTomb();
        return .{ .root = rt.root, .tomb_head = rt.tomb_head };
    }

    /// Is `key` covered by any tombstone on the chain at `head`?
    /// tomb_head==0 short-circuits (unique: impl-plan §7-4) — zero I/O, zero
    /// allocation, byte-identical behavior on tomb-less stores.
    /// Corrupt-chain errors (CorruptCrc/InvalidTombPage/Truncated, incl. the
    /// H-1 cycle guard) propagate — NEVER swallowed into "no tombs"
    /// (design §5.1: tomb corruption is library corruption).
    fn isShadowed(self: *Db, head: u32, key: []const u8) !bool {
        if (head == 0) return false;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var pages: std.ArrayList(f2.TombPage) = .empty;
        try walkTombChain(self.store, head, &pages, arena.allocator());
        return tombListCovers(pages.items, key);
    }

    pub fn get(self: *Db, key: []const u8) !?[]u8 {
        // Register-then-capture (same pattern as select / ReadTxn, T-29
        // review finding 1): the reader must be registered BEFORE the root
        // snapshot is taken — an unregistered in-flight get is invisible to
        // the watermark, so a concurrent commit's reclaimPendingFree
        // (reader_count==0 fast path) could free the COW old pages the
        // snapshot still references, and the next alloc would overwrite them
        // mid-descent (silent misread). Whichever root is read, its COW old
        // pages stay in pending_free until endRead releases the pin.
        // T-38-2: the same pin keeps the tomb chain pages alive for the
        // shadow walk below.
        const reader = self.state.beginRead();
        defer self.state.endRead(reader);
        const snap = captureSnapshot(self);
        // T-38-2 (design §3.1): pure spatial pre-descent check — a covered key
        // is "missing" (INV-RT1: no timestamp needed on the read path).
        if (try self.isShadowed(snap.tomb_head, key)) return null;
        return try btree.getChecked(self.allocator, self.store, snap.root, key, self.state.opts.crc_check);
    }

    /// Zero-copy point read (T-29 Phase A): value is copied into the caller's
    /// buffer, returning the byte count; missing key -> null; buffer too small
    /// -> error.BufferTooSmall (buffer untouched). Frees hot-path readers
    /// (cache/index layers) from get()'s per-call alloc/free.
    pub fn getInto(self: *Db, key: []const u8, buffer: []u8) !?usize {
        // Register-then-capture, identical to get() above: pin the snapshot
        // before capturing the root so concurrent reclamation cannot free
        // pages the in-flight descent still references.
        const reader = self.state.beginRead();
        defer self.state.endRead(reader);
        const snap = captureSnapshot(self);
        // T-38-2: covered key → null without touching the caller's buffer
        // (check runs before descent, so BufferTooSmall can't fire either).
        if (try self.isShadowed(snap.tomb_head, key)) return null;
        return try btree.getIntoChecked(self.store, snap.root, key, buffer, self.state.opts.crc_check);
    }

    /// Range query (T-29 Phase B borrowed iterator): next() returns borrowed
    /// entry slices, valid only until the next next()/deinit() (overflow values
    /// are assembled in an internal reuse buffer); the iterator holds an MVCC
    /// reader slot, so writer COW dirty pages are deferred until deinit() (last
    /// reader out); mid-iteration commits do not affect already-borrowed pages.
    /// Forgetting deinit leaks the reader slot (dirty pages never reclaimed).
    pub fn select(self: *Db, min: ?[]const u8, max: ?[]const u8) !btree.Iterator {
        // T-29 review finding 1 (major): the reader slot must be registered
        // before capturing the root snapshot — if getRoot() came first, the
        // writer's grace-period reclaim (applyBatch flushes when
        // reader_count==0) could free the old pages the snapshot root
        // references, within the window between the two calls.
        // Register-then-capture: whichever root is read, its COW old pages stay
        // in pending_free until the iterator's deinit (last reader out).
        const reader = self.state.beginRead(); // MVCC pin: snapshot protection for the iterator's borrowed pages
        errdefer self.state.endRead(reader);
        const snap = captureSnapshot(self);
        var it = try btree.selectChecked(self.allocator, self.store, snap.root, min, max, self.state.opts.crc_check);
        // T-38-2 (M-1): shadow filter — decode the whole chain ONCE here
        // (eager: corrupt-chain errors surface at select() itself), then
        // per-entry checks are pure compares. it.deinit() releases BOTH the
        // shadow ctx (skip_deinit) and the reader pin (pin_deinit).
        if (snap.tomb_head != 0) {
            const ctx = try loadShadowCtx(self.allocator, self.store, snap.tomb_head);
            it.skip_ctx = ctx;
            it.skip_fn = shadowSkip;
            it.skip_deinit = shadowSkipDeinit;
        }
        it.pin_ctx = @ptrCast(reader);
        it.pin_deinit = endReadPin;
        return it;
    }

    /// T-38-4 (C3): harvest tombstone intervals that can no longer shadow
    /// anything. For every interval on the chain, a RAW tree scan decides
    /// (no shadow skip — same 口径 as materializeSegment): any physically
    /// present entry in the range → KEEP the interval (dropping it would
    /// resurrect the entries it shadows — F1 direction, data loss); none →
    /// drop it (observationally neutral for EVERY snapshot, P3 — no reader
    /// watermark needed; old chain pages retire via the standard
    /// pending_free/release_seq discipline).
    /// Zero-side-effect short-circuits: tomb_head == 0, or nothing harvestable
    /// → no meta write, no sequence bump. Publishing goes through
    /// commitTombSwap (canonical chain per C2) with BOTH deltas 0 — dropping
    /// an entry-less interval cannot change visible counts.
    /// Deliberately NOT called from compact(): compact is O(1) by public
    /// contract (docs/usage.md) — gc is the separate convergence exit.
    pub fn gcTombstones(self: *Db) !void {
        // Same serialization as every other write path (single-writer commit
        // view for the raw scans and the chain swap).
        self.write_mutex.lock() catch return error.LockFailed;
        defer self.write_mutex.unlock();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        var tobs: std.ArrayList(f2.RangeTombstone) = .empty;
        var old_pages: std.ArrayList(u32) = .empty;
        try loadTombChainInto(self, aa, &tobs, &old_pages);
        if (tobs.items.len == 0) return; // tomb_head == 0: zero-side-effect no-op

        // Raw probe per interval: one bounded raw iteration each; the first
        // entry (alive OR tree-tombstone — anything physical counts, keep is
        // the conservative direction) marks the interval as load-bearing.
        // Write mutex held: no commit can interleave, no MVCC pin needed
        // (same reasoning as materializeSegment).
        const root = self.state.getRoot();
        var kept: std.ArrayList(f2.RangeTombstone) = .empty;
        for (tobs.items) |t| {
            const has_entry = blk: {
                var it = try btree.selectChecked(aa, self.store, root, if (t.min) |m| try effBoundBytes(aa, m) else null, if (t.max) |m| try effBoundBytes(aa, m) else null, self.state.opts.crc_check);
                defer it.deinit();
                break :blk (try it.next()) != null;
            };
            if (has_entry) try kept.append(aa, t);
        }
        if (kept.items.len == tobs.items.len) return; // nothing harvestable → no side effects

        // Deltas 0: an entry-less interval shadows nothing, so visibility and
        // both counters are unchanged by dropping it (P3).
        try self.state.commitTombSwap(kept.items, old_pages.items, 0, 0);
    }

    pub fn compact(self: *Db) !void {
        // Shares the root/sequence/meta writes with applyBatch; must be
        // serialized through the write mutex (avoids interleaved meta writes).
        self.write_mutex.lock() catch return error.LockFailed;
        defer self.write_mutex.unlock();
        try self.state.compact();
    }

    /// Explicit sync (manually flush committed data to disk in async mode).
    pub fn sync(self: *Db) !void {
        try self.store.sync();
    }

    pub fn dirtCount(self: *Db) u64 {
        return self.state.dirtCount();
    }

    // ---- Explicit transaction API (LMDB-style) ----

    /// Begin a write txn: single-writer mutex. Writes stage in a buffer; commit
    /// runs applyBatch + meta switch + fsync.
    pub fn beginWriteTxn(self: *Db) !WriteTxn {
        self.write_mutex.lock() catch return error.LockFailed;
        return .{
            .db = self,
            .staged = .empty,
            .finished = false,
            // Arena for staging: put/delete dupe into the arena, freed in one
            // shot at commit/abort — zero extra syscalls
            .staging_arena = std.heap.ArenaAllocator.init(self.allocator),
        };
    }

    /// Begin a read txn: takes the current root snapshot, does not block
    /// writers (MVCC). Must be ended via endReadTxn/ReadTxn.end.
    pub fn beginReadTxn(self: *Db) !ReadTxn {
        const reader = self.state.beginRead();
        // T-38-2: tomb_head captured atomically-with-root (captureSnapshot seam);
        // the txn must keep using THIS value — never db.tomb_head's current
        // value, which a later commit could swap mid-txn (phase 3).
        const snap = captureSnapshot(self);
        return .{ .db = self, .snapshot_root = snap.root, .snapshot_tomb_head = snap.tomb_head, .reader = reader };
    }

    pub fn beginRead(self: *Db) *wrt.Reader {
        return self.state.beginRead();
    }

    pub fn endRead(self: *Db, reader: *wrt.Reader) void {
        self.state.endRead(reader);
    }
};

/// Write txn (LMDB-style). Single-writer mutex; writes stage in a buffer;
/// commit runs an atomic applyBatch + meta switch + fsync. abort discards the
/// staged writes without applying them. Keys/values are caller-owned slices;
/// put/delete dupes them into the staging arena immediately.
pub const WriteTxn = struct {
    db: *Db,
    staged: std.ArrayList(Entry),
    finished: bool,
    staging_arena: std.heap.ArenaAllocator,
    arena_freed: bool = false,

    pub fn put(self: *WriteTxn, key: []const u8, value: []const u8) !void {
        try checkKeySize(key); // T-33: reject at put time, not at commit
        if (self.finished) return error.TxnFinished;
        // Copy key/value into the arena — the caller's slice (e.g. a stack
        // buffer) may not live until commit
        const alloc = self.staging_arena.allocator();
        const k = try alloc.dupe(u8, key);
        const v = try alloc.dupe(u8, value);
        try self.staged.append(alloc, .{ .key = k, .value = v, .tombstone = false });
    }

    pub fn delete(self: *WriteTxn, key: []const u8) !void {
        try checkKeySize(key); // T-33
        if (self.finished) return error.TxnFinished;
        // Copy key into the arena — the caller's slice may not live until commit
        const alloc = self.staging_arena.allocator();
        const k = try alloc.dupe(u8, key);
        try self.staged.append(alloc, .{ .key = k, .value = "", .tombstone = true });
    }

    /// Commit: applyBatch + meta switch + fsync. On completion or error,
    /// finished=true and the mutex is released. The staging arena is freed in
    /// one shot after commit (applyBatch has already duped key/values into its
    /// own arena; page writes are copy semantics, leaving no lingering references).
    pub fn commit(self: *WriteTxn) !void {
        if (self.finished) return error.TxnFinished;
        self.finished = true;
        defer self.db.write_mutex.unlock();
        defer {
            self.arena_freed = true;
            self.staging_arena.deinit();
        }
        if (self.staged.items.len == 0) return;

        // Arena for futures allocation — avoids large stack frame when batch is big
        var commit_arena = std.heap.ArenaAllocator.init(self.db.allocator);
        defer commit_arena.deinit();
        const arena_alloc = commit_arena.allocator();

        const prof = wrt.ProfileStats.enable;
        const t_reqs0 = if (prof) wrt.ProfileStats.now() else 0;
        const reqs = try arena_alloc.alloc(wrt.Request, self.staged.items.len);
        var futures = try arena_alloc.alloc(zio.Future(wrt.OpResult), self.staged.items.len);
        for (self.staged.items, 0..) |e, i| {
            futures[i] = .{};
            reqs[i] = .{ .key = e.key, .value = e.value, .tombstone = e.tombstone, .future = &futures[i] };
        }
        if (prof) wrt.ProfileStats.db_reqs_ns += @intCast(wrt.ProfileStats.now() - t_reqs0);
        // T-38-3 (C2, INV-RT1): same-commit tomb split for covered puts
        // (see putBatch — one code path, same invariant).
        const swap = try planTombPunch(self.db, arena_alloc, reqs);
        try self.db.state.applyBatchSwap(reqs, swap);
        const t_wait0 = if (prof) wrt.ProfileStats.now() else 0;
        for (futures) |*f| try (try f.wait()).value;
        if (prof) wrt.ProfileStats.db_futures_wait_ns += @intCast(wrt.ProfileStats.now() - t_wait0);
    }

    /// Abort: discard staged writes without applying. Releases the mutex.
    /// The arena is freed in one shot.
    pub fn abort(self: *WriteTxn) !void {
        if (self.finished) return;
        self.finished = true;
        self.arena_freed = true;
        self.staging_arena.deinit();
        self.db.write_mutex.unlock();
    }

    /// Destructor: calls abort if not yet committed/aborted (prevents leaking the mutex).
    pub fn deinit(self: *WriteTxn) void {
        if (!self.arena_freed) {
            self.arena_freed = true;
            self.staging_arena.deinit();
        }
        if (!self.finished) {
            self.finished = true;
            self.db.write_mutex.unlock();
        }
    }
};

/// Read txn (LMDB-style). Holds a snapshot root (MVCC), does not block
/// writers. Must be ended via end (or deinit).
pub const ReadTxn = struct {
    db: *Db,
    snapshot_root: u32,
    /// T-38-2: tombstone chain head at the txn's BEGIN moment (captured
    /// atomically-with-root in beginReadTxn). Fixed for the txn's lifetime —
    /// later tomb swaps by concurrent writers never leak into this snapshot.
    snapshot_tomb_head: u32,
    reader: *wrt.Reader,
    ended: bool = false,

    pub fn get(self: *ReadTxn, key: []const u8) !?[]u8 {
        // T-38-2: shadow check with the BEGIN-time snapshot tomb_head; the
        // txn's own reader pin keeps the chain pages alive for the walk.
        if (try self.db.isShadowed(self.snapshot_tomb_head, key)) return null;
        return try btree.getChecked(self.db.allocator, self.db.store, self.snapshot_root, key, self.db.state.opts.crc_check);
    }

    /// Zero-copy point read (T-29 Phase A): same semantics as Db.getInto
    /// (null = key missing, BufferTooSmall = buffer too small, nothing
    /// written), with the snapshot pinned to this txn's root.
    pub fn getInto(self: *ReadTxn, key: []const u8, buffer: []u8) !?usize {
        // T-38-2: same pre-descent shadow check (buffer untouched on cover).
        if (try self.db.isShadowed(self.snapshot_tomb_head, key)) return null;
        return try btree.getIntoChecked(self.db.store, self.snapshot_root, key, buffer, self.db.state.opts.crc_check);
    }

    /// Range query (T-29 Phase B borrowed iterator): borrowing contract
    /// identical to Db.select (next() invalidates the previous entry).
    /// The snapshot is pinned to this txn's root; the iterator holds its own
    /// additional MVCC reader slot (stacking with the txn's pin, reader counts
    /// are incremental), released at deinit() — the iterator must still be
    /// deinit'd before the txn ends.
    /// T-38-2: shadow filter uses the txn's BEGIN-time tomb snapshot.
    pub fn select(self: *ReadTxn, min: ?[]const u8, max: ?[]const u8) !btree.Iterator {
        const reader = self.db.state.beginRead(); // iterator's own pin (released at deinit)
        errdefer self.db.state.endRead(reader);
        var it = try btree.selectChecked(self.db.allocator, self.db.store, self.snapshot_root, min, max, self.db.state.opts.crc_check);
        // T-38-2 (M-1): same shadow-filter shape as Db.select, but pinned to
        // the txn's BEGIN-time tomb snapshot (snapshot_tomb_head).
        if (self.snapshot_tomb_head != 0) {
            const ctx = try loadShadowCtx(self.db.allocator, self.db.store, self.snapshot_tomb_head);
            it.skip_ctx = ctx;
            it.skip_fn = shadowSkip;
            it.skip_deinit = shadowSkipDeinit;
        }
        it.pin_ctx = @ptrCast(reader);
        it.pin_deinit = endReadPin;
        return it;
    }

    pub fn end(self: *ReadTxn) void {
        if (self.ended) return;
        self.ended = true;
        self.db.state.endRead(self.reader);
    }

    pub fn deinit(self: *ReadTxn) void {
        self.end();
    }
};

/// MVCC pin callback for btree.Iterator (T-29 Phase B): releases the reader
/// slot at deinit. The btree layer does not depend on wrt.State; decoupled
/// via an opaque callback.
fn endReadPin(ctx: *anyopaque) void {
    const reader: *wrt.Reader = @ptrCast(@alignCast(ctx));
    reader.state.endRead(reader);
}

// ===== T-38-2: range-tombstone shadowing helpers (design §3.1/§1.4) =====

/// Compare `k` against a bound's EFFECTIVE byte string (bytes ++ 0x00 if
/// append_zero — design §1.4), without materializing the concatenation.
/// Semantics ported verbatim from the validated spike probe (探针 2).
fn boundCmpKey(k: []const u8, b: f2.TombBound) std.math.Order {
    const n = @min(k.len, b.bytes.len);
    for (0..n) |i| {
        if (k[i] != b.bytes[i]) return if (k[i] < b.bytes[i]) .lt else .gt;
    }
    if (k.len < b.bytes.len) return .lt; // k is a proper prefix of bytes → k < bytes ≤ eff
    if (k.len > b.bytes.len) {
        if (!b.append_zero) return .gt; // k extends bytes → k > bytes
        // eff = bytes ++ 0x00: compare k[bytes.len] against the 0x00 suffix
        if (k[b.bytes.len] != 0) return .gt;
        return if (k.len == b.bytes.len + 1) .eq else .gt;
    }
    // k.len == bytes.len
    return if (b.append_zero) .lt else .eq; // k == bytes < bytes ++ 0x00
}

/// [min, max) half-open coverage — min inclusive, max exclusive, null =
/// unbounded (design §3.1 INV-RT1: pure spatial check, no timestamps).
fn tombCovers(t: f2.RangeTombstone, k: []const u8) bool {
    if (t.min) |m| {
        if (boundCmpKey(k, m) == .lt) return false; // k < min
    }
    if (t.max) |m| {
        if (boundCmpKey(k, m) != .lt) return false; // k >= max
    }
    return true;
}

/// Linear scan over decoded pages — deliberately NOT assuming any ordering
/// (L-1: chain sorting is a phase-3 writer invariant; injected/corrupt chains
/// are unordered).
fn tombListCovers(pages: []const f2.TombPage, key: []const u8) bool {
    for (pages) |p| {
        for (p.tobs) |t| {
            if (tombCovers(t, key)) return true;
        }
    }
    return false;
}

/// Walk a tombstone chain following free_next (0 = tail), decoding every
/// page into `pages` (tobs arrays allocated with `a`).
/// H-1 trust boundary: decodeTombPage does NOT validate free_next — a
/// CRC-valid cycle would loop forever. Guard: visited-page set (dedup by
/// page number) — the instant free_next revisits an already-walked page,
/// return error.Truncated (typed, no hang; memory O(chain length)).
/// T-52: NOT a mapsize() step bound — that "limit" is backend-inconsistent
/// (MemPageStore: page count, FilePageStore: 2^28) and on FilePageStore a
/// CRC-valid ring would run ~2.68e8 steps / ~12 GiB before tripping —
/// a quasi-hang. The visited set catches a ring on its first revisit,
/// regardless of store backend.
fn walkTombChain(store: PageStore, head: u32, pages: *std.ArrayList(f2.TombPage), a: std.mem.Allocator) !void {
    var visited = std.AutoHashMapUnmanaged(u32, void){};
    defer visited.deinit(a);
    // mapsize() 不可作步数上界：两后端单位不一致（Mem=页数、File=2^28），File 侧宽到准 hang（T-52）。
    var pn: u32 = head;
    while (pn != 0) {
        const gop = try visited.getOrPut(a, pn);
        if (gop.found_existing) return error.Truncated; // cycle: page revisited
        const raw = try store.readPage(pn);
        const tp = try f2.decodeTombPage(a, raw[0..f2.PAGE_SIZE]);
        // Exact-capacity growth (T-38-B mem budget): ArrayList's default first
        // append reserves capacity 8 (384B for TombPage) — noticeable against
        // the O(1) deleteRange budget on the idempotent re-delete path.
        // ponytail: O(pages²) copy worst case on very long chains — fine at
        // real chain sizes; revisit if chains exceed ~100 pages.
        try pages.ensureTotalCapacity(a, pages.items.len + 1);
        try pages.append(a, tp);
        pn = tp.next;
    }
}

/// Decoded tomb chain for select-time shadowing: the chain is walked and
/// decoded ONCE per select() (corrupt-chain errors surface at the select
/// call itself), then every per-entry check is a pure compare. The struct is
/// arena-owned as a whole: `arena` state lives inside the ctx allocation,
/// and deinit frees everything (ctx included) in one shot.
const ShadowCtx = struct {
    arena: std.heap.ArenaAllocator,
    pages: []f2.TombPage, // tobs arrays arena-owned; bound bytes BORROW the (COW-immutable, pin-protected) page buffers

    fn covers(self: *const ShadowCtx, key: []const u8) bool {
        return tombListCovers(self.pages, key);
    }
};

fn loadShadowCtx(a: std.mem.Allocator, store: PageStore, head: u32) !*ShadowCtx {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const ctx = try aa.create(ShadowCtx);
    var pages: std.ArrayList(f2.TombPage) = .empty;
    try walkTombChain(store, head, &pages, aa);
    // NOTE: `aa` borrows the stack `arena`; both uses above happen before the
    // struct-init moves the arena state into ctx (which lives in arena memory).
    ctx.* = .{ .arena = arena, .pages = try pages.toOwnedSlice(aa) };
    return ctx;
}

/// btree.Iterator skip hook (T-38-2, M-1): true = entry shadowed → skip.
/// Pure compare (decode already happened at select time) — cannot fail.
fn shadowSkip(ctx: *anyopaque, key: []const u8) anyerror!bool {
    const s: *ShadowCtx = @ptrCast(@alignCast(ctx));
    return s.covers(key);
}

fn shadowSkipDeinit(ctx: *anyopaque) void {
    const s: *ShadowCtx = @ptrCast(@alignCast(ctx));
    s.arena.deinit(); // frees the ctx allocation itself
}

// ===== T-38-3: write-path tomb planning (design §4.3, INV-RT1) =====

/// Effective-bound comparison without materializing bytes: eff(b) =
/// b.bytes ++ (0x00 if append_zero). Null is handled by callers (a null
/// min/max means ±infinity and never reaches here).
fn boundCmp(a: f2.TombBound, b: f2.TombBound) std.math.Order {
    const a_len = a.bytes.len + @as(usize, @intFromBool(a.append_zero));
    const b_len = b.bytes.len + @as(usize, @intFromBool(b.append_zero));
    const n = @min(a_len, b_len);
    for (0..n) |i| {
        const ab: u8 = if (i < a.bytes.len) a.bytes[i] else 0;
        const bb: u8 = if (i < b.bytes.len) b.bytes[i] else 0;
        if (ab != bb) return if (ab < bb) .lt else .gt;
    }
    if (a_len < b_len) return .lt;
    if (a_len > b_len) return .gt;
    return .eq;
}

/// Sort a tomb list by effective min (null min = -inf sorts first). Stable
/// enough for determinism; exact-equal duplicates are removed by dedupTobs.
fn sortTobs(tobs: []f2.RangeTombstone) void {
    const Ctx = struct {
        fn lt(_: void, a: f2.RangeTombstone, b: f2.RangeTombstone) bool {
            const am = a.min orelse return b.min != null; // -inf first
            const bm = b.min orelse return false;
            return boundCmp(am, bm) == .lt;
        }
    };
    std.mem.sort(f2.RangeTombstone, tobs, {}, Ctx.lt);
}

/// Drop adjacent exact-equal entries (post-sort). Rebuilds the arena-backed
/// list in place: every tomb whose (min,max) effective pair equals the kept
/// predecessor is removed (design §4.3: union + dedup — a repeated
/// deleteRange of the same range leaves one tomb).
fn dedupTobs(list: *std.ArrayList(f2.RangeTombstone), a: std.mem.Allocator) !void {
    if (list.items.len < 2) return;
    var keep: usize = 0;
    for (list.items[1..]) |t| {
        const prev = list.items[keep];
        const same = blk: {
            if ((prev.min == null) != (t.min == null)) break :blk false;
            if (prev.min) |pm| {
                if (boundCmp(pm, t.min.?) != .eq) break :blk false;
            }
            if ((prev.max == null) != (t.max == null)) break :blk false;
            if (prev.max) |pmax| {
                if (boundCmp(pmax, t.max.?) != .eq) break :blk false;
            }
            break :blk true;
        };
        if (!same) {
            keep += 1;
            list.items[keep] = t;
        }
    }
    list.shrinkRetainingCapacity(keep + 1);
    _ = a; // entries are arena-owned; shrinking needs no allocator
}

/// Load the current chain into `tobs` (bounds BORROW the page buffers — the
/// caller holds the write mutex, no swap can race) and record its page
/// numbers into `old_pages` (retired at commit).
fn loadTombChainInto(self: *Db, a: std.mem.Allocator, tobs: *std.ArrayList(f2.RangeTombstone), old_pages: *std.ArrayList(u32)) !void {
    const head = self.state.getTombHead();
    if (head == 0) return;
    var pages: std.ArrayList(f2.TombPage) = .empty;
    defer pages.deinit(a);
    try walkTombChain(self.store, head, &pages, a);
    for (pages.items) |tp| {
        // Exact-capacity growth — see walkTombChain's note (T-38-B).
        try old_pages.ensureTotalCapacity(a, old_pages.items.len + 1);
        try old_pages.append(a, tp.hdr.page_no);
        try tobs.ensureTotalCapacity(a, tobs.items.len + tp.tobs.len);
        try tobs.appendSlice(a, tp.tobs);
    }
}

/// Is [min, max) fully covered by the union of `tobs`? (Idempotent
/// short-circuit predicate — finite bounds only; null bounds fall back to the
/// general path.) Order-agnostic greedy interval cover: extend a frontier
/// with the largest reachable tomb max until it passes max. O(T²) worst case
/// on a small in-memory list — fine.
fn rangeCoveredBy(tobs: []const f2.RangeTombstone, min: ?[]const u8, max: ?[]const u8) bool {
    if (min == null or max == null) return false;
    const lo: f2.TombBound = .{ .bytes = min.? };
    const hi: f2.TombBound = .{ .bytes = max.? };
    var frontier = lo; // covered up to (exclusive) `frontier`
    var moved = true;
    while (boundCmp(frontier, hi) == .lt) {
        if (!moved) return false; // gap: nothing extends the frontier
        moved = false;
        for (tobs) |t| {
            if (t.max == null) return true; // +inf max swallows everything
            const tmax = t.max.?;
            // t must start at or before the frontier …
            if (t.min != null and boundCmp(t.min.?, frontier) == .gt) continue;
            // … and extend it strictly further
            if (boundCmp(tmax, frontier) != .gt) continue;
            if (boundCmp(tmax, hi) != .lt) return true; // reached max
            frontier = tmax;
            moved = true;
        }
    }
    return true;
}

/// Does this split segment fit the single-entry envelope? (design §4.3 F1:
/// "right segment too large" is NEVER a drop reason — callers materialize.)
fn segmentFits(min: ?f2.TombBound, max: ?f2.TombBound) bool {
    const min_len: usize = if (min) |m| m.bytes.len else 0;
    const max_len: usize = if (max) |m| m.bytes.len else 0;
    return f2.TOMB_ENTRY_SIZE + min_len + max_len <= f2.TOMB_PAYLOAD_SIZE;
}

/// T-38-3 (C2, INV-RT1): plan the tomb-split for a batch of puts.
/// For every live-entry request key covered by a tombstone t=[tmin,tmax):
/// split t into [tmin,k) and [succ(k),tmax) — succ(k) is stored compactly as
/// {k, append_zero} (§1.4). Left segment dropped only when tmin == k
/// (effective); right segment dropped only when tmax == succ(k) (the truly
/// empty segment — a7c); a too-large segment is MATERIALIZED as per-key
/// tree tombstones in the same commit (never dropped, F1).
/// Returns null when nothing is covered (the common no-tomb / no-overlap
/// case — zero planning cost beyond one packed load + chain walk).
/// Caller holds the write mutex; everything allocates in `a` (punch arena).
fn planTombPunch(self: *Db, a: std.mem.Allocator, reqs: []const wrt.Request) !?wrt.State.TombSwap {
    const head = self.state.getTombHead();
    if (head == 0) return null;
    // Any live-entry key that can be covered? Cheapest filter first: only
    // non-tombstone requests participate (a delete inside a tomb range is
    // already shadowed — INV-RT1 only constrains LIVE entries).
    var has_live = false;
    for (reqs) |r| {
        if (!r.tombstone) {
            has_live = true;
            break;
        }
    }
    if (!has_live) return null;

    var tobs: std.ArrayList(f2.RangeTombstone) = .empty;
    var old_pages: std.ArrayList(u32) = .empty;
    try loadTombChainInto(self, a, &tobs, &old_pages);
    if (tobs.items.len == 0) return null;

    var extra: std.ArrayList(wrt.Request) = .empty;
    var revive_count: i64 = 0;
    var revive_bytes: i64 = 0;
    var changed = false;
    for (reqs) |r| {
        if (r.tombstone) continue;
        const k = r.key;
        var punched = false;
        // Split every covering tomb (multiple overlapping toms may cover k —
        // all must split, else k stays shadowed by the survivor).
        var i: usize = 0;
        while (i < tobs.items.len) {
            const t = tobs.items[i];
            if (!tombCovers(t, k)) {
                i += 1;
                continue;
            }
            changed = true;
            punched = true;
            // Build the two segments, drop the original.
            const tmin = t.min;
            const tmax = t.max;
            _ = tobs.orderedRemove(i);

            // Left segment [tmin, k): dropped iff tmin == k (effective).
            const left_empty = tmin != null and boundCmp(tmin.?, .{ .bytes = k }) == .eq;
            if (!left_empty) {
                const lmin = tmin;
                const lmax: ?f2.TombBound = .{ .bytes = k };
                if (segmentFits(lmin, lmax)) {
                    try tobs.append(a, .{ .min = lmin, .max = lmax });
                } else {
                    try materializeSegment(self, a, &extra, &revive_count, &revive_bytes, lmin, k);
                }
            }

            // Right segment [succ(k), tmax): dropped iff tmax == succ(k).
            const succ: f2.TombBound = .{ .bytes = k, .append_zero = true };
            const right_empty = tmax != null and boundCmp(tmax.?, succ) == .eq;
            if (!right_empty) {
                const rmin: ?f2.TombBound = succ;
                const rmax = tmax;
                if (segmentFits(rmin, rmax)) {
                    try tobs.append(a, .{ .min = rmin, .max = rmax });
                } else {
                    // F1: NEVER drop the right segment — it covers entries
                    // deleted by the tomb being split; dropping resurrects
                    // them. Materialize per-key tombstones instead.
                    try materializeSegment(self, a, &extra, &revive_count, &revive_bytes, succ, if (tmax) |tm| try effBoundBytes(a, tm) else null);
                }
            }
        }
        // entryCount/byte_size compensation (TombSwap.revive_*): k was
        // covered → shadowed → already excluded from the counters when its
        // tomb was created. If the PRE-COMMIT tree entry is physically live,
        // the overwrite below yields insert count_delta=0 while k becomes
        // visible → +1 (bytes likewise, get-value convention matching the
        // shadowing deduction). Physically-absent / tree-tombstone entries
        // get insert's own +1 — no compensation.
        if (punched) {
            const root = self.state.getRoot();
            if (try btree.get(a, self.store, root, k)) |old_v| {
                revive_count += 1;
                revive_bytes += @intCast(k.len + old_v.len + 10);
            }
        }
    }
    if (!changed) return null;

    sortTobs(tobs.items);
    try dedupTobs(&tobs, a);
    return .{
        .tobs = tobs.items,
        .old_pages = old_pages.items,
        .extra_reqs = extra.items,
        .revive_count = revive_count,
        .revive_bytes = revive_bytes,
    };
}

/// Materialize a segment [min, max) as per-key tree tombstone requests for
/// every key the tree currently holds in that range (visible or shadowed —
/// the segment's range coverage is being dropped, so both kinds must be
/// pinned dead; already-dead tombstone entries are skipped by insert).
/// Raw byte bounds: the caller materializes effective bounds via
/// effBoundBytes. O(range) — only reachable in the envelope corner.
fn materializeSegment(self: *Db, a: std.mem.Allocator, extra: *std.ArrayList(wrt.Request), revive_count: *i64, revive_bytes: *i64, min: ?f2.TombBound, max: ?[]const u8) !void {
    // Raw iteration on the current root: no shadow skip (we must see
    // physically-present entries regardless of current shadowing), no MVCC
    // pin needed — the write mutex is held, no commit can interleave.
    const root = self.state.getRoot();
    var it = try btree.selectChecked(a, self.store, root, if (min) |m| try effBoundBytes(a, m) else null, max, self.state.opts.crc_check);
    defer it.deinit();
    while (try it.next()) |e| {
        const k = try a.dupe(u8, e.key);
        try extra.append(a, .{ .key = k, .value = "", .tombstone = true, .future = undefined });
        // Counter compensation: every materialized key is inside the split
        // segment ⊆ t → currently shadowed → excluded from the counters; the
        // tree tombstone insert below reports live→tombstone (count_delta
        // -1, live_delta -old) — both wrong for a key that was already
        // invisible. +1 / +old-contribution restores the invariant.
        revive_count.* += 1;
        revive_bytes.* += @intCast(e.key.len + e.value.len + 10);
    }
}

/// Materialize a bound's effective bytes (bytes ++ 0x00 if append_zero) as a
/// raw key slice for tree iteration bounds. Caller's arena; the result of a
/// null bound is handled by the caller (null = unbounded).
fn effBoundBytes(a: std.mem.Allocator, b: f2.TombBound) ![]const u8 {
    if (!b.append_zero) return b.bytes;
    const out = try a.alloc(u8, b.bytes.len + 1);
    @memcpy(out[0..b.bytes.len], b.bytes);
    out[b.bytes.len] = 0;
    return out;
}
test "db: open default state" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();
    try std.testing.expectEqual(@as(u32, btree.NULL_ROOT), db.getRoot());
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
    // T-37-B treeDepth contract: 0 = empty tree, 1 = single-leaf tree.
    try std.testing.expectEqual(@as(usize, 0), db.treeDepth());
    try db.putDirect("k", "v");
    try std.testing.expectEqual(@as(usize, 1), db.treeDepth());
}

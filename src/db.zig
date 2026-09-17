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

    /// T-38-2 (design §2): range-tombstone chain head captured at open from
    /// the SAME meta read that seeds State (same-page consistent pair).
    /// v2/fresh stores decode to 0. Immutable for this Db's lifetime in
    /// phase 2 (no write path swaps it) — that is what makes captureSnapshot's
    /// two independent loads tear-free; phase 3 moves root+tomb_head into one
    /// packed atomic in wrt.State when deleteRange starts swapping it.
    tomb_head: std.atomic.Value(u32),

    pub fn open(allocator: std.mem.Allocator, store: PageStore, opts: wrt.Options) !*Db {
        const state = try allocator.create(State);
        state.* = State.init(allocator, store, opts);

        var tomb_head: u32 = 0; // T-38-2: captured with root from the SAME meta page
        if (try store.readMeta()) |meta| {
            tomb_head = meta.tomb_head;
            state.root.store(meta.root_page, .release);
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
            .tomb_head = std.atomic.Value(u32).init(tomb_head),
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
        try self.state.applyBatch(reqs);
        for (futures) |*f| try (try f.wait()).value;
    }

    /// Delete all keys k in [min, max) — half-open, same boundary semantics as select.
    /// null min/max = unbounded (null, null) deletes every key.
    /// Idempotent on already-missing keys. No-op (success) when range is inverted/empty.
    pub fn deleteRange(self: *Db, min: ?[]const u8, max: ?[]const u8) !void {
        // Inverted/empty range → no-op success, no side effects (don't even flush).
        if (min) |m| {
            if (max) |mx| {
                if (btree.cmpKey(m, mx) != .lt) return;
            }
        }
        // Micro-batch: the select iterator reads the committed root only, so pending
        // staged puts/deletes must be flushed first to be visible (and deletable).
        try self.flush();
        // T-38-B: stream the range in fixed-size chunks instead of collecting
        // every key first — net memory is O(CHUNK) (constant), not O(range).
        //
        // The iterator pins the root snapshot it was opened with (MVCC reader
        // slot, released at its deinit): chunk commits swap in new roots, but
        // the snapshot keeps reading the open-time tree, so every key in the
        // range is visited exactly once and each gets exactly one tombstone —
        // entry_count deltas add up exactly as the old single-batch path.
        //
        // Borrowed-iterator contract: next() invalidates the previous entry, so
        // each key is duped before the chunk commit; the dupes are freed after
        // putBatch returns (insertBatch copies into the leaf pages). CHUNK is a
        // count: keys are <= MAX_KEY_SIZE, so CHUNK * MAX_KEY_SIZE is a
        // constant byte bound — no separate byte budget needed.
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

    /// (root, tomb_head) captured as one logical snapshot. Phase 2 tear-free
    /// proof: tomb_head is immutable after open (only open writes it), so the
    /// two loads can never interleave into mismatched generations. Phase 3
    /// MUST replace the body with a single packed-atomic load from wrt.State
    /// (root<<32|tomb_head) once deleteRange starts swapping tomb_head —
    /// both tear directions are unsafe (stale tomb hides re-put keys; fresh
    /// tomb leaks a future delete into an old snapshot). This fn is the only
    /// capture point for all five read entrypoints.
    const ReadSnapshot = struct { root: u32, tomb_head: u32 };

    fn captureSnapshot(self: *Db) ReadSnapshot {
        return .{ .root = self.state.getRoot(), .tomb_head = self.tomb_head.load(.acquire) };
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
        try self.db.state.applyBatch(reqs);
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
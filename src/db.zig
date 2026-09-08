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

pub const Db = struct {
    allocator: std.mem.Allocator,
    state: *State,
    store: PageStore,
    store_owned: bool,
    write_mutex: Mutex,

    /// Micro-batching: staged entries pending commit
    batch_threshold: usize,
    pending: std.ArrayList(Entry),

    pub fn open(allocator: std.mem.Allocator, store: PageStore, opts: wrt.Options) !*Db {
        const state = try allocator.create(State);
        state.* = State.init(allocator, store, opts);

        if (try store.readMeta()) |meta| {
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
            .batch_threshold = opts.micro_batch.batch_threshold,
            .pending = .empty,
        };
        return db;
    }

    pub fn close(self: *Db) void {
        // Auto-flush any pending entries before closing
        self.flush() catch {};
        // If flush failed, still free pending to avoid leak
        for (self.pending.items) |e| {
            self.allocator.free(e.key);
            if (!e.tombstone) self.allocator.free(e.value);
        }
        self.pending.deinit(self.allocator);
        _ = self.state.deinit();
        self.allocator.destroy(self.state);
        self.allocator.destroy(self);
    }

    pub fn getRoot(self: *Db) u32 {
        return self.state.getRoot();
    }

    pub fn entryCount(self: *Db) u64 {
        return self.state.entry_count.load(.acquire);
    }

    // ---- Implicit-txn convenience API (wraps an implicit WriteTxn) ----

    /// Put with optional micro-batching: if batch_threshold > 0, stages the entry;
    /// auto-flushes when threshold reached. Use flush() to force commit.
    /// Use putDirect() to bypass micro-batching entirely.
    pub fn put(self: *Db, key: []const u8, value: []const u8) !void {
        if (self.batch_threshold == 0) return self.putDirect(key, value);
        // Copy key and value — caller's slices may not live until flush
        const k = try self.allocator.dupe(u8, key);
        const v = try self.allocator.dupe(u8, value);
        try self.pending.append(self.allocator, .{ .key = k, .value = v, .tombstone = false });
        if (self.pending.items.len >= self.batch_threshold) {
            try self.flush();
        }
    }

    /// Delete with optional micro-batching (same logic as put).
    pub fn delete(self: *Db, key: []const u8) !void {
        if (self.batch_threshold == 0) return self.deleteDirect(key);
        const k = try self.allocator.dupe(u8, key);
        try self.pending.append(self.allocator, .{ .key = k, .value = "", .tombstone = true });
        if (self.pending.items.len >= self.batch_threshold) {
            try self.flush();
        }
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
    pub fn flush(self: *Db) !void {
        if (self.pending.items.len == 0) return;
        defer {
            for (self.pending.items) |e| {
                self.allocator.free(e.key);
                if (!e.tombstone) self.allocator.free(e.value);
            }
            self.pending.clearRetainingCapacity();
        }
        try self.putBatch(self.pending.items);
    }

    /// Batch put: commit all entries in one WriteTxn (bypasses micro-batching).
    /// Keys and values are copied internally, so caller's slices only need to be
    /// valid during the putBatch call itself (not after).
    pub fn putBatch(self: *Db, entries: []const Entry) !void {
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
        // Collect keys in [min, max) — iterator entries are borrowed and next()
        // invalidates the previous entry, so dupe keys for the tombstone batch.
        var keys: std.ArrayList([]const u8) = .empty;
        defer {
            for (keys.items) |k| self.allocator.free(k);
            keys.deinit(self.allocator);
        }
        var it = try self.select(min, max);
        defer it.deinit();
        while (try it.next()) |e| {
            try keys.append(self.allocator, try self.allocator.dupe(u8, e.key));
        }
        if (keys.items.len == 0) return;
        const entries = try self.allocator.alloc(Entry, keys.items.len);
        defer self.allocator.free(entries);
        for (keys.items, 0..) |k, i| {
            entries[i] = .{ .key = k, .value = "", .tombstone = true };
        }
        try self.putBatch(entries);
    }

    // ---- Read path (default snapshot = current root) ----

    pub fn get(self: *Db, key: []const u8) !?[]u8 {
        // Register-then-capture (same pattern as select / ReadTxn, T-29
        // review finding 1): the reader must be registered BEFORE the root
        // snapshot is taken — an unregistered in-flight get is invisible to
        // the watermark, so a concurrent commit's reclaimPendingFree
        // (reader_count==0 fast path) could free the COW old pages the
        // snapshot still references, and the next alloc would overwrite them
        // mid-descent (silent misread). Whichever root is read, its COW old
        // pages stay in pending_free until endRead releases the pin.
        const reader = self.state.beginRead();
        defer self.state.endRead(reader);
        const root = self.state.getRoot();
        return try btree.get(self.allocator, self.store, root, key);
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
        const root = self.state.getRoot();
        return try btree.getInto(self.store, root, key, buffer);
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
        const root = self.state.getRoot();
        var it = try btree.select(self.allocator, self.store, root, min, max);
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
        return .{ .db = self, .snapshot_root = self.state.getRoot(), .reader = reader };
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
        if (self.finished) return error.TxnFinished;
        // Copy key/value into the arena — the caller's slice (e.g. a stack
        // buffer) may not live until commit
        const alloc = self.staging_arena.allocator();
        const k = try alloc.dupe(u8, key);
        const v = try alloc.dupe(u8, value);
        try self.staged.append(alloc, .{ .key = k, .value = v, .tombstone = false });
    }

    pub fn delete(self: *WriteTxn, key: []const u8) !void {
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
    reader: *wrt.Reader,
    ended: bool = false,

    pub fn get(self: *ReadTxn, key: []const u8) !?[]u8 {
        return try btree.get(self.db.allocator, self.db.store, self.snapshot_root, key);
    }

    /// Zero-copy point read (T-29 Phase A): same semantics as Db.getInto
    /// (null = key missing, BufferTooSmall = buffer too small, nothing
    /// written), with the snapshot pinned to this txn's root.
    pub fn getInto(self: *ReadTxn, key: []const u8, buffer: []u8) !?usize {
        return try btree.getInto(self.db.store, self.snapshot_root, key, buffer);
    }

    /// Range query (T-29 Phase B borrowed iterator): borrowing contract
    /// identical to Db.select (next() invalidates the previous entry).
    /// The snapshot is pinned to this txn's root; the iterator holds its own
    /// additional MVCC reader slot (stacking with the txn's pin, reader counts
    /// are incremental), released at deinit() — the iterator must still be
    /// deinit'd before the txn ends.
    pub fn select(self: *ReadTxn, min: ?[]const u8, max: ?[]const u8) !btree.Iterator {
        const reader = self.db.state.beginRead(); // iterator's own pin (released at deinit)
        errdefer self.db.state.endRead(reader);
        var it = try btree.select(self.db.allocator, self.db.store, self.snapshot_root, min, max);
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
test "db: open default state" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 1000);
    defer ms.deinit();
    var db = try Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();
    try std.testing.expectEqual(@as(u32, btree.NULL_ROOT), db.getRoot());
    try std.testing.expectEqual(@as(u64, 0), db.entryCount());
}
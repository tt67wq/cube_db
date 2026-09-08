//! writer.zig — v2 batch apply: COW B-tree (btree), freelist reclamation (MVCC-safe), alternating meta commit
const std = @import("std");
const zio = @import("zio");
const f2 = @import("format.zig");
const ps = @import("page_store.zig");
const btree = @import("btree.zig");

const PageStore = ps.PageStore;

// ---- T-32: explicit Reader handle API ----
//
// T-30's design existed only because endRead() took no identity argument:
// a thread-local stack + a fixed 64-slot array + a top-bit claim encoding +
// overflow-counter fallback recovered "which slot did my beginRead occupy".
// The explicit handle deletes all of that: beginRead returns a *Reader,
// endRead(self, reader) unregisters exactly that reader.

/// pending_free entry: page number + the sequence of the commit that freed
/// it (that commit's new_sequence).
/// Reclamation rule: safe to reclaim when release_seq < the oldest-active-reader
/// watermark (every active reader snapshot is >= watermark > release_seq, so
/// nobody can still reference the page); equal or greater must be kept (old
/// snapshots remain valid — the correctness floor, conservatively including
/// the boundary).
pub const PendingPage = struct {
    page_no: u32,
    release_seq: u64,
};

/// A reader registration. Holds the owning State, the snapshot sequence, and
/// liveness. Allocated by beginRead, must be released by endRead.
/// Embedded (allocation-free) handle pool depth: covers the realistic
/// nesting/concurrency of this codebase (ReadTxn + select nesting <= 3,
/// plus headroom for concurrent iterator scans); deeper concurrency falls
/// back to heap Readers recycled through the same free list.
const EMBEDDED_READERS = 8;

pub const Reader = struct {
    state: *State,
    seq: u64,
    active: bool,
    /// Intrusive active-set links (protected by pending_free_mu)
    prev_active: ?*Reader = null,
    next_active: ?*Reader = null,
    /// Free-list link for the reusable handle pool (protected by pending_free_mu)
    next_free: ?*Reader = null,
};

/// Phase-by-phase timing profile (#35): enabled at compile time, off the
/// production hot path.
/// Usage: profile tool sets enable=true; applyBatch accumulates per-phase
/// timings.
pub const ProfileStats = struct {
    pub var enable: bool = false;

    // Per-phase timings (ns) and call counts
    pub var txn_dupe_ns: u64 = 0;
    pub var txn_sort_ns: u64 = 0;
    pub var txn_order_ns: u64 = 0;
    pub var txn_dedup_ns: u64 = 0;
    pub var txn_insertbatch_ns: u64 = 0;
    pub var txn_pending_free_ns: u64 = 0;
    pub var txn_flush_free_ns: u64 = 0;
    pub var txn_meta_ns: u64 = 0;
    pub var txn_total_ns: u64 = 0;
    pub var txn_count: u64 = 0;
    pub var txn_entries: u64 = 0;
    // db layer (staging/futures)
    pub var db_staging_ns: u64 = 0;
    pub var db_reqs_ns: u64 = 0;
    pub var db_futures_wait_ns: u64 = 0;

    pub fn reset() void {
        txn_dupe_ns = 0;
        txn_sort_ns = 0;
        txn_order_ns = 0;
        txn_dedup_ns = 0;
        txn_insertbatch_ns = 0;
        txn_pending_free_ns = 0;
        txn_flush_free_ns = 0;
        txn_meta_ns = 0;
        txn_total_ns = 0;
        txn_count = 0;
        txn_entries = 0;
        db_staging_ns = 0;
        db_reqs_ns = 0;
        db_futures_wait_ns = 0;
    }

    pub fn now() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
    }

    pub fn print() void {
        if (txn_count == 0) return;
        std.debug.print("\n=== applyBatch phase timings (page_allocator) ===\n", .{});
        std.debug.print("  total batches: {d}, total entries: {d}\n", .{ txn_count, txn_entries });
        const avg = @divFloor(txn_total_ns, txn_count);
        std.debug.print("  avg per batch: {d} ns ({d:.2} ms)\n", .{ avg, @as(f64, @floatFromInt(avg)) / 1_000_000.0 });
        const per_entry = @divFloor(txn_total_ns, @max(txn_entries, 1));
        std.debug.print("  per entry:  {d} ns ({d:.3} us)\n", .{ per_entry, @as(f64, @floatFromInt(per_entry)) / 1000.0 });
        inline for (.{
            .{ "dupe        ", txn_dupe_ns },
            .{ "order_detect", txn_order_ns },
            .{ "sort        ", txn_sort_ns },
            .{ "dedup       ", txn_dedup_ns },
            .{ "insertBatch ", txn_insertbatch_ns },
            .{ "pending_free", txn_pending_free_ns },
            .{ "flush_free  ", txn_flush_free_ns },
            .{ "meta+write  ", txn_meta_ns },
        }) |row| {
            const pct = @as(f64, @floatFromInt(row[1])) / @as(f64, @floatFromInt(@max(txn_total_ns, 1))) * 100.0;
            const p_entry = @divFloor(row[1], @max(txn_entries, 1));
            std.debug.print("  {s}: {d:>12} ns ({d:.1}%)  {d} ns/entry\n", .{ row[0], row[1], pct, p_entry });
        }
        std.debug.print("  --- db layer ---\n", .{});
        inline for (.{
            .{ "staging     ", db_staging_ns },
            .{ "reqs+futures", db_reqs_ns },
            .{ "futures.wait", db_futures_wait_ns },
        }) |row| {
            const p_entry = @divFloor(row[1], @max(txn_entries, 1));
            std.debug.print("  {s}: {d:>12} ns  {d} ns/entry\n", .{ row[0], row[1], p_entry });
        }
    }
};

/// Durability levels (T-27):
/// - `process_crash` (default): commit protocol = writeMeta + one sync.
///   Safe and fast under the process-crash (page cache intact) model — the
///   default for the bench battleground.
/// - `power_fail`: commit protocol = syncDataPages (data pages to disk
///   first) -> writeMeta -> sync (meta to disk). Two syncs buy power-loss
///   correctness: at the moment the meta page reaches stable storage, the
///   data pages it points to have already landed (or land at the same time
///   at the latest). Single-put latency roughly doubles; amortized over a
///   batch it is acceptable. In this level every commit is a double sync
///   (fsync=false only makes sense for process_crash — the async mode where
///   the user calls Db.sync() manually).
pub const Durability = enum { process_crash, power_fail };

pub const Options = struct {
    fsync: bool = true,
    micro_batch: MicroBatchConfig = .{},
    durability: Durability = .process_crash,
};

/// Micro-batching config: stage puts/deletes and commit in batches
/// to amortize COW + meta write + fsync overhead.
pub const MicroBatchConfig = struct {
    /// Max staged entries before auto-flush. 0 = disabled (direct commit).
    batch_threshold: usize = 0,
};

pub const OpResult = anyerror!void;

pub const Request = struct {
    key: []const u8,
    value: []const u8,
    tombstone: bool,
    future: *zio.Future(OpResult),
};

pub const State = struct {
    allocator: std.mem.Allocator,
    store: PageStore,
    root: std.atomic.Value(u32),
    sequence: std.atomic.Value(u64),
    dirt: std.atomic.Value(u64),
    entry_count: std.atomic.Value(u64),
    byte_size: std.atomic.Value(u64),
    opts: Options,
    closed: std.atomic.Value(bool),

    meta_index: u32,

    /// Active reader count (0 = no readers, dirty pages can be reclaimed
    /// safely; the fast-path predicate)
    reader_count: std.atomic.Value(u32),

    /// Active-reader set: intrusive doubly-linked list (protected by
    /// pending_free_mu). Watermark = min seq across this set.
    readers_head: ?*Reader = null,
    /// Reusable handle pool: a small embedded array (lazily linked into the
    /// free list on first use — init returns by value, so self-referencing
    /// pointers cannot be set up there) plus a heap fallback for deeper
    /// concurrency. Bounded by peak concurrent readers — handles are
    /// recycled, never grown per begin/end cycle. The embedded array keeps
    /// the select() reader hot path allocation-free.
    reader_free: ?*Reader = null,
    embedded_readers: [EMBEDDED_READERS]Reader = undefined,
    readers_linked: bool = false,
    reader_pool: std.ArrayList(*Reader) = .empty,

    /// Dirty pages pending reclamation (carrying the release sequence;
    /// reclaimed incrementally by watermark while readers are active)
    pending_free: std.ArrayList(PendingPage),
    /// pending_free mutex: serializes writer appends against reader/compact
    /// incremental reclamation (fixes the UB of concurrent ArrayList
    /// mutation). Readers take this lock only when there is a backlog
    /// (dirt>0).
    pending_free_mu: zio.Mutex,

    pub fn init(allocator: std.mem.Allocator, store: PageStore, opts: Options) State {
        return .{
            .allocator = allocator,
            .store = store,
            .root = std.atomic.Value(u32).init(btree.NULL_ROOT),
            .sequence = std.atomic.Value(u64).init(0),
            .dirt = std.atomic.Value(u64).init(0),
            .entry_count = std.atomic.Value(u64).init(0),
            .byte_size = std.atomic.Value(u64).init(0),
            .opts = opts,
            .closed = std.atomic.Value(bool).init(false),
            .meta_index = 0,
            .reader_count = std.atomic.Value(u32).init(0),
            .pending_free = .empty,
            .pending_free_mu = .{},
        };
    }

    pub fn deinit(self: *State) void {
        self.closed.store(true, .release);
        // Free the remaining pending_free (safe: writer thread done, no readers)
        for (self.pending_free.items) |pp| self.store.freePage(pp.page_no);
        self.pending_free.deinit(self.allocator);
        for (self.reader_pool.items) |r| self.allocator.destroy(r);
        self.reader_pool.deinit(self.allocator);
    }

    // ---- MVCC reader API ----

    /// Begin a read txn. Allocates and registers a Reader (from the reusable
    /// pool), returns its handle. The Reader stays valid until
    /// endRead(self, reader).
    /// B1 invariant (preserved by the lock): reader_count is incremented
    /// (acquire) *before* taking pending_free_mu, so applyBatch's lock-free
    /// reader_count==0 flush fast path can never observe 0 here; the
    /// snapshot seq is loaded *while holding* the lock and the reader is
    /// inserted into the active set in the same critical section — no
    /// reclamation can interleave between the seq load and the registration,
    /// so a watermark can never exceed an in-flight reader's eventual seq.
    /// Registration happens before returning; the caller then captures the
    /// root snapshot, and whichever root it sees, its COW old pages stay in
    /// pending_free until the watermark releases them.
    pub fn beginRead(self: *State) *Reader {
        _ = self.reader_count.fetchAdd(1, .acquire);
        self.pending_free_mu.lockUncancelable();
        defer self.pending_free_mu.unlock();
        if (!self.readers_linked) {
            // Lazy link of the embedded pool: State.init returns by value, so
            // self-referencing free-list pointers can only be wired up here,
            // once the State has reached its final address.
            var i: usize = 0;
            while (i < EMBEDDED_READERS) : (i += 1) {
                self.embedded_readers[i].next_free = self.reader_free;
                self.reader_free = &self.embedded_readers[i];
            }
            self.readers_linked = true;
        }
        const r = self.reader_free orelse blk: {
            const nr = self.allocator.create(Reader) catch @panic("beginRead: out of memory");
            nr.next_free = null;
            self.reader_pool.append(self.allocator, nr) catch {
                self.allocator.destroy(nr);
                @panic("beginRead: out of memory");
            };
            break :blk nr;
        };
        self.reader_free = r.next_free;
        r.* = .{
            .state = self,
            .seq = self.sequence.load(.acquire),
            .active = true,
            .prev_active = null,
            .next_active = self.readers_head,
            .next_free = null,
        };
        if (self.readers_head) |h| h.prev_active = r;
        self.readers_head = r;
        return r;
    }

    /// End a read txn. Unregisters the exact Reader, returns it to the pool,
    /// and immediately reclaims the now-safe pending pages by oldest-reader
    /// watermark — a short-lived reader's exit releases its pinned pages
    /// without waiting for the last reader; the last reader's exit
    /// (reader_count reaching 0) still reclaims everything (the existing
    /// fast-path semantics preserved). Guards: double-end is a no-op
    /// (checked via .active); cross-state misuse (reader.state != self) is a
    /// guarded no-op — neither State's registry nor reader_count is touched.
    pub fn endRead(self: *State, reader: *Reader) void {
        if (reader.state != self) return; // cross-state misuse: guarded no-op
        if (!reader.active) return; // double-end: no-op
        {
            self.pending_free_mu.lockUncancelable();
            defer self.pending_free_mu.unlock();
            // unlink from the active set
            if (reader.prev_active) |p| {
                p.next_active = reader.next_active;
            } else {
                self.readers_head = reader.next_active;
            }
            if (reader.next_active) |n| n.prev_active = reader.prev_active;
            reader.active = false;
            // return to the free list
            reader.next_free = self.reader_free;
            self.reader_free = reader;
            _ = self.reader_count.fetchSub(1, .release);
        }
        if (self.dirt.load(.acquire) > 0) {
            self.reclaimPendingFree();
        }
    }

    /// Returns the number of dirty pages currently awaiting release
    pub fn pendingFreeCount(self: *State) usize {
        return self.pending_free.items.len;
    }

    /// Returns the current root (for tests)
    pub fn getRoot(self: *State) u32 {
        return self.root.load(.acquire);
    }

    /// compact: reclaim the currently safe pending pages (all of them with
    /// no readers; incrementally by watermark with readers), then write
    /// meta. T-30: no more "clear the counter only" — dirt always reflects
    /// the true count of still-pinned (unreclaimable) pages.
    pub fn compact(self: *State) !void {
        // Reclaim (dispatched internally by reader_count/watermark; dirt set
        // to the remaining pinned count)
        self.reclaimPendingFree();
        // Write the new meta
        const cur_root = self.root.load(.acquire);
        const cur_sequence = self.sequence.load(.acquire);
        const cur_entry_count = self.entry_count.load(.acquire);
        const cur_byte_size = self.byte_size.load(.acquire);
        const meta = f2.MetaPage{
            .magic = f2.MAGIC_V2,
            .version = 2,
            .mapsize = self.store.mapsize(),
            .sequence = cur_sequence + 1,
            .root_page = cur_root,
            .entry_count = cur_entry_count,
            .byte_size = cur_byte_size,
            // free_head/free_count are placeholders: FilePageStore.vtWriteMeta
            // overrides them with the persisted chain values (same pattern as
            // last_page). MemPageStore has no persistence and keeps them 0.
            .free_head = 0,
            .free_count = 0,
            .last_page = 0,
        };
        try self.store.writeMeta(&meta);
        if (self.opts.fsync) {
            try self.store.sync();
        }
        self.sequence.store(cur_sequence + 1, .release);
        // T-30: dirt is no longer zeroed — reclaimPendingFree already set it
        // to the still-pinned page count
    }

    /// Returns the dirt count (for tests)
    pub fn dirtCount(self: *State) u64 {
        return self.dirt.load(.acquire);
    }

    // ---- Internal ----

    // flushPendingFree (T-33 P0 fix): deleted. The old lock-free full-free
    // checked reader_count OUTSIDE pending_free_mu, leaving a coherence race:
    // a reader whose fetchAdd had not yet propagated could register with the
    // old sequence while the writer's step-0/step-9 flush freed pages that
    // reader's root still referenced (release_seq == seq+1). Both call sites
    // now route through reclaimPendingFree, which re-checks reader_count
    // under the lock (B1: count is incremented before the lock, so any
    // reader visible in real time is visible under the lock) and otherwise
    // reclaims only release_seq < watermark — airtight.

    /// T-30 incremental reclamation of pending pages by oldest-reader
    /// watermark:
    /// - No readers (reader_count==0, re-checked under the lock) -> reclaim
    ///   everything (the old fast path, preserved);
    /// - Readers present -> reclaim pages with release_seq < watermark;
    ///   keep equal or greater (old snapshots may still reference them —
    ///   the correctness floor).
    /// The reader_count check is inside the lock: reader reclamation and
    /// writer appends are mutually excluded via pending_free_mu; only a
    /// count==0 seen under the lock triggers the full reclaim — any reader
    /// registering afterwards has a snapshot >= every pending release_seq
    /// and cannot reference the reclaimed pages.
    fn reclaimPendingFree(self: *State) void {
        self.pending_free_mu.lockUncancelable();
        defer self.pending_free_mu.unlock();
        const prof = ProfileStats.enable;
        const t0 = if (prof) ProfileStats.now() else 0;
        defer if (prof) {
            ProfileStats.txn_flush_free_ns += @intCast(ProfileStats.now() - t0);
        };

        // T-33 P0 fix: watermark = min(oldest active reader, sequence+1).
        // The sequence+1 floor is load-bearing: the commit IN FLIGHT has its
        // COW victims in pending_free with release_seq = sequence+1, and a
        // reader registering right now (seq = sequence, root = tree(sequence))
        // still references those pages. The old count==0 full-free ignored
        // release_seq entirely — a reader's endRead during the in-flight
        // commit (count momentarily 0) handed live pages to the pool, and the
        // next data alloc or chain persist overwrote them mid-descent. With
        // the floor, "no readers" still frees everything with release_seq <=
        // sequence (the old fast path, minus the in-flight hole).
        var watermark = self.sequence.load(.acquire) + 1;
        if (self.reader_count.load(.acquire) > 0) {
            watermark = @min(watermark, self.readerWatermark());
        }
        var keep: usize = 0;
        for (self.pending_free.items) |pp| {
            if (pp.release_seq < watermark) {
                self.store.freePage(pp.page_no);
            } else {
                self.pending_free.items[keep] = pp;
                keep += 1;
            }
        }
        self.pending_free.shrinkRetainingCapacity(keep);
        self.dirt.store(keep, .release);
    }

    /// Oldest-active-reader watermark: the minimum snapshot sequence across
    /// the active-reader set. Empty set -> 0 (a reader is mid-registration,
    /// its seq not yet visible — the conservative floor, pin everything).
    /// Caller must hold pending_free_mu.
    fn readerWatermark(self: *State) u64 {
        var min: u64 = 0;
        var found = false;
        var cur = self.readers_head;
        while (cur) |r| : (cur = r.next_active) {
            if (!found or r.seq < min) {
                min = r.seq;
                found = true;
            }
        }
        return min;
    }

    /// Apply a batch of write requests to the B-tree, commit meta, fsync,
    /// update atomic state
    pub fn applyBatch(self: *State, batch: []const Request) !void {
        if (self.closed.load(.acquire)) {
            for (batch) |r| r.future.set(error.Closed);
            return;
        }

        const prof = ProfileStats.enable;
        const t0 = if (prof) ProfileStats.now() else 0;

        // 0. Grace-period reclamation: if there are no readers right now,
        //    the dirty pages accumulated before this batch can be reclaimed
        //    safely (all are old pages COW'd out by historical commits, held
        //    only by readers that already exited). Mutually excluded with
        //    reader endRead's flush via pending_free_mu (a single
        //    synchronizable mutator).
        if (self.reader_count.load(.acquire) == 0) {
            self.reclaimPendingFree();
        }

        // 1. Snapshot the current root
        const cur_root = self.root.load(.acquire);
        const cur_sequence = self.sequence.load(.acquire);
        const cur_entry_count = self.entry_count.load(.acquire);
        const cur_byte_size = self.byte_size.load(.acquire);

        // 2. Arena for COW path temporary allocations (key/value dupe, Leaf/Branch decode).
        // Eliminates per-allocation syscall overhead: ~145 alloc/free per btree.insert
        // collapses to arena bump-pointer, freed in one shot at batch end.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // Collect dirty pages (arena-backed: btree.insert appends via arena_alloc)
        var batch_dirty = std.ArrayList(u32).empty;
        defer batch_dirty.deinit(arena_alloc);
        var batch_entry_delta: i64 = 0;
        var batch_byte_delta: i64 = 0;
        var new_root = cur_root;

        // Fast path for single entry: use insert directly (avoids sort/dupe/insertBatch overhead)
        if (batch.len == 1) {
            const wr = btree.insert(arena_alloc, self.store, new_root, batch[0].key, batch[0].value, batch[0].tombstone, &batch_dirty) catch |err| {
                for (batch) |r| r.future.set(err);
                return;
            };
            new_root = wr.new_root;
            batch_entry_delta += wr.count_delta;
            batch_byte_delta += wr.live_delta;
        } else {
            // Copy keys/values into arena first (caller slices may not survive — e.g. stack buffer reuse)

        // O(n) order detection: strict (strictly increasing, no dups) /
        // non_dec (non-decreasing, with dups) / unordered
        const t_order0 = if (prof) ProfileStats.now() else 0;
        const Order = enum { strict, non_dec, unordered };
        const order = blk: {
            if (batch.len <= 1) break :blk Order.strict;
            var has_dup = false;
            for (1..batch.len) |i| {
                switch (btree.cmpKey(batch[i - 1].key, batch[i].key)) {
                    .lt => {},
                    .eq => has_dup = true,
                    .gt => break :blk Order.unordered,
                }
            }
            break :blk if (has_dup) Order.non_dec else Order.strict;
        };
        if (prof) ProfileStats.txn_order_ns += @intCast(ProfileStats.now() - t_order0);

        const t_dupe0 = if (prof) ProfileStats.now() else 0;
        const arena_entries = try arena_alloc.alloc(btree.LeafEntry, batch.len);
        if (order != .unordered) {
            // Fast path: ordered input skips dupe + sort, referencing the caller's slices directly
            for (batch, 0..) |req, i| {
                arena_entries[i] = .{ .tombstone = req.tombstone, .key = req.key, .value = req.value };
            }
            if (prof) ProfileStats.txn_dupe_ns += @intCast(ProfileStats.now() - t_dupe0);

            // O(n) dedup (with non-decreasing duplicates, collapse adjacent
            // duplicates; last write wins)
            var n: usize = 0;
            for (arena_entries) |e| {
                if (n > 0 and btree.cmpKey(arena_entries[n - 1].key, e.key) == .eq) {
                    arena_entries[n - 1] = e;
                } else {
                    arena_entries[n] = e;
                    n += 1;
                }
            }
            const entries = arena_entries[0..n];

            const t_ib0 = if (prof) ProfileStats.now() else 0;
            const wr = btree.insertBatch(arena_alloc, self.store, new_root, entries, &batch_dirty) catch |err| {
                for (batch) |r| r.future.set(err);
                return;
            };
            if (prof) ProfileStats.txn_insertbatch_ns += @intCast(ProfileStats.now() - t_ib0);
            new_root = wr.new_root;
            batch_entry_delta += wr.count_delta;
            batch_byte_delta += wr.live_delta;
        } else {
            // Unordered: current path (dupe + sort + dedup)
            // Pre-allocate one contiguous key/value buffer (single
            // allocation), memcpy into it, and sort reading contiguous
            // memory (cache-hot)
            var key_buf_len: usize = 0;
            for (batch) |req| {
                key_buf_len += req.key.len;
                if (!req.tombstone) key_buf_len += req.value.len;
            }
            const key_buf = try arena_alloc.alloc(u8, key_buf_len);
            var key_off: usize = 0;
            for (batch, 0..) |req, i| {
                @memcpy(key_buf[key_off..][0..req.key.len], req.key);
                const k = key_buf[key_off..][0..req.key.len];
                key_off += req.key.len;
                var v: []const u8 = "";
                if (!req.tombstone) {
                    @memcpy(key_buf[key_off..][0..req.value.len], req.value);
                    v = key_buf[key_off..][0..req.value.len];
                    key_off += req.value.len;
                }
                arena_entries[i] = .{ .tombstone = req.tombstone, .key = k, .value = v };
            }
            if (prof) ProfileStats.txn_dupe_ns += @intCast(ProfileStats.now() - t_dupe0);

            // Sort by key
            const t_sort0 = if (prof) ProfileStats.now() else 0;
            if (arena_entries.len > 1) {
                const SortCtx = struct {
                    fn lt(_: void, a: btree.LeafEntry, b: btree.LeafEntry) bool {
                        return btree.cmpKey(a.key, b.key) == .lt;
                    }
                };
                std.mem.sort(btree.LeafEntry, arena_entries, {}, SortCtx.lt);
            }
            if (prof) ProfileStats.txn_sort_ns += @intCast(ProfileStats.now() - t_sort0);

            // Dedup (last write wins)
            const t_dedup0 = if (prof) ProfileStats.now() else 0;
            var n: usize = 0;
            for (arena_entries) |e| {
                if (n > 0 and btree.cmpKey(arena_entries[n - 1].key, e.key) == .eq) {
                    arena_entries[n - 1] = e;
                } else {
                    arena_entries[n] = e;
                    n += 1;
                }
            }
            const entries = arena_entries[0..n];
            if (prof) ProfileStats.txn_dedup_ns += @intCast(ProfileStats.now() - t_dedup0);

            const t_ib0 = if (prof) ProfileStats.now() else 0;
            const wr = btree.insertBatch(arena_alloc, self.store, new_root, entries, &batch_dirty) catch |err| {
                for (batch) |r| r.future.set(err);
                return;
            };
            if (prof) ProfileStats.txn_insertbatch_ns += @intCast(ProfileStats.now() - t_ib0);
            new_root = wr.new_root;
            batch_entry_delta += wr.count_delta;
            batch_byte_delta += wr.live_delta;
        } // end unordered path
        } // end else (batch.len > 1)

        // 3. This batch's dirty pages go into pending_free (not reclaimed
        //    immediately — MVCC safe). Take pending_free_mu, serializing
        //    against the concurrent mutation by reader reclamation (UB fix).
        const t_pf0 = if (prof) ProfileStats.now() else 0;
        {
            self.pending_free_mu.lockUncancelable();
            defer self.pending_free_mu.unlock();
            for (batch_dirty.items) |pn| {
                // T-30: carry the release sequence (this commit's
                // new_sequence = cur_sequence+1). The page belongs to the
                // tree as of cur_sequence; readers with snapshot >=
                // new_sequence cannot reference it (it is not in the tree
                // after the new_sequence commit).
                self.pending_free.append(self.allocator, .{ .page_no = pn, .release_seq = cur_sequence + 1 }) catch {};
            }
            // T-30: dirt is updated under the lock together with the append
            // (mutually excluded with the reader thread's incremental
            // reclamation, avoiding overwriting its result; the old step-7
            // unlocked store moved here)
            self.dirt.store(@intCast(self.pending_free.items.len), .release);
        }
        if (prof) ProfileStats.txn_pending_free_ns += @intCast(ProfileStats.now() - t_pf0);

        // 4. Compute the new meta values
        const new_sequence = cur_sequence + 1;
        const new_entry_count_signed: i64 = @as(i64, @intCast(cur_entry_count)) + batch_entry_delta;
        const new_entry_count: u64 = @intCast(@max(@as(i64, 0), new_entry_count_signed));
        const new_byte_signed: i64 = @as(i64, @intCast(cur_byte_size)) + batch_byte_delta;
        const new_byte: u64 = @intCast(@max(@as(i64, 0), new_byte_signed));

        // 5. Write meta
        const t_meta0 = if (prof) ProfileStats.now() else 0;
        const meta = f2.MetaPage{
            .magic = f2.MAGIC_V2,
            .version = 2,
            .mapsize = self.store.mapsize(),
            .sequence = new_sequence,
            .root_page = new_root,
            .entry_count = new_entry_count,
            .byte_size = new_byte,
            // free_head/free_count are placeholders: FilePageStore.vtWriteMeta
            // overrides them with the persisted chain values (same pattern as
            // last_page). MemPageStore has no persistence and keeps them 0.
            .free_head = 0,
            .free_count = 0,
            .last_page = 0,
        };
        // T-27 commit ordering: under power_fail, flush this batch's data
        // pages to stable storage (fdatasync semantics) before writing meta,
        // guaranteeing that at the moment the meta commit becomes durable,
        // the data pages it points to have already landed (or land at the
        // latest simultaneously) — power loss can never recover a root
        // pointing at dangling pages. The process_crash level keeps the old
        // behavior (no pre-flush needed under the page-cache-intact
        // process-crash model).
        if (self.opts.durability == .power_fail) {
            try self.store.syncDataPages();
        }
        try self.store.writeMeta(&meta);

        // 6. fsync (meta to disk). power_fail syncs unconditionally (every
        // commit is a double sync: data pages first, meta after — see the
        // Durability notes above); fsync=false only makes sense for
        // process_crash (async durability, the user calls Db.sync() manually).
        if (self.opts.fsync or self.opts.durability == .power_fail) {
            try self.store.sync();
        }
        if (prof) ProfileStats.txn_meta_ns += @intCast(ProfileStats.now() - t_meta0);

        // 7. Atomically update state (dirt was already updated with the
        // append under the lock in step 3)
        self.root.store(new_root, .release);
        self.sequence.store(new_sequence, .release);
        self.entry_count.store(new_entry_count, .release);
        self.byte_size.store(new_byte, .release);

        // 8. All requests succeeded
        for (batch) |req| {
            req.future.set({});
        }

        // 9. If there are no readers at this point, reclaim dirty pages immediately

        if (self.reader_count.load(.acquire) == 0) {
            self.reclaimPendingFree();
        }

        if (prof) {
            ProfileStats.txn_total_ns += @intCast(ProfileStats.now() - t0);
            ProfileStats.txn_count += 1;
            ProfileStats.txn_entries += batch.len;
        }
    }
};

test "writer: State init defaults" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 100);
    defer ms.deinit();
    var state = State.init(std.testing.allocator, ms.store(), .{});
    defer state.deinit();
    try std.testing.expectEqual(btree.NULL_ROOT, state.root.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.sequence.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.dirt.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.entry_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), state.byte_size.load(.acquire));
}

//! writer.zig — v2 batch apply: COW B-tree (btree), freelist reclamation (MVCC-safe), alternating meta commit
const std = @import("std");
const zio = @import("zio");
const f2 = @import("format.zig");
const ps = @import("page_store.zig");
const btree = @import("btree.zig");

const PageStore = ps.PageStore;

// ---- T-30: per-reader sequence registration + oldest-reader watermark precise reclamation ----

/// pending_free entry: page number + the sequence of the commit that freed it
/// (that commit's new_sequence).
/// Reclamation rule: safe to reclaim when release_seq < the oldest-active-reader
/// watermark (every active reader snapshot is >= watermark > release_seq, so
/// nobody can still reference the page); equal or greater must be kept (old
/// snapshots remain valid — the correctness floor, conservatively including
/// the boundary).
pub const PendingPage = struct {
    page_no: u32,
    release_seq: u64,
};

/// Per-reader snapshot registration slots. When exceeded (concurrent readers
/// > 64, or TLS nesting overflow), degrade conservatively to watermark=0
/// (pin everything = the old global-count behavior) — safe but imprecise.
const READER_SLOTS = 64;
/// Max beginRead nesting depth per thread (ReadTxn + select nesting etc.;
/// realistically <= 3).
const MAX_TLS_READERS = 16;
/// Slot value encoding: 0 = free; non-zero = snapshot | CLAIM_BIT (the
/// snapshot sequence occupies everything below the top bit).
const CLAIM_BIT: u64 = 1 << 63;

/// Thread-local registration stack: beginRead/endRead pair up LIFO within a
/// thread (all current callers — ReadTxn/Iterator pin/tests — begin and end
/// on the same thread; that contract is unchanged).
/// endRead() takes no argument (db.zig must not change), so pairing identity
/// = (State pointer, LIFO).
const TlsEntry = struct {
    state: *const anyopaque,
    slot: u32, // READER_SLOTS = overflow registration (not a slot)
};
threadlocal var tls_readers: [MAX_TLS_READERS]TlsEntry = undefined;
threadlocal var tls_readers_len: usize = 0;

/// Claim a reader snapshot slot (called by beginRead before reading
/// sequence — the B1 invariant).
/// The claimed value = sentinel snapshot 0 (CLAIM_BIT): until the real
/// snapshot is published, watermark sees 0 -> pin everything — no page is
/// released within the claim-to-publish window. Returns the slot index;
/// slots exhausted or TLS stack full -> READER_SLOTS (overflow registration,
/// which watermark likewise treats as 0).
fn claimReaderSlot(self: *State) u32 {
    if (tls_readers_len < MAX_TLS_READERS) {
        var i: usize = 0;
        while (i < READER_SLOTS) {
            if (self.reader_slots[i].load(.acquire) != 0) {
                i += 1;
                continue;
            }
            // m2: cmpxchgWeak may fail spuriously — retry the same slot on
            // failure (reload to re-check busyness) instead of skipping a
            // still-free slot.
            if (self.reader_slots[i].cmpxchgWeak(0, CLAIM_BIT, .acq_rel, .acquire) == null) {
                tls_readers[tls_readers_len] = .{ .state = @ptrCast(self), .slot = @intCast(i) };
                tls_readers_len += 1;
                return @intCast(i);
            }
        }
    }
    // Slots exhausted (or TLS stack full): overflow registration. M1:
    // acq_rel RMW — paired with readerWatermark's acquire read, so once the
    // watermark sees the registration there is a happens-before edge; when
    // there are readers but no visible slots, the watermark already returns
    // 0 conservatively (pin everything), so overflow readers are always
    // covered. When the stack is full, nothing is pushed — matching endRead's
    // saturating decrement when the stack is full and the top doesn't match.
    _ = self.overflow_readers.fetchAdd(1, .acq_rel);
    if (tls_readers_len < MAX_TLS_READERS) {
        tls_readers[tls_readers_len] = .{ .state = @ptrCast(self), .slot = READER_SLOTS };
        tls_readers_len += 1;
    }
    return READER_SLOTS;
}

/// Saturating decrement of the overflow reader count (m1: no wraparound).
/// An under-paired decrement only inflates the count -> watermark=0 pins
/// everything, the safe direction; a u32 wraparound would pin everything
/// permanently and must be avoided.
fn saturatingOverflowDec(self: *State) void {
    while (true) {
        const cur = self.overflow_readers.load(.acquire);
        if (cur == 0) return; // under-paired decrement: conservatively don't (inflated count = over-pinning, safe)
        if (self.overflow_readers.cmpxchgWeak(cur, cur - 1, .acq_rel, .acquire) == null) return;
    }
}

/// Pop the TLS stack top and unregister it (slot back to 0 / saturating
/// decrement of the overflow count).
fn popTopTlsEntry(self: *State) void {
    const entry = tls_readers[tls_readers_len - 1];
    tls_readers_len -= 1;
    if (entry.slot < READER_SLOTS) {
        self.reader_slots[entry.slot].store(0, .release);
    } else {
        saturatingOverflowDec(self);
    }
}

/// Unregister a reader registration (called by endRead). Pairing: with a
/// non-full stack, find this State's most recent registration (LIFO within
/// the same State; cross-State out-of-order nesting matches exactly by State
/// pointer).
/// Not found (cross-thread end / misuse), or stack full with a non-matching
/// top -> saturating decrement of the overflow count (m1: no wraparound; an
/// inflated count = watermark 0 = pin everything — the failure direction is
/// always the safe side).
/// ponytail: beyond MAX_TLS_READERS(16)-deep same-thread nesting, unpushed
/// overflow registrations cannot be paired precisely (when the stack is full
/// and the top matches, popping could pop an earlier own registration) —
/// real nesting in this codebase is <=3 (ReadTxn+select), 16 deep is
/// unreachable; to support it, upgrade to an explicit reader handle API
/// (requires changing the db.zig interface).
fn unregisterReaderSlot(self: *State) void {
    if (tls_readers_len == MAX_TLS_READERS) {
        // m1: when the stack is full and the top belongs to this State, pop
        // for an exact unregister (removes the stickiness: otherwise every
        // endRead after the stack fills takes the conservative branch and
        // never pops, and the overflow count gets wrongly decremented into
        // wraparound); non-matching top -> this end pairs with an unpushed
        // overflow registration, decrement saturatingly.
        if (tls_readers[tls_readers_len - 1].state == @as(*const anyopaque, @ptrCast(self))) {
            popTopTlsEntry(self);
            return;
        }
        saturatingOverflowDec(self);
        return;
    }
    var i = tls_readers_len;
    while (i > 0) {
        i -= 1;
        if (tls_readers[i].state == @as(*const anyopaque, @ptrCast(self))) {
            const entry = tls_readers[i];
            // swap-remove: what is removed is this State's latest
            // registration; the relative LIFO order of this State's remaining
            // entries is preserved (only other States' entries can sit
            // in between).
            tls_readers[i] = tls_readers[tls_readers_len - 1];
            tls_readers_len -= 1;
            if (entry.slot < READER_SLOTS) {
                self.reader_slots[entry.slot].store(0, .release);
            } else {
                saturatingOverflowDec(self);
            }
            return;
        }
    }
    // No registration record for this State on this thread (cross-thread
    // end / misuse) -> saturating decrement of the overflow count
    saturatingOverflowDec(self);
}

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

    /// T-30 per-reader snapshot registration slots: 0 = free; non-zero =
    /// snapshot|CLAIM_BIT. watermark = the minimum snapshot across active
    /// slots, driving incremental precise reclamation of pending_free.
    reader_slots: [READER_SLOTS]std.atomic.Value(u64),
    /// Readers beyond the slots / unregistrable (>0 -> watermark treated as
    /// 0, conservatively pinning everything = the old behavior)
    overflow_readers: std.atomic.Value(u32),

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
            .reader_slots = @splat(std.atomic.Value(u64).init(0)),
            .overflow_readers = std.atomic.Value(u32).init(0),
            .pending_free = .empty,
            .pending_free_mu = .{},
        };
    }

    pub fn deinit(self: *State) void {
        self.closed.store(true, .release);
        // Free the remaining pending_free (safe: writer thread done, no readers)
        for (self.pending_free.items) |pp| self.store.freePage(pp.page_no);
        self.pending_free.deinit(self.allocator);
    }

    // ---- MVCC reader API ----

    /// Begin a read txn. Returns the current sequence (for a consistent
    /// read snapshot).
    /// T-30 + B1 invariant: claim (sentinel snapshot 0) -> read sequence ->
    /// publish the real snapshot. Within the claim-to-publish window,
    /// watermark sees snapshot 0 -> pin everything; after the publish
    /// (release store), any watermark computation sees either the sentinel
    /// or the real snapshot, always <= this reader's snapshot — an active
    /// snapshot can never reference a reclaimed page. Registration happens
    /// before returning; the caller then captures the root snapshot, and
    /// whichever root it sees, its COW old pages stay in pending_free until
    /// the watermark releases them.
    pub fn beginRead(self: *State) u64 {
        _ = self.reader_count.fetchAdd(1, .acquire);
        const slot = claimReaderSlot(self); // claim first (sentinel 0), then read sequence
        const seq = self.sequence.load(.acquire);
        if (slot < READER_SLOTS) {
            self.reader_slots[slot].store(seq | CLAIM_BIT, .release);
        }
        return seq;
    }

    /// End a read txn. T-30: unregisters this reader's snapshot and
    /// immediately reclaims the now-safe pending pages by oldest-reader
    /// watermark — a short-lived reader's exit releases its pinned pages
    /// without waiting for the last reader; the last reader's exit
    /// (reader_count reaching 0) still reclaims everything (the existing
    /// fast-path semantics preserved). With no backlog (dirt==0) this is
    /// just two atomics and no lock — the reader hot path never degrades
    /// into a lock.
    pub fn endRead(self: *State) void {
        _ = self.reader_count.fetchSub(1, .release);
        unregisterReaderSlot(self);
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

    /// Reclaim all of pending_free: does *not* check reader_count (the
    /// caller guarantees safety: applyBatch's reader_count==0 fast path, a
    /// single-writer context).
    /// Takes pending_free_mu, serializing writer and reader incremental
    /// reclamation mutations of the list.
    fn flushPendingFree(self: *State) void {
        self.pending_free_mu.lockUncancelable();
        defer self.pending_free_mu.unlock();
        const prof = ProfileStats.enable;
        const t0 = if (prof) ProfileStats.now() else 0;
        for (self.pending_free.items) |pp| {
            self.store.freePage(pp.page_no);
        }
        self.pending_free.clearRetainingCapacity();
        self.dirt.store(0, .release);
        if (prof) ProfileStats.txn_flush_free_ns += @intCast(ProfileStats.now() - t0);
    }

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

        if (self.reader_count.load(.acquire) == 0) {
            for (self.pending_free.items) |pp| self.store.freePage(pp.page_no);
            self.pending_free.clearRetainingCapacity();
            self.dirt.store(0, .release);
            return;
        }
        const watermark = self.readerWatermark();
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
    /// active readers. Returning 0 = the conservative floor (overflow
    /// readers / readers present but snapshot not yet visible) -> pin
    /// everything.
    fn readerWatermark(self: *State) u64 {
        if (self.overflow_readers.load(.acquire) > 0) return 0;
        var min: u64 = 0;
        var found = false;
        for (&self.reader_slots) |*slot| {
            const v = slot.load(.acquire);
            if (v == 0) continue;
            const snap = v & ~CLAIM_BIT;
            if (!found or snap < min) {
                min = snap;
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
            self.flushPendingFree();
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
            self.flushPendingFree();
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

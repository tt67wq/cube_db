//! compact.zig — compactFull copy kernel (U5-5, design `bb4d489` §7 step 3).
//!
//! Rewrites the OLD root's visible entry set into a brand-new tree + pages
//! and returns the result to the caller: {new_root, entries_copied,
//! live_bytes, retired_pages, new_pages}. This module performs NO publish
//! work — no meta write, no root/tomb swap, no pending_free enqueue, no
//! sequence bump (those are step 4 / U5-6). The caller owns both lists.
//!
//! Streaming shape (design §2.1–§2.3):
//!   - visible stream = `Db.select(null, null)` (tombstone entries skipped by
//!     the iterator; range-tombstone shadowing filtered by the select's skip
//!     hook) — the copy is exactly "the visible set";
//!   - each batch materializes the iterator's borrowed slices into an arena,
//!     flushed when EITHER budget trips: count > 256 (deleteRange's CHUNK
//!     precedent) or payload > 256KB (T-40: never chunk by count alone — a
//!     single oversized entry rides the overflow chain and lands as its own
//!     tail batch);
//!   - `btree.insertBatch` builds the new tree from the current new root;
//!     pages it allocates are accumulated in `new_pages` (abort cleanup and
//!     step-4 accounting share this list);
//!   - retirement (design §2.1 ⑦ / §3.1, review 3c3e2a0 N-2): the OLD tree
//!     pages via `btree.collectTreePages` PLUS the old tomb-chain pages
//!     walked from the captured `tomb_head` via `free_next` — design §2.4:
//!     the whole chain is DROPPED on publish (the new tree holds no shadowed
//!     entries, so tomb_head=0 is the correct published state), and old
//!     readers stay safe because these pages are only retired by the caller's
//!     publish path (queuePendingFree + watermark), never freed here.
//!
//! Abort (design §2.5): the progress callback (when supplied) runs after
//! EVERY batch; returning false frees every page the kernel allocated
//! (`new_pages`) back to the store and returns error.CompactAborted with the
//! old db untouched (nothing was published, nothing referenced was freed).
//!
//! This module does NOT touch writer/db state — it reads `db.select` and
//! `db.state.getTombHead()` only. All publication decisions stay in step 4.

const std = @import("std");
const btree = @import("btree.zig");
const db_mod = @import("db.zig");
const page_store = @import("page_store.zig");
const format = @import("format.zig");

const Db = db_mod.Db;
const PageStore = page_store.PageStore;
const LeafEntry = btree.LeafEntry;

/// The kernel's error surface: CompactAborted (progress cancel) plus every
/// store/iterator/allocator error reachable from select/insertBatch/
/// collectTreePages (whose inferred sets vary by call path — surfaced as
/// anyerror!Result for step-4 wiring simplicity).

pub const Options = struct {
    /// Called after each batch: (entries_copied_so_far, batches_done, user).
    /// Return false to abort (error.CompactAborted, pages returned).
    progress: ?*const fn (copied: u64, batches: u64, user: ?*anyopaque) bool = null,
    /// Opaque user pointer passed to `progress`.
    progress_user: ?*anyopaque = null,
    /// Batch budgets (design §2.3 defaults; shrinkable for tests).
    batch_max_entries: usize = 256,
    batch_max_bytes: usize = 256 * 1024,
};

pub const Result = struct {
    /// Root of the freshly built tree (0 when the visible set was empty).
    new_root: u32,
    /// Visible entries copied (== the new tree's entry count).
    entries_copied: u64,
    /// Σ(key.len + value.len + 10) over the copied set (B formula,
    /// db.zig streaming-count convention).
    live_bytes: u64,
    /// Pages the PUBLISH path (step 4) must retire: old tree pages
    /// (collectTreePages) ∪ old tomb-chain pages. Deduped; caller frees.
    /// NOT freed by this module — the old tree stays reader-reachable until
    /// the caller publishes (design §3.1).
    retired_pages: []u32,
    /// Every page of the freshly built tree, deduped (collectTreePages of
    /// new_root at return). Does NOT include intra-build victims: pages
    /// superseded during construction were already returned to the pool by
    /// the kernel before this Result exists. Caller frees.
    new_pages: []u32,
    /// Batches written.
    batches: u64,
};

/// Walk the old tomb chain from `head`, collecting every chain page into
/// `seen` (dedup guard: first revisit → error.Truncated, T-52 discipline —
/// the same rule as walkTombChain/collectTreePages).
fn collectChainPages(store: PageStore, head: u32, seen: *std.AutoHashMap(u32, void)) !void {
    var cur = head;
    while (cur != 0) {
        const gop = try seen.getOrPut(cur);
        if (gop.found_existing) return error.Truncated; // cycle: bounded stop (T-52)
        const page = try store.readPage(cur);
        const hdr = format.decodePageHeader(page[0..format.PAGE_HEADER_SIZE]);
        cur = hdr.free_next;
    }
}

const Flush = struct {
    /// Write one staged batch into the new tree. Returns the payload bytes
    /// (key+value) flushed — caller folds +10/entry into live_bytes.
    fn flush(
        alloc: std.mem.Allocator,
        batch: *std.ArrayList(LeafEntry),
        new_pages: *std.ArrayList(u32),
        new_root: *u32,
        store: PageStore,
        entries_copied: *u64,
        live_bytes: *u64,
        batches: *u64,
    ) !usize {
        if (batch.items.len == 0) return 0;
        const wr = try btree.insertBatch(alloc, store, new_root.*, batch.items, new_pages);
        new_root.* = wr.new_root;
        entries_copied.* += batch.items.len;
        batches.* += 1;
        var payload: usize = 0;
        for (batch.items) |e| {
            payload += e.key.len + e.value.len;
            live_bytes.* += @intCast(e.key.len + e.value.len + 10); // B formula
        }
        batch.clearRetainingCapacity();
        return payload;
    }
};

pub fn run(db: *Db, alloc: std.mem.Allocator, opts: Options) anyerror!Result {
    var batches: u64 = 0;

    // Freeze the source snapshot up front. The caller (step 4) is responsible
    // for single-writer serialization + flush-before-copy; this module only
    // reads, so a consistent capture is all it needs. Nothing here publishes.
    const old_root = db.getRoot();
    const old_tomb_head = db.state.getTombHead();

    // Design §2.1 ④ / §8: empty db → zero-work empty result.
    if (old_root == 0 and old_tomb_head == 0) {
        return .{
            .new_root = 0,
            .entries_copied = 0,
            .live_bytes = 0,
            .retired_pages = &.{},
            .new_pages = &.{},
            .batches = 0,
        };
    }

    // Retirement plan (§2.1 ⑦ / §3.1 / review 3c3e2a0 N-2): old tree pages ∪
    // old tomb-chain pages. collectTreePages covers tree + overflow chains;
    // the tomb chain is walked separately — design §2.4 drops the whole chain
    // on publish (new tree holds no shadowed entries), and §3.1 keeps the old
    // tree reader-safe until the caller's queuePendingFree + watermark.
    var retired: std.ArrayList(u32) = .empty;
    errdefer retired.deinit(alloc);
    {
        // Single dedup pass: tree pages first, then chain pages — retired is
        // built FROM the seen-set so each page appears exactly once (F1: the
        // list is the publish path's direct input; MemPageStore.freePage has
        // no pool-side dedup, a duplicate entry would double-enqueue).
        var seen = std.AutoHashMap(u32, void).init(alloc);
        defer seen.deinit();
        try btree.collectTreePages(alloc, db.store, old_root, &retired);
        for (retired.items) |p| try seen.put(p, {});
        try collectChainPages(db.store, old_tomb_head, &seen);
        retired.clearRetainingCapacity();
        var kit = seen.keyIterator();
        while (kit.next()) |kp| try retired.append(alloc, kp.*);
    }

    // Pages made garbage WITHIN the new-tree build (insertBatch's dirty list:
    // split/rewrite victims — never part of the old tree, never visible to any
    // reader). The kernel returns them to the pool on abort; on success they
    // are freed immediately (nothing can reference them pre-publish).
    var build_victims: std.ArrayList(u32) = .empty;
    defer build_victims.deinit(alloc);
    // The new tree's page set (authoritative enumeration happens at the end
    // via collectTreePages — insertBatch's dirty list is victims, not all
    // allocations). Empty on abort (all pages returned to the pool).
    var new_pages: std.ArrayList(u32) = .empty;
    errdefer new_pages.deinit(alloc);

    var new_root: u32 = 0;
    var entries_copied: u64 = 0;
    var live_bytes: u64 = 0;

    // Visible-entry stream (§2.2): tombstone entries are skipped by the
    // iterator itself; range-shadowed entries by the select's skip hook.
    // The kernel holds NO locks (the caller serializes writers) and NO
    // publication state — it is a pure reader + tree builder.
    var txn = try db.beginReadTxn();
    defer txn.end();
    var it = try txn.select(null, null);
    defer it.deinit();

    // Batch staging (§2.3): count + payload double budget. Borrowed slices
    // are duped into the arena (iterator values die on next()); insertBatch
    // copies into pages, then the arena resets for the next batch.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var batch: std.ArrayList(LeafEntry) = .empty;
    defer batch.deinit(alloc);
    var batch_payload: usize = 0;

    while (try it.next()) |e| {
        const aa = arena.allocator();
        const k = try aa.dupe(u8, e.key);
        const v = try aa.dupe(u8, e.value);
        try batch.append(alloc, .{ .key = k, .value = v, .tombstone = false });

        const next_payload = batch_payload + k.len + v.len;
        const count_trips = batch.items.len >= opts.batch_max_entries;
        const bytes_trips = next_payload >= opts.batch_max_bytes;
        if (count_trips or bytes_trips) {
            _ = try Flush.flush(alloc, &batch, &build_victims, &new_root, db.store, &entries_copied, &live_bytes, &batches);
            batch_payload = 0;
            _ = arena.reset(.retain_capacity);
            // progress callback after EVERY batch (§2.1 ⑥): false → abort (§2.5)
            if (opts.progress) |cb| {
                if (!cb(entries_copied, batches, opts.progress_user)) {
                    // §2.5 abort: return every page the build touched —
                    // reachable new-tree pages AND intra-build victims. Both
                    // sets are invisible to readers (nothing published).
                    // Dedup: MemPageStore.freePage is a plain append (no
                    // pool_set mirror like FilePageStore), so a page in both
                    // sets would be double-listed → double allocation later.
                    var touched = std.AutoHashMap(u32, void).init(alloc);
                    defer touched.deinit();
                    var reachable: std.ArrayList(u32) = .empty;
                    defer reachable.deinit(alloc);
                    try btree.collectTreePages(alloc, db.store, new_root, &reachable);
                    for (reachable.items) |p| try touched.put(p, {});
                    for (build_victims.items) |p| try touched.put(p, {});
                    var tit = touched.keyIterator();
                    while (tit.next()) |kp| db.store.freePage(kp.*);
                    // lists stay alive for the defers; just emptied logically
                    new_pages.clearRetainingCapacity();
                    retired.clearRetainingCapacity();
                    return error.CompactAborted;
                }
            }
        } else {
            batch_payload = next_payload;
        }
    }
    // tail batch (§2.3: a single entry larger than the payload budget lands
    // alone here — insertBatch routes big values to fresh overflow chains)
    _ = try Flush.flush(alloc, &batch, &build_victims, &new_root, db.store, &entries_copied, &live_bytes, &batches);

    // Success: enumerate the new tree's pages (insertBatch's dirty list is
    // victims, not allocations — collectTreePages is the authoritative set).
    try btree.collectTreePages(alloc, db.store, new_root, &new_pages);
    // Intra-build victims go back to the pool right away: they were allocated
    // and superseded inside this build, invisible to every reader (nothing
    // published), and pool persistence follows the normal commit path.
    // (No dedup needed here: victims and the final tree are disjoint by
    // construction — a victimized page is by definition no longer reachable.)
    for (build_victims.items) |p| db.store.freePage(p);

    return .{
        .new_root = new_root,
        .entries_copied = entries_copied,
        .live_bytes = live_bytes,
        .retired_pages = try retired.toOwnedSlice(alloc),
        .new_pages = try new_pages.toOwnedSlice(alloc),
        .batches = batches,
    };
}

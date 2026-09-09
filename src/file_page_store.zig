//! file_page_store.zig — file-backed page store (LMDB-style 1TB reserved mmap region)
//!
//! On open, mmaps a 1TB MAP_SHARED reserved virtual region (scheme I;
//! spike_mmap.zig verified this works on macOS). The file grows via ftruncate
//! on demand; readers see new data through the same mmap pointer — no SIGBUS,
//! no re-mmap. The write path keeps the PageStore page interface
//! (allocPage/freePage/writePage); the read path is zero-copy via the mmap pointer.
const std = @import("std");
const f2 = @import("format.zig");
const ps = @import("page_store.zig");
const zio = @import("zio");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("errno.h"); // T-34: EWOULDBLOCK/EAGAIN for the flock error path
    @cInclude("sys/file.h"); // T-34: flock()/LOCK_* — Linux defines these here, not in fcntl.h
});

const PAGE_SIZE = f2.PAGE_SIZE;

/// 1 TB reserved virtual region (LMDB-style placeholder; 64-bit address space is plentiful)
pub const REGION_SIZE: u64 = 1 << 40;

/// #41 FPS write-path counters (profile toggle, off the production hot path)
pub const FpsCounters = struct {
    pub var enable: bool = false;
    pub var write_page_calls: u64 = 0;
    pub var alloc_page_calls: u64 = 0;
    pub var free_page_calls: u64 = 0;
    pub var read_page_calls: u64 = 0;
    pub var fstat_calls: u64 = 0;
    pub var ftruncate_calls: u64 = 0;
    pub var write_page_ns: u64 = 0;
    pub var alloc_page_ns: u64 = 0;
    pub var ensure_growth_ns: u64 = 0;

    pub fn reset() void {
        write_page_calls = 0;
        alloc_page_calls = 0;
        free_page_calls = 0;
        read_page_calls = 0;
        fstat_calls = 0;
        ftruncate_calls = 0;
        write_page_ns = 0;
        alloc_page_ns = 0;
        ensure_growth_ns = 0;
    }

    pub fn now() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
    }
};

pub const FilePageStore = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    region_size: u64,
    mmap_ptr: [*]u8,
    freelist: std.ArrayList(u32),
    next_free: u32,
    meta_index: u32,
    meta0: [PAGE_SIZE]u8,
    meta1: [PAGE_SIZE]u8,
    /// T-33 step 0 (P0): guards freelist / next_free / chain_cur / chain_prev.
    /// Reader threads reach freePage via endRead -> reclaimPendingFree while the
    /// writer thread pops in allocPage — MemPageStore has this lock, FilePageStore
    /// must mirror it. Lock order repo-wide: pending_free_mu -> freelist_mu only.
    freelist_mu: zio.Mutex = .{},
    /// T-33: chain pages referenced by the current durable meta (two-generation
    /// retirement: these are retired to the pool by the *next* writeMeta after a
    /// newer meta lands, so any crash point leaves the winning meta's chain intact).
    chain_cur: std.ArrayList(u32) = .empty,
    /// Chain pages of the previous generation (dead once the current meta landed).
    chain_prev: std.ArrayList(u32) = .empty,
    /// True when open-time chain restore rejected the persisted freelist (INV-F2:
    /// leak, never mis-reclaim). Written once in init, read-only afterwards.
    free_list_discarded: bool = false,

    /// T-33(T5): crash-injection points of the commit write-order matrix.
    pub const CrashTag = enum { before_chain, mid_chain, after_chain_before_meta, after_meta };

    /// Test-only crash injection (T5): the forked child arms a tag; the commit
    /// path aborts the process when the matching point is reached. Always null
    /// in production (one predictable cold branch per fire point).
    pub var test_crash_hook: ?CrashTag = null;

    /// Open (or create) path and mmap the 1TB reserved region. The file grows on demand.
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !FilePageStore {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const fd = c.open(path_z, @as(c_int, c.O_RDWR | c.O_CREAT), @as(c.mode_t, 0o644));
        if (fd < 0) return error.OpenFailed;

        // T-34: advisory exclusive lock — one writer process per file.
        // flock binds to the open file description: a second open (any process,
        // or the same process via a different fd) fails with EWOULDBLOCK.
        // fork'd children inheriting this fd share the OFD and never self-conflict;
        // the lock releases when the LAST fd of the OFD closes (deinit's c.close
        // suffices, crash included). NFS: flock semantics not guaranteed — local
        // filesystems only (documented in usage.md).
        if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) {
            const errno: *c_int = std.c._errno();
            if (errno.* == c.EWOULDBLOCK or errno.* == c.EAGAIN) {
                _ = c.close(fd);
                return error.FileLocked;
            }
            // other flock failures (EBADF/EINTR/ENOLCK...): treat as open failure
            _ = c.close(fd);
            return error.OpenFailed;
        }

        // Initial file must cover at least meta0 + meta1 (3 pages)
        var st: c.struct_stat = undefined;
        if (c.fstat(fd, &st) != 0) {
            _ = c.close(fd);
            return error.FstatFailed;
        }
        const min_size: u64 = @as(u64, ps.FIRST_DATA_PAGE) * PAGE_SIZE;
        if (@as(u64, @intCast(st.st_size)) < min_size) {
            if (c.ftruncate(fd, @as(c.off_t, @intCast(min_size))) != 0) {
                _ = c.close(fd);
                return error.TruncateFailed;
            }
        }

        // mmap the 1TB MAP_SHARED reserved region
        const ptr = c.mmap(null, REGION_SIZE, @as(c_int, c.PROT_READ) | @as(c_int, c.PROT_WRITE), @as(c_int, c.MAP_SHARED), fd, 0);
        if (ptr == c.MAP_FAILED) {
            _ = c.close(fd);
            return error.MapFailed;
        }

        var fps: FilePageStore = .{
            .allocator = allocator,
            .fd = fd,
            .region_size = REGION_SIZE,
            .mmap_ptr = @ptrCast(ptr),
            .freelist = .empty,
            .next_free = ps.FIRST_DATA_PAGE,
            .meta_index = 0,
            .meta0 = [_]u8{0} ** PAGE_SIZE,
            .meta1 = [_]u8{0} ** PAGE_SIZE,
        };

        // Load the meta buffers from the mmap region, then try to recover
        // next_free and meta_index
        @memcpy(fps.meta0[0..PAGE_SIZE], fps.pagePtr(f2.META_PAGE_0)[0..PAGE_SIZE]);
        @memcpy(fps.meta1[0..PAGE_SIZE], fps.pagePtr(f2.META_PAGE_1)[0..PAGE_SIZE]);
        // Determine which meta page is active (higher sequence) and set meta_index
        // to write the OTHER page next (alternating write for crash safety)
        const m0 = f2.readMetaPageSingle(&fps.meta0);
        const m1 = f2.readMetaPageSingle(&fps.meta1);
        if (m0 != null and m1 != null) {
            // Both valid: active page is the one with higher sequence;
            // meta_index should point to the inactive (older) page to overwrite next
            if (m0.?.sequence >= m1.?.sequence) {
                // meta0 is active (was last written with meta_index=0), so next write goes to meta1
                fps.meta_index = 1;
                fps.next_free = @max(fps.next_free, m0.?.last_page + 1);
            } else {
                // meta1 is active (was last written with meta_index=1), so next write goes to meta0
                fps.meta_index = 0;
                fps.next_free = @max(fps.next_free, m1.?.last_page + 1);
            }
        } else if (m0 != null) {
            fps.meta_index = 1; // only meta0 valid, next write to meta1
            fps.next_free = @max(fps.next_free, m0.?.last_page + 1);
        } else if (m1 != null) {
            fps.meta_index = 0; // only meta1 valid, next write to meta0
            fps.next_free = @max(fps.next_free, m1.?.last_page + 1);
        }
        // else: both null (fresh DB), meta_index stays 0, next_free stays FIRST_DATA_PAGE

        // T-33: freelist restore gate. Chain pages live inside mmap; reading one
        // beyond EOF is a SIGBUS, not an error code — grow the file to cover
        // last_page BEFORE walking the chain. Never shrink: needed is clamped to
        // min_size and compared against the ORIGINAL st_size. On ftruncate
        // failure skip the restore entirely (chain discarded = leak direction,
        // the DB itself still opens and stays writable via bump allocation).
        const active: ?f2.MetaPage = if (m0 != null and m1 != null)
            (if (m0.?.sequence >= m1.?.sequence) m0 else m1)
        else if (m0 != null) m0 else m1;
        if (active) |m| {
            const needed: u64 = @max(min_size, (@as(u64, m.last_page) + 1) * PAGE_SIZE);
            if (@as(u64, @intCast(st.st_size)) < needed) {
                if (c.ftruncate(fd, @as(c.off_t, @intCast(needed))) != 0) {
                    fps.free_list_discarded = (m.free_head != 0 or m.free_count != 0);
                    return fps;
                }
            }
            fps.restoreFreeList(m); // init is single-threaded: no lock taken
        }
        return fps;

    }

    pub fn deinit(self: *FilePageStore) void {
        _ = c.munmap(@ptrCast(self.mmap_ptr), REGION_SIZE);
        _ = c.close(self.fd);
        self.freelist.deinit(self.allocator);
        self.chain_cur.deinit(self.allocator);
        self.chain_prev.deinit(self.allocator);
    }

    /// Reserved virtual region size (bytes)
    pub fn regionSize(self: *const FilePageStore) u64 {
        return self.region_size;
    }

    pub fn store(self: *FilePageStore) ps.PageStore {
        return .{ .ptr = self, .vtable = &file_vtable };
    }

    fn pagePtr(self: *FilePageStore, page_no: u32) [*]u8 {
        return self.mmap_ptr + @as(usize, @intCast(page_no)) * PAGE_SIZE;
    }

    /// Flush the meta buffers to the file (visible in the mmap region)
    fn flushMetaBuffer(self: *FilePageStore, page_no: u32) void {
        const buf = if (page_no == f2.META_PAGE_0) &self.meta0 else &self.meta1;
        const dst = self.pagePtr(page_no);
        @memcpy(dst[0..PAGE_SIZE], buf[0..PAGE_SIZE]);
    }

    /// Ensure the file has grown to cover page_no (full page)
    fn ensureFileGrowth(self: *FilePageStore, page_no: u32) !void {
        const t0 = if (FpsCounters.enable) FpsCounters.now() else 0;
        const needed: u64 = (@as(u64, page_no) + 1) * PAGE_SIZE;
        var st: c.struct_stat = undefined;
        if (c.fstat(self.fd, &st) != 0) return error.FstatFailed;
        if (FpsCounters.enable) FpsCounters.fstat_calls += 1;
        if (@as(u64, @intCast(st.st_size)) < needed) {
            if (c.ftruncate(self.fd, @as(c.off_t, @intCast(needed))) != 0) return error.TruncateFailed;
            if (FpsCounters.enable) FpsCounters.ftruncate_calls += 1;
        }
        if (FpsCounters.enable) FpsCounters.ensure_growth_ns += @intCast(FpsCounters.now() - t0);
    }

    // ===== T-33 step 0: lock-free pool primitives =====
    //
    // Contract: *Locked functions require the caller to hold freelist_mu.
    // vtWriteMeta / persistChainLocked must call these directly — going through
    // the vtable shells below would re-lock (zio.Mutex is not recursive).

    /// Pop a free page from the pool (LIFO, from the end). null = pool empty.
    fn popPoolLocked(self: *FilePageStore) ?u32 {
        if (self.freelist.items.len == 0) return null;
        return self.freelist.pop().?;
    }

    /// Return a page to the pool. Idempotent: a page already pooled is not
    /// added again. Load-bearing for P0-A: open ACCEPTS a damaged chain that
    /// lists live tree pages (structural validation cannot see tree
    /// reachability; T7 surfaces the overlap afterwards), and when the writer
    /// later COWs such a page, reclaim legitimately frees a page the restore
    /// already pooled — without dedupe the pool would list it twice and hand
    /// it out twice. On clean runs every COW victim is freed exactly once, so
    /// the scan never hits. OOM on grow leaks the page (leak direction is
    /// always safe — the established freePage semantics).
    /// ponytail: O(pool) scan per free; upgrade to a HashSet-backed pool if
    /// huge-pool churn ever shows this in a profile.
    fn pushPoolLocked(self: *FilePageStore, page_no: u32) void {
        if (std.mem.indexOfScalar(u32, self.freelist.items, page_no) != null) return;
        self.freelist.append(self.allocator, page_no) catch {};
    }

    /// Extend the high-water mark by one page (never touches the pool).
    fn bumpPageLocked(self: *FilePageStore) !u32 {
        const pn = self.next_free;
        if (@as(u64, pn) * PAGE_SIZE >= self.region_size) return error.MapFull;
        try self.ensureFileGrowth(pn);
        self.next_free = pn + 1;
        return pn;
    }

    // ---- Debug runtime guard (compiled out in Release) ----
    // Tripwire for INV-F1's second half: a chain page handed out as data means
    // the two-generation retirement is broken — explode now, not as silent
    // corruption later.
    // NOTE: there is deliberately NO "not in pool" guard on freePage — P0-A
    // accepts chains poisoned with live tree pages, so reclaim may legitimately
    // re-free a page restore already pooled (T6 v2). pushPoolLocked dedupes
    // instead: idempotent free prevents the double-listing -> double-allocation
    // the guard would have caught, without crashing on the accepted poison.

    fn assertNotChainPageLocked(self: *FilePageStore, page_no: u32) void {
        if (comptime builtin.mode == .Debug) {
            for (self.chain_cur.items) |p| std.debug.assert(p != page_no);
            for (self.chain_prev.items) |p| std.debug.assert(p != page_no);
        }
    }

    // ===== T-33: freelist chain persistence =====

    /// Result of one chain-persistence attempt. `owned` carries the chain-page
    /// list to vtWriteMeta (rotated into chain_cur); `.empty` on skip/fallback.
    const ChainOutcome = struct {
        head: u32,
        count: u64,
        owned: std.ArrayList(u32),
    };

    /// Serialize the current pool into a fresh FREE-page chain (whole-chain COW
    /// rewrite). Caller MUST hold freelist_mu and MUST use the *Locked pool
    /// primitives (vtable alloc/freePage would re-lock: zio.Mutex is not
    /// recursive). Never fails the commit: any allocation problem falls back to
    /// {head=0, count=0} — the meta simply does not persist a freelist this
    /// time; dropped persistence is the leak direction (INV-F2), and the old
    /// chain pages still retire through the normal generation rotation.
    ///
    /// ponytail: whole-chain rewrite per commit costs O(free_pages/1016) page
    /// memcpy+CRC (~400KB at 100k free pages, mmap-only, no syscall). Upgrade
    /// path if it ever shows up in a profile: append-in-place tail page for
    /// grow-only commits, or a dirty flag to skip unchanged pools.
    fn persistChainLocked(self: *FilePageStore, seq: u64) ChainOutcome {
        const n = self.freelist.items.len;

        // n==0: nothing to persist. n==1: popping the sole entry as a chain page
        // would leave 0 entries — free_head!=0 && free_count==0, which the open
        // gate rejects as XOR damage. Skip instead; the entry stays pooled for a
        // later commit (bounded one-page lag, leak direction is safe).
        if (n <= 1) return .{ .head = 0, .count = 0, .owned = .empty };

        // Each chain page consumes one pool slot itself, so k = ceil(n/(cap+1));
        // the remaining n-k entries then always fit in k pages (n-k <= k*cap by
        // the ceil definition). P0-B: naive ceil(n/cap) loses entries at n=1018.
        const cap = f2.MAX_FREE_ENTRIES_PER_PAGE;
        const k = (n + cap) / (cap + 1);

        var chain = std.ArrayList(u32).initCapacity(self.allocator, k) catch
            return .{ .head = 0, .count = 0, .owned = .empty };

        var i: usize = 0;
        while (i < k) : (i += 1) {
            const p = self.popPoolLocked() orelse self.bumpPageLocked() catch {
                // Fallback tail #1: every popped page goes back; the commit
                // proceeds without a persisted chain.
                for (chain.items) |q| self.pushPoolLocked(q);
                chain.deinit(self.allocator);
                return .{ .head = 0, .count = 0, .owned = .empty };
            };
            chain.append(self.allocator, p) catch {
                self.pushPoolLocked(p);
                for (chain.items) |q| self.pushPoolLocked(q);
                chain.deinit(self.allocator);
                return .{ .head = 0, .count = 0, .owned = .empty };
            };
        }

        // Entry snapshot = the pool AFTER the chain pages were popped, so a chain
        // page can never appear as an entry (INV-F1 second half). The pool cannot
        // change under us: freelist_mu is held for the whole critical section.
        const entries = self.freelist.items;
        std.debug.assert(entries.len == n - k);

        // Write the chain pages: header first — writeFreelistEntries recomputes
        // the whole-page CRC last, covering header + payload in one shot.
        const half = (k + 1) / 2; // mid_chain fires after ceil(k/2) pages
        for (0..k) |j| {
            const arr: *[PAGE_SIZE]u8 = @ptrCast(self.pagePtr(chain.items[j]));
            const hdr = f2.PageHeader{
                .page_no = chain.items[j],
                .page_type = f2.PAGE_TYPE_FREE,
                .gen = seq, // H1: restore rejects chain pages stamped with any other sequence
                .nkeys = 0,
                .free_next = if (j + 1 < k) chain.items[j + 1] else 0,
            };
            f2.encodePageHeader(arr[0..f2.PAGE_HEADER_SIZE], &hdr);
            const lo = j * cap;
            const hi = @min(lo + cap, entries.len);
            f2.writeFreelistEntries(arr, entries[lo..hi]);
            if (j + 1 == half) fireCrashHook(.mid_chain);
        }

        return .{ .head = chain.items[0], .count = n - k, .owned = chain };
    }

    /// Rebuild the in-memory pool from the persisted chain (open path).
    /// INV-F2: ANY validation failure discards the whole chain — the pages
    /// become orphans (leak); a suspect chain is never accepted, because
    /// accepting one can hand a live tree page to the next allocation.
    /// Single-threaded init phase: takes no lock (do not add one here).
    fn restoreFreeList(self: *FilePageStore, meta: f2.MetaPage) void {
        self.free_list_discarded = false;

        // XOR gate (T6 v8): head and count must both be zero or both non-zero.
        if (meta.free_head == 0 and meta.free_count == 0) return; // legitimately empty (incl. pre-T33 files)
        if (meta.free_head == 0 or meta.free_count == 0) {
            self.free_list_discarded = true;
            return;
        }
        // Bound 1: there cannot be more free pages than pages in the file.
        if (meta.free_count > meta.last_page) {
            self.free_list_discarded = true;
            return;
        }
        // Bound 2: chain-length ceiling. free_count is an untrusted u64; chain
        // pages are distinct data pages, so last_page+1 caps the walk hard.
        const max_pages = @min(meta.free_count / f2.MAX_FREE_ENTRIES_PER_PAGE + 2, @as(u64, meta.last_page) + 1);

        var chain_pages = std.ArrayList(u32).initCapacity(self.allocator, 8) catch {
            self.free_list_discarded = true;
            return;
        };
        var entries = std.ArrayList(u32).empty;
        // Both success and discard paths must release the temps: on success the
        // lists are moved out (reset to .empty) before these defers run.
        defer {
            chain_pages.deinit(self.allocator);
            entries.deinit(self.allocator);
        }

        var ok = true;
        var cur: u32 = meta.free_head;
        while (cur != 0) {
            if (chain_pages.items.len >= max_pages) {
                ok = false;
                break;
            }
            if (cur < ps.FIRST_DATA_PAGE or cur > meta.last_page) {
                ok = false;
                break;
            }
            // Bound 3: explicit revisit guard — free_next cycle (T6 v4).
            if (std.mem.indexOfScalar(u32, chain_pages.items, cur) != null) {
                ok = false;
                break;
            }
            const arr: *const [PAGE_SIZE]u8 = @ptrCast(self.pagePtr(cur));
            if (!f2.verifyPageChecksum(arr)) {
                ok = false; // torn / never-landed page (T6 v1, v10)
                break;
            }
            const hdr = f2.decodePageHeader(arr[0..f2.PAGE_HEADER_SIZE]);
            if (hdr.page_type != f2.PAGE_TYPE_FREE) {
                ok = false; // type confusion (T6 v9)
                break;
            }
            if (hdr.page_no != cur) {
                ok = false;
                break;
            }
            if (hdr.gen != meta.sequence) {
                ok = false; // H1: previous-generation content revived (T6 v6)
                break;
            }
            chain_pages.append(self.allocator, cur) catch {
                ok = false;
                break;
            };
            for (f2.readFreelistEntries(arr)) |e| {
                // element-wise copy: readFreelistEntries borrows align(1) u32s
                entries.append(self.allocator, e) catch {
                    ok = false;
                    break;
                };
            }
            if (!ok) break;
            cur = hdr.free_next;
        }

        // T6 v7: total must match the meta exactly (catches a dropped free_next
        // terminating the walk early, and an inflated free_count).
        if (ok and entries.items.len != meta.free_count) ok = false;

        if (ok) {
            // One sort pass powers all remaining checks: entry range, entry
            // duplicates, and the entry ∩ chain_pages intersection.
            std.mem.sort(u32, entries.items, {}, std.sort.asc(u32));
            std.mem.sort(u32, chain_pages.items, {}, std.sort.asc(u32)); // retirement is order-agnostic
            var ci: usize = 0;
            for (entries.items, 0..) |p, ei| {
                // range: < FIRST_DATA_PAGE catches meta pages (T6 v5b),
                // > last_page catches beyond-the-high-water entries (T6 v5a)
                if (p < ps.FIRST_DATA_PAGE or p > meta.last_page) {
                    ok = false;
                    break;
                }
                if (ei + 1 < entries.items.len and entries.items[ei + 1] == p) {
                    ok = false; // duplicate => double allocation (T6 v3)
                    break;
                }
                while (ci < chain_pages.items.len and chain_pages.items[ci] < p) ci += 1;
                if (ci < chain_pages.items.len and chain_pages.items[ci] == p) {
                    ok = false; // entry is a chain page (self-reference)
                    break;
                }
            }
        }

        if (!ok) {
            // Whole-chain discard: the pool stays empty, every chain page and
            // entry becomes an orphan (leak = the only safe direction, INV-F2).
            self.free_list_discarded = true;
            return;
        }

        // Success. The pool stays ASCENDING: allocPage pops from the end, so the
        // highest page numbers are reused first and low-numbered pages (which a
        // damaged chain is most likely to poison, see T6 v2) are handed out last.
        self.freelist = entries;
        entries = .empty; // ownership moved; the defer above frees nothing
        // The restored chain belongs to the LIVE meta (generation cur): it may
        // only retire after a newer meta has landed — first writeMeta rotates it
        // into chain_prev and retires it by the one after that.
        self.chain_cur = chain_pages;
        chain_pages = .empty;
    }

    // ---- T-33 test/diagnostic outlets (fixed names per contract) ----

    /// Current in-memory pool length. Equals the persisted meta.free_count only
    /// at commit boundaries (endRead reclamation can grow the pool in between).
    pub fn freePageCount(self: *const FilePageStore) usize {
        const mutable: *FilePageStore = @constCast(self); // lock-only mutation; logically const
        mutable.freelist_mu.lockUncancelable();
        defer mutable.freelist_mu.unlock();
        return mutable.freelist.items.len;
    }

    /// Whether open-time restore rejected the persisted chain. Written once in
    /// init, read-only afterwards — no lock needed.
    pub fn freeListDiscarded(self: *const FilePageStore) bool {
        return self.free_list_discarded;
    }

    /// Pool contents snapshot (T7 partition helper). Caller owns the memory.
    pub fn freePagesSnapshot(self: *FilePageStore, allocator: std.mem.Allocator) ![]u32 {
        self.freelist_mu.lockUncancelable();
        defer self.freelist_mu.unlock();
        return allocator.dupe(u32, self.freelist.items);
    }

    // ===== PageStore vtable =====

    fn vtAllocPage(ptr: *anyopaque) !u32 {
        const self: *FilePageStore = @ptrCast(@alignCast(ptr));
        const t0 = if (FpsCounters.enable) FpsCounters.now() else 0;
        if (FpsCounters.enable) FpsCounters.alloc_page_calls += 1;
        self.freelist_mu.lockUncancelable();
        defer self.freelist_mu.unlock();
        const pn = self.popPoolLocked() orelse try self.bumpPageLocked();
        self.assertNotChainPageLocked(pn);
        if (FpsCounters.enable) FpsCounters.alloc_page_ns += @intCast(FpsCounters.now() - t0);
        return pn;
    }

    fn vtFreePage(ptr: *anyopaque, page_no: u32) void {
        const self: *FilePageStore = @ptrCast(@alignCast(ptr));
        if (FpsCounters.enable) FpsCounters.free_page_calls += 1;
        self.freelist_mu.lockUncancelable();
        defer self.freelist_mu.unlock();
        self.pushPoolLocked(page_no); // idempotent (dedupes): see pushPoolLocked / P0-A note
    }

    fn vtReadPage(ptr: *anyopaque, page_no: u32) ![]const u8 {
        const self: *FilePageStore = @ptrCast(@alignCast(ptr));
        if (FpsCounters.enable) FpsCounters.read_page_calls += 1;
        if (page_no == f2.META_PAGE_0) return &self.meta0;
        if (page_no == f2.META_PAGE_1) return &self.meta1;
        if (@as(u64, page_no) * PAGE_SIZE >= self.region_size) return error.PageNotFound;
        return self.pagePtr(page_no)[0..PAGE_SIZE];
    }

    fn vtWritePage(ptr: *anyopaque, page_no: u32) ![]u8 {
        const self: *FilePageStore = @ptrCast(@alignCast(ptr));
        const t0 = if (FpsCounters.enable) FpsCounters.now() else 0;
        if (FpsCounters.enable) FpsCounters.write_page_calls += 1;
        if (page_no == f2.META_PAGE_0) return &self.meta0;
        if (page_no == f2.META_PAGE_1) return &self.meta1;
        if (@as(u64, page_no) * PAGE_SIZE >= self.region_size) return error.MapFull;
        try self.ensureFileGrowth(page_no);
        if (FpsCounters.enable) FpsCounters.write_page_ns += @intCast(FpsCounters.now() - t0);
        return self.pagePtr(page_no)[0..PAGE_SIZE];
    }

    fn vtReadMeta(ptr: *anyopaque) !?f2.MetaPage {
        const self: *FilePageStore = @ptrCast(@alignCast(ptr));
        // Sync from the mmap region into the buffers first, then read
        // (a cross-process writer may have written)
        @memcpy(self.meta0[0..PAGE_SIZE], self.pagePtr(f2.META_PAGE_0)[0..PAGE_SIZE]);
        @memcpy(self.meta1[0..PAGE_SIZE], self.pagePtr(f2.META_PAGE_1)[0..PAGE_SIZE]);
        return f2.readMetaPage(&self.meta0, &self.meta1);
    }

    fn vtWriteMeta(ptr: *anyopaque, meta: *const f2.MetaPage) !void {
        const self: *FilePageStore = @ptrCast(@alignCast(ptr));
        // T-33: ONE freelist_mu critical section covers retire -> chain persist ->
        // meta field overrides -> generation rotation -> meta write. Only *Locked
        // primitives are called inside (vtable alloc/freePage would re-lock:
        // zio.Mutex is not recursive). Lock order stays pending_free_mu ->
        // freelist_mu repo-wide; nothing here ever takes pending_free_mu.
        self.freelist_mu.lockUncancelable();
        defer self.freelist_mu.unlock();

        fireCrashHook(.before_chain);

        // (1) Retire the previous generation's chain pages: the meta that pointed
        // at them has been superseded and its slot is about to be overwritten, so
        // no recoverable meta references them any more.
        for (self.chain_prev.items) |p| self.pushPoolLocked(p);
        self.chain_prev.clearRetainingCapacity();

        // (2) Serialize the pool into a fresh chain (best-effort: fallback {0,0}
        // never fails the commit). H1: chain pages are gen-stamped with this
        // commit's sequence.
        const outcome = self.persistChainLocked(meta.sequence);
        if (outcome.head == 0) {
            // Degenerate mid_chain: no chain pages to write this commit (pool
            // empty/tiny or allocation fallback) — the injection point collapses
            // onto "chain phase done, meta not written". No-op in production.
            fireCrashHook(.mid_chain);
        }

        // (3) Override the store-owned meta fields. writer.zig passes
        // free_head/free_count as 0/0 placeholders, exactly like last_page:
        // the store is the only layer that knows the real values.
        var meta_copy = meta.*;
        if (self.next_free > ps.FIRST_DATA_PAGE) {
            meta_copy.last_page = self.next_free - 1;
        } else {
            meta_copy.last_page = 0;
        }
        meta_copy.free_head = outcome.head;
        meta_copy.free_count = outcome.count;

        // (4) Two-generation rotation (success and fallback share this path: an
        // empty outcome just makes chain_cur empty while the old chain pages wait
        // in chain_prev for their retirement — never reused while any live meta
        // may still point at them). deinit frees the cleared prev buffer first so
        // the struct-assignment rotation cannot leak an ArrayList allocation.
        self.chain_prev.deinit(self.allocator);
        self.chain_prev = self.chain_cur;
        self.chain_cur = outcome.owned;

        // (5) Meta write (existing alternating-slot protocol, unchanged).
        fireCrashHook(.after_chain_before_meta);
        const page = if (self.meta_index == 0) &self.meta0 else &self.meta1;
        const page_no = if (self.meta_index == 0) f2.META_PAGE_0 else f2.META_PAGE_1;
        f2.writeMetaPage(page, &meta_copy, self.meta_index);
        self.flushMetaBuffer(page_no);
        self.meta_index = 1 - self.meta_index;

        // (6) Meta is in the mmap (the process-crash-model "landed" point); the
        // caller's sync covers chain pages and meta with a single fsync.
        fireCrashHook(.after_meta);
    }

    fn vtSync(ptr: *anyopaque) !void {
        const self: *FilePageStore = @ptrCast(@alignCast(ptr));
        // fsync(fd) flushes the page cache for the inode (mmap MAP_SHARED writes go through the page cache)
        if (c.fsync(self.fd) != 0) return error.SyncFailed;
    }

    /// Flush the data-page range to stable storage (T-27). Semantics research
    /// and rationale:
    ///
    /// Goal: before writeMeta, flush this batch's data pages
    /// (FIRST_DATA_PAGE..next_free-1, i.e. pages dirtied via writePage in the
    /// mmap region) to stable storage, establishing the byte-level commit
    /// ordering "data pages before the meta page".
    ///
    /// Candidates and trade-offs:
    /// - `fdatasync(fd)`: the symbol exists on macOS, but POSIX semantics
    ///   allow skipping inode metadata. This engine grows the file via
    ///   `ftruncate` (ensureFileGrowth) — file size is inode metadata. Under
    ///   fdatasync, "data page bytes on disk but file length not persisted"
    ///   can occur: data pages beyond the old EOF become unreachable after
    ///   power loss while the meta page (at the file head, unaffected by
    ///   length) may already be persisted -> exactly the dangling root we
    ///   must prevent. Not used.
    /// - `msync(MS_SYNC)` page range: can target exactly [FIRST_DATA_PAGE,
    ///   next_free), but likewise does not guarantee the ftruncate length
    ///   metadata reaches disk — still needs a follow-up fsync, so two
    ///   syscalls for no gain.
    /// - `fsync(fd)` (chosen): flushes data + inode metadata (including the
    ///   post-ftruncate length). At call time writeMeta has not run yet (the
    ///   meta pages are still clean in the mmap — the previous sync already
    ///   persisted them), so the dirty pages fsync flushes now are exactly
    ///   this batch's data pages; the meta pages cannot hitch a ride early.
    ///   The ordering is established by construction, not by luck.
    ///
    /// Known boundary (recorded as-is, not fixed here): macOS fsync has
    /// historically not guaranteed flushing through the disk controller cache
    /// (that needs F_FULLFSYNC). This impl uses the same primitive as the
    /// existing vtSync; the relative "data pages before meta" ordering holds
    /// under either primitive. Absolute power-loss safety at the controller
    /// cache level (F_FULLFSYNC) is a separate, costlier option — see
    /// docs/crash-model.md.
    fn vtSyncDataPages(ptr: *anyopaque) !void {
        const self: *FilePageStore = @ptrCast(@alignCast(ptr));
        // Data-page range: FIRST_DATA_PAGE..next_free-1 (every page this
        // batch's writePage may touch; freelist-recycled pages are also within
        // this bump ceiling). The meta pages are unwritten at call time.

        if (c.fsync(self.fd) != 0) return error.SyncFailed;
    }

    fn vtMapSize(ptr: *anyopaque) u64 {
        const self: *FilePageStore = @ptrCast(@alignCast(ptr));
        return self.region_size / PAGE_SIZE;
    }
};

/// T-33(T5): test-only crash injection. Production keeps
/// FilePageStore.test_crash_hook null and this is one predictable cold branch;
/// the armed child aborts (SIGABRT) exactly at the injected commit point.
fn fireCrashHook(tag: FilePageStore.CrashTag) void {
    if (FilePageStore.test_crash_hook) |armed| {
        if (armed == tag) std.process.abort();
    }
}

const file_vtable: ps.PageStore.VTable = .{
    .allocPage = FilePageStore.vtAllocPage,
    .freePage = FilePageStore.vtFreePage,
    .readPage = FilePageStore.vtReadPage,
    .writePage = FilePageStore.vtWritePage,
    .readMeta = FilePageStore.vtReadMeta,
    .writeMeta = FilePageStore.vtWriteMeta,
    .syncDataPages = FilePageStore.vtSyncDataPages,
    .sync = FilePageStore.vtSync,
    .mapsize = FilePageStore.vtMapSize,
};

fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}
test "file_page_store: 1TB region reserved on open" {
    const allocator = std.testing.allocator;
    const path = ".fps_region_test.db";
    defer unlinkPath(path);
    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    try std.testing.expect(fps.regionSize() >= (1 << 40));
}

test "file_page_store: alloc grows file, read-back visible" {
    const allocator = std.testing.allocator;
    const path = ".fps_grow_test.db";
    defer unlinkPath(path);
    var fps = try FilePageStore.init(allocator, path);
    defer fps.deinit();
    const s = fps.store();
    const pn = try s.allocPage();
    const w = try s.writePage(pn);
    @memcpy(w[0..4], "ABCD");
    const r = try s.readPage(pn);
    try std.testing.expectEqualStrings("ABCD", r[0..4]);
}

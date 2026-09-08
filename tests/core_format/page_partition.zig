//! page_partition.zig - T-33(T7): page-class partition invariant helper
//!
//! Independent re-derivation of "who owns each page". It trusts nothing but the bytes on disk
//! (meta page + page headers + node payloads) and never reads FilePageStore's in-memory
//! bookkeeping — that is the whole point: this is the machine-checkable form of
//!
//!   INV-F1: no page listed as free is referenced by the committed tree, and no chain page is
//!           listed as free.
//!
//! and the seed of a future offline `cube_check`.
//!
//! Classes over [0, meta.last_page]:
//!   meta       the two meta slots (pages 1, 2)
//!   tree       reachable from meta.root_page — branch/leaf pages AND overflow chain pages,
//!              the latter followed through PageHeader.free_next of overflow entries
//!   chain      persisted freelist chain pages, walked from meta.free_head via free_next
//!   free_entry a page number listed as free inside a chain page
//!   orphan     allocated (<= last_page) but in none of the above — leaked. Leaking is the only
//!              allowed failure direction (INV-F2), so orphans are counted, never asserted zero.
//!
//! A page that would take a SECOND class is recorded as an overlap. Overlap == corruption signal
//! (double allocation / a live page handed out / a chain page recycled into the free list).
//!
//! Deliberately robust against damaged input: every walk is bounded and revisits are skipped, so a
//! cyclic chain or a corrupt node terminates instead of hanging; damage that is *not* an overlap is
//! counted in `walk_errors` / `out_of_range` for diagnosis.
//!
//! No `test` blocks here on purpose: this file is imported by both freelist_persist_test.zig (T6)
//! and freelist_persist_crash_test.zig (T5); test blocks would run twice.

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const ps = cube.page_store;
const btree = cube.btree;

// btree.zig keeps these private; mirrored here (btree.zig: LEAF_KIND / BRANCH_KIND /
// LEAF_FLAG_OVERFLOW). If they ever change, the tree walk below reports walk_errors rather than
// silently misclassifying — the payload kind byte is validated on decode.
const kind_branch: u8 = 1;
const kind_leaf: u8 = 2;
const flag_overflow: u8 = 1;

/// format.zig's per-page freelist capacity. GREEN exposes it as MAX_FREE_ENTRIES_PER_PAGE; until
/// then fall back to the arithmetic (same value the tests use).
fn freeCap() u64 {
    if (@hasDecl(f2, "MAX_FREE_ENTRIES_PER_PAGE")) return @intCast(f2.MAX_FREE_ENTRIES_PER_PAGE);
    return (f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4 - 4) / 4;
}

/// Sanity ceiling on the classified range: a 1TB region is 268M pages = 268MB of class bytes.
/// Fixtures and tests here stay far below; anything above this is a bug in the test, not the DB.
const max_classified_pages: u64 = 4 << 20;

pub const Class = enum { unassigned, meta, tree, chain, free_entry, orphan };

pub const Overlap = struct {
    page: u32,
    first: Class,
    second: Class,
};

pub const Report = struct {
    allocator: std.mem.Allocator,
    last_page: u32,
    /// class per page, indexed [0 .. last_page]
    class_of: []Class,
    overlaps: std.ArrayList(Overlap),
    tree_pages: std.ArrayList(u32),
    chain_pages: std.ArrayList(u32),
    free_pages: std.ArrayList(u32),

    n_meta: usize = 0,
    n_tree: usize = 0,
    n_chain: usize = 0,
    n_free: usize = 0,
    n_orphan: usize = 0,
    /// damaged-but-not-overlapping findings (bad CRC, undecodable node, non-FREE chain page, ...)
    walk_errors: usize = 0,
    /// page numbers outside [0, last_page] seen in a pointer/entry
    out_of_range: usize = 0,

    pub fn deinit(self: *Report) void {
        self.allocator.free(self.class_of);
        self.overlaps.deinit(self.allocator);
        self.tree_pages.deinit(self.allocator);
        self.chain_pages.deinit(self.allocator);
        self.free_pages.deinit(self.allocator);
    }

    pub fn classOf(self: *const Report, page: u32) Class {
        if (page >= self.class_of.len) return .unassigned;
        return self.class_of[page];
    }

    /// First overlap between these two classes, if any (order-insensitive).
    pub fn findOverlap(self: *const Report, a: Class, b: Class) ?Overlap {
        for (self.overlaps.items) |o| {
            if ((o.first == a and o.second == b) or (o.first == b and o.second == a)) return o;
        }
        return null;
    }

    fn bump(self: *Report, cls: Class) void {
        switch (cls) {
            .meta => self.n_meta += 1,
            .tree => self.n_tree += 1,
            .chain => self.n_chain += 1,
            .free_entry => self.n_free += 1,
            .orphan => self.n_orphan += 1,
            .unassigned => {},
        }
    }

    /// Assign a class; a second, different class on the same page is an overlap. Re-marking with
    /// the same class is a no-op (that is how revisit/cycle guards stay quiet).
    fn mark(self: *Report, page: u32, cls: Class) void {
        if (page >= self.class_of.len) {
            self.out_of_range += 1;
            return;
        }
        const prev = self.class_of[page];
        if (prev == cls) return;
        if (prev != .unassigned) {
            self.overlaps.append(self.allocator, .{ .page = page, .first = prev, .second = cls }) catch {};
            return; // keep the first classification stable
        }
        self.class_of[page] = cls;
        self.bump(cls);
    }
};

/// Classify every page in [0, meta.last_page] from the bytes alone.
pub fn classify(allocator: std.mem.Allocator, store: ps.PageStore, meta: f2.MetaPage) !Report {
    const n64: u64 = @as(u64, meta.last_page) + 1;
    if (n64 > max_classified_pages) return error.RangeTooBig;
    const n: usize = @intCast(n64);

    const class_of = try allocator.alloc(Class, n);
    @memset(class_of, .unassigned);

    var rep: Report = .{
        .allocator = allocator,
        .last_page = meta.last_page,
        .class_of = class_of,
        .overlaps = .empty,
        .tree_pages = .empty,
        .chain_pages = .empty,
        .free_pages = .empty,
    };
    errdefer rep.deinit();

    rep.mark(f2.META_PAGE_0, .meta);
    rep.mark(f2.META_PAGE_1, .meta);

    // ---- tree walk (iterative, bounded, revisit-safe) ----
    var stack = std.ArrayList(u32).empty;
    defer stack.deinit(allocator);
    if (meta.root_page != btree.NULL_ROOT) try stack.append(allocator, meta.root_page);

    const guard_max: usize = 4 * n + 1024;
    var guard: usize = 0;
    while (stack.items.len > 0 and guard < guard_max) : (guard += 1) {
        const p = stack.pop().?;
        if (p == 0 or p >= n) {
            if (p != 0) rep.out_of_range += 1;
            continue;
        }
        if (rep.class_of[p] == .tree) continue; // visited (also breaks cycles in damaged files)

        const page = store.readPage(p) catch {
            rep.walk_errors += 1;
            continue;
        };
        if (page.len < f2.PAGE_SIZE) {
            rep.walk_errors += 1;
            continue;
        }
        const payload = page[f2.PAGE_HEADER_SIZE .. f2.PAGE_SIZE - 4];
        rep.mark(p, .tree);
        rep.tree_pages.append(allocator, p) catch {};
        if (payload.len < 3) {
            rep.walk_errors += 1;
            continue;
        }

        switch (payload[0]) {
            kind_branch => {
                const count = std.mem.readInt(u16, payload[1..3], .little);
                if (count < 2 or count > 4096) {
                    rep.walk_errors += 1;
                    continue;
                }
                const keys = try allocator.alloc([]const u8, count - 1);
                defer allocator.free(keys);
                const kids = try allocator.alloc(u32, count);
                defer allocator.free(kids);
                if (btree.decodeBranchPayload(payload, keys, kids)) |_| {
                    for (kids) |k| try stack.append(allocator, k);
                } else |_| rep.walk_errors += 1;
            },
            kind_leaf => {
                const count = std.mem.readInt(u16, payload[1..3], .little);
                if (count > 4096) {
                    rep.walk_errors += 1;
                    continue;
                }
                const ents = try allocator.alloc(btree.DecodedLeafEntry, count);
                defer allocator.free(ents);
                if (btree.decodeLeafPayload(payload, ents)) |_| {
                    for (ents[0..count]) |e| {
                        if (e.flags & flag_overflow == 0 or e.value.len < 4) continue;
                        // overflow value: the entry stores the chain head page number; the chain
                        // is linked through PageHeader.free_next and belongs to the tree.
                        var cur = std.mem.readInt(u32, e.value[0..4], .little);
                        var og: usize = 0;
                        while (cur != 0 and og < n + 8) : (og += 1) {
                            if (cur >= n) {
                                rep.out_of_range += 1;
                                break;
                            }
                            if (rep.class_of[cur] == .tree) break; // visited
                            const op = store.readPage(cur) catch {
                                rep.walk_errors += 1;
                                break;
                            };
                            rep.mark(cur, .tree);
                            rep.tree_pages.append(allocator, cur) catch {};
                            cur = f2.decodePageHeader(op[0..f2.PAGE_HEADER_SIZE]).free_next;
                        }
                    }
                } else |_| rep.walk_errors += 1;
            },
            else => rep.walk_errors += 1, // meta page in the tree, or garbage
        }
    }
    if (guard >= guard_max) rep.walk_errors += 1;

    // ---- persisted freelist chain walk (bounded the same way restoreFreeList must) ----
    var cur = meta.free_head;
    const cap = freeCap();
    const c_max: u64 = @min(meta.free_count / cap + 2, n64) + 2;
    var cg: u64 = 0;
    while (cur != 0 and cg < c_max) : (cg += 1) {
        if (cur >= n) {
            rep.out_of_range += 1;
            break;
        }
        if (rep.class_of[cur] == .chain) break; // cycle guard
        const page = store.readPage(cur) catch {
            rep.walk_errors += 1;
            break;
        };
        const arr: *const [f2.PAGE_SIZE]u8 = @ptrCast(page.ptr);
        const hdr = f2.decodePageHeader(page[0..f2.PAGE_HEADER_SIZE]);
        rep.mark(cur, .chain);
        rep.chain_pages.append(allocator, cur) catch {};
        if (hdr.page_type != f2.PAGE_TYPE_FREE) {
            rep.walk_errors += 1; // type confusion (T6 v9)
            break;
        }
        if (!f2.verifyPageChecksum(arr)) {
            rep.walk_errors += 1; // torn / never-landed chain page (T6 v1, v10)
            break;
        }
        for (f2.readFreelistEntries(arr)) |e| {
            rep.mark(e, .free_entry); // the INV-F1 check: tree ∩ free_entry must stay empty
            if (e < n) rep.free_pages.append(allocator, e) catch {};
        }
        cur = hdr.free_next;
    }

    // ---- remainder = orphan (leaked, allowed) ----
    var p: usize = ps.FIRST_DATA_PAGE;
    while (p < n) : (p += 1) {
        if (rep.class_of[p] == .unassigned) rep.mark(@intCast(p), .orphan);
    }

    return rep;
}

pub fn dump(self: *const Report, label: []const u8) void {
    std.debug.print(
        "[T7 {s}] last_page={d} meta={d} tree={d} chain={d} free={d} orphan={d} walk_errors={d} out_of_range={d} overlaps={d}\n",
        .{ label, self.last_page, self.n_meta, self.n_tree, self.n_chain, self.n_free, self.n_orphan, self.walk_errors, self.out_of_range, self.overlaps.items.len },
    );
}

/// Strict form used by T3/T4/T5: the five classes must be pairwise disjoint.
pub fn expectDisjoint(self: *const Report) !void {
    if (self.overlaps.items.len != 0) {
        dump(self, "DISJOINT VIOLATION");
        for (self.overlaps.items[0..@min(8, self.overlaps.items.len)]) |o| {
            std.debug.print("  page {d}: {s} also claimed as {s}\n", .{ o.page, @tagName(o.first), @tagName(o.second) });
        }
        return error.PartitionOverlap;
    }
}

/// Inverse form used by T6 v2 (P0-A): open *accepts* a chain that lists a tree-reachable page
/// (O(1) recovery is preserved), so the overlap must be visible here instead.
pub fn expectOverlap(self: *const Report, a: Class, b: Class) !void {
    if (self.findOverlap(a, b) == null) {
        dump(self, "EXPECTED OVERLAP MISSING");
        std.debug.print("  wanted: {s} ∩ {s}\n", .{ @tagName(a), @tagName(b) });
        return error.ExpectedOverlapMissing;
    }
}

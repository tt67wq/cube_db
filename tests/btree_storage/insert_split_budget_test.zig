//! insert_split_budget_test.zig — T-43: single-insert path payload budget
//! (insertIntoLeafSplit mid-split / insertBranch ≤64 count-only re-encode).
//!
//! Issue T-43: T-40 made the BATCH path payload-size-aware, but the single
//! `insert`/`put` path still has two count-only decision points that can
//! exceed NODE_PAYLOAD_CAP (4068B) when the tree holds near-MAX_KEY_SIZE keys:
//!
//! 1. insertIntoLeafSplit: `mid = len/2` count split — the right half can
//!    carry more bytes than one page (out-of-bounds encode panic).
//! 2. insertIntoBranch: `children.len <= BRANCH_MAX_CHILDREN` re-encodes the
//!    branch without a byte check — big separators overflow the page.
//!
//! Plus the T-42 residual: root-split `sk` leaked on PageStore write failure
//! (defensive errdefer; see test-report for reachability notes).
//!
//! RED shape (pre-fix, deterministic):
//!   - leaf: 6 tiny + 5×678B keys in one valid leaf (3538B ≤ cap), insert one
//!     696B key -> mid-split right half = 4155B > 4096 -> encode panic.
//!   - branch: 20×850B keys -> batch-built 2-level tree (root branch payload
//!     3439B ≤ cap), single insert splits a leaf -> root re-encode = 4297B
//!     > 4096 -> `buf[0..pl]` slice panic.
//!
//! Fault-injection sweeps (FailingAllocator on BOTH the store and the btree
//! allocator — MemPageStore allocates pages through its allocator, so this
//! covers PageStore write failures as well as btree-side allocation
//! failures): every fail_index must yield either success or a clean
//! error.OutOfMemory — never a crash (UAF/double-free), never a leak (the
//! backing testing.allocator checks at test end).
//!
//! Wiring: comptime-imported from btree_test.zig into the test-btree step.

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;

const alloc = std.testing.allocator;

fn newStore() ps.MemPageStore {
    return ps.MemPageStore.init(alloc, 100000);
}

/// Fixed-size key with a prefix and zero padding: lexicographic order is
/// prefix order ('a' < 'm' < 'z'), sizes are exact for byte accounting.
fn bigKey(buf: []u8, comptime prefix: []const u8) []const u8 {
    buf[0] = prefix[0];
    @memset(buf[1..], 'k');
    return buf;
}

// ===== 1. insertIntoLeafSplit mid-split byte overflow (leaf path) =====

test "T-43: single insert into byte-heavy leaf must not exceed page (mid-split)" {
    var ms = newStore();
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(alloc);

    // Seed one valid leaf via insertBatch: 6 tiny 'a' keys (15B each) +
    // 5 'z' keys of 678B (689B each) = 3 + 90 + 3445 = 3538B <= 4068.
    var a_bufs: [6][4]u8 = undefined;
    var z_bufs: [5][678]u8 = undefined;
    var seed: [11]btree.LeafEntry = undefined;
    for (0..6) |i| {
        a_bufs[i] = .{ 'a', '0', '0', @intCast(i) };
        seed[i] = .{ .tombstone = false, .key = &a_bufs[i], .value = "v" };
    }
    for (0..5) |i| {
        const k = bigKey(&z_bufs[i], "z");
        seed[6 + i] = .{ .tombstone = false, .key = k, .value = "v" };
    }
    const wr = try btree.insertBatch(alloc, ms.store(), btree.NULL_ROOT, &seed, &dirty);
    try std.testing.expect(wr.new_root != btree.NULL_ROOT);

    // Single insert of a 696B 'm' key: sorts between the a's and z's.
    // Pre-fix: precheck redirects to insertIntoLeafSplit, mid = 6, right half
    // = m + 5 z's = 3 + 707 + 3445 = 4155B > 4096 -> out-of-bounds encode.
    var m_buf: [696]u8 = undefined;
    const m_key = bigKey(&m_buf, "m");
    const wr2 = try btree.insert(alloc, ms.store(), wr.new_root, m_key, "v", false, &dirty);
    try std.testing.expect(wr2.new_root != btree.NULL_ROOT);

    // Content: 12 entries, all readable.
    var it = try btree.select(alloc, ms.store(), wr2.new_root, null, null);
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 12), count);
}

// ===== 2. insertIntoBranch ≤64 count-only re-encode byte overflow =====

test "T-43: branch re-encode after child split must respect payload cap" {
    var ms = newStore();
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(alloc);

    // 20 keys of 850B: insertBatch chunks 4 per leaf (5 leaves), root branch
    // payload = 3 + 4*5 + 4*(4+850) = 3439B <= cap. All keys share prefix
    // 'k' (the padding char) so ordering is by nothing else — they must be
    // DISTINCT: use a varying 2nd byte.
    var bufs: [20][850]u8 = undefined;
    var seed: [20]btree.LeafEntry = undefined;
    for (0..20) |i| {
        bufs[i][0] = 'k';
        bufs[i][1] = @intCast('a' + i);
        @memset(bufs[i][2..], 'k');
        seed[i] = .{ .tombstone = false, .key = &bufs[i], .value = "v" };
    }
    const wr = try btree.insertBatch(alloc, ms.store(), btree.NULL_ROOT, &seed, &dirty);
    try std.testing.expect(wr.new_root != btree.NULL_ROOT);

    // Single insert of a 850B key sorting last ('zz' prefix). The rightmost
    // leaf is byte-full (3447B), so the insert splits it; the parent branch
    // integrates +1 separator -> payload 4297B > 4096. Pre-fix the <=64
    // fast return slices buf[0..4297] -> panic.
    var zbuf: [850]u8 = undefined;
    zbuf[0] = 'z';
    zbuf[1] = 'z';
    @memset(zbuf[2..], 'k');
    const wr2 = try btree.insert(alloc, ms.store(), wr.new_root, &zbuf, "v", false, &dirty);
    try std.testing.expect(wr2.new_root != btree.NULL_ROOT);

    // Content: 21 entries, all readable.
    var it = try btree.select(alloc, ms.store(), wr2.new_root, null, null);
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 21), count);
}

// ===== 3./4. Error paths: fault-injection sweeps ========================
// One FailingAllocator wraps the backing testing.allocator and is handed to
// BOTH MemPageStore and the btree calls: MemPageStore allocates its pages
// through the allocator, so the sweep covers PageStore write failures
// (allocPage/ensurePage OOM) as well as btree-side failures (separator
// dupes, splice arrays, toOwnedSlice, buildBranchLevels level lists).
// Each fail_index is a fresh end-to-end run: success or clean OOM only.

const ScenarioFn = fn (store: ps.PageStore, fa: std.mem.Allocator, dirty: *std.ArrayList(u32)) anyerror!void;

fn sweepFailIndexes(comptime label: []const u8, comptime build: ScenarioFn, first: usize, last_exclusive: usize) !void {
    var fail_index: usize = first;
    while (fail_index < last_exclusive) : (fail_index += 1) {
        // ONE FailingAllocator for BOTH the store and the btree calls: the
        // fail_index counts every allocation on either side, so the sweep
        // interleaves store faults and btree faults.
        var failing = std.testing.FailingAllocator.init(alloc, .{
            .fail_index = fail_index,
        });
        const fa = failing.allocator();
        var ms = ps.MemPageStore.init(fa, 100000);
        defer ms.deinit();
        var dirty = std.ArrayList(u32).empty;
        defer dirty.deinit(alloc);

        build(ms.store(), fa, &dirty) catch |e| {
            if (e != error.OutOfMemory) {
                std.debug.print("{s}: fail_index={d}: unexpected error {s}\n", .{ label, fail_index, @errorName(e) });
                return error.UnexpectedError;
            }
        };
    }
}

/// One clean run to count the scenario's total allocations (calibrates the
/// sweep range; store + btree allocations alike go through the wrapper).
fn countAllocs(comptime build: ScenarioFn) !usize {
    var failing = std.testing.FailingAllocator.init(alloc, .{});
    const fa = failing.allocator();
    var ms = ps.MemPageStore.init(fa, 100000);
    defer ms.deinit();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(alloc);

    try build(ms.store(), fa, &dirty);
    return failing.allocations;
}

/// Leaf overflow scenario (test 1 shape): byte-heavy single leaf, one big
/// single insert -> insertIntoLeafSplit chunk/splice + root splice.
fn leafOverflowScenario(store: ps.PageStore, fa: std.mem.Allocator, dirty: *std.ArrayList(u32)) anyerror!void {
    var a_bufs: [6][4]u8 = undefined;
    var z_bufs: [5][678]u8 = undefined;
    var seed: [11]btree.LeafEntry = undefined;
    for (0..6) |i| {
        a_bufs[i] = .{ 'a', '0', '0', @intCast(i) };
        seed[i] = .{ .tombstone = false, .key = &a_bufs[i], .value = "v" };
    }
    for (0..5) |i| {
        const k = bigKey(&z_bufs[i], "z");
        seed[6 + i] = .{ .tombstone = false, .key = k, .value = "v" };
    }
    const wr = try btree.insertBatch(fa, store, btree.NULL_ROOT, &seed, dirty);
    var root = wr.new_root; // T-45: 每步 insert 后更新，勿向 dirty 表内排队旧页写入

    var m_buf: [696]u8 = undefined;
    const m_key = bigKey(&m_buf, "m");
    root = (try btree.insert(fa, store, root, m_key, "v", false, dirty)).new_root;

    // Overwrite the last 'z' key with a big value: same byte-heavy leaf,
    // found=true path in insertIntoLeafSplit (the precheck redirects because
    // entry_start + new_entry_sz + tail > cap). Covers the overwrite-side
    // ownership (old entry must not be freed before the new dupes exist).
    // Still hits found=true: 'z3' lives in the same leaf after the 'm'
    // insert (m sorts between a and z, no split occurred), and the big
    // value triggers the same precheck redirect into the overwrite path.
    var vbuf: [3000]u8 = undefined;
    @memset(&vbuf, 'w');
    _ = try btree.insert(fa, store, root, bigKey(&z_bufs[3], "z"), &vbuf, false, dirty);
}

test "T-43: leaf-overflow error path — no UAF, no leaks (full fault sweep, store+btree)" {
    const total = try countAllocs(leafOverflowScenario);
    try sweepFailIndexes("leaf", leafOverflowScenario, 1, total + 2);
}

/// Branch overflow scenario (test 2 shape): 2-level tree with byte-heavy
/// root branch, one big single insert -> leaf split + branch splice.
fn branchOverflowScenario(store: ps.PageStore, fa: std.mem.Allocator, dirty: *std.ArrayList(u32)) anyerror!void {
    var bufs: [20][850]u8 = undefined;
    var seed: [20]btree.LeafEntry = undefined;
    for (0..20) |i| {
        bufs[i][0] = 'k';
        bufs[i][1] = @intCast('a' + i);
        @memset(bufs[i][2..], 'k');
        seed[i] = .{ .tombstone = false, .key = &bufs[i], .value = "v" };
    }
    const wr = try btree.insertBatch(fa, store, btree.NULL_ROOT, &seed, dirty);

    var zbuf: [850]u8 = undefined;
    zbuf[0] = 'z';
    zbuf[1] = 'z';
    @memset(zbuf[2..], 'k');
    _ = try btree.insert(fa, store, wr.new_root, &zbuf, "v", false, dirty);
}

test "T-43: branch-overflow error path — no UAF, no leaks (full fault sweep, store+btree)" {
    const total = try countAllocs(branchOverflowScenario);
    try sweepFailIndexes("branch", branchOverflowScenario, 1, total + 2);
}

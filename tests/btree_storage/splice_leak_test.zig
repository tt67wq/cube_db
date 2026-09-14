//! splice_leak_test.zig — T-41: root-splice error-path leak (TDD RED).
//!
//! Issue: `insertBatch`'s root-splice path frees `sp.keys`/`sp.children`
//! only AFTER `buildBranchLevels` succeeds; a failure inside it (allocPage)
//! leaks the splice separator keys + arrays under a non-arena allocator.
//! Production callers pass an arena (no real impact) — defensive fix.
//!
//! Test strategy (fault injection, isolated to the root-splice consumer):
//! - A MemPageStore sized so the root-branch page allocation inside
//!   buildBranchLevels hits error.MapFull: seed leaf (1 page) + 5 spliced
//!   chunk leaves fit (pages 3..8, max_pages=9); the 7th allocPage fails.
//! - A tracking allocator wraps page_allocator. It is ARMED by the wrapped
//!   store right after the FIRST chunk-leaf page allocation, i.e. after
//!   every pre-splice allocation (leaf decode, merged-entry dupes) already
//!   happened. Everything allocated while armed is exactly the splice tail:
//!   separator-key dupes, split_keys ArrayList growth, sp.children,
//!   toOwnedSlice'd sp.keys.
//! - After insertBatch returns error.MapFull, every armed allocation must
//!   have been freed (the errdefer under test). Pre-fix: children + keys
//!   array + separator dupes leak -> live set non-empty -> RED.
//!
//! Known co-existing (out of T-41 scope, see
//! issues/T-42-insertbatchintoleaf-merged-dupes-leak.md): merged-entry
//! key/value dupes in insertBatchIntoLeaf leak on success+error paths for
//! non-arena allocators — they are allocated BEFORE arming, so this test
//! stays precisely scoped to the splice arrays.

const std = @import("std");
const cube = @import("cube_db");
const ps = cube.page_store;
const btree = cube.btree;

const KEY_LEN = 6; // "b000".."b096"
const VAL_LEN = 13;

/// Tracking allocator: records allocations made while armed; a live set that
/// is non-empty at assertLiveEmpty() time means an error-path leak.
const Tracker = struct {
    armed: bool = false,
    live: std.AutoHashMapUnmanaged(usize, void) = .empty,

    fn allocator(self: *Tracker) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        const ptr = std.heap.page_allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
        if (self.armed) self.live.put(std.heap.page_allocator, @intFromPtr(ptr), {}) catch {};
        return ptr;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        _ = ctx;
        return std.heap.page_allocator.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        const new_ptr = std.heap.page_allocator.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (self.armed) {
            if (@intFromPtr(new_ptr) != @intFromPtr(memory.ptr)) {
                _ = self.live.remove(@intFromPtr(memory.ptr));
                self.live.put(std.heap.page_allocator, @intFromPtr(new_ptr), {}) catch {};
            }
        }
        return new_ptr;
    }

    fn free(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        if (self.armed) _ = self.live.remove(@intFromPtr(memory.ptr));
        std.heap.page_allocator.rawFree(memory, alignment, ret_addr);
    }

    fn assertLiveEmpty(self: *Tracker) !void {
        var it = self.live.keyIterator();
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        if (n != 0) {
            std.debug.print("T-41: {d} allocation(s) leaked on the root-splice error path\n", .{n});
            return error.MemoryLeakDetected;
        }
    }
};

/// PageStore wrapper: forwards everything to the child MemPageStore store;
/// arms the tracker once the (arm_at)th page has been allocated.
const ArmingStore = struct {
    child: ps.PageStore,
    tracker: *Tracker,
    allocs: u32 = 0,
    /// seed leaf = page 1, first chunk leaf = page 2
    arm_at: u32 = 2,

    fn store(self: *ArmingStore) ps.PageStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = ps.PageStore.VTable{
        .allocPage = allocPage,
        .freePage = freePage,
        .readPage = readPage,
        .writePage = writePage,
        .readMeta = readMeta,
        .writeMeta = writeMeta,
        .syncDataPages = syncDataPages,
        .sync = sync,
        .mapsize = mapsize,
    };

    fn allocPage(ptr: *anyopaque) anyerror!u32 {
        const self: *ArmingStore = @ptrCast(@alignCast(ptr));
        const pn = try self.child.allocPage();
        self.allocs += 1;
        if (self.allocs == self.arm_at) self.tracker.armed = true;
        return pn;
    }
    fn freePage(ptr: *anyopaque, page_no: u32) void {
        const self: *ArmingStore = @ptrCast(@alignCast(ptr));
        self.child.freePage(page_no);
    }
    fn readPage(ptr: *anyopaque, page_no: u32) anyerror![]const u8 {
        const self: *ArmingStore = @ptrCast(@alignCast(ptr));
        return self.child.readPage(page_no);
    }
    fn writePage(ptr: *anyopaque, page_no: u32) anyerror![]u8 {
        const self: *ArmingStore = @ptrCast(@alignCast(ptr));
        return self.child.writePage(page_no);
    }
    fn readMeta(ptr: *anyopaque) anyerror!?cube.format.MetaPage {
        const self: *ArmingStore = @ptrCast(@alignCast(ptr));
        return self.child.readMeta();
    }
    fn writeMeta(ptr: *anyopaque, meta: *const cube.format.MetaPage) anyerror!void {
        const self: *ArmingStore = @ptrCast(@alignCast(ptr));
        return self.child.writeMeta(meta);
    }
    fn syncDataPages(ptr: *anyopaque) anyerror!void {
        const self: *ArmingStore = @ptrCast(@alignCast(ptr));
        return self.child.syncDataPages();
    }
    fn sync(ptr: *anyopaque) anyerror!void {
        const self: *ArmingStore = @ptrCast(@alignCast(ptr));
        return self.child.sync();
    }
    fn mapsize(ptr: *anyopaque) u64 {
        const self: *ArmingStore = @ptrCast(@alignCast(ptr));
        return self.child.mapsize();
    }
};

test "T-41: root-splice path frees splice keys/children on buildBranchLevels failure" {
    var tracker: Tracker = .{};
    defer tracker.live.deinit(std.heap.page_allocator);
    const talloc = tracker.allocator();

    // Store budget: seed leaf (page 3) + 5 chunk leaves (pages 4..8) fit;
    // the root-branch allocPage in buildBranchLevels (would-be page 9)
    // fails with error.MapFull. Store allocations use a separate allocator
    // so page slabs never enter the tracked live set.
    var ms = ps.MemPageStore.init(std.testing.allocator, 9);
    defer ms.deinit();
    var arming = ArmingStore{ .child = ms.store(), .tracker = &tracker };
    const s = arming.store();

    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(talloc);

    // Seed: full 32-entry leaf root (fresh path; no tracked allocations).
    var seed_kbufs: [32][KEY_LEN]u8 = undefined;
    var seed_vbufs: [32][VAL_LEN]u8 = undefined;
    var seed: [32]btree.LeafEntry = undefined;
    for (0..32) |i| {
        const k = try std.fmt.bufPrint(&seed_kbufs[i], "a{d:0>4}", .{i});
        @memset(&seed_vbufs[i], 'v');
        seed[i] = .{ .tombstone = false, .key = k, .value = seed_vbufs[i][0..VAL_LEN] };
    }
    const wr1 = try btree.insertBatch(talloc, s, btree.NULL_ROOT, &seed, &dirty);
    try std.testing.expect(wr1.new_root != btree.NULL_ROOT);

    // Overflow batch: 97 keys all greater than the seed's ("b*" > "a*") —
    // merged = 32 + 97 = 129 > LEAF_MAX_ENTRIES (32) -> 5 chunk leaves ->
    // splice {5 children, 4 separator keys}; the root IS the leaf, so
    // insertBatch takes the root-splice path (buildBranchLevels).
    var kbufs: [97][KEY_LEN]u8 = undefined;
    var vbufs: [97][VAL_LEN]u8 = undefined;
    var entries: [97]btree.LeafEntry = undefined;
    for (0..97) |i| {
        const k = try std.fmt.bufPrint(&kbufs[i], "b{d:0>4}", .{i});
        @memset(&vbufs[i], 'w');
        entries[i] = .{ .tombstone = false, .key = k, .value = vbufs[i][0..VAL_LEN] };
    }

    // The tracker arms during the first chunk-leaf allocation; from then on
    // every allocation is splice-owned and must be freed on the error path.
    try std.testing.expectError(error.MapFull, btree.insertBatch(talloc, s, wr1.new_root, &entries, &dirty));

    // Lock the page-budget model: exactly seed + 5 chunk leaves were
    // allocated; the failure was the 7th allocPage (root branch page).
    try std.testing.expectEqual(@as(u32, 6), arming.allocs);
    try std.testing.expect(tracker.armed);

    // THE assertion: nothing allocated after arming (separator-key dupes,
    // sp.children, sp.keys array) survives the error return.
    try tracker.assertLiveEmpty();
}

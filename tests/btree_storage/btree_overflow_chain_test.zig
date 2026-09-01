//! btree_overflow_chain_test.zig — T-12: 溢出页链测试（#7）
//!
//! src/btree.zig:75-150 溢出页链机制：
//! - writeOverflowPages（:76 private）写大值到溢出页链，链靠 free_next 串联
//! - readOverflowValue（:131 private）读回拼接
//! - freeOverflowPages（:144 private）回收，readPage 失败时静默 return（:148）
//!
//! 这些函数都 private，本文件通过 pub API（btree.insert / btree.get）间接触发，
//! 再用 MemPageStore + format 页头解码直接观察溢出页链结构与回收行为。
//!
//! 接入：tests/btree_storage/btree_test.zig comptime 块。

const std = @import("std");
const cube = @import("cube_db");
const f2 = cube.format;
const ps = cube.page_store;
const btree = cube.btree;

const allocator = std.testing.allocator;

/// 溢出页 payload 容量 = PAGE_SIZE - PAGE_HEADER_SIZE(24) - CRC(4) = 4068
const OVERFLOW_PAYLOAD: usize = f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4;

/// 计算给定 value 长度需要的溢出页数 = ceil(len / OVERFLOW_PAYLOAD)
fn expectedOverflowPages(vlen: usize) u32 {
    return @intCast(@divTrunc(vlen + OVERFLOW_PAYLOAD - 1, OVERFLOW_PAYLOAD));
}

/// 从 leaf root 读出第一个 entry，若是溢出 entry 则返回溢出首页号，否则 null
fn overflowFirstPage(store: ps.PageStore, root: u32) !?u32 {
    const payload = try btree.readNodePayload(store, root);
    var entries: [1]btree.DecodedLeafEntry = undefined;
    try btree.decodeLeafPayload(payload, &entries);
    const e = entries[0];
    // 溢出 entry 的 value 是 4 字节 page_no（.little）；flags & LEAF_FLAG_OVERFLOW
    if (e.value.len == 4 and (e.flags & 1) != 0) {
        return std.mem.readInt(u32, e.value[0..4], .little);
    }
    return null;
}

/// 沿 free_next 遍历溢出页链，返回遍历到的页号列表 + 校验每页 page_type
fn walkOverflowChain(store: ps.PageStore, first_page: u32, out: *std.ArrayList(u32)) !void {
    var cur: u32 = first_page;
    var guard: u32 = 0;
    while (cur != 0 and guard < 10000) : (guard += 1) {
        const page = try store.readPage(cur);
        const hdr = f2.decodePageHeader(page[0..f2.PAGE_HEADER_SIZE]);
        // 每页 page_type 必须是 OVERFLOW
        if (hdr.page_type != f2.PAGE_TYPE_OVERFLOW) return error.WrongPageType;
        try out.append(allocator, cur);
        cur = hdr.free_next;
    }
}

// ===== 1. 多页溢出链（50KB） =====

test "overflow_chain: 50KB value — chain length, page_type, content match" {
    var ms = ps.MemPageStore.init(allocator, 100000);
    defer ms.deinit();
    const s = ms.store();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    // 构造 50000 字节可验证的值（每字节 = i % 251，非平凡 pattern）
    var value: [50000]u8 = undefined;
    var i: usize = 0;
    while (i < value.len) : (i += 1) value[i] = @intCast(i % 251);

    const wr = try btree.insert(allocator, s, btree.NULL_ROOT, "big", &value, false, &dirty);
    // WriteResult.new_root 是页号 u32，insert 内部 dupe 的 key/value 已在函数内 free，调用方无需释放

    // 查询返回正确值
    const got = try btree.get(allocator, s, wr.new_root, "big");
    try std.testing.expect(got != null);
    defer allocator.free(got.?);
    try std.testing.expectEqual(@as(usize, 50000), got.?.len);
    try std.testing.expectEqualSlices(u8, &value, got.?);

    // 断言溢出链长度 = ceil(50000 / 4068) = 13
    const first = (try overflowFirstPage(s, wr.new_root)) orelse return error.NotOverflow;
    var chain = std.ArrayList(u32).empty;
    defer chain.deinit(allocator);
    try walkOverflowChain(s, first, &chain);
    try std.testing.expectEqual(expectedOverflowPages(50000), @as(u32, @intCast(chain.items.len)));
    // 13 页：50000 = 12*4068 + 16（最后一页只装 16 字节）
    try std.testing.expectEqual(@as(u32, 13), @as(u32, @intCast(chain.items.len)));

    // 逐页断言内容：前 12 页各 4068 字节，末页 16 字节，均与 value 对应段一致
    var offset: usize = 0;
    for (chain.items, 0..) |pn, idx| {
        const page = try s.readPage(pn);
        const hdr = f2.decodePageHeader(page[0..f2.PAGE_HEADER_SIZE]);
        try std.testing.expectEqual(f2.PAGE_TYPE_OVERFLOW, hdr.page_type);
        // 链表 free_next：非末页指向下一页，末页为 0
        if (idx + 1 < chain.items.len) {
            try std.testing.expectEqual(chain.items[idx + 1], hdr.free_next);
        } else {
            try std.testing.expectEqual(@as(u32, 0), hdr.free_next);
        }
        // payload 区内容
        const chunk_len = @min(OVERFLOW_PAYLOAD, 50000 - offset);
        const chunk = page[f2.PAGE_HEADER_SIZE ..][0..chunk_len];
        try std.testing.expectEqualSlices(u8, value[offset..][0..chunk_len], chunk);
        offset += chunk_len;
    }
    try std.testing.expectEqual(@as(usize, 50000), offset);
}

// ===== 2. 更大值（100KB） =====

test "overflow_chain: 100KB value — correct read-back and chain length" {
    var ms = ps.MemPageStore.init(allocator, 200000);
    defer ms.deinit();
    const s = ms.store();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    var value: [100000]u8 = undefined;
    var i: usize = 0;
    while (i < value.len) : (i += 1) value[i] = @intCast((i * 7) % 251);

    const wr = try btree.insert(allocator, s, btree.NULL_ROOT, "huge", &value, false, &dirty);

    const got = try btree.get(allocator, s, wr.new_root, "huge");
    try std.testing.expect(got != null);
    defer allocator.free(got.?);
    try std.testing.expectEqual(@as(usize, 100000), got.?.len);
    try std.testing.expectEqualSlices(u8, &value, got.?);

    // 链长度 = ceil(100000/4068) = 25
    const first = (try overflowFirstPage(s, wr.new_root)) orelse return error.NotOverflow;
    var chain = std.ArrayList(u32).empty;
    defer chain.deinit(allocator);
    try walkOverflowChain(s, first, &chain);
    try std.testing.expectEqual(expectedOverflowPages(100000), @as(u32, @intCast(chain.items.len)));
    try std.testing.expectEqual(@as(u32, 25), @as(u32, @intCast(chain.items.len)));
}

// ===== 3. 溢出页回收后可复用 =====

test "overflow_chain: freed overflow pages reused by later alloc (LIFO)" {
    var ms = ps.MemPageStore.init(allocator, 100000);
    defer ms.deinit();
    const s = ms.store();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    // put 50KB 溢出值
    var value: [50000]u8 = undefined;
    @memset(&value, 0x77);
    const wr1 = try btree.insert(allocator, s, btree.NULL_ROOT, "k", &value, false, &dirty);

    // 记录溢出首页号 + 链
    const first = (try overflowFirstPage(s, wr1.new_root)) orelse return error.NotOverflow;
    var chain = std.ArrayList(u32).empty;
    defer chain.deinit(allocator);
    try walkOverflowChain(s, first, &chain);
    const overflow_page_count = chain.items.len;

    // overwrite 为小内联值 → insertIntoLeaf 触发 freeOverflowPages 把旧链加入 dirty
    var dirty2 = std.ArrayList(u32).empty;
    defer dirty2.deinit(allocator);
    const wr2 = try btree.insert(allocator, s, wr1.new_root, "k", "small", false, &dirty2);
    _ = wr2;

    // dirty2 应包含旧溢出链页号（数量 >= overflow_page_count）
    var freed_count: usize = 0;
    for (dirty2.items) |pn| {
        for (chain.items) |opn| {
            if (pn == opn) freed_count += 1;
        }
    }
    try std.testing.expect(freed_count >= overflow_page_count);

    // 手动 flush dirty → freePage 入 freelist（模拟 writer pending_free 回收）
    for (dirty2.items) |pn| s.freePage(pn);

    // 后续 allocPage 应 LIFO 复用这些页：连续 alloc 应见到 chain 里的页号
    var reused: usize = 0;
    var allocd = std.ArrayList(u32).empty;
    defer allocd.deinit(allocator);
    var n: usize = 0;
    while (n < overflow_page_count) : (n += 1) {
        const pn = try s.allocPage();
        try allocd.append(allocator, pn);
        for (chain.items) |opn| {
            if (pn == opn) reused += 1;
        }
    }
    // 至少部分复用（LIFO，最先 alloc 的应是最后 free 的页）
    try std.testing.expect(reused > 0);
}

// ===== 4. freeOverflowPages 静默失败 =====

test "overflow_chain: freeOverflowPages silent on broken chain — no panic, partial dirty" {
    var ms = ps.MemPageStore.init(allocator, 100000);
    defer ms.deinit();
    const s = ms.store();
    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    // put 50KB 溢出值
    var value: [50000]u8 = undefined;
    @memset(&value, 0x99);
    const wr1 = try btree.insert(allocator, s, btree.NULL_ROOT, "k", &value, false, &dirty);

    // 取溢出链
    const first = (try overflowFirstPage(s, wr1.new_root)) orelse return error.NotOverflow;
    var chain = std.ArrayList(u32).empty;
    defer chain.deinit(allocator);
    try walkOverflowChain(s, first, &chain);
    try std.testing.expect(chain.items.len >= 3);
    // 破坏第 2 页的 free_next：指向一个无效页号（>= max_pages 或不存在）
    // 这会让 freeOverflowPages 遍历到第 2 页后，读 next（无效）时 readPage 失败 → 静默 return
    const break_page = chain.items[1];
    const w = try s.writePage(break_page);
    var hdr = f2.decodePageHeader(w[0..f2.PAGE_HEADER_SIZE]);
    const invalid_next: u32 = 0xFFFFFFFE; // 远超 max_pages，readPage 必 PageNotFound
    hdr.free_next = invalid_next;
    f2.encodePageHeader(w[0..f2.PAGE_HEADER_SIZE], &hdr);
    // 注意：不重算 CRC，freeOverflowPages 用 store.readPage 直读页头（不走 readNodePayload 的 CRC 校验）

    // overwrite 触发 freeOverflowPages —— 应不 panic
    var dirty2 = std.ArrayList(u32).empty;
    defer dirty2.deinit(allocator);
    const wr2 = btree.insert(allocator, s, wr1.new_root, "k", "v", false, &dirty2) catch |err| {
        // 若 insert 因链破坏失败也不算 panic-crash；但期望它成功（freeOverflowPages 静默吞错）
        return err;
    };
    _ = wr2;

    // 已遍历到的页（首页 + 破坏页本身）应进 dirty，断裂后的页（第 3 页起）不应进
    var found_first = false;
    var found_break = false;
    var found_after_break = false;
    for (dirty2.items) |pn| {
        if (pn == chain.items[0]) found_first = true;
        if (pn == break_page) found_break = true;
    }
    // 第 3 页及之后不应在 dirty（因链在 break_page 后断裂）
    var i: usize = 2;
    while (i < chain.items.len) : (i += 1) {
        for (dirty2.items) |pn| {
            if (pn == chain.items[i]) found_after_break = true;
        }
    }
    try std.testing.expect(found_first); // 首页回收
    try std.testing.expect(found_break); // 破坏页本身回收（在 readPage 失败前已 append）
    try std.testing.expect(!found_after_break); // 断裂后页不回收
}

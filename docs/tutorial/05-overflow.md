# 05 — 溢出页

固定 4KB 页的 B-tree 叶子节点内联值上限约 3800 字节（`MAX_INLINE_VALUE`）。大于此的值走**溢出页链**——用多个页串起来存一个值。

## 为什么需要溢出页

叶子页的 payload 区只有 4068 字节（4096 − 24 页头 − 4 CRC），还要容纳多个 entry 的元数据（tombstone、key、vlen、flags）。如果有一个很大的 value，可能挤不下，或者挤得下但导致单叶子页能容纳的条目数太少。

解决方式：value 超过阈值时，不直接内联存 value，而在条目中存一个 **溢出首页号**，值正文存到一或多页链上。

### 内联 vs 溢出

```
内联（value ≤ 3800 字节）：
 Leaf entry: tombstone(1) | klen(4) | key | vlen(4) | flags=0 | value(...)

溢出（value > 3800 字节）：
 Leaf entry: tombstone(1) | klen(4) | key | vlen(4) | flags=1 | ov_page(4)
                                                    ↑ flags 标记指示溢出
```

溢出链中的每页：

```
+------ 4KB --------+
| 页头 (24B)         |
|   page_type=4      |  ← PAGE_TYPE_OVERFLOW
|   free_next=next   |  ← 链表中下一页
+--------------------+
| payload (4068B)     |
|   （value 片段）   |
+--------------------+
| CRC32 (4B)          |
+--------------------+
```

链通过页头的 `free_next` 字段链接——这就是为什么 freelist 和溢出页复用同一个 `free_next` 字段。

## 核心源码讲解

### needsOverflow — 判定

```zig
fn needsOverflow(entry: LeafEntry) bool {
    return entry.value.len > MAX_INLINE_VALUE;
}
```

阈值 `MAX_INLINE_VALUE = 3800`——留出页头 24、CRC 4、多个 entry 元数据的空间（leaf 最多 32 条目，每个 entry 有 10 字节元数据，32×10=320，3800+320+24+4 = 4148 > 4096 → 所以实际上不是每章都能放 32 个 3800 字节的 value，这个阈值只是确保**单个值**内联不溢出页。）

### writeOverflowPages — 写溢出链

```zig
fn writeOverflowPages(store: PageStore, value: []const u8) !u32 {
    var remaining = value.len;
    var offset: usize = 0;
    var first_page: u32 = 0;
    var prev_page: u32 = 0;

    while (remaining > 0) {
        const page_no = try store.allocPage();
        const page = try store.writePage(page_no);
        const arr: *[f2.PAGE_SIZE]u8 = @ptrCast(page.ptr);
        const chunk = @min(remaining, OVERFLOW_PAYLOAD);  // 4068/次

        // 写页头
        const hdr = f2.PageHeader{
            .page_no = page_no,
            .page_type = f2.PAGE_TYPE_OVERFLOW,
            .gen = 0,
            .nkeys = 0,
            .free_next = 0,
        };
        f2.encodePageHeader(page[0..f2.PAGE_HEADER_SIZE], &hdr);
        // 写 payload 片段
        @memcpy(page[f2.PAGE_HEADER_SIZE..][0..chunk],
               value[offset..offset+chunk]);
        // 补零剩余
        const rem = OVERFLOW_PAYLOAD - chunk;
        if (rem > 0) @memset(page[f2.PAGE_HEADER_SIZE + chunk ..
                                  f2.PAGE_SIZE - 4], 0);
        f2.setPageChecksum(arr, f2.computePageChecksum(arr));

        if (first_page == 0) {
            first_page = page_no;
        } else {
            // 更新前页的 free_next 链接到本页
            const prev = try store.writePage(prev_page);
            const prev_arr: *[f2.PAGE_SIZE]u8 = @ptrCast(prev.ptr);
            var prev_hdr = f2.decodePageHeader(prev[0..f2.PAGE_HEADER_SIZE]);
            prev_hdr.free_next = page_no;
            f2.encodePageHeader(prev[0..f2.PAGE_HEADER_SIZE], &prev_hdr);
            f2.setPageChecksum(prev_arr, f2.computePageChecksum(prev_arr));
        }
        prev_page = page_no;
        remaining -= chunk;
        offset += chunk;
    }
    return first_page;
}
```

**逐段讲解：**

1. 循环分配新页，每页最多写 `OVERFLOW_PAYLOAD`（4068 字节）数据。
2. 第一页记作 `first_page` 返回——这个页号存到 leaf entry 的 4 字节字段中。
3. 后续页通过修改**前一页**的 `free_next` 字段形成链表。注意写者要重新写前页（read-modify-write），这会产生前页的旧版——但溢出页是新分配的，旧前页也还没回收，所以没问题。
4. 每页单独 CRC 校验——读时逐页验证。

### readOverflowValue — 读溢出链

```zig
fn readOverflowValue(allocator: std.mem.Allocator, store: PageStore,
                     first_page: u32, vlen: u32) ![]u8 {
    const result = try allocator.alloc(u8, vlen);
    errdefer allocator.free(result);
    var offset: usize = 0;
    var cur = first_page;
    while (cur != 0 and offset < vlen) {
        const payload = try readNodePayload(store, cur);
        const chunk = @min(vlen - offset, payload.len);
        @memcpy(result[offset..][0..chunk], payload[0..chunk]);
        offset += chunk;
        const page = try store.readPage(cur);
        const hdr = f2.decodePageHeader(page[0..f2.PAGE_HEADER_SIZE]);
        cur = hdr.free_next;   // 沿链走到下一页
    }
    return result;
}
```

从 `first_page` 沿 `free_next` 链逐页读取，每页 payload 拷入结果缓冲区。调用方获整段 value（调用方 `free` 释放）。

### freeOverflowPages — 回收溢出链

```zig
fn freeOverflowPages(store: PageStore, first_page: u32,
                     dirty: *std.ArrayList(u32), allocator: std.mem.Allocator) void {
    var cur = first_page;
    while (cur != 0) {
        const page = store.readPage(cur) catch return;
        const hdr = f2.decodePageHeader(page[0..f2.PAGE_HEADER_SIZE]);
        const next = hdr.free_next;
        dirty.append(allocator, cur) catch {};
        cur = next;
    }
}
```

沿链遍历，每页加入 dirty 列表。之后由 writer 的 pending_free 统一回收。注意：这个函数在 leaf 的 `fromPayload` 中被调用——**读入旧 leaf 时就把旧溢出页加入回收列表了**，不需要等 insert 时的脏页收集。

### 在 encodeLeafPayload 中触发

`encodeLeafPayload` 写叶子 entry 时遇到大 value 自动调用 `writeOverflowPages`：

```zig
if (is_ov) {
    buf[pos] = LEAF_FLAG_OVERFLOW;    // flags=1
    pos += 1;
    const ov_page = try writeOverflowPages(store, e.value);  // 写溢出链
    std.mem.writeInt(u32, buf[pos..][0..4], ov_page, .little); // 存首页号
    pos += 4;
} else {
    buf[pos] = 0;        // flags=0
    pos += 1;
    @memcpy(buf[pos..][0..e.value.len], e.value);  // 内联存值
    pos += e.value.len;
}
```

## 可运行片段

把以下代码保存到 `tests/overflow_tutorial_test.zig`，用 `zig build test` 执行：

```zig
const std = @import("std");
const cube = @import("cube_db");
const MemPageStore = cube.page_store.MemPageStore;
const btree = cube.btree;

test "大 value 溢出页链" {
    const allocator = std.testing.allocator;
    var ms = MemPageStore.init(allocator, 1 << 12);
    defer ms.deinit();
    const store = ms.store();

    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    var root: u32 = 0;

    // 写一个超过 4KB 的大 value
    const big_value = try allocator.alloc(u8, 5000);
    defer allocator.free(big_value);
    @memset(big_value, 0xAB);

    const result = try btree.insert(allocator, store, root,
        "bigkey", big_value, false, &dirty);
    root = result.new_root;

    // 读回
    const v = try btree.get(allocator, store, root, "bigkey");
    defer if (v) |val| allocator.free(val);

    try std.testing.expect(v != null);
    try std.testing.expectEqual(@as(usize, 5000), v.?.len);
    try std.testing.expectEqual(@as(u8, 0xAB), v.?[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), v.?[4999]);
}
```

## 要点回顾

- 大 value（> 3800 字节）自动走溢出页链，entry 中只存首页号（4 字节）。
- 溢出链用页头的 `free_next` 链接——与 freelist 共用同一字段。
- 每页最多 4068 字节 payload，页头 + CRC 固定占用 28 字节。
- `writeOverflowPages` 分配新页并写链，`readOverflowValue` 沿链读回，`freeOverflowPages` 回收链到 dirty 列表。
- 旧溢出页同样通过 pending_free + MVCC reader_count 安全回收。

至此，整个 cube_db 的核心数据流已通：**页格式 → B-tree → COW 写入 → MVCC 安全回收 → 溢出页兜底。**

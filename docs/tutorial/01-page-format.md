# 01 — 页格式

cube_db 的数据以 **固定 4KB 页** 为单位组织。这是最底层——理解页格式才能理解后续所有概念。

## 页是什么

一个页就是 4096 字节（`PAGE_SIZE`）。在文件或内存中，页按序号（页号 `page_no`）寻址。你读取或写入数据时，始终操作的是完整页。

页的内部布局：

```
+------ 4KB (4096 字节) ------+
| 页头 (24B)                   |
|   - page_no (u32)           |
|   - page_type (u8)          |
|   - gen (u64)               |
|   - nkeys (u16)             |
|   - free_next (u32)         |
|   - padding (5B)            |
+------------------------------+
| payload (4068B)              |
|   （页内容，依页类型不同）    |
+------------------------------+
| CRC32 (4B)                   |
+------------------------------+
```

页面三部分：**页头**（24 字节）、**payload**（4068 字节）、**CRC 校验和**（4 字节）。

### 页头字段

| 字段 | 类型 | 含义 |
|------|------|------|
| `page_no` | u32 | 页本身序号，抹除时自我标识 |
| `page_type` | u8 | 页类型：FREE=0, META=1, BRANCH=2, LEAF=3, OVERFLOW=4 |
| `gen` | u64 | 代次号（等于写入时 meta sequence），用于 MVCC |
| `nkeys` | u16 | 负载中的条目数（B-tree 节点用） |
| `free_next` | u32 | freelist 链的下一页（仅 FREE 页有意义） |

### 页类型

- `FREE` (0)：已回收的空闲页，链在 freelist 中待复用
- `META` (1)：元数据页，存引擎全局状态（仅页号 1、2）
- `BRANCH` (2)：B-tree 分支节点
- `LEAF` (3)：B-tree 叶子节点
- `OVERFLOW` (4)：溢出页链（大 value）

### 特殊页号

| 页号 | 用途 |
|------|------|
| 0 | `NULL_PAGE` — 空指针 |
| 1 | `META_PAGE_0` — meta 页 0（交替写） |
| 2 | `META_PAGE_1` — meta 页 1（交替写） |
| 3+ | 数据页起始 |

页号 0 用作 B-tree 中的空指针（无子节点）。页 1 和 2 是元数据页，不参与数据分配。

### CRC 校验

每页末尾 4 字节是 `CRC32` 校验和，覆盖 [0, 4092) 字节。写入时计算并存储，读取时验证。用于检测数据损坏。

## 核心源码讲解

### 页头编解码

`encodePageHeader` / `decodePageHeader` 是页面格式的核心——所有页共享的 24 字节头。

```zig
pub const PAGE_HEADER_SIZE: usize = 24;

pub fn encodePageHeader(buf: []u8, h: *const PageHeader) void {
    std.debug.assert(buf.len >= PAGE_HEADER_SIZE);
    var pos: usize = 0;
    std.mem.writeInt(u32, buf[pos..][0..4], h.page_no, .little);
    pos += 4;
    buf[pos] = h.page_type;
    pos += 1;
    std.mem.writeInt(u64, buf[pos..][0..8], h.gen, .little);
    pos += 8;
    std.mem.writeInt(u16, buf[pos..][0..2], h.nkeys, .little);
    pos += 2;
    std.mem.writeInt(u32, buf[pos..][0..4], h.free_next, .little);
    pos += 4;
    // padding 5 bytes (leave as is)
}
```

**逐段讲解：**

1. `std.debug.assert` 是 Zig 的运行时断言——超出缓冲区立即 crash，越早暴露错误越好。
2. 按小端序 (`.little`) 逐一写入各字段。Zig 的 `writeInt` 直接处理字节序，无需手动移位。
3. `page_no`（u32）占 4 字节，`page_type`（u8）占 1 字节，`gen`（u64）占 8 字节，`nkeys`（u16）占 2 字节，`free_next`（u32）占 4 字节 → 4+1+8+2+4=19 字节，再加 5 字节 padding 凑满 24。
4. 解码是反过来，用 `readInt` 读出：

```zig
pub fn decodePageHeader(buf: []const u8) PageHeader {
    std.debug.assert(buf.len >= PAGE_HEADER_SIZE);
    var pos: usize = 0;
    const page_no = std.mem.readInt(u32, buf[pos..][0..4], .little);
    pos += 4;
    const page_type = buf[pos];
    pos += 1;
    const gen = std.mem.readInt(u64, buf[pos..][0..8], .little);
    pos += 8;
    const nkeys = std.mem.readInt(u16, buf[pos..][0..2], .little);
    pos += 2;
    const free_next = std.mem.readInt(u32, buf[pos..][0..4], .little);
    return .{ .page_no = page_no, .page_type = page_type,
              .gen = gen, .nkeys = nkeys, .free_next = free_next };
}
```

用裸 `return .{ ... }` 语法构造 `PageHeader` 结构体——Zig 的结构体字面量可省略类型名，编译器从返回类型推断。

### CRC 校验

```zig
pub fn computePageChecksum(page: *const [PAGE_SIZE]u8) u32 {
    var crc = Crc32.init();
    crc.update(page[0 .. PAGE_SIZE - 4]);
    return crc.final();
}

pub fn setPageChecksum(page: *[PAGE_SIZE]u8, cs: u32) void {
    std.mem.writeInt(u32, page[PAGE_SIZE - 4 ..][0..4], cs, .little);
}

pub fn verifyPageChecksum(page: *const [PAGE_SIZE]u8) bool {
    const stored = std.mem.readInt(u32, page[PAGE_SIZE - 4 ..][0..4], .little);
    const computed = computePageChecksum(page);
    return stored == computed;
}
```

**关键设计：**

- 计算范围是 `[0, 4092)` 即跳过末尾 4 字节——不能把自己也异或进去。
- 校验时重新计算并与存储值比较，不等则数据已损坏。
- `*const [PAGE_SIZE]u8` 是指向固定长度数组的指针，不是切片——调用方保证提供完整页。

### Meta 页写入与读取

Meta 页承载引擎全局状态：root 页号、entry 数量、freelist 头等。

```zig
pub fn writeMetaPage(page: *[PAGE_SIZE]u8, meta: *const MetaPage, index: u32) void {
    std.debug.assert(index == 0 or index == 1);
    const page_no = if (index == 0) META_PAGE_0 else META_PAGE_1;
    // 写页头
    const hdr = PageHeader{
        .page_no = page_no,
        .page_type = PAGE_TYPE_META,
        .gen = meta.sequence,
        .nkeys = 0,
        .free_next = 0,
    };
    encodePageHeader(page[0..PAGE_HEADER_SIZE], &hdr);
    // 写 meta payload
    @memset(page[PAGE_HEADER_SIZE .. PAGE_SIZE - 4], 0);
    encodeMetaPayload(page[PAGE_HEADER_SIZE .. PAGE_SIZE - 4], meta);
    // 写校验和
    setPageChecksum(page, computePageChecksum(page));
}
```

**要点：**

- `index` 决定写入页 1 还是页 2——这是双 meta 交替机制的基础。
- 写入前先 `@memset` 清空 payload 区，防止旧数据残留。
- `gen` 直接取 `meta.sequence`——代次号就是写操作的序列号。

读取时从两个 meta 页取 sequence 较大的那个（crash 安全）：

```zig
pub fn readMetaPage(page0: *const [PAGE_SIZE]u8, page1: *const [PAGE_SIZE]u8) ?MetaPage {
    const m0 = readMetaPageSingle(page0);
    const m1 = readMetaPageSingle(page1);
    if (m0 == null and m1 == null) return null;
    if (m0 == null) return m1;
    if (m1 == null) return m0;
    return if (m0.?.sequence >= m1.?.sequence) m0 else m1;
}
```

写入时交替写两个 meta 页，读取时取 sequence 大的——如果写中途 crash，只有一个 meta 页更新，另一个保留旧值，读取总能拿到完整的最新状态。这就是 **O(1) 恢复** 的底层保障。

### PageStore 接口

PageStore 是存储层抽象，用 Zig 的 vtable 模式实现运行时多态：

```zig
pub const PageStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        allocPage: *const fn (ptr: *anyopaque) anyerror!u32,
        freePage:  *const fn (ptr: *anyopaque, page_no: u32) void,
        readPage:  *const fn (ptr: *anyopaque, page_no: u32) anyerror![]const u8,
        writePage: *const fn (ptr: *anyopaque, page_no: u32) anyerror![]u8,
        readMeta:  *const fn (ptr: *anyopaque) anyerror!?f2.MetaPage,
        writeMeta: *const fn (ptr: *anyopaque, meta: *const f2.MetaPage) anyerror!void,
        sync:      *const fn (ptr: *anyopaque) anyerror!void,
        mapsize:   *const fn (ptr: *anyopaque) u64,
    };
    // ... 委派方法
}
```

`ptr: *anyopaque` 指向具体实现（MemPageStore 或 FilePageStore），`vtable` 是函数指针表。每个 `pub fn` 方法只是简单委派：

```zig
pub fn allocPage(self: PageStore) !u32 {
    return self.vtable.allocPage(self.ptr);
}
```

这种模式使上层（B-tree、writer）不感知具体存储后端。测试用 `MemPageStore`（内存 HashMap），生产用 `FilePageStore`（mmap 文件）。

## 可运行片段

把以下代码保存到 `tests/format_tutorial_test.zig`，用 `zig build test` 执行：

```zig
const std = @import("std");
const format = @import("cube_db").format;

test "手写页头编解码和 CRC 校验" {
    // 构造一个页头
    const h = format.PageHeader{
        .page_no = 42,
        .page_type = format.PAGE_TYPE_LEAF,
        .gen = 1000,
        .nkeys = 16,
        .free_next = 0,
    };

    // 编解码往返
    var buf: [format.PAGE_HEADER_SIZE]u8 = undefined;
    format.encodePageHeader(&buf, &h);
    const got = format.decodePageHeader(&buf);
    try std.testing.expectEqual(h.page_no, got.page_no);
    try std.testing.expectEqual(h.page_type, got.page_type);
    try std.testing.expectEqual(h.gen, got.gen);

    // 构造完整页并校验
    var page: [format.PAGE_SIZE]u8 = undefined;
    @memset(&page, 0);
    format.encodePageHeader(&page, &h);
    @memset(page[format.PAGE_HEADER_SIZE .. format.PAGE_SIZE - 4], 0xbb);

    const cs = format.computePageChecksum(&page);
    format.setPageChecksum(&page, cs);
    try std.testing.expect(format.verifyPageChecksum(&page));

    // 篡改后校验应失败
    page[100] ^= 0xff;
    try std.testing.expect(!format.verifyPageChecksum(&page));
}
```

## 要点回顾

- 每页 4KB，页头 24B，CRC 4B，payload 4068B。
- 页类型决定 payload 含义：FREE/META/BRANCH/LEAF/OVERFLOW。
- 页号 0→NULL，1→meta0，2→meta1，3+→数据。
- CRC32 覆盖 [0, 4092)，写入时设、读取时验。
- 双 meta 交替写 = O(1) 恢复：读两个 meta，取 sequence 大者。
- PageStore vtable 隔离存储层，上层代码不关心内存还是 mmap。

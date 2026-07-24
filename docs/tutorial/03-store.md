# 03 - Store 抽象与实现

## 本章目标

读完本章，你应该能：
- 理解为什么 `cube_db` 要把文件操作抽象成 `Store` 接口。
- 看懂 `readBorrow`（借用切片）为什么是读得快的核心。
- 看懂 `MemStore`、`FileStore`、`FaultStore` 分别是做什么的。

---

## 1. 为什么需要 Store 抽象？

B-tree 和 DB 层都需要做这些事：

- 读一段字节（比如读一个节点）。
- 追加一段字节（比如写一个新节点）。
- 获取文件长度。
- 同步到磁盘（fsync）。

但底层实现可以不同：
- 单元测试时，希望用一个内存里的数组（快、无副作用）。
- 真实运行时，希望用磁盘文件（而且要 mmap 零拷贝读）。
- 测试崩溃时，希望人为注入故障。

如果 B-tree 直接写死 `zio.File`，那么：
- 单元测试每次都要创建临时文件，很慢。
- 测试崩溃场景需要真实拔电源，不可能。

所以 `cube_db` 定义了一个统一的 `Store` 接口：

```zig
pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read:        *const fn (ptr: *anyopaque, buf: []u8, offset: u64) anyerror!usize,
        append:      *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!u64,
        sync:        *const fn (ptr: *anyopaque) anyerror!void,
        setSize:     *const fn (ptr: *anyopaque, len: u64) anyerror!void,
        size:        *const fn (ptr: *anyopaque) anyerror!u64,
        readPhysical: *const fn (ptr: *anyopaque, buf: []u8, phys_offset: u64) anyerror!usize,
        physicalSize: *const fn (ptr: *anyopaque) anyerror!u64,
        readBorrow:  *const fn (ptr: *anyopaque, offset: u64, max: usize) anyerror![]const u8, // 借用切片（零拷贝）
        close:       *const fn (ptr: *anyopaque) void,
    };
};
```

这就是「运行时多态」：一个 `Store` 值可以指向 `MemStore`、`FileStore` 或 `FaultStore`，调用时通过 vtable 分发。

> **为什么不用 Zig 泛型（comptime）？** 如果用泛型，`Db` 的类型会变成 `Db(FileStore)`，公开 API 就复杂了。用 vtable 只损失一次间接跳转，IO 开销可忽略，但 API 保持简单。

---

## 2. 偏移：逻辑 == 物理

这是 `Store` 里最重要的概念，但现在它**很简单**。

**物理偏移** = 文件里真实的字节位置，从 0 开始。
**逻辑偏移** = B-tree 层用来定位记录的位置。

在 `cube_db` 里，**两者完全相等**（逻辑偏移 == 物理偏移）：

```zig
pub fn logicalToPhysical(logical_offset: u64) u64 {
    return logical_offset; // identity
}
pub fn physicalToLogical(physical_offset: u64) u64 {
    return physical_offset; // identity
}
```

> **历史**：早期有 marker（每 4096 字节插 1 字节标记），逻辑偏移和物理偏移不一样，要算「跳过几个 marker」。后来为了 mmap 零拷贝读，把 marker 去掉了，逻辑就 == 物理了，这两个函数退化成 identity，但保留着方便读代码。所以 B-tree 存的偏移直接就是文件偏移，没有任何换算。

所以：
- `Store.size()` 返回逻辑长度（== 物理长度，文件有多少字节）。
- `appendRaw` 返回这次追加的起始偏移，直接就是文件里的位置。
- 读记录时，偏移 `offset` 就是真的文件偏移，一步到位。

---

## 3. MemStore：内存里的测试 Store

`MemStore` 用 `std.ArrayList(u8)` 模拟文件。好处：

- 不需要真正创建文件。
- 毫秒级，可以跑成千上万次。
- 可以安全地破坏、截断、注入故障。

核心实现：

```zig
pub const MemStore = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8),   // 字节（逻辑==物理）
    logical_len: u64 = 0,      // == data.items.len
    sync_count: u32 = 0,        // 测试用：sync 被调用次数

    pub fn appendRaw(self: *Self, bytes: []const u8) !u64 {
        const start_logical = self.logical_len;
        try self.data.appendSlice(self.allocator, bytes); // 连续追加，无 marker
        self.logical_len += bytes.len;
        return start_logical;
    }
};
```

`appendRaw` 就是把字节连续地 append 到 ArrayList 末尾，返回起始偏移。读的时候直接切 ArrayList 的切片就行。

`readBorrow`（零拷贝）对 MemStore 就是直接返回 ArrayList 的一段切片，不分配、不复制：

```zig
fn vtReadBorrow(ptr, offset, max) ![]const u8 {
    const self: *Self = @ptrCast(...);
    if (offset >= self.logical_len) return &[_]u8{};
    const start: usize = @intCast(offset);
    const take = @min(max, self.logical_len - offset);
    return self.data.items[start..][0..take]; // 直接给指针，不复制
}
```

---

## 4. FileStore：真实磁盘 Store（含 mmap）

`FileStore` 基于 `zio.File` 提供位置 IO，数据真正写到磁盘。它还额外做了一件大事：**把整个文件 mmap 到内存**，读的时候直接读内存指针，不走系统调用。

```zig
pub const FileStore = struct {
    allocator: std.mem.Allocator,
    file: zio.File,
    logical_len: u64,     // == physical_len
    physical_len: u64,
    sync_count: u32 = 0,
    mmap_base: ?[*]align(mmap_mod.PAGE_SIZE) u8 = null,  // mmap 预留大区基指针
    mmap_region_len: usize = 0,
};
```

### 4.1 create：打开文件 + mmap

```zig
pub fn create(allocator, path) !Self {
    const file = try cwd.createFile(path, .{ .read = true, .truncate = false, .exclusive = false });
    const phys = file.size() catch 0;
    var self: Self = .{ ..., .logical_len = phys, .physical_len = phys };
    // mmap 预留大区（1 TB 虚拟地址，sparse 几乎不占资源）
    if (mmap_mod.mapReadOnly(@intCast(file.fd), MMAP_REGION)) |ptr| {
        self.mmap_base = ptr;
        self.mmap_region_len = MMAP_REGION;
    } else |_| {
        // mmap 失败则回退 pread，功能不退化（但非零拷贝）
    }
    return self;
}
```

- `logical_len = phys`：去 marker 后逻辑 == 物理，直接用文件大小。
- mmap 把整个文件映射成一段内存。这里映射 **1 TB 的虚拟地址区**——听起来吓人，但只是「预留地址空间」，没真正用内存也没占盘（sparse）。append-only 往后写新内容，新内容自动落到预留区里，**永远不用重新映射（remap）**，也就不会有「读着读着映射失效」的并发问题。

> **mmap 是什么？** 操作系统把文件「贴」到一段虚拟内存地址上。之后你读那段地址 = 读文件对应字节，不用每次都发 read 系统调用。系统调用的开销是微秒级的，而读内存指针是纳秒级，差几百倍。LMDB 这种顶级读性能的数据库就是靠 mmap。

### 4.2 readBorrow：零拷贝读（核心）

```zig
fn vtReadBorrow(ptr, offset, max) ![]const u8 {
    const self: *Self = @ptrCast(...);
    if (offset >= self.logical_len) return &[_]u8{};
    const take = @min(max, self.logical_len - offset);
    if (self.mmap_base) |base| {
        const src = base + offset;
        return src[0..take]; // 直接返回指向 mmap 的切片！不分配、不复制
    }
    return error.NoMmapBorrow; // 无 mmap 时借用不可行，回退 read（分配+复制）
}
```

这是整个读路径**快**的关键：调用方拿到的是一个**指向 mmap 内存的切片**，不是新分配的副本。读 B-tree 节点时，节点内容直接就在 mmap 里，指针指过去就能读，**零次内存分配、零次 memcpy**。

### 4.3 appendRaw：连续追加落盘

```zig
pub fn appendRaw(self, bytes) !u64 {
    const start_logical = self.logical_len;
    var i: usize = 0;
    while (i < bytes.len) {
        const n = try self.file.write(bytes[i..], self.physical_len); // pwrite 落盘
        self.physical_len += n;
        self.logical_len += n;
        i += n;
    }
    return start_logical;
}
```

写还是走 `file.write`（pwrite 系统调用），不用 mmap 写。为什么？因为 mmap 写要保证页对齐、要管虚拟页生命周期，麻烦；而读要快、写本来就是低频（写有 fsync 瓶颈，见 05 章）。**读 mmap、写 pwrite** 各取所长。

### 4.4 为什么读 mmap 安全？

`cube_db` 是 append-only COW：写新数据只往后追加，从不覆盖旧字节。所以 mmap 里旧字节永不变，正在读旧版本 B-tree 的读者看到的永远是一致快照——这就是天然的多版本并发控制（MVCC）。新写的字节落在 mmap 预留区的新页里，写完 fsync 后读者也能看到（POSIX 规定 MAP_SHARED 和 pwrite 对已落盘页一致）。

---

## 5. FaultStore：故障注入 Store

`FaultStore` 包装另一个 Store（通常是 `MemStore`），用于测试崩溃场景。它让代码「以为自己遇到了磁盘故障」。

```zig
pub const FaultConfig = struct {
    fail_after_bytes: ?usize = null,  // 写入 N 字节后返回 InjectedIoError
    truncate_to: ?usize = null,        // 把底层物理数据截断到某长度
};
```

例如：
- `fail_after_bytes = 100`：写入 100 字节后模拟磁盘写失败，测试代码是否能正确返回错误。
- `truncate_to`：模拟断电后文件尾部丢失，测试恢复逻辑。

它的 `readBorrow` / `read` 等都直接代理给内部 store。

---

## 6. 为什么 Store 层设计是核心？

| 实现 | 用途 | 好处 |
|------|------|------|
| MemStore | 单元测试 | 快、无副作用、可注入故障 |
| FileStore | 生产运行 | 真实持久化、fsync + **mmap 零拷贝读** |
| FaultStore | 崩溃测试 | 可复现崩溃场景 |

`btree.zig` 和 `db.zig` 全部面向 `Store` 接口编程。这意味着：
- 同样的 B-tree 逻辑，既能跑内存测试，也能跑真实文件测试。
- 读路径通过 `readBorrow` 享受 mmap 零拷贝，测试用 MemStore 也照样返回切片，零代码差异。

---

## 7. 本章小结

- `Store` 是运行时接口，屏蔽底层差异（内存/文件/故障）。
- 逻辑偏移 == 物理偏移（去 marker 后 identity），B-tree 存的偏移直接是文件偏移。
- `appendRaw` 连续追加字节，返回起始偏移。
- `readBorrow` 返回**借用切片**：FileStore 给 mmap 指针、MemStore 给 ArrayList 切片，零分配零复制——这是读路径快的根基。
- 写走 pwrite（落盘 + fsync），读走 mmap（零拷贝），各取所长；append-only 让读 mmap 永远安全。

---

## 8. 本章练习

1. 在 `src/store.zig` 里找到 `logicalToPhysical`，确认它就是 `return logical_offset`（identity）。
2. 在 `src/file_store.zig` 里找到 `vtReadBorrow`，跟着代码看它怎么返回 `base + offset` 的切片。
3. 思考：如果 mmap 不可用（`mmap_base == null`），`readBorrow` 返回什么？读路径会怎么回退？（提示：返回 `error.NoMmapBorrow`，`readRecord` 会回退到 `read` 即分配+复制。）
4. 思考：为什么 mmap 预留 1 TB 虚拟地址却几乎不耗内存？（提示：虚拟地址 ≠ 物理内存，没真正用到的页不占内存。）

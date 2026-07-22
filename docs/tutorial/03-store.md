# 03 - Store 抽象与实现

## 本章目标

读完本章，你应该能：
- 理解为什么 `cube_db` 要把文件操作抽象成 `Store` 接口。
- 清楚区分“逻辑偏移”和“物理偏移”。
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
- 真实运行时，希望用磁盘文件。
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
        close:       *const fn (ptr: *anyopaque) void,
    };
};
```

这就是“运行时多态”：一个 `Store` 值可以指向 `MemStore`、`FileStore` 或 `FaultStore`，调用时通过 vtable 分发。

你可能好奇：为什么不用 Zig 的泛型（comptime）？因为如果用泛型，`Db` 的类型会变成 `Db(FileStore)`，公开 API 就复杂了。用 vtable 只损失一次间接跳转，IO 开销可忽略，但 API 保持简单。

---

## 2. 逻辑偏移 vs 物理偏移

这是 `Store` 里最核心、最容易混淆的概念。

### 2.1 物理偏移

物理偏移就是文件里真实的字节位置，从 0 开始。

```
文件物理字节：
0   1   2   3   ...   4095 4096 4097 ...
```

### 2.2 逻辑偏移

逻辑偏移是**忽略 marker 字节**后，只看内容字节的偏移。

为什么需要逻辑偏移？

B-tree 节点保存的是文件里的位置。如果 marker 也算进位置，那么每跨过一个块，偏移就要“跳一下”，B-tree 的代码会很难写。

用逻辑偏移，B-tree 可以假装文件里根本没有 marker，存的就是一段连续的内容。Store 层负责把逻辑偏移映射到物理偏移。

### 2.3 块结构

每块大小 `4096`：

```
+------------+----------------------------------+
| marker: u8 | 内容：4095 字节                  |
+------------+----------------------------------+
```

物理偏移 `0, 4096, 8192, ...` 是 marker 位置。
物理偏移 `1..4095, 4097..8191, ...` 是内容位置。

### 2.4 转换公式

`src/store.zig` 提供了两个函数：

```zig
pub fn logicalToPhysical(logical_offset: u64) u64 {
    const block_index = logical_offset / (f.BLOCK_SIZE - 1); // 前面完整有多少块
    const in_block = logical_offset % (f.BLOCK_SIZE - 1);    // 在当前块内容中的位置
    return block_index * f.BLOCK_SIZE + 1 + in_block;          // +1 跳过 marker
}

pub fn physicalToLogical(physical_offset: u64) u64 {
    const block_index = physical_offset / f.BLOCK_SIZE;       // 物理块号
    const in_block = physical_offset % f.BLOCK_SIZE;          // 在物理块内的位置
    return block_index * (f.BLOCK_SIZE - 1) + (in_block - 1); // -1 去掉 marker
}
```

### 2.5 小例子

假设块大小是 **8 字节**（1 marker + 7 内容），方便画出来。实际项目是 4096，道理一样。

写入 `A B C D E F G H I J` 10 个字节。

**物理文件：**

```
物理偏移:  0   1   2   3   4   5   6   7 | 8   9  10  11  12  13  14  15
          [M] [A] [B] [C] [D] [E] [F] [G] | [M] [H] [I] [J] ...
```

- 物理偏移 `0` 和 `8` 是 marker。
- 物理文件总长度 = 16 字节。

**逻辑内容：**

```
逻辑偏移:  0   1   2   3   4   5   6   7   8   9
内容:      A   B   C   D   E   F   G   H   I   J
```

- 逻辑总长度 = 10 字节。
- `Store.size()` 返回 10，不是物理的 16。

转换表：

| 逻辑偏移 | 所在块 | 块内位置 | 物理偏移 | 说明 |
|----------|--------|----------|----------|------|
| 0 | 0 | 0 | 1 | 跳过块 0 marker |
| 6 | 0 | 6 | 7 | 仍在块 0 |
| 7 | 1 | 0 | 9 | 进入块 1，跳过块 1 marker |
| 8 | 1 | 1 | 10 | 继续读 |

### 2.6 `Store.read` 做了什么？

假设调用 `store.read(buf, 7)`，从逻辑偏移 7 开始读。

1. 把逻辑偏移 7 转成物理偏移 9。
2. 从物理偏移 9 开始读当前块剩余内容。
3. 如果还要读更多字节，跳到下一个 marker 之后（物理偏移 16），继续读。

B-tree 完全不用关心 marker 在哪里。

---

## 3. MemStore：内存里的测试 Store

`MemStore` 用 `std.ArrayList(u8)` 模拟物理文件。它的好处是：

- 不需要真正创建文件。
- 毫秒级，可以跑成千上万次。
- 可以安全地破坏、截断、注入故障。

核心实现：

```zig
pub const MemStore = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8),    // 物理字节（含 marker）
    logical_len: u64 = 0,        // 逻辑内容长度
    sync_count: u32 = 0,          // 测试用：sync 被调用次数

    pub fn appendRaw(self: *Self, bytes: []const u8) !u64 {
        const start_logical = self.logical_len;
        for (bytes) |b| {
            // 如果当前在物理块首，先写 marker
            if (self.data.items.len % f.BLOCK_SIZE == 0) {
                try self.data.append(self.allocator, f.MARKER_DATA);
            }
            try self.data.append(self.allocator, b);
            self.logical_len += 1;
        }
        return start_logical;
    }
};
```

`appendRaw` 的关键：
- 每次写一个字节前，检查当前是不是物理块首。
- 如果是，先写 marker，再写内容。
- 返回的是这次追加的**逻辑起始偏移**。

读的时候，MemStore 从逻辑偏移出发，通过 `logicalToPhysical` 找到物理位置，跳过 marker 读取。

---

## 4. FileStore：真实磁盘 Store

`FileStore` 基于 `zio.File` 提供位置 IO。它的逻辑和 MemStore 几乎一样，只是数据真正写到磁盘。

```zig
pub const FileStore = struct {
    allocator: std.mem.Allocator,
    file: zio.File,
    logical_len: u64,    // 逻辑长度
    physical_len: u64,    // 物理长度（含 marker）
    sync_count: u32 = 0,
};
```

`appendRaw` 同样按块插 marker，但调用 `zio.File.write` 落盘。

`create` 打开已有文件时，需要从物理大小反推逻辑长度：

```zig
const full_blocks = phys / f.BLOCK_SIZE;
const rem = phys % f.BLOCK_SIZE;
var logical: u64 = full_blocks * (f.BLOCK_SIZE - 1);
if (rem > 0) {
    if (rem > 1) logical += rem - 1; // 末块 marker 后还有内容
}
```

例如：
- 物理大小 8193 字节 = 2 完整块 + 1 个 marker。
- 逻辑大小 = 2 * 4095 = 8190 字节。
- 物理大小 8194 字节 = 2 完整块 + 1 marker + 1 内容字节。
- 逻辑大小 = 8190 + 1 = 8191 字节。

---

## 5. FaultStore：故障注入 Store

`FaultStore` 包装 `MemStore`，用于测试崩溃场景。它让代码“以为自己遇到了磁盘故障”。

```zig
pub const FaultConfig = struct {
    fail_after_bytes: ?usize = null,  // 写入 N 字节后返回 InjectedIoError
    truncate_to: ?usize = null,        // 把底层物理数据截断到某长度
};
```

例如：
- `fail_after_bytes = 100`：写入 100 字节后模拟磁盘写失败，测试代码是否能正确返回错误。
- `truncate_to`：模拟断电后文件尾部丢失，测试恢复逻辑。

---

## 6. 为什么 Store 层设计是核心？

| 实现 | 用途 | 好处 |
|------|------|------|
| MemStore | 单元测试 | 快、无副作用、可注入故障 |
| FileStore | 生产运行 | 真实持久化、fsync |
| FaultStore | 崩溃测试 | 可复现崩溃场景 |

`btree.zig` 和 `db.zig` 全部面向 `Store` 接口编程。这意味着：
- 同样的 B-tree 逻辑，既能跑内存测试，也能跑真实文件测试。
- 测试不需要改动业务代码。

---

## 7. 本章小结

- `Store` 是运行时接口，屏蔽底层实现差异。
- 逻辑偏移忽略 marker，让 B-tree 代码更简单。
- 物理偏移包含 marker，只在 Store 层和恢复header时使用。
- `MemStore` 是内存测试实现；`FileStore` 是真实磁盘实现；`FaultStore` 用于故障注入测试。

---

## 8. 本章练习

1. 在 `src/store.zig` 里找到 `logicalToPhysical` 和 `physicalToLogical`，用上面的 8 字节块例子验证几个转换。
2. 在 `MemStore` 中追加一个跨块边界的记录（比如大小接近 4096），验证 `read` 能完整读回。
3. 给 `FaultStore` 增加一个功能：让 `sync()` 调用时也返回 `error.InjectedIoError`，并写一条测试。
4. 思考：如果 `FileStore` 打开文件时物理大小是 0，逻辑大小应该是多少？

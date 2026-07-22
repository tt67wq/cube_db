# 02 - 文件格式与编解码

## 本章目标

读完本章，你应该能：
- 解释 `cube_db` 数据文件里每一个字节代表什么。
- 理解“块 + marker + 记录”的层级结构。
- 能看懂 `format.zig` 里的编码/解码函数。

---

## 1. 为什么数据文件格式很重要？

数据库最终就是一堆字节保存在磁盘上。要理解 `cube_db` 怎么做崩溃恢复、怎么做 compaction、怎么做 COW，都必须先理解文件格式。

可以这么想：文件格式是数据库的“语言”。你写的 `put("k", "v")`，最终要翻译成这种字节语言存进磁盘。

---

## 2. 总体设计：append-only 单文件

`cube_db` 只用一个数据文件。文件里所有数据都是**追加**的，不修改已有内容。

为什么 append-only 很重要？
- 旧数据永远不会被覆盖，所以读旧版本仍然安全。
- 崩溃时即使写到一半，旧 header 仍然有效。
- 配合 COW B-tree，天然支持多版本快照。

但 append-only 也会带来问题：文件会越来越大。所以后面有 **compaction** 来回收垃圾空间。

---

## 3. 块与 marker

数据文件被划分成一个个 **块（block）**，每块大小固定为 `4096` 字节。

每块的第一个字节是一个 **marker**，用来标记这块的用途。

```
+------------+----------------------------------+
| marker: u8 | 内容（4095 字节）                |
+------------+----------------------------------+
```

`format.zig` 里定义了两种 marker：

```zig
pub const MARKER_DATA: u8 = 0;    // 普通数据块
pub const MARKER_HEADER: u8 = 1;  // header 块
```

- `MARKER_DATA`（0）：块里存的是 B-tree 节点或 entry 数据。
- `MARKER_HEADER`（1）：块里存的是一个 **header 记录**。header 是数据库的一次“提交点”。

把文件分成块的好处：
- 启动时可以从文件末尾反向扫描 marker，快速找到最新的 header。
- header 总是从块首开始，避免跨块读取 header 时边界混乱。

---

## 4. 记录（record）格式

块里存的是一条条 **记录**。记录的格式是：

```
+----------+----------------+----------+
| len: u32 | payload: [len] | crc: u32 |
+----------+----------------+----------+
```

含义：
- `len`：payload 长度，4 字节，**大端**（big-endian）。
- `payload`：实际数据，长度由 `len` 决定。
- `crc`：校验和，覆盖 `len + payload`，也是 4 字节大端。

什么叫大端？就是高位字节在前。比如长度 `0x0000001A`（26），在文件里存成 `00 00 00 1A`。

为什么需要 CRC？因为磁盘可能坏、程序可能崩溃、写可能只完成一半。CRC 能检测出“数据被破坏了”。

---

## 5. 记录编解码代码

`src/format.zig` 提供了：

```zig
pub fn recordTotalSize(payload_size: usize) usize {
    return REC_LEN_SIZE + payload_size + REC_CRC_SIZE; // 4 + payload + 4
}

pub fn encodeRecord(buf: []u8, payload: []const u8) usize;
pub fn decodeRecord(buf: []const u8) Error![]const u8;
```

`encodeRecord` 的代码逻辑：

```zig
pub fn encodeRecord(buf: []u8, payload: []const u8) usize {
    const total = recordTotalSize(payload.len);
    std.debug.assert(buf.len >= total);

    var pos: usize = 0;
    // 1. 写 len
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(payload.len), .big);
    pos += 4;

    // 2. 写 payload
    @memcpy(buf[pos..][0..payload.len], payload);
    pos += payload.len;

    // 3. 计算并写 crc
    var crc = Crc32.init();
    crc.update(buf[0..pos]); // crc 覆盖 len + payload
    std.mem.writeInt(u32, buf[pos..][0..4], crc.final(), .big);
    pos += 4;

    return total;
}
```

`decodeRecord` 则反过来：

1. 先读 `len`。
2. 检查 buffer 是否够长（`len + 8`）。
3. 读 payload。
4. 重新计算 CRC，和文件里的 CRC 比较。
5. 如果不一致，返回 `error.CorruptCrc`。

---

## 6. Header 记录

Header 是数据库的“提交点”。每次写一批数据后，会追加一个 header。只有 header 成功写入并 fsync 后，这次写才可见。

```zig
pub const Header = struct {
    magic: u32 = MAGIC,        // 0x4355_4244，即 "CUBD"
    version: u16 = VERSION,    // 1
    btree_root: u64,           // 当前 B-tree root 的逻辑偏移
    entry_count: u64,          // 数据库里有多少条 key
    byte_size: u64,            // 逻辑数据量（live bytes）
    dirt: u64,                 // 垃圾字节数
};
```

Header payload 固定 38 字节：

```zig
pub const HEADER_PAYLOAD_SIZE: usize = 4 + 2 + 8 + 8 + 8 + 8; // 38
```

写入顺序：

```
+-------+---------+------------+-------------+-------------+--------+
| magic | version | btree_root | entry_count | byte_size   | dirt   |
| u32   | u16     | u64        | u64         | u64         | u64    |
+-------+---------+------------+-------------+-------------+--------+
```

编码函数：

```zig
pub fn encodeHeaderPayload(buf: []u8, h: Header) usize {
    std.mem.writeInt(u32, buf[0..4], h.magic, .big);
    std.mem.writeInt(u16, buf[4..6], h.version, .big);
    std.mem.writeInt(u64, buf[6..14], h.btree_root, .big);
    std.mem.writeInt(u64, buf[14..22], h.entry_count, .big);
    std.mem.writeInt(u64, buf[22..30], h.byte_size, .big);
    std.mem.writeInt(u64, buf[30..38], h.dirt, .big);
    return 38;
}
```

注意：header 本身也是一条记录，所以存进文件时是：

```
+----------+---------+----------+
| len: u32 | header  | crc: u32 |
+----------+---------+----------+
```

---

## 7. B-tree 节点记录

B-tree 有两种节点：**branch（内部节点）** 和 **leaf（叶子节点）**。

### 7.1 Branch 节点

Branch 负责把 key 范围分到不同子树。

内存结构：

```zig
pub const Branch = struct {
    keys: std.ArrayList([]u8),      // 分隔 key，数量 = children.len - 1
    children: std.ArrayList(u64),  // 子节点逻辑偏移
};
```

序列化格式：

```
+------+-------+-----------+------------+
| kind | count | keys...   | children...|
| u8   | u16   | u32+[]    | u64 each   |
+------+-------+-----------+------------+
```

- `kind = 1` 表示 branch。
- `count` 是子节点数量。
- `keys` 比 `children` 少一个：`keys[i]` 分隔 `children[i]` 和 `children[i+1]`。

### 7.2 Leaf 节点

Leaf 真正保存 key-value 对。

内存结构：

```zig
pub const Leaf = struct {
    entries: std.ArrayList(LeafEntry),
};

pub const LeafEntry = struct {
    tombstone: bool,   // true 表示已删除
    key: []const u8,
    value: []const u8,
};
```

序列化格式：

```
+------+-------+---------------------------+
| kind | count | entries...                |
| u8   | u16   | tombstone + klen + key +  |
|      |       | vlen + value              |
+------+-------+---------------------------+
```

- `kind = 2` 表示 leaf。
- 每个 entry 开头 1 字节 `tombstone`：1 表示删除，0 表示正常。
- 然后 `klen: u32`、`key`、`vlen: u32`、`value`。

为什么要 tombstone？因为 append-only 不能真正删除，所以用 tombstone 标记“这个 key 已删除”。

---

## 8. 跨块记录

记录可能跨越多个块。比如一个节点很大，从块 0 尾部开始，延伸到块 1 的内容区域。

Store 层（下一章讲）会自动处理这种跨块：读的时候跳过下一个 marker，写的时候自动插入 marker。

B-tree 层完全不需要关心跨块问题。

---

## 9. 文件格式总结

从大到小，文件结构是：

```
文件
├── 块 0（marker = 0）
│   ├── 记录 1：len | payload | crc
│   └── 记录 2：...
├── 块 1（marker = 0）
│   └── 记录 3（可能跨块）
├── ...
├── 块 N（marker = 1）
│   └── header 记录
└── 可能还有尾部垃圾
```

启动时：
1. 从文件末尾反向扫描 marker。
2. 找到最新的 `MARKER_HEADER`。
3. 读取 header 记录，CRC 校验。
4. 如果失败，继续往前找上一个 header。

---

## 10. 本章小结

- `cube_db` 只用一个 append-only 数据文件。
- 文件按 4096 字节分块，每块首字节是 marker。
- 记录格式是 `len + payload + crc`。
- Header 是提交点，包含 root、entry_count、byte_size、dirt。
- Branch 存分隔 key 和子节点偏移；Leaf 存 entry 和 tombstone。
- 跨块读写由 Store 层处理，上层无感知。

---

## 11. 本章练习

1. 在 `src/format.zig` 里找到 `encodeRecord` 和 `decodeRecord`，跟着注释走一遍逻辑。
2. 写一个小 Zig 程序：用 `encodeRecord` 编码 `"hello"`，然后故意翻转 payload 中一个字节，再用 `decodeRecord` 解码，观察是否返回 `error.CorruptCrc`。
3. 画一张图：一个数据文件有 3 个块，块 0 和块 1 是数据块，块 2 是 header 块，标出每个 marker 的位置。

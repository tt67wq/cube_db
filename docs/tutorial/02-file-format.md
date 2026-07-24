# 02 - 文件格式与编解码

## 本章目标

读完本章，你应该能：
- 解释 `cube_db` 数据文件里每一个字节代表什么。
- 理解「记录（record）」是怎么一层层堆在文件里的。
- 能看懂 `format.zig` 里的编码/解码函数。

---

## 1. 为什么数据文件格式很重要？

数据库最终就是一堆字节保存在磁盘上。要理解 `cube_db` 怎么做崩溃恢复、怎么做 compaction、怎么做 COW，都必须先理解文件格式。

可以这么想：文件格式是数据库的「语言」。你写的 `put("k", "v")`，最终要翻译成这种字节语言存进磁盘。

---

## 2. 总体设计：append-only 单文件

`cube_db` 只用一个数据文件。文件里所有数据都是**追加**的，不修改已有内容。

为什么 append-only 很重要？
- 旧数据永远不会被覆盖，所以读旧版本仍然安全。
- 崩溃时即使写到一半，旧的提交点（header）仍然有效。
- 配合 COW B-tree，天然支持多版本快照（多个版本同时存在，互不影响）。

但 append-only 也会带来问题：文件会越来越大。所以后面有 **compaction** 来回收垃圾空间。

> **一句话**：append-only 就是「只往文件末尾加东西，永不回头改」。像写日记，写一页翻一页，不涂改。

---

## 3. 文件里装的是什么：一条条记录

整个文件就是**一条接一条的记录**挨在一起，没有缝隙、没有特殊分隔符：

```
文件开头                                     文件末尾
  ↓                                            ↓
[记录1][记录2][记录3]...[记录N]
```

每条记录自己带长度，所以读的时候「先读长度，再按长度读内容」，一条接一条，不需要别的标记。

> **注意（历史小坑）**：早期的 `cube_db` 把文件按 4096 字节分块、每块首字节插一个「marker」字节来区分 header 块和数据块。后来为了读得更快（mmap 零拷贝，见第 03/04 章），把 marker 去掉了——marker 让文件字节不连续，挡住了「直接拿内存指针当数据用」这条路。现在文件是**纯连续字节**，逻辑偏移 == 物理偏移，简单又快。
>
> `format.zig` 里还留着 `MARKER_DATA` / `MARKER_HEADER` 常量，但**写数据时已经不再插入 marker**。你可以当它不存在。

---

## 4. 记录（record）格式

每条记录的格式是：

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

为什么需要 CRC？因为磁盘可能坏、程序可能崩溃、写可能只完成一半。CRC 能检测出「数据被破坏了」。读的时候重新算一遍 CRC，和文件里存的对不上，就知道这条记录坏了。

---

## 5. 记录编解码代码

`src/format.zig` 提供了：

```zig
pub const REC_LEN_SIZE: usize = 4;
pub const REC_CRC_SIZE: usize = 4;

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

还有一个 `decodeRecordNoCrc`：只读 `len` 和 payload、**不验 CRC**。这是读数据时为了快跳过 CRC 校验用的（写和恢复时仍然验 CRC，见 08 章）。

---

## 6. Header 记录

Header 是数据库的「提交点」。每次写一批数据后，会追加一个 header。只有 header 成功写入并 fsync 后，这次写才算真正生效。

```zig
pub const Header = struct {
    magic: u32 = MAGIC,        // 0x4355_4244，即 "CUBD"
    version: u16 = VERSION,    // 1
    btree_root: u64,           // 当前 B-tree root 的偏移
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

header 本身也是一条记录，所以存进文件时是：

```
+----------+---------+----------+
| len: u32 | header  | crc: u32 |
+----------+---------+----------+
```

> **header 在哪？** 每次 `applyBatch`（写一批）的最后一步就是 `appendHeaderRecord`：把 header 记录追加到文件末尾。所以**最新的 header 就是文件里最后一条 header 记录**。启动恢复时，从文件头开始一条条记录往后扫，记住最后一个「magic + version 都对、CRC 也对」的 header，就是最新提交点（见 08 章的 `getLatestHeader` 正向扫描）。

---

## 7. B-tree 节点记录

B-tree 有两种节点：**branch（内部节点）** 和 **leaf（叶子节点）**。它们各自也是一条记录。

### 7.1 Branch 节点

Branch 负责把 key 范围分到不同子树。

内存结构：

```zig
pub const Branch = struct {
    keys: std.ArrayList([]u8),      // 分隔 key，数量 = children.len - 1
    children: std.ArrayList(u64),  // 子节点偏移
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

为什么要 tombstone？因为 append-only 不能真正删除，所以用 tombstone 标记「这个 key 已删除」。读到 tombstone 就当这条 key 不存在。

> **leaf 里的 entry 是按 key 排好序的**。这一点在第 04 章的 `findInLeaf` 里很关键——可以直接顺序扫找到目标 key，不用把整页都解码出来。

---

## 8. 记录连续，没有跨块问题

记录大小不限。一个 B-tree 节点可能 8KB，跨好几条记录的边界——但这没关系，因为记录是连续字节、自己带长度，Store 层（下一章）按偏移读任意一段就行，上层完全不用关心。

（早期有 marker 时确实有「跨块要跳 marker」的麻烦事，现在 marker 去掉了，这个问题也一起消失了。）

---

## 9. 文件格式总结

从大到小，文件结构是：

```
文件开头                                          文件末尾
  ↓                                                 ↓
[记录1][记录2][记录3]...[节点记录][...][header 记录]  ← 最新提交点
```

启动恢复时：
1. 从文件头 offset=0 开始，按记录长度一条条往后走。
2. 每条解码，如果它是 header（magic + version 对、CRC 对）就记住它。
3. 走到文件尾或遇到坏记录（CRC 错 / 长度越界，多半是崩溃时写了一半）就停。
4. 最后记住的那个 header，就是最新有效提交点。

---

## 10. 本章小结

- `cube_db` 只用一个 append-only 数据文件。
- 文件是**连续字节**，一条条记录挨着，每条 = `len + payload + crc`。
- 记录有三种：header（提交点）、branch 节点、leaf 节点。header payload 固定 38 字节。
- Header 包含 root 偏移、entry 数、byte_size、dirt（垃圾量）。
- Branch 存分隔 key 和子节点偏移；Leaf 存 entry 和 tombstone。
- 启动时正向扫记录找最新 header，遇到坏记录就停（崩溃安全）。

---

## 11. 本章练习

1. 在 `src/format.zig` 里找到 `encodeRecord` 和 `decodeRecord`，跟着注释走一遍逻辑。
2. 写一个小 Zig 程序：用 `encodeRecord` 编码 `"hello"`，然后故意翻转 payload 中一个字节，再用 `decodeRecord` 解码，观察是否返回 `error.CorruptCrc`。
3. 对比 `decodeRecord` 和 `decodeRecordNoCrc`，想想为什么读数据热路径要用后者（提示：CRC 计算不便宜，写/恢复才需要验，读自己刚写的数据可以信）。

# 05 Delete：tombstone 写法

> LSM 的删除不删数据——写一条标记，compaction 时才物理清除

---

本章对应 `src/db.zig` 第 127-141 行的 `Db.delete` LSM 分支，涉及 `src/wal.zig` 的 `append(.delete)` 和 `src/memtable.zig` 的 `delete`。

---

## 函数签名

```zig
// src/db.zig:127
pub fn delete(self: *Db, key: []const u8) !void
```

参数：key，没有返回值。

---

## 数据流

```
db.delete("hello")
  │
  ├─ wal.append(.delete, "hello", "")     // WAL 写一条 tombstone 记录
  │
  └─ mt.delete("hello")                   // memtable 标记删除
```

**特别短**——就是两行代码：

```zig
if (self.mt) |mt| {
    if (self.wal) |w| _ = try w.append(.delete, key, "");
    _ = try mt.delete(key);
    return;
}
// COW 路径兜底：applyBatch 带 tombstone = true
```

---

## 第一步：WAL tombstone

```zig
_ = try w.append(.delete, key, "");
```

`EntryType.delete = 1`。写入 WAL 的格式和 `put` 完全一样，只是 type 字节不同：

```
[type=1(1B) + key_len(4B) + val_len(4B) + key(N) + val=""(0B) + crc32(4B)]
```

**为什么删除要写 WAL？** 因为删除操作也需要保持持久性——如果写完 memtable 就崩溃，WAL replay 时需要重放这条删除，否则数据库会**漏删**。

---

## 第二步：Memtable delete（`src/memtable.zig:82`）

```zig
pub fn delete(self: *Memtable, key: []const u8) !bool {
    if (self.index.get(key)) |idx| {
        // key 已在 memtable → 标记 tombstone，释放 value
        const entry = &self.entries.items[idx];
        if (!entry.tombstone) {
            entry.tombstone = true;
            self.size_bytes -|= entry.value.len;
            // key 保留在 index 中，用于屏蔽 B-tree 的旧值
        }
        return true;  // 已存在
    }
    // key 不在 memtable → 插入一条 tombstone 记录屏蔽 B-tree
    const owned_key = try self.allocator.dupe(u8, key);
    const idx = self.entries.items.len;
    try self.entries.append(self.allocator, .{
        .key = owned_key,
        .value = "",
        .tombstone = true,
    });
    try self.index.put(owned_key, idx);
    self.size_bytes += key.len;
    return false;
}
```

**两种场景**：

### 场景 1：key 在 memtable 中（刚写入过）

```
mt.put("hello", "world")     → entries: [(k="hello", v="world", ts=false)]
mt.delete("hello")           → entries: [(k="hello", v="world", ts=true )]
                                    # value 被释放，size 扣减，tombstone=true
```

此时 `mt.get("hello")` 返回 `null`（因为 `entry.tombstone == true`），而 B-tree 里如果有旧值也被 memtable 的 index 条目**屏蔽**了。

### 场景 2：key 不在 memtable 中（旧数据）

```
mt.delete("hello")           → entries: [(k="hello", v="", ts=true)]
                                    # key dupe 到 entries，index 指向它
```

即使 B-tree 里也没 "hello"，这个 tombstone 也没关系——compaction 灌 B-tree 时，tombstone 会变成一个带删除标记的 B-tree 条目，下次 compact 时清理。

---

## Tombstone 生命周期

```
写入时
  db.delete("hello")
    → wal.append(.delete)     // 磁盘：崩溃可恢复
    → mt.delete("hello")      // 内存：标记为已删

读取时
  db.get("hello")
    → mt.get("hello")         // 命中 tombstone → return null
    → btree.get("hello")      // memtable 无条目时才查 B-tree

Compaction 时
  compactor.flush(mt)
    → mt.snapshot()           // 包含 tombstone 条目
    → applyBatch(reqs)        // tombstone=true 写进 B-tree
    → mt.clear()              // memtable 清空

最终物理清除
  state.compact() 或下次 compaction
    → B-tree 内的 tombstone 在 rebalance 时被清除
```

---

## 对比 COW 路径的删除

```zig
// COW 路径：直接 applyBatch 带 tombstone=true
var future: zio.Future(wrt.OpResult) = .{};
try self.state.applyBatch(&.{.{
    .key = key,
    .value = "",
    .tombstone = true,
    .future = &future,
}});
_ = try future.wait();
```

COW 删除直接改 B-tree（复制页链、写新 meta），开销和 put 一样——~449 µs。LSM 的删除只要 2 步（WAL + memtable），和 put 一样快（~9.7 µs）。

---

## 读完本章能回答

- LSM 的删除是物理删除吗？（不是——写一条 tombstone 标记，等 compaction 才清除）
- 为什么删除要写 WAL？（崩溃恢复时需要知道这条删除）
- 如果 key 在 memtable 中，mt.delete 做什么？（标记 tombstone，释放 value，保留 key 在 index 中用于屏蔽）
- tombstone 什么时候被物理清除？（B-tree 层面的 compaction 时 rebalance）

---

下一步：[06 Flush / Compaction——后台线程灌 B-tree](06-compaction.md)

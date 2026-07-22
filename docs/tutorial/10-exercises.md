# 10 - 动手实验

## 本章目标

通过 10 个由浅入深的练习，把前面学到的知识落地。

建议按顺序做，每个实验独立成一个 commit。完成后跑 `zig build test`，确保没破坏现有测试。

---

## 实验 1：添加 `exists` 方法

### 目标

给 `Db` 加一个 `exists(key)` 方法，不分配 value 内存，只返回 key 是否存在。

### 提示

- 可以复用 `btree.get`，如果返回值非 null 就 free 掉，返回 true。
- 或者直接在 `btree.zig` 加一个 `contains` 函数，只找 key 不拷贝 value。

### 验证

```zig
const exists = try db.exists("k");
try std.testing.expect(exists);
```

---

## 实验 2：实现真正的 `putNoFsync`

### 目标

让 `putNoFsync` 不再调用 `fsync`。

### 步骤

1. 在 `writer.Request` 或 `Options` 里加一个 `fsync` 标志。
2. 在 `applyBatch` 里根据标志决定是否 `sync()`。
3. 在 `Db.sendRequest` 里，把 `put` 和 `putNoFsync` 区分开。

### 验证

用 `FileStore.sync_count` 或 `FaultStore` 统计 `sync()` 调用次数，确认 `putNoFsync` 不触发。

---

## 实验 3：统计并打印 store 大小

### 目标

在 `Db.close()` 前打印数据库统计信息。

### 要打印的内容

- `entry_count`
- `byte_size`（live bytes）
- `dirt`（垃圾字节）
- 物理文件大小（需要 `Store.physicalSize`）

### 提示

```zig
std.log.info("entries={d} live={d} dirt={d} phys={d}", .{
    state.entry_count.load(.acquire),
    state.byte_size.load(.acquire),
    state.dirt.load(.acquire),
    try store.physicalSize(),
});
```

---

## 实验 4：实现自动 compaction 执行

### 目标

当 `compact_count` 增加时，自动调用 `compact()`。

### 注意

- 避免递归：compact 本身会写 header，可能再次触发 compact。
- 简单做法：在 `Db.put` 后检查 `state.compact_count.load(.acquire)`，如果 > 0 则调用 `compact()` 并把计数清零。

### 验证

配置一个很小的 `auto_compact_min_bytes` 和较低的阈值，连续 put 覆盖同一个 key 多次，验证 compact 自动执行。

---

## 实验 5：清理 `.compact` 残留文件

### 目标

`Db.open` 时检查 `.compact` 文件是否存在，如果存在则删除。

### 提示

在创建 `FileStore` 之前：

```zig
const compact_path = try std.fmt.allocPrint(allocator, "{s}.compact", .{path});
defer allocator.free(compact_path);
cwd.deleteFile(compact_path) catch {};
```

### 验证

手动创建一个 `.compact` 文件，然后 `Db.open`，验证文件被删除。

---

## 实验 6：父目录 fsync

### 目标

在 `doCompact` 的 `rename` 之后 fsync 父目录。

### 背景

`rename` 只是把目录项改了，但目录项本身可能还在操作系统缓存里。如果 `rename` 后、目录项落盘前断电，重启后可能看不到新文件。fsync 父目录能避免这个问题。

### 步骤

1. 在 `Db.open` 时打开父目录并保存 `dir` 句柄。
2. 在 `doCompact` 的 `rename` 后调用 `dir.sync(.{ .only_data = false })`。

### 验证

用 `FaultStore` 或 mock 记录 `sync` 调用顺序，断言“新文件 fsync → rename → 父目录 fsync”。

---

## 实验 7：reader refcount（高级）

### 目标

实现设计 §6 的 reader refcount，让 compaction 期间旧的读迭代器不受文件切换影响。

### 背景

当前 `doCompact` 会 `self.fs.close()`。如果此时正好有读迭代器在用旧文件，就会读失败。正确做法是：读开始时增加引用计数，迭代器释放时减少；旧文件在引用计数归零时才 close。

### 步骤

1. 给 `FileStore` 加 `reader_count: std.atomic.Value(usize)`。
2. 提供 `acquireRead()` 和 `releaseRead()` 方法。
3. `Db.get` / `Db.select` 调用 `acquireRead()`；`Iterator.deinit` 调用 `releaseRead()`。
4. `doCompact` 切换文件时，旧 FD 不立即 close，等 `releaseRead()` 归零时 close。

### 验证

在 `compact` 期间创建一个 `select` 迭代器，验证迭代器完成前旧文件 FD 不被关闭。

---

## 实验 8：属性测试扩展（高级）

### 目标

给 `Db` 加一层模型测试。

### 步骤

1. 在 `tests/db_test.zig` 里新建一个随机 op 序列。
2. 同时维护一个 `std.StringHashMap`。
3. 随机执行 put/delete，每步后用 `db.get` 验证与 map 一致。
4. 序列末尾重开 DB，验证持久化后的数据与 map 一致。

### 提示

每次重开 DB 比较慢，可以只在末尾重开一次，而不是每步都重开。

---

## 实验 9：给 B-tree 加节点合并（高级）

### 目标

当前删除只产生 tombstone，leaf 不会合并。试着实现删除后如果 leaf 条目过少，尝试和兄弟合并或借用。

### 提示

这是 B-tree 的常规操作，但会显著增加代码复杂度。建议先在 MemStore 上写大量测试，再考虑集成到 DB。

---

## 实验 10：实现 `clear()` 方法（高级）

### 目标

给 `Db` 加一个 `clear()` 方法，清空所有数据，但保留文件。

### 提示

最简单做法：
1. 写一个空的 header（`btree_root = 0`，`entry_count = 0`，`byte_size = 0`，`dirt = 0`）。
2. 截断文件到 header 末尾。
3. 更新 `state.root = 0`。

但这不会释放磁盘空间。更好的做法类似 compaction：重建空文件并切换。

---

## 推荐顺序

```
1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10
```

前 6 个是“改一处就见效”的练习；后 4 个需要跨模块改动或深入 B-tree 细节。

---

## 提交建议

每个实验一个 commit，message 格式：

```
experiment X: 简短描述
```

完成后一定要跑：

```bash
zig build test
zig build -Doptimize=ReleaseSafe
```

全部通过再提交。

---

## 如果卡住了怎么办？

1. 先回到本章前面章节，找到对应知识点。
2. 在 `tests/` 里先写一个小测试，验证你的想法。
3. 用 `std.debug.print` 打印中间状态。
4. 先让 MemStore 版本工作，再切换到 FileStore。

祝玩得开心。

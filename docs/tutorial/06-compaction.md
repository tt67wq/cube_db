# 06 Flush / Compaction：后台线程灌 B-tree

> LSM 的核心——把内存批量灌入持久化 B-tree

---

本章对应 `src/compactor.zig` 全部（线程模型 + flush），按需钻 `src/writer.zig` 的 `applyBatch`（compaction 落盘路径）。

**这是最重要的一章**。理解 compaction 才算理解 LSM。

---

## Compactor 全景

`Compactor` 是一个**后台线程**。当 memtable 超过阈值时，`signal(mt)` 唤醒它；它把 memtable 数据批量写入 B-tree，然后清空 memtable 和 WAL。

```
Memtable 满
  → db.put 里 mt.shouldFlush() = true
  → compactor.signal(mt)
  
后台线程 loop:
  → 拿到 pending memtable
  → flush(mt):
       snapshot → Request[] → rwlock.lock() → applyBatch → wal.truncate → mt.clear
```

---

## 数据流

```mermaid
flowchart TD
    subgraph 触发
        MT["memtable.shouldFlush()=true"]
        SIG["db.put → compactor.signal(mt)"]
    end

    subgraph 后台线程
        LOOP["threadLoop"]
        LOCK["rwlock.lock() 独占"]
        SNAP["mt.snapshot()"]
        BUILD["entries → Request[]"]
        AB["state.applyBatch(reqs)"]
        TRUNC["wal.truncate()"]
        CLEAR["mt.clear()"]
    end

    subgraph applyBatch 内部（按需钻）
        INSERT["btree.insert() 逐个写入"]
        META["写 meta 页（交替）"]
        FSYNC["fsync"]
        PENDING["脏页→pending_free"]
        SIGNAL["futures set ok"]
    end

    subgraph 最终状态
        MT_EMPTY["Memtable 清空"]
        WAL_EMPTY["WAL 文件重置"]
        BT_UPDATED["B-tree 包含新数据"]
    end

    MT --> SIG
    SIG --> LOOP
    LOOP --> SNAP
    SNAP --> BUILD
    BUILD --> LOCK
    LOCK --> AB
    AB --> INSERT
    INSERT --> META
    META --> FSYNC
    FSYNC --> PENDING
    PENDING --> SIGNAL
    SIGNAL --> TRUNC
    TRUNC --> CLEAR
    CLEAR --> MT_EMPTY
    TRUNC --> WAL_EMPTY
    INSERT --> BT_UPDATED
```

---

## 后台线程模型（`src/compactor.zig`）

### 启动

```zig
pub fn start(self: *Compactor) !void {
    self.running = true;
    self.thread = try std.Thread.spawn(.{}, struct {
        fn run(c: *Compactor) void { c.threadLoop(); }
    }.run, .{self});
}
```

### 线程循环

```zig
fn threadLoop(self: *Compactor) void {
    while (self.running) {
        self.mutex.lock() catch {};
        while (self.pending_memtable == null and self.running) {
            self.cond.wait(&self.mutex) catch continue;
        }
        const mt = self.pending_memtable orelse {
            self.mutex.unlock(); continue;
        };
        self.pending_memtable = null;
        self.mutex.unlock();

        self.flush(mt) catch {};
    }
}
```

**关键模式**：
- `mutex` 保护 `pending_memtable` 的读写
- `cond.wait` 让线程休眠（不占 CPU）
- `signal(mt)` 设置 pending 并 `cond.signal()` 唤醒
- 同一时间只处理一个 memtable（串行 compaction）

### Signal

```zig
pub fn signal(self: *Compactor, mt: *memtable_mod.Memtable) void {
    self.mutex.lock() catch {};
    defer self.mutex.unlock();
    self.pending_memtable = mt;
    self.cond.signal();  // 唤醒后台线程
}
```

> **Zig 注意**：`catch continue` 在锁操作里有点粗暴，但在这种简化实现里够用。`defer self.mutex.unlock()` 确保异常路径也能解锁。

---

## flush（核心）

```zig
fn flush(self: *Compactor, mt: *memtable_mod.Memtable) !void {
    // 1. 快照 memtable（排序好的全部条目）
    const entries = try mt.snapshot();
    defer self.allocator.free(entries);

    if (entries.len == 0) {
        try self.wal.truncate();
        mt.clear();
        return;
    }

    // 2. 转为 Request[]（带 future 用于同步）
    var reqs = try self.allocator.alloc(Request, entries.len);
    defer self.allocator.free(reqs);
    var futures = try self.allocator.alloc(zio.Future(wrt.OpResult), entries.len);
    defer self.allocator.free(futures);

    for (entries, 0..) |e, i| {
        futures[i] = .{};
        reqs[i] = .{
            .key = e.key, .value = e.value,
            .tombstone = e.tombstone,
            .future = &futures[i],
        };
    }

    // 3. 独占锁 → applyBatch → 等完成
    try self.rwlock.lock();
    defer self.rwlock.unlock();  // ponytail: 全局锁, per-account 锁如果争用严重

    try self.state.applyBatch(reqs);

    for (futures) |*f| _ = try f.wait();

    // 4. 清空 WAL 和 memtable（数据已安全落盘）
    try self.wal.truncate();  // 删除 WAL 文件，重建（空）
    mt.clear();               // 释放所有 entries，计数归零
}
```

**关键顺序**：
1. **先 snapshot**：把 memtable 数据拍照，这样 applyBatch 期间 mt 不变
2. **再独占锁**：`rwlock.lock()` 保证此时没有 `get` 在读（共享锁已释放）
3. **再 applyBatch**：写进 B-tree
4. **最后清空**：数据安全了再删 WAL 和 memtable

> **为什么顺序重要？** 如果先删 WAL 再 applyBatch，崩溃就丢失了数据。如果先 applyBatch 再删 WAL，崩溃时可以 replay 旧 WAL——B-tree 数据可能重复，但幂等。**安全 > 性能**。

---

## applyBatch 按需钻（`src/writer.zig:145`）

这是 compaction 落盘的关键。`flush` 调 `state.applyBatch(reqs)`，把 Request[] 批量写入 B-tree。

**7 步流程**：

### 1. 快照当前状态

```zig
const cur_root = self.root.load(.acquire);
const cur_sequence = self.sequence.load(.acquire);
const cur_entry_count = self.entry_count.load(.acquire);
const cur_byte_size = self.byte_size.load(.acquire);
```

取当前 B-tree 根页号、版本序列、条目数、字节数。

### 2. 逐个插入 B-tree

```zig
for (batch) |req| {
    const wr = btree.insert(self.allocator, self.store, new_root,
        req.key, req.value, req.tombstone, &batch_dirty);
    new_root = wr.new_root;
    batch_entry_delta += wr.count_delta;
    batch_byte_delta += wr.live_delta;
}
```

`btree.insert` 是 COW 路径的插入函数。每调一次：
- 从 `new_root` 开始找插入位置
- **复制**沿途页链（COW）
- 收集被替换的旧页号到 `batch_dirty`
- 返回 `WriteResult.new_root`（可能是新根页号，或不变）

### 3. 脏页暂存到 pending_free

```zig
for (batch_dirty.items) |pn| {
    self.pending_free.append(self.allocator, pn) catch {};
}
```

**不立即回收**这些脏页。因为可能有 `get` 还持有旧 root 的快照在找数据。只有所有读者退出后才释放。

### 4. 计算新 meta

```zig
const new_sequence = cur_sequence + 1;  // 序列递增
const new_entry_count = @intCast(@max(@as(i64, 0), ...));  // 条目数（防止负数）
const new_byte = @intCast(@max(@as(i64, 0), ...));  // 字节数
```

### 5. 写 meta 页

```zig
const meta = f2.MetaPage{
    .magic = f2.MAGIC_V2,
    .version = 2,
    .mapsize = self.store.mapsize(),
    .sequence = new_sequence,
    .root_page = new_root,
    .entry_count = new_entry_count,
    .byte_size = new_byte,
    .free_head = 0,
    .free_count = 0,
    .last_page = 0,
};
try self.store.writeMeta(&meta);
```

`writeMeta` 用 **交替写** 策略：
- 如果上次写了 meta0（页 1），这次写 meta1（页 2）
- 如果写一半崩溃，meta 页中 `sequence` 更大的那个是完整的
- 这就是 **O(1) 恢复** 的保障：最多读 2 个页

### 6. fsync

```zig
if (self.opts.fsync) {
    try self.store.sync();
}
```

`sync()` 确保所有页面数据落盘。如果 `fsync = false`（benchmark 模式），性能更好但数据不安全。

### 7. 原子更新

```zig
self.root.store(new_root, .release);
self.sequence.store(new_sequence, .release);
self.dirt.store(@intCast(self.pending_free.items.len), .release);
self.entry_count.store(new_entry_count, .release);
self.byte_size.store(new_byte, .release);
```

全部用 `store(.release)` —— 所有读者通过 `load(.acquire)` 看到一致的最新状态。

最后给所有 request 的 future 设置成功信号：

```zig
for (batch) |req| {
    req.future.set({});  // void 成功
}
```

---

## 对比：COW applyBatch vs LSM put

| 操作 | 做了啥 | 延迟 |
|------|--------|------|
| LSM put | WAL append(6.4µs) + mt.put(3.2µs) | **~9.7 µs** |
| COW put | applyBatch 单条直接写 B-tree | **~449 µs** |
| Compaction | snapshot → applyBatch **批量**写 N 条 | N×几十 µs（均摊到每次 put） |

Compaction 把 N 次 put 攒成一批写 B-tree，均摊每条的 B-tree 写成本。而且 memtable 越大，分摊越薄——这就是 LSM「**把随机写先缓存在内存，再批量归并到持久层**」的精髓。

---

## 读完本章能回答

- Compactor 的后台线程怎么被唤醒的？（signal → cond.signal → threadLoop 醒来）
- Flush 的 4 步顺序为什么重要？（先 applyBatch 落盘，再清 WAL/memtable，崩溃不丢数据）
- applyBatch 的 7 步做了什么？（insert COW → pending_free → 算 meta → 写 meta → fsync → 更新状态 → future 完成）
- 脏页为什么不立即回收？（MVCC 读者可能还在读旧 B-tree 快照，等读者归零才释放）
- O(1) 恢复怎么工作的？（两个 meta 页交替写，sequence 大的那个是完整的）
- Compaction 后为什么能 truncate WAL？（因为数据已安全写入 B-tree，meta 页已 fsync）

---

下一步：[07 Recovery——WAL replay 与调用方职责](07-recovery.md)

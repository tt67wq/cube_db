# 03 — COW 写入

前两章建立了页格式和 B-tree。本章把两者串联——写请求如何批量应用到引擎。

## 写流程概览

`applyBatch` 是写入口。一次 call 完成以下步骤：

```
1. 快照当前 root/sequence/entry_count/byte_size
2. 对 batch 中每个 request 调用 btree.insert（COW 产生新页路径）
3. 收集旧页到 pending_free（不立即回收，MVCC 安全）
4. 写新 meta（含新 root、新 sequence）
5. fsync（可选）
6. 原子更新状态
7. 完成后唤醒等待的 future
8. 如果无活跃 reader，立即 flush pending_free
```

### COW 语义

B-tree 的 `insert` 不原地修改页——它写新页，返回新 root，旧页号进 dirty 列表。`applyBatch` 把这些 dirty 页累积到 `pending_free`，在读者安全时（reader_count=0）才真正交还 freelist。

### 双 meta 交替

meta 页有两个（页号 1 和 2），`writeMeta` 交替写入。写入顺序：页头 → payload → CRC → 切换索引。读取时取 sequence 更大的那个。

crash 场景：假设写 meta0 完成但 meta1 未写，下次启动读两个 meta，取 sequence 大者——拿到的是 meta0（已更新但 sequence 大）或 meta1（旧但完整）。无论哪种，都不会读到半写页面。

### O(1) compact

compact 只做一件事：**写一个新 meta，把 dirt 清零**。不重写任何数据页。旧页早已在 pending_free 中被 freelist 回收，物理空间可复用。

```
compact():
  1. 如果无活跃 reader → flushPendingFree（把 pending_free 归还 freelist）
  2. 写新 meta（sequence+1, dirt=0）
  3. fsync
```

## 核心源码讲解

### applyBatch

```zig
pub fn applyBatch(self: *State, batch: []const Request) !void {
    if (self.closed.load(.acquire)) {
        for (batch) |r| r.future.set(error.Closed);
        return;
    }

    // 1. 快照当前状态
    const cur_root = self.root.load(.acquire);
    const cur_sequence = self.sequence.load(.acquire);
    const cur_entry_count = self.entry_count.load(.acquire);
    const cur_byte_size = self.byte_size.load(.acquire);

    // 2. 收集脏页
    var batch_dirty = std.ArrayList(u32).empty;
    defer batch_dirty.deinit(self.allocator);
    var batch_entry_delta: i64 = 0;
    var batch_byte_delta: i64 = 0;
    var new_root = cur_root;

    for (batch) |req| {
        const wr = btree.insert(self.allocator, self.store, new_root,
                                req.key, req.value, req.tombstone, &batch_dirty)
            catch |err| {
                for (batch) |r| r.future.set(err);
                return;
            };
        new_root = wr.new_root;
        batch_entry_delta += wr.count_delta;
        batch_byte_delta += wr.live_delta;
    }

    // 3. 脏页进 pending_free（延迟回收）
    for (batch_dirty.items) |pn| {
        self.pending_free.append(self.allocator, pn) catch {};
    }

    // 4-5. 写新 meta + fsync
    const new_sequence = cur_sequence + 1;
    ...
    try self.store.writeMeta(&meta);
    if (self.opts.fsync) try self.store.sync();

    // 6. 原子更新状态
    self.root.store(new_root, .release);
    self.sequence.store(new_sequence, .release);
    self.dirt.store(@intCast(self.pending_free.items.len), .release);
    self.entry_count.store(new_entry_count, .release);
    self.byte_size.store(new_byte, .release);

    // 7. 信号成功
    for (batch) |req| req.future.set({});
}
```

**逐段讲解：**

1. **批量插入**：循环调用 `btree.insert`，每次传给当前 new_root。B-tree layer 每次返回新 root 页号，所以 batch 内的 insert 是顺序依赖的——后一个在前一个的基础上插入。

2. **脏页收集**：`btree.insert` 把需要释放的旧页号追加到 `batch_dirty`。所有旧页在 writer 层统一管理，而非立即归还 freelist——因为可能有其他 reader 仍在读旧页。

3. **`Future` 模式**：每个 request 含一个 `*zio.Future(OpResult)`。成功时 `.set({})`，失败时 `.set(err)`，使调用方能以阻塞或回调方式等待结果。

4. **原子更新**：`root`, `sequence`, `entry_count`, `byte_size` 都是 `std.atomic.Value`，用 `store(.release)` 写入——确保之前所有 I/O 对其他线程可见。

5. **延迟回收**：最后检查 `reader_count`——如果为 0，立即 `flushPendingFree` 把批量旧页交还 freelist。如果 >0，等待 future reader 退出时触发。

### compact

```zig
pub fn compact(self: *State) !void {
    if (self.reader_count.load(.acquire) == 0) {
        self.flushPendingFree();
    } else {
        self.dirt.store(0, .release);
    }

    const cur_root = self.root.load(.acquire);
    const cur_sequence = self.sequence.load(.acquire);
    const cur_entry_count = self.entry_count.load(.acquire);
    const cur_byte_size = self.byte_size.load(.acquire);

    const meta = f2.MetaPage{
        .magic = f2.MAGIC_V2,
        .version = 2,
        .mapsize = self.store.mapsize(),
        .sequence = cur_sequence + 1,
        .root_page = cur_root,
        .entry_count = cur_entry_count,
        .byte_size = cur_byte_size,
        .free_head = 0,
        .free_count = 0,
        .last_page = 0,
    };
    try self.store.writeMeta(&meta);
    if (self.opts.fsync) try self.store.sync();
    self.sequence.store(cur_sequence + 1, .release);
    self.dirt.store(0, .release);
}
```

**要点：**

- compact 不碰任何数据页——只写 meta。这就是 O(1)。
- writer.zig 注释准确：`// ponytail: MVP 不阻塞，只清计数`——如果读者活跃，只清 dirt 计数不真正 flush。复杂场景下需要阻塞等 reader 退出，MVP 简化了。
- meta 的 `sequence` 递增 1——确保下次 `readMetaPage` 取到最新的 meta。

### pending_free 和 reader 的关系

```zig
fn flushPendingFree(self: *State) void {
    for (self.pending_free.items) |pn| {
        self.store.freePage(pn);
    }
    self.pending_free.clearRetainingCapacity();
    self.dirt.store(0, .release);
}
```

`freePage` 把页号归还 freelist（MemPageStore 是 push 到 freelist ArrayList，FilePageStore 是写 freelist 页）。关键在于：调用 `flushPendingFree` 时调用方保证 **没有 reader 持有这些旧页的引用**。

本章和下一章（MVCC）紧密关联——pending_free 是 MVCC 安全回收的核心机制。

## 可运行片段

把以下代码保存到 `tests/writer_tutorial_test.zig`，用 `zig build test` 执行：

```zig
const std = @import("std");
const cube = @import("cube_db");
const MemPageStore = cube.page_store.MemPageStore;
const zio = @import("zio");

test "applyBatch 批量写入 + compact" {
    const allocator = std.testing.allocator;
    var ms = MemPageStore.init(allocator, 1 << 10);
    defer ms.deinit();
    const store = ms.store();

    const wrt = cube.writer;
    var state = wrt.State.init(allocator, store, .{ .fsync = false });
    defer state.deinit();

    // 构造 3 个写请求
    var f1: zio.Future(wrt.OpResult) = .{};
    var f2: zio.Future(wrt.OpResult) = .{};
    var f3: zio.Future(wrt.OpResult) = .{};

    const batch = [_]wrt.Request{
        .{ .key = "alpha", .value = "100", .tombstone = false, .future = &f1 },
        .{ .key = "beta",  .value = "200", .tombstone = false, .future = &f2 },
        .{ .key = "gamma", .value = "300", .tombstone = false, .future = &f3 },
    };

    try state.applyBatch(&batch);

    // 所有请求成功
    _ = try f1.wait();
    _ = try f2.wait();
    _ = try f3.wait();

    // compact
    try state.compact();
    try std.testing.expectEqual(@as(u64, 0), state.dirtCount());
}
```

## 要点回顾

- `applyBatch` 批量 insert → 收集旧页到 pending_free → 写 meta → fsync → 更新原子状态。
- 旧页不立即回收（MVCC 安全），等读者退出后 `flushPendingFree` 归还 freelist。
- 双 meta 交替写保障 crash 恢复：取 sequence 大的那个。
- compact 是 O(1) 的：只写 meta，不重写数据。`dirt` 计数清零。
- Zio Future 提供异步信号机制——writer 不阻塞调用方。

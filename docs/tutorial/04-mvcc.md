# 04 — MVCC 读者安全

cube_db 的 "MVCC" 不是传统的事务隔离——而是一种 **reader-safe 回收机制**：写者不阻塞读者，读者在旧页上读取一致性快照，写者产出的旧页等待所有读者释放后才回收。

## 问题

B-tree 的 COW 写入每批产生若干旧页（进 `pending_free`）。如果有一个读者正在读这些旧页，而写者立即把它们归还 freelist，freelist 就可能把这些页分配给新数据——读者就读到了被覆盖的半写数据。

解决方案：**引用计数**。

## 读者代次

每次 `beginRead()` 递增 `reader_count`，`endRead()` 递减：

```
reader_count = 0 → 无读者，写者可以安全 flush pending_free
reader_count > 0 → 有读者活跃，pending_free 不归还，积累等待
```

关键 API：

| 函数 | 作用 |
|------|------|
| `beginRead()` | +1 reader_count，返回当前 sequence（事务快照） |
| `endRead()` | -1 reader_count，若归零则触发 `flushPendingFree()` |
| `pendingFreeCount()` | 当前等待回收的脏页数 |
| `dirtCount()` | 当前 pending_free 中的页数（≈ 脏页水位） |
| `flushPendingFree()` | 把 pending_free 中的页真正交还 freelist |

### 数据流

```
写者 applyBatch → 旧页 → pending_free ↑ → reader_count > 0? → 是 → 攒着
                                                          → 否 → flushPendingFree
                                          ↑
读者 endRead → reader_count = 0 → flushPendingFree → pending_free 清空 → freelist 复用
```

## 核心源码讲解

### beginRead / endRead

```zig
pub fn beginRead(self: *State) u64 {
    _ = self.reader_count.fetchAdd(1, .acquire);
    return self.sequence.load(.acquire);
}

pub fn endRead(self: *State) void {
    const prev = self.reader_count.fetchSub(1, .release);
    if (prev == 1) {
        self.flushPendingFree();
    }
}
```

**逐段讲解：**

1. `beginRead` 用 `fetchAdd(1, .acquire)` 原子递增——acquire barrier 确保 reader_count 增加在后续内存操作之前可见。
2. 返回当前 `sequence`——这个 sequence 是读者快照的"版本号"。虽然当前代码没直接把 sequence 传给 B-tree 查询，但 reader_count 自身保证了所有 reader 退出前 dirty 页不会被自由复用。（ponytail：简单 reader_count 而非精确版本匹配，已覆盖常见场景。）
3. `endRead` 用 `fetchSub(1, .release)` 递减——release barrier 确保 reader 的所有读取操作完成后才递减计数。
4. 关键行：`if (prev == 1)` ——这条原子的意义：如果递减之前 reader_count 是 1，说明当前线程退出后 reader_count 归零。只有这个"最后一个读者退出"的瞬间触发 flush。

### flushPendingFree

```zig
fn flushPendingFree(self: *State) void {
    for (self.pending_free.items) |pn| {
        self.store.freePage(pn);
    }
    self.pending_free.clearRetainingCapacity();
    self.dirt.store(0, .release);
}
```

`freePage` 真正把页号还给 freelist（MemPageStore 是 push 到 ArrayList，FilePageStore 是写 freelist 页）。调用后这些页可以被 `allocPage` 分配。

### pendingFreeCount / dirtCount

```zig
pub fn pendingFreeCount(self: *State) usize {
    return self.pending_free.items.len;
}

pub fn dirtCount(self: *State) u64 {
    return self.dirt.load(.acquire);
}
```

`pendingFreeCount` 是 ArrayList 长度，`dirtCount` 是原子变量——后者是前者的快照（写入 meta 时设，flush 时清 0）。两者基本等价，只是更新时机不同。

### applyBatch 中的 MVCC 保护

applyBatch 末尾：

```zig
// 9. 若此时无读者，立即回收脏页
if (self.reader_count.load(.acquire) == 0) {
    self.flushPendingFree();
}
```

如果写者写的时候恰好没读者，立即 flush——pending_free 不积累。如果读者在，等待 endRead 触发。

## 可运行片段

把以下代码保存到 `tests/mvcc_tutorial_test.zig`，用 `zig build test` 执行：

```zig
const std = @import("std");
const cube = @import("cube_db");
const MemPageStore = cube.page_store.MemPageStore;
const zio = @import("zio");

test "MVCC 读者延迟回收" {
    const allocator = std.testing.allocator;
    var ms = MemPageStore.init(allocator, 1 << 10);
    defer ms.deinit();
    const store = ms.store();

    const wrt = cube.writer;
    var state = wrt.State.init(allocator, store, .{ .fsync = false });
    defer state.deinit();

    // 先写一条，让树有数据（后续 insert 才会产生脏页）
    {
        var f0: zio.Future(wrt.OpResult) = .{};
        try state.applyBatch(&.{.{ .key = "seed", .value = "x",
            .tombstone = false, .future = &f0 }});
        _ = try f0.wait();
    }

    // 启动读者
    const snap = state.beginRead();
    defer state.endRead();

    try std.testing.expect(snap >= 0);
    try std.testing.expectEqual(@as(u32, 1), state.reader_count.load(.acquire));

    // 写者写入
    var future: zio.Future(wrt.OpResult) = .{};
    try state.applyBatch(&.{.{ .key = "mvcc", .value = "test",
        .tombstone = false, .future = &future }});
    _ = try future.wait();

    // 读者活跃时：dirt > 0（脏页未回收）
    try std.testing.expect(state.dirtCount() > 0);
    try std.testing.expect(state.pendingFreeCount() > 0);

    // endRead（已在 defer 中）→ reader 归零 → flushPendingFree → dirt=0
}
```

## 要点回顾

- 写者产出的脏页不立即回收——先在 `pending_free` 积累。
- `reader_count` 原子计数追踪活跃读者。
- 最后一个读者退出时触发 `flushPendingFree`，脏页归还 freelist。
- reader 读到的一致性快照由"页不回收"保证，而非传统 MVCC 的 undo log。
- 写者不阻塞读者，读者不阻塞写者——并发无锁。

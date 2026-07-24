# 05 - Writer 与状态管理

## 本章目标

读完本章，你应该能：
- 理解 `writer.zig` 在写路径中的作用。
- 看懂 `applyBatch` 用 `BTreeBatch` 一次 flush 的流程。
- 理解 `State` 里每个字段的含义。
- 知道 group commit 怎么合并并发写。

---

## 1. writer 是做什么的？

用户调用 `db.put("k", "v")` 后，真正落到磁盘上需要几个步骤：

1. 用 COW B-tree 生成新的 root。
2. 把新节点追加到文件。
3. 写一个新的 header（提交点）。
4. 调用 `fsync` 保证数据落盘。
5. 原子更新内存里的 root 指针。

`writer.zig` 负责把这些步骤封装成 `applyBatch`。

原设计里，writer 是一个独立协程，通过 channel 接收写请求批量处理。现在改成了「group commit（leader/follower）」：并发 `put` 不各自 fsync，而是多个并发请求自动合并成一次 `applyBatch`（1 次 fsync）。这个机制在 `db.sendRequest` 里实现，见第 06 章。`writer.applyBatch` 本身只管「把一批请求应用到树 + 写 header + fsync」。

另外，现代的 `applyBatch` 不再是逐个 `btree.insert`（那样每个 op 都要重读+重写整条路径，N 个 op 就 N×路径重写），而是用 **BTreeBatch**：把整批 op 先在内存里的「缓存树」上应用，最后**一次性 flush**（只重写真正变脏的节点）。这是单线程批量写快 1000× 的原因。

---

## 2. 核心结构

### 2.1 Options

```zig
pub const Options = struct {
    auto_compact_dirt_ratio: ?f32 = 0.30,   // 自动 compact 垃圾比例阈值
    auto_compact_min_bytes: u64 = 16 * 1024 * 1024, // 触发自动 compact 的最小文件大小
    fsync: bool = true,                     // 是否默认 fsync
};
```

这些参数在 `Db.open` 时传入，控制写行为。

### 2.2 Request

```zig
pub const Request = struct {
    key: []const u8,
    value: []const u8,
    tombstone: bool,
    future: *zio.Future(OpResult),
};
```

一个写请求包含：
- key：要操作的 key。
- value：要写入的 value（删除时为空）。
- tombstone：是否为删除。
- future：调用方用 `zio.Future` 等待结果。

### 2.3 State

```zig
pub const State = struct {
    allocator: std.mem.Allocator,
    store: Store,
    fs: *file_store.FileStore,
    root: std.atomic.Value(u64),         // 当前 DB 层 root：0 = 空树，n = btree 偏移 + 1
    dirt: std.atomic.Value(u64),         // 垃圾字节数
    entry_count: std.atomic.Value(u64), // entry 数量
    byte_size: std.atomic.Value(u64),     // 逻辑数据量
    opts: Options,
    closed: std.atomic.Value(bool),       // 是否已关闭
    compact_count: std.atomic.Value(u32), // 自动 compact 触发次数（测试用）
};
```

这些字段都是原子值，因为读线程会并发读 `root`。

---

## 3. applyBatch 详解

```zig
pub fn applyBatch(state: *State, batch: []Request) !void
```

作用：把一批请求应用到 B-tree，生成新 root，写 header，fsync，更新状态。

流程：

```mermaid
graph TD
    A[applyBatch] --> B[快照当前 root]
    B --> C[BTreeBatch 应用整批]
    C --> D{出错?}
    D -->|是| E[已处理设成功 失败设错误]
    D -->|否| F[写 header]
    F --> G[fsync]
    G --> H[原子更新 root/dirt/count/byte_size]
    H --> I[所有请求 set success]
    I --> J{检查自动 compact?}
    J -->|是| K[compact_count + 1]
```

### 3.1 快照当前 root

```zig
const cur_root = state.root.load(.acquire);
var bt_root: u64 = if (cur_root == 0) btree.NULL_ROOT else cur_root - 1;
```

`root` 在 DB 层是 `0 = 空树，n = btree 偏移 + 1`。传给 B-tree 时需要转换。

### 3.2 BTreeBatch：缓存树 + 一次 flush

旧实现是逐个 `btree.insert`（每个 op 独立走一遍 COW 路径）。现在用 `btree_batch.BTreeBatch`：

```zig
var bt = btree_batch.BTreeBatch.init(state.allocator, state.store, bt_root);
defer bt.deinit();
for (batch) |req| {
    bt.apply(req.key, req.value, req.tombstone) catch |err| {
        // apply 失败：全批不提交，全部 future set err
        for (batch) |r| r.future.set(err);
        return;
    };
}
const wr = try bt.commit(); // 一次 flush：只重写变脏的节点，算 offset，写 store
```

BTreeBatch 关键点：
- **节点缓存**：读过的节点放内存缓存，同一个节点被多个 op 命中只读一次、只写一次。
- **脏集**：只有真正改了的节点才标记变脏，flush 时只重写这些。
- **自底向上 flush**：先 flush 子节点拿到真实偏移，再 flush 父节点（父的 children 指向子的真实偏移），保证 offset 正确。
- 这样 N 个 op 摊薄成 ~1 次 header + 1 次 fsync + 只重写变脏的少数节点。

每个请求调用 `bt.apply`。注意：如果某个请求失败，整批回滚，不写 header。

### 3.3 写 header

```zig
const new_db_root = if (bt_root == btree.NULL_ROOT) 0 else bt_root + 1;
const new_count = ...;
const new_byte = ...;
const new_dirt = ...;

_ = try file_store.appendHeaderRecord(state.fs, .{
    .btree_root = new_db_root,
    .entry_count = new_count,
    .byte_size = new_byte,
    .dirt = new_dirt,
});
```

header 记录当前版本的所有元信息。

### 3.4 fsync

```zig
if (state.opts.fsync) {
    try state.store.sync();
}
```

只有 fsync 之后，数据才算真正安全落盘。如果 `fsync = false`，崩溃时可能丢失最近一次或几次写。

### 3.5 原子更新状态

```zig
state.root.store(new_db_root, .release);
state.dirt.store(new_dirt, .release);
state.entry_count.store(new_count, .release);
state.byte_size.store(new_byte, .release);
```

注意顺序：先写 header 并 fsync，再原子更新 root。这样读线程永远看不到“header 没写但 root 已变”的中间状态。

### 3.6 通知调用方

```zig
for (batch) |req| {
    req.future.set({});
}
```

每个请求通过 `zio.Future` 通知结果。`{}` 表示成功。

---

## 4. DB 层 root 编码

btree 层有效 root 偏移可能是 0（第一个节点）。DB 层需要在 header 里区分「空树」和「偏移 0」。

规则：

- DB 层 `root`：`0` = 空树；`n > 0` = btree 偏移 + 1。
- 转换代码：

```zig
fn currentBtreeRoot(self: *Db) u64 {
    const r = self.state.root.load(.acquire);
    return if (r == 0) btree.NULL_ROOT else r - 1;
}

// 写入 header 前
const new_db_root = if (bt_root == btree.NULL_ROOT) 0 else bt_root + 1;
```

举例：
- btree 偏移 0 → DB root = 1。
- 空树 → DB root = 0。

这样就不会混淆了。

---

## 5. 自动 compact 触发

每次 `applyBatch` 成功后会检查：

```zig
if (state.opts.auto_compact_dirt_ratio) |ratio| {
    const live = new_byte;
    const total = new_dirt + live;
    if (total >= state.opts.auto_compact_min_bytes and live > 0) {
        const dirt_ratio = @as(f64, @floatFromInt(new_dirt)) / @as(f64, @floatFromInt(total));
        if (dirt_ratio >= ratio) {
            _ = state.compact_count.fetchAdd(1, .monotonic);
        }
    }
}
```

当前 MVP 只统计触发次数，不自动执行 compaction。真正的自动 compact 是后续扩展点。

---

## 6. Group commit：并发写的合并

并发场景下，多个线程同时 `put` 会怎样？如果各自 `fsync`，N 个线程 = N 次 fsync，很贵。`cube_db` 用 **leader/follower group commit** 合并：

- 每个并发写请求先进一个共享队列。
- 第一个来的线程当 **leader**：它拿着写锁，把队列里所有请求（包括后来排队的）一次 `applyBatch`（1 次 fsync），然后继续清空队列直到空。
- 后来排队的线程是 **follower**：它们只把自己的请求塞进队列，然后阻塞等 `Future`，leader 处理完会唤醒它们。

结果：16 个线程 × 50 个 put（800 个写）实测只产生 ~117 次 fsync（合并 ~6.8×）。leader 的 `applyBatch` 一次性 set 所有请求的 future，follower 被唤醒拿到结果。

这套机制在 `db.sendRequest` 里实现（见第 06 章）。`writer.applyBatch` 本身不关心是单个还是合并——它就管「这批请求应用 + 写 header + fsync + set 全部 future」。

错误处理：leader 任何出错路径都经 `defer leaderReset` 让出 leader 身份，防 follower 死等。

---

## 7. 本章小结

- `writer.applyBatch` 用 `BTreeBatch`（缓存树 + 一次 flush）把一批 op 摊薄成 1 header + 1 fsync，单线程批量写快 ~1000×。
- `State` 是共享的写状态，所有字段都是原子的，读线程可以安全读 root。
- DB 层用 `root = btree_offset + 1` 编码来区分空树和偏移 0。
- 并发写走 group commit（leader/follower），多个 put 合并成 1 次 fsync。

---

## 8. 本章练习

1. 在 `writer.zig` 里找到 `applyBatch`，逐行注释每个步骤（快照 root → BTreeBatch.apply → commit flush → header → fsync → 更新状态 → set futures）。
2. 解释为什么 `applyBatch` 要先写 header、再 fsync、最后才原子更新 root？顺序能不能反过来？
3. 给 `applyBatch` 加一条测试：两个请求合并成一次 batch，验证 header 数只增加 1。
4. 读 `btree_batch.zig` 的 `commit`/`flushNode`，理解「自底向上 flush」（子先写拿 offset，父再写）为什么能保证 children offset 正确。
5. 解释：如果 `root` 是 `0`，为什么 B-tree 层要把它转成 `NULL_ROOT`？

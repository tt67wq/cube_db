# cube_db 写路径优化设计（详细版）

> 旧名 group-commit-design；范围扩为写路径三杠杆。文件名保留避免 churn。

## 0. TL;DR

三杠杆，正交可叠加：

1. **显式 `putBatch([]Entry)`**（单线程 fsync 杠杆）— 一次 applyBatch 含 N op，1 header + 1 fsync。durable。摊 fsync+header。
2. **`BTreeBatch` 批量树提交**（单线程 10x 钥匙）— 节点缓存 + 脏集 + 一次 flush，摊 COW 路径重写。N=100 → leaf 写 4 次 vs 100 次（~25x）。
3. **隐式 group commit**（并发杠杆）— leader/follower 合并并发 put 到一次 applyBatch。

1+2 给单线程 ~10x（COW 摊薄 + fsync 摊薄）。3 给并发再叠乘数。三者共享 `applyBatch`（改用 BTreeBatch）。

---

## 1. 目标与非目标

### 目标

- 单线程 put 100B 从 ~498us/op 降到 ~50us/op（~10x），攻 fsync + COW 两块。
- 并发 put 吞吐再叠 N 倍（leader 合并）。
- 保留 durable 语义（不靠 durability 窗口换吞吐）。

### 非目标

- 不改 `get`/`select`（读路径另案）。
- 不做 deferred/async sync（不开 durability 窗口；用户选了显式 batch 非 deferred）。
- 不改 compact 实现（只保证互斥不死锁）。
- 不全量重设计 B-tree（BTreeBatch 复用 Leaf/Branch/encode/decode）。

## 2. 背景与成本拆解

### 2.1 benchmark（NVMe，ReleaseFast，单线程）

| 指标 | 数值 |
|---|---|
| put 100B | 498 us/op |
| put 10KB | 3.9 ms/op |
| get 100B | 251 us/op |

### 2.2 单线程 put 498us 成本拆解（估算）

| 成分 | 估算 | 当前是否每 op 一次 |
|---|---|---|
| fsync | ~100–200us | 是（applyBatch 内 store.sync） |
| COW 路径重写（btree.insert） | ~250–350us | 是（读+解码+改+append，leaf+depth 个 branch） |
| mutex+future+header append | ~30–50us | header 每 op；mutex/future 每 op |

**fsync 占 ~30%，COW 占 ~60%。** 单去掉 fsync → ~1.4–2x。攻 COW（BTreeBatch）→ ~10x。两者都摊 → ~10x+。

### 2.3 COW 路径重写为何贵（scout 证实）

`btree.insert`（btree.zig:330）每次：
1. `readRecord` 读 leaf+所有祖先（深度~4）→ 解码。**`store.zig:vtRead` 逐逻辑字节读**，~8KB leaf = ~8000 次读+算。
2. 内存改（Leaf/Branch ArrayList）。
3. `appendLeaf`/`appendBranch` 重新编码+CRC+`store.append` 写全新节点。
4. 旧节点变垃圾（dirt_delta）。

N 个 insert 各自全路径重写。**Op2 读 Op1 刚写的 leaf 再重写一遍** → N leaf 写 + N×depth branch 写。

### 2.4 批量提交收益（Option B，scout 估算）

N=100、均匀 key、深度~3：
- 不同 leaf 数 K ≈ 100/32 ≈ 4。
- leaf 写：4 vs 100（~25x leaf IO）。
- branch 写：~4 vs 300（~75x branch IO）。
- 自底向上 flush：子先父后，祖先 branch 共享坍缩。

单线程 put 100B 498us → 估算 ~40–60us/op（fsync+header 摊薄 + COW 摊薄）。~10x。

## 3. 杠杆 1：显式 `putBatch` API

### 3.1 公开 API

```zig
pub const Entry = struct { key: []const u8, value: []const u8, tombstone: bool = false };

pub fn putBatch(self: *Self, entries: []const Entry) !void {
    // 栈/堆分配 N 个 Request（future 共享一次 applyBatch）
    // → 走 group commit 同一入口（leader 路径），或直接 applyBatch
}
```

- 单次调用 N 个 op → 1 header + 1 fsync + 1 次 BTreeBatch flush。
- durable：fsync 完成才返回。
- `put`/`delete` 保留（单 op = putBatch 长度 1 的特例，或走原 sendRequest）。

### 3.2 bench 验证

`bench/bench.zig` 的 `runPut` 改用 `putBatch`（一次 N 个），对比单 op put。预期：
- putBatch(10000)：1 fsync + ~625 次 flush（K=10000/16... 实际按 leaf 容量）。
- 对比现状 10000 次 put = 10000 fsync + 10000 COW。

## 4. 杠杆 2：`BTreeBatch` 批量树提交（核心）

### 4.1 数据结构

```zig
pub const BTreeBatch = struct {
    allocator: std.mem.Allocator,        // arena，batch 末整体释放
    arena: std.heap.ArenaAllocator,
    store: Store,
    root: u64,                          // 当前 root（逻辑 off，NULL_ROOT=空）
    /// 节点缓存：offset → CachedNode。miss 时解码、入缓存。
    cache: std.AutoHashMap(u64, CachedNode),
    /// 脏节点（本次 batch 改过的）。flush 时写。
    dirty: std.AutoHashMap(u64, void),
    /// 新分裂产生的节点（无旧 offset）用临时 ID。
    next_temp_id: u64 = 0x8000_0000_0000_0000,  // 高位置 1 区分临时/真实
    /// 累积 delta
    live_delta: i64 = 0,
    dirt_delta: u64 = 0,
    count_delta: i64 = 0,

    const CachedNode = union(enum) {
        leaf: *Leaf,
        branch: *Branch,
    };
};
```

### 4.2 三阶段

**Stage（apply N op 到缓存树）**：
```zig
pub fn apply(self: *BTreeBatch, key, value, tombstone) !void {
    // 1. 从 root 下沉找 leaf（命中缓存不读 store）
    // 2. miss → readRecord+解码入 cache
    // 3. 改内存 leaf（复用 insertIntoLeaf 的分裂逻辑，但写改成"标脏 + 分裂产生临时节点"）
    // 4. 累 live/dirt/count delta
}
```

**关键：apply 不碰 store.append**。分裂产生的新 leaf 用临时 ID 入缓存，旧 leaf 标脏（即将被替换）。

**Flush（一次写所有脏节点，自底向上）**：
```zig
pub fn commit(self: *BTreeBatch) !WriteResult {
    // 1. 拓扑排序脏节点：子先父后（post-order）
    //    - 叶子先 append → 拿真实 offset
    //    - 父 branch 的 children 数组填真实 offset → branch append
    //    - 根 branch 最后 append → new_root
    // 2. 旧路径节点 offset 计入 dirt_delta
    // 3. 返回 WriteResult { new_root, live_delta, dirt_delta, count_delta }
    // 4. 调用方写 header + fsync（一次）
}
```

### 4.3 分裂处理

apply 时 leaf 满（>32）→ 分裂成两个缓存节点。后续 op 下沉从 root 走缓存，自然路由到分裂后的正确 leaf（缓存里 root 已更新指向新 leaf）。

**key 排序 + 去重（last-write-wins）**：apply 前按 key 排序 entries，同 key 取最后。好处：
- 减少分裂抖动（顺序填满左 leaf 再分）。
- 去重减 op 数。
- 简化路由。

### 4.4 自底向上 offset 分配（唯一新算法件）

flush 必须保证子节点先写拿真实 offset，父 branch 才能填 children 数组。实现：
- 脏集按深度降序处理（叶最深先）。
- 或递归：从 root 开始，先递归 flush 子节点，再 append 自己。
- 临时 ID → 真实 offset 的映射表，flush 过程填。

COW 保留：缓存节点是解码副本，改的是副本；旧 store offset 不动（append-only）。old root 仍可读直到新 root 写入 header。

### 4.5 复用与改动

- **复用**：`Leaf`/`Branch` struct、`fromPayload`/`toRecord` 编解码、CRC、分裂逻辑（搬 insertIntoLeaf/insertIntoBranch 的分裂部分）。
- **改 `btree.zig`**：新增 `BTreeBatch` struct + `apply` + `commit`（~200–300 LOC）。`insert` 保留（单 op 路径、compact 用）。
- **改 `writer.zig` `applyBatch`**：不再 `for (batch) btree.insert`，改为建 `BTreeBatch`、`apply` 全部 req、`commit` 一次、写 header、fsync。

```zig
pub fn applyBatch(state: *State, batch: []Request) !void {
    var bt = btree.BTreeBatch.init(state.allocator, state.store, currentBtreeRoot);
    // key 排序 + 去重（last-write-wins）
    for (sorted_batch) |req| try bt.apply(req.key, req.value, req.tombstone);
    const wr = try bt.commit();  // 一次 flush
    // 写 header（用 wr.new_root 等）+ fsync + future.set
    bt.deinit();  // arena 整体释放
}
```

### 4.6 fallback：Option A（若 B 的 flush 太险）

Option A = 按 key 排序 + 每 leaf 一次 decode→改→append（无缓存，leaf 级合并）。~3–5x，~150 LOC，无 offset 分配难题。作为 B 交付前的去风险台阶或 B flush 证伪时的降级。

## 5. 杠杆 3：隐式 group commit（并发）

（详细见前版 §3，此处摘要 + 与 1/2 的衔接）

- leader/follower 无线程：`queue_mutex` + `write_queue`，队头=leader 跑 applyBatch，余者 future.wait。
- 并发 put/delete/putBatch 自动合并到一次 applyBatch。
- **与 BTreeBatch 衔接**：leader 收集到的 N 个 req（来自不同调用方）传给 applyBatch → BTreeBatch 一次 flush。并发乘数 × COW 摊薄叠加。
- batch-of-1 零开销（零并发）。

## 6. 三杠杆如何叠加

| 场景 | 触发 | 收益来源 |
|---|---|---|
| 单线程 putBatch(100) | 杠杆 1+2 | 1 fsync + ~4 leaf 写（vs 100×fsync + 100 leaf 写）→ ~10x |
| 单线程 put（单 op） | 无 | batch-of-1 = 现状（用户要快就显式 batch） |
| 10 线程 put（各 10 op） | 杠杆 2+3 | leader 合 100 op → 1 applyBatch → BTreeBatch flush → ~10x × 并发摊薄 |
| 10 线程 putBatch（各 100） | 1+2+3 | 极致：1000 op → 1 flush → ~100 leaf 写（vs 1000） |

## 7. 失败语义

### 7.1 BTreeBatch apply 阶段 insert 失败

某 op apply 出错（内存满）→ 整批失败，不 flush、不 fsync、全 `set(err)`。无"已应用未落盘"漂移（批量要么全成功要么全失败）。比现状逐 insert 宽松语义更安全。

### 7.2 fsync 失败

applyBatch flush 后 `store.sync()` 抛错 → leader 设全部 future=err（**改 applyBatch fsync 失败路径必 set future，防 follower 死等**）+ poison `state.closed` 拒后续写。

### 7.3 group commit follower 死等

fsync 失败 applyBatch 不 set future → follower 死等。**必须修**：§7.2 的 set future 覆盖。

## 8. Benchmark 验证

`bench/bench.zig` 加格：
- `putbatch small 100B`：单线程 putBatch(N)。
- `putbatch large 100B`。
- `threaded_put small 100B`：10 线程各 put N/10（group commit + BTreeBatch）。
- `threaded_put large 100B`。

对比基线 `put small 100B`（现状逐 op）。预期 putbatch ~10x，threaded ~10x×并发。

## 9. 改动文件

| 文件 | 改动 |
|---|---|
| `src/btree.zig` | 新增 `BTreeBatch` struct + `apply` + `commit`（~250 LOC）。`insert` 保留。 |
| `src/writer.zig` | `applyBatch` 改用 BTreeBatch（替代 `for batch insert`）；fsync 失败 set future + poison。 |
| `src/db.zig` | 加 `putBatch` 公开 API；加 `queue_mutex`/`write_queue` + leader/follower sendRequest；`compact` 互斥不变。 |
| `bench/bench.zig` | 加 putbatch + threaded_put 格。 |
| `tests/` | 加 `btree_batch_test.zig`（批量正确性、分裂、去重、COW 旧 root 可读）；group commit 单测。 |
| `docs/tutorial/05-writer.md`, `06-db-api.md` | 更新设计说明。 |

## 10. 风险与边界

### 10.1 BTreeBatch flush 自底向上 offset 分配

新算法件。子先父后拓扑序 + 临时→真实映射。错则 child 指针悬空。**需单测覆盖**：多分裂、深树、混合 put/delete。

### 10.2 key 排序 + 去重

apply 前排序 entries。同 key last-write-wins。注意 tombstone（delete）也是 entry，去重后同 key put→delete = 保留 tombstone。**单测覆盖**。

### 10.3 分裂路由

apply 中途 leaf 分裂，后续 op 下沉走缓存 root → 正确路由。若缓存 root 未及时更新指向分裂后 leaf → 路由错。**apply 分裂后立即更新缓存父 branch 指向**。

### 10.4 store.read 逐字节成本

`store.zig:vtRead` 逐逻辑字节读。BTreeBatch 缓存避免重复读，但首次 miss 仍逐字节。若 leaf ~8KB，单次解码 ~8000 次读+算。**缓存命中是收益关键**；冷读仍贵。可选：后续优化 vtRead 批量读（另案）。

### 10.5 group commit leader 循环饿死 compact

高并发 leader 循环持 `write_mutex`，compact 抢不到。MVP 接受"compact 与 put 不并发"；`MAX_BATCH_OPS=64` 上限控单批时长。

### 10.6 zio 跨线程语义

`zio.Mutex`/`Future` foreign-thread 阻塞降级（scout 确认），但 `Future.set` 跨线程唤醒需 spike 验证。**实现前小 spike**。

## 11. 测试策略

1. `zig build test` 全过（现有 concurrent puts 测天然验证 group commit）。
2. `tests/btree_batch_test.zig`：
   - 批量 put 后 get 全命中。
   - 批量含分裂（>32 op 同 leaf）。
   - 去重（同 key 多次 put，last 胜）。
   - tombstone 去重。
   - COW：commit 后旧 root 仍可读。
   - flush offset 正确（多深度分裂）。
3. `tests/group_commit_test.zig`：
   - 多线程 put，fsync 次数 < op 次数（统计 sync_count）。
   - fsync 失败注入（fault_store），follower 不死等、错误传播、poison。
4. bench 对比 putbatch / threaded_put vs put 基线。

## 12. 迁移步骤

1. spike：zio.Mutex/Future 跨线程唤醒小测。
2. `src/btree.zig`：BTreeBatch struct + apply + commit + 单测。
3. `src/writer.zig`：applyBatch 改用 BTreeBatch；fsync 失败 set future + poison。
4. `zig build test` 全过。
5. `src/db.zig`：putBatch API + group commit leader/follower。
6. `bench/bench.zig`：putbatch + threaded 格，对比验证。
7. 更新 tutorial + README 结论。

## 13. 待定（review 定夺）

1. **Option B vs Option A 先行**：B（10x，~250 LOC，flush 有风险）直接上，还是 A（3–5x，~150 LOC，无 flush 难题）先行去风险再升级 B？
2. **key 排序去重**：putBatch 内自动排序去重（last-write-wins），还是保留调用方顺序（更复杂，要处理同 key 多版本）？推荐自动排序去重。
3. **group commit 与 putBatch 关系**：putBatch 自带 N op，是否还入 group commit 队列合并（与别的并发 put 凑更大批）？还是 putBatch 直接 leader 跑完？推荐：putBatch 也走队列（一个 putBatch = 一个 req-group，leader 可合并多个 putBatch）。
4. **`MAX_BATCH_OPS`/`MAX_BATCH_BYTES`**：64/1MB 搬旧够否？BTreeBatch 下单批 leaf 数 = N/32，64 op ≈ 2 leaf，可能偏小。考虑提到 256/4MB？
5. **putNoFsync**：借这次真跳 fsync（batch 内全 no-fsync 则跳 sync）？还是保持 stub？
6. **vtRead 逐字节优化**：本次顺带改批量读，还是 BTreeBatch 缓存够用、vtRead 另案？推荐另案（BTreeBatch 命中后不读）。

# 08 串联 + 修改练习

> 回头看全景——完整的数据流串起来，然后动手改

---

## 完整 LSM 数据流

你现在已经走通了 cube_db LSM 路径的**全生命周期**：

```
启动
  open → readMeta → 灌 state
  + wal.init → mt.init → wal.replay → 灌 mt → attach → compactor.start

写
  put → wal.append(.put) → mt.put → (shouldFlush? → signal compactor)

读
  get → rwlock.shared → mt.get → (未中 → btree.get)

删
  delete → wal.append(.delete) → mt.delete

压缩
  compactor.threadLoop → signal 唤醒 → flush:
    snapshot → Request[] → rwlock.exclusive → applyBatch → wal.truncate → mt.clear

恢复
  wal.replay → CRC 校验 → 逐条灌回 memtable（调用方职责）
```

### 全程数据流图

```mermaid
flowchart TD
    subgraph 启动
        OPEN["Db.open<br/>readMeta→B-tree 恢复"]
        WAL_INIT["Wal.init<br/>打开/创建 WAL 文件"]
        MT_INIT["Memtable.init<br/>创建内存 HashMap"]
        REPLAY["wal.replay<br/>CRC 校验读全文件"]
        REBUILD["逐条灌回 memtable"]
        ATTACH["attach mt/wal/rwlock/compactor"]
    end

    subgraph 运行中：写路径
        PUT["db.put(key, val)"]
        WAL_APPEND["wal.append(.put)<br/>单 pwrite 写磁盘"]
        MT_PUT["mt.put(key, val)<br/>HashMap dupe"]
        FLUSH_CHECK["mt.shouldFlush()?"]
        SIGNAL["compactor.signal(mt)<br/>互斥锁→条件变量唤醒"]
    end

    subgraph 运行中：读路径
        GET["db.get(key)"]
        RL_SHARED["rwlock.lockShared()"]
        MT_GET["mt.get(key)<br/>O(1) HashMap 查找"]
        BT_GET["btree.get(store, root, key)<br/>页面逐层二分"]
    end

    subgraph 运行中：删除路径
        DELETE["db.delete(key)"]
        WAL_DEL["wal.append(.delete)<br/>tombstone"]
        MT_DEL["mt.delete(key)<br/>tombstone 标记"]
    end

    subgraph 后台：Compaction
        THREAD["threadLoop<br/>等待 cond"]
        SNAP["mt.snapshot()<br/>排序全量快照"]
        BUILD_REQ["entries → Request[]"]
        RL_EXCL["rwlock.lock() 独占"]
        APPLY["state.applyBatch(reqs)"]
        BTREE_WRITE["btree.insert<br/>COW 页复制"]
        META_WRITE["writeMeta<br/>交替写 meta0/meta1"]
        FSYNC["store.sync()"]
        PENDING_DIRT["脏页→pending_free<br/>等读者释放"]
        FUTURE_DONE["futures.set({})"]
        TRUNC_WAL["wal.truncate()<br/>删文件重建"]
        MT_CLEAR["mt.clear()"]
    end

    subgraph 崩溃恢复
        CRASH["崩溃"]
        RESTART["重启→open"]
        REPLAY_CRC["wal.replay<br/>CRC 校验"]
        REBUILD_MT["灌 memtable"]
    end

    OPEN --> WAL_INIT
    WAL_INIT --> MT_INIT
    MT_INIT --> REPLAY
    REPLAY --> REBUILD
    REBUILD --> ATTACH

    PUT --> WAL_APPEND
    WAL_APPEND --> MT_PUT
    MT_PUT --> FLUSH_CHECK
    FLUSH_CHECK -->|"满了"| SIGNAL

    GET --> RL_SHARED
    RL_SHARED --> MT_GET
    MT_GET -->|"命中"| RESULT["return dupe(value)"]
    MT_GET -->|"未中"| BT_GET
    BT_GET --> RESULT

    DELETE --> WAL_DEL
    WAL_DEL --> MT_DEL

    SIGNAL --> THREAD
    THREAD --> SNAP
    SNAP --> BUILD_REQ
    BUILD_REQ --> RL_EXCL
    RL_EXCL --> APPLY
    APPLY --> BTREE_WRITE
    BTREE_WRITE --> META_WRITE
    META_WRITE --> FSYNC
    FSYNC --> PENDING_DIRT
    PENDING_DIRT --> FUTURE_DONE
    FUTURE_DONE --> TRUNC_WAL
    TRUNC_WAL --> MT_CLEAR

    CRASH -->|"重启"| RESTART
    RESTART --> REPLAY_CRC
    REPLAY_CRC --> REBUILD_MT
```

---

## 修改练习

以下是 4 个动手练习，按难度排序。每个练习都带有提示（不直接给答案），你可以尝试修改 cube_db 的源码然后跑测试验证。

---

### 练习 1：改 flush 阈值（★☆☆☆☆）

**目标**：修改 memtable 的 flush 阈值，观察 compaction 频率变化。

**背景**：目前 threshold 在 `Memtable.init` 时设置，调用方传参。`shouldFlush()` 检查 `size_bytes >= threshold`。

**提示**：
- 看 `src/memtable.zig:22` 的 `init(allocator, threshold)`
- 看 `src/memtable.zig:107` 的 `shouldFlush()`
- 在 `bench/bench_lsm.zig` 里改 `Memtable.init(allocator, 1024 * 1024)` 的第二个参数为更小值（如 `1024`）
- 编译运行：`zig build bench-lsm -Doptimize=ReleaseFast`
- 观察：compaction 是不是触发得更频繁了？

**涉及文件**：`src/memtable.zig`、`bench/bench_lsm.zig`

---

### 练习 2：给 WAL 加新 EntryType（★★☆☆☆）

**目标**：在 WAL 中增加一种新操作类型 `CHECKPOINT`。

**背景**：目前 WAL 只有两种 type：`put = 0`、`delete = 1`。`replay` 用 `type_byte & 0x01` 取最低位。

**步骤**：
1. 在 `src/wal.zig` 的 `EntryType` 枚举中加 `checkpoint = 2`
2. 在 `append` 函数中，`type_byte` 写入直接用 `@intFromEnum`——已经支持新枚举值
3. 在 `replay` 中，`type_byte & 0x01` 只能区分 0 和 1——要改成 `@as(EntryType, @enumFromInt(type_byte))`（但 `@enumFromInt` 要处理未知值）
4. 写一个测试：append checkpoint 条目，replay 后验证类型

**关键问题**：`replay` 里的 `type_byte & 0x01` 是故意只取低位，为了未来扩展。加了新类型后，这个位掩码逻辑要改吗？为什么原作者这样写？

**涉及文件**：`src/wal.zig`

---

### 练习 3：给 get 加读缓存（★★★☆☆）

**目标**：给 `Db.get` 加一个小型 LRU 缓存，对热 key 跳过 memtable/B-tree 查找。

**背景**：每条 `get` 走 memtable 查找（O(1) 哈希）+ 可能的 btree.get（O(log N) 页面遍历）。如果某些 key 被高频读取，可以缓存结果。

**提示**：
- 在 `Db` 中加一个新字段（如 `std.AutoHashMap([]const u8, []u8)`）
- 在 `Db.get` 中：先在缓存中查找 → 命中直接 dupe 返回 → 未中走原逻辑 → 查到后写入缓存
- 注意：`put` 和 `delete` 操作要**使缓存失效**（删除或更新对应条目）
- 注意：`dupe` 和 free 的生命周期

**涉及文件**：`src/db.zig`、`src/memtable.zig`

---

### 练习 4：把 recovery 接进 Db.open（★★★★☆）

**目标**：修改 `Db.open`，让它自动检测 WAL 文件并执行 recovery——不再让调用方手动 replay。

**背景**：目前 recovery 是调用方职责——`open` 后调用方自己 `wal.init`、`wal.replay`、灌 memtable。这个练习把它自动化。

**提示**：
- 在 `Db.open` 或一个新的 `Db.openLsm` 函数中，接受 WAL 路径、memtable 阈值等额外参数
- 在 `open` 内部：`Wal.init` → `wal.replay()` → 创建 Memtable → 灌入 → 设置 `db.mt`/`db.wal`
- 考虑：如果 WAL 文件不存在（首次运行），`Wal.init` 会创建它——不影响
- 考虑：replay 后 WAL 是否需要 truncate？（数据已安全回到 memtable，WAL 可以重置）
- 修改 `bench/bench_lsm.zig` 用新的 `openLsm` 替代手动 attach

**涉及文件**：`src/db.zig`、`src/wal.zig`、`bench/bench_lsm.zig`

---

## 读完教程的总回顾

做完上述练习后，你应该能：

- ✅ 说清 cube_db 两条数据路径（COW vs LSM）的差异
- ✅ 画出 LSM put/get/delete/compaction/recovery 的数据流
- ✅ 解释 WAL 格式（magic+version 头 + 条目格式 + CRC32）
- ✅ 解释 memtable 内部（HashMap index + ArrayList entries + 阈值）
- ✅ 解释 compaction 后台线程模型（mutex + cond + signal + flush）
- ✅ 解释 applyBatch 7 步（insert COW → pending_free → meta → fsync → 状态更新 → future → 脏页回收）
- ✅ 解释 LSM 字段 attach 模式（DB open 不建 LSM，调用方 attach）
- ✅ 解释 tombstone 生命周期（写标记 → 读屏蔽 → compaction 清除）
- ✅ 解释 O(1) recovery 和 WAL replay 的差异
- ✅ 独立修改 cube_db LSM 路径的任意一处

---

**你已读完 cube_db LSM 教程。下一步：打开源码，动手改。**

教程文件结构：
```
docs/tutorial/
├── README.md          ← 架构总图 + 数据流总图（入口）
├── 00-overview.md     ← 全景
├── 01-foundations.md  ← 基础概念黑盒
├── 02-open.md         ← Db.open
├── 03-put.md          ← 写路径
├── 04-get.md          ← 读路径
├── 05-delete.md       ← 删除路径
├── 06-compaction.md   ← Compaction（核心）
├── 07-recovery.md     ← 恢复
└── 08-wrapup.md       ← 串联 + 练习（本页）
```

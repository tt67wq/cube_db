# cube_db 设计文档

Zig 实现的嵌入式 KV 引擎。参考 CubDB（Elixir）架构，异步 IO 基于 zio。

**状态**：已批准（决策 D1–D7 锁定）
**工具链**：Zig 0.16.0 + zio 0.16.0
**开发方式**：TDD（测试驱动开发，见 §12）

---

## 1. 目标与范围

### MVP（做）
- `get` / `put` / `delete` / `select`（按 key 字节序范围查询）
- append-only 不可变 B-tree 存储
- compaction：手动 `compact()` + 垃圾比例阈值自动触发
- 崩溃安全：进程/机器崩溃不损坏数据文件，已 fsync 的写不丢

### 显式排除（后续版本）
- ACID 事务（`transaction` API）
- MVCC 并发读快照
- 多数据目录 / 多文件
- 服务器模式（TCP）

---

## 2. 关键决策

| # | 决策 | 内容 |
|---|------|------|
| D1 | MVP 范围 | get/put/delete/select + B-tree + compaction |
| D2 | 数据模型 | key/value 均为 `[]const u8`，排序按字节序（memcmp） |
| D3 | API 形态 | 嵌入式库，zio async API，调用方拥有 runtime |
| D4 | 并发模型 | 单 writer 协程 + mailbox；读无锁 |
| D5 | 持久化 | 写 API 可选 fsync，默认开启 |
| D6 | compaction | 手动 + 垃圾 ≥30%（可配）且满足最小数据量时自动 |
| D7 | 工具链 | Zig 0.16.0，zio 作为 build.zig.zon 依赖 |
| D8 | allocator | `open` 收 `std.mem.Allocator`，库存入 Db；`get` 返回值由此 allocator 分配，调用方用 `db.allocator` free |
| D9 | Store 抽象 | 运行时 vtable（`ptr + vtable`），非 comptime 泛型——避免 store 类型泄漏进公开 API |
| D10 | group commit 策略 | writer 收首请求后 `yield` 一次，`tryReceive` 排空至上限（64 ops 或 1 MiB），单次提交。无定时器 |

---

## 3. 总体架构

```
                调用方协程 A          调用方协程 B
                     │                     │
        put/delete ──┼───── mailbox ───────┤
                     ▼                     ▼
              ┌─────────────────────────────────┐
              │         Writer 协程              │  ← 唯一写者，串行执行
              │  - 应用写 batch                  │
              │  - 构建新 B-tree 路径（COW）     │
              │  - append 节点 + header          │
              │  - fsync（可选）                 │
              │  - 原子替换 root 指针            │
              │  - 跟踪垃圾字节                  │
              └────────┬───────────────┬────────┘
                       │               │
                       ▼               ▼
              ┌──────────────┐  ┌──────────────┐
              │  B-tree      │  │  Compactor   │
              │  (不可变)    │  │  协程        │
              └──────┬───────┘  └──────┬───────┘
                     │                 │
                     ▼                 ▼
              ┌─────────────────────────────────┐
              │   Store（append-only 数据文件）  │
              └─────────────────────────────────┘

   get/select（任意协程）：读原子 root 指针 → 沿不可变 B-tree 下行 → pread，无锁
```

核心思想（继承自 CubDB）：**数据永不原地修改**。每次写产生一条新的 root→leaf 路径，旧版本节点成为垃圾，由 compaction 回收。读操作持有 root 指针即持有不可变快照，与写天然无冲突（为 MVCC 预留）。

---

## 4. 文件格式

仿 CubDB `Store.File`：append-only 单文件，固定大小块，块首 1 字节标记。

### 4.1 块布局

- 文件划分为 `BLOCK_SIZE = 4096` 字节的块
- 每块第 1 字节为标记：
  - `0` = 数据块（node/entry 内容）
  - `1` = header 块（块首紧跟 header 记录）
- 记录跨块时，跨块部分从下一个数据块的标记字节之后继续
- header **只**写在 header 块起始位置（marker 字节之后），因此启动时可 O(块数) 反向定位最新 header

### 4.2 记录格式

所有整数 big-endian。每条记录（node 或 header）：

```
+----------+----------------+----------+
| len: u32 | payload: [len] | crc: u32 |   crc 覆盖 len+payload
+----------+----------------+----------+
```

（CubDB 用 `term_to_binary` 序列化；Zig 用手写字节布局，payload 结构见下。）

### 4.3 Header（提交点）

Header 是原子提交单位：一批节点写完后，最后 append 一个 header。**只有 header 落盘（并 fsync）的写才可见。**

```
magic:        u32   = 0x4355_4244 ("CUBD")
version:      u16
btree_root:   u64   本提交的 B-tree root 节点位置（文件偏移）
entry_count:  u64
byte_size:    u64   逻辑数据量（live bytes，用于垃圾比例计算）
dirt:         u64   垃圾字节数（writer 维护并随 header 持久化）
```

### 4.4 B-tree 节点

内部节点（branch）：
```
kind:   u8 = 1
count:  u16                 子指针数
keys:   [count-1] 个 (klen: u32, key: [klen])
children: [count] 个 u64    子节点文件偏移
```

叶子节点（leaf）：
```
kind:   u8 = 2
count:  u16
entries: [count] 个
  tombstone: u8             1 = delete
  klen: u32, key: [klen]
  vlen: u32, value: [vlen]  tombstone 时 vlen = 0
```

节点写满目标上限（默认约 BLOCK_SIZE 的整数倍，实现时定，如 ≤ 8KB payload）即分裂。插入/删除采用 copy-on-write：复制 root→leaf 路径，追加新节点，旧路径成为垃圾。

### 4.5 启动恢复

1. 打开数据文件（不存在则创建）
2. 从文件末尾反向按块扫描 marker 字节，定位最新 header 块
3. 读 header，CRC 校验失败则继续向前找上一个 header（容忍尾部撕裂写）
4. **`ftruncate(fd, header_end)` 物理截断**，丢弃尾部垃圾。正确性其实不依赖这步（反向扫描 + CRC 回退已足够，CubDB 也不截断）；做它是为了消除"append 位置在 header_end 还是 eof"的歧义并立即回收磁盘。截断后 append 位置 = header_end，invariant：文件尾永远是最新有效 header
5. 恢复 dirt / entry_count 等元数据

### 4.6 排他访问

打开时对数据文件加 `flock`（或等价物），防止两个进程同时打开同一数据库（等价 CubDB 的 `ensure_exclusive_access!`）。

---

## 5. 模块划分

```
src/
  root.zig        库入口，导出公共 API
  db.zig          DB 句柄：open/close/get/put/delete/select/compact，mailbox
  writer.zig      writer 协程：batch 应用、COW、header 提交、垃圾统计、自动 compaction 触发
  btree.zig       不可变 B-tree：查找、范围迭代、COW 插入/删除、节点序列化
  store.zig       文件抽象：块标记读写、append 节点/header、反向 header 扫描、pread
  compactor.zig   compaction 协程：全量拷贝到新文件、原子切换
  format.zig      常量与编解码（块标记、记录、header、节点布局、CRC32）
  iter.zig        select 范围迭代器
```

### 5.0 zio 依赖接入（M0 spike，先于一切）

zio 0.16.0 源码已核实，D4 所需原语全部存在：
- `zio.Channel(T)`：有界 channel（`init(buffer)` + `send/trySend/receive/tryReceive/close`）→ writer mailbox
- `zio.Future`：原子 set/get completion → 写请求结果回传
- `zio.File`：`read(buf, offset)`/`write(data, offset)` 位置 IO（pread/pwrite 语义）、`sync(flags)`、`setSize()`（= ftruncate）、`rename`、`deleteFile`
- `zio.spawn/yield/sleep`、`JoinHandle`

`build.zig.zon` 加 path 依赖指向本地 zio checkout。M0 spike（§12.4 T0）用小程序验证 channel roundtrip + spawn + 位置写读，通过后才动 format.zig。

### 5.1 Store 抽象机制（D9）

`store.zig` 定义运行时多态接口：

```zig
pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (ptr: *anyopaque, buf: []u8, offset: u64) anyerror!usize,
        append: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!u64, // 返回写入偏移
        sync: *const fn (ptr: *anyopaque) anyerror!void,
        setSize: *const fn (ptr: *anyopaque, len: u64) anyerror!void,
        size: *const fn (ptr: *anyopaque) anyerror!u64,
        close: *const fn (ptr: *anyopaque) void,
    };
};
```

三个实现同一 vtable：`FileStore`（zio.File）、`TestStore`（ArrayList 内存）、`FaultStore`（包装另一 Store + 故障注入）。btree/writer/db 全部面向 `Store` 值编程。

排除 comptime `anytype` 泛型：会让 `Db` 类型参数化、store 类型泄漏进公开 API（调用方得写 `Db(FileStore)`）。vtable 一次间接跳转在 IO 路径上成本可忽略。

## 5.2 模块文件

---

## 6. 并发模型（D4）

- **写路径**：`put`/`delete` 把请求（含 `zio.Future` 结果槽）发到有界 `zio.Channel(Request)` mailbox，调用方 await future。writer 串行处理，按 D10 策略合并 batch、一次 header 提交 + 一次 fsync。
- **group commit 排空策略（D10）**：writer 循环 = 阻塞 `receive` 首请求 → `zio.yield()` 一次（让已排队 sender 完成 enqueue）→ `tryReceive` 排空 channel，直到空或达上限（64 ops 或 1 MiB payload，先到先截）→ 整批 COW + 一次 header + 一次可选 fsync → 逐请求 set future。无定时器：MVP 不为 batching 引入延迟，yield 一次是零成本折中。后续若加 `fsync:false` 快速模式再评估定时器合并。
- **读路径**：`get`/`select` 读 DB 句柄中的原子 root 指针（`@atomicLoad`），沿不可变 B-tree 下行，用 `pread` 读节点。无锁、不阻塞 writer。
- **旧节点/旧文件生命周期**：读协程可能正持有旧 root。append-only 保证旧节点不被覆写，但 compaction 会换文件（§8），光"不覆写"不够。采用 **reader refcount + 延迟关闭**（CubDB 同款方案，靠 POSIX unlink 语义）：
  - 每次 `get`/`select` 开始读时对当前 store 的 FD `acquireRead()`（refcount+1），读完/迭代器 `deinit` 时 `releaseRead()`（refcount-1）
  - compaction 原子切换后：旧文件立刻 `unlink`（目录项消失，清理即完成），但旧 FD **不 close**，直到其 refcount 归 0。POSIX 下已 unlink 的打开文件 inode 仍存活，进行中的 reader pread 不受任何影响
  - 读侧无锁：refcount 用原子计数；只有 compaction 路径在归 0 时负责 close
  - 迭代器跨 compact 全程持有旧 FD，语义 = 创建时快照，数据始终可读

## 7. API 签名（草案）

```zig
pub const Options = struct {
    /// 自动 compaction 垃圾比例阈值，默认 0.30；设 null 关闭自动 compaction
    auto_compact_dirt_ratio: ?f32 = 0.30,
    /// 自动 compaction 最小文件大小，默认 16 MiB（小文件不值得 compact）
    auto_compact_min_bytes: u64 = 16 * 1024 * 1024,
    /// 写默认是否 fsync
    fsync: bool = true,
};

pub const Db = struct {
    allocator: std.mem.Allocator, // 来自 open；get 返回值用它分配

    /// 打开（或创建）数据库。rt 为调用方的 zio runtime；allocator 用于所有内部分配与 get 返回值。
    pub fn open(allocator: std.mem.Allocator, rt: *zio.Runtime, path: []const u8, opts: Options) !Db;
    /// fsync 并关闭，停止 writer/compactor 协程。
    pub fn close(db: *Db) !void;

    /// 返回 value 由 db.allocator 分配，调用方负责 `db.allocator.free(v)`。
    pub fn get(db: *Db, key: []const u8) !?[]u8;
    pub fn put(db: *Db, key: []const u8, value: []const u8) !void;
    pub fn putNoFsync(db: *Db, key: []const u8, value: []const u8) !void;
    pub fn delete(db: *Db, key: []const u8) !void;

    /// 范围查询，返回迭代器；key 字节序 [min, max)，null 表示无界。
    /// 迭代器持有 reader refcount（§6），必须 `iter.deinit()` 释放。
    pub fn select(db: *Db, min: ?[]const u8, max: ?[]const u8) !Iterator;

    /// 手动 compaction。返回前等待完成。
    pub fn compact(db: *Db) !void;
};
```

所有公开方法为 zio async（在协程中调用；阻塞在内部 await，不占线程）。

---

## 8. Compaction（D6）

流程（仿 CubDB Compactor）：
1. 触发：手动 `compact()`，或 writer 每次提交后检查 `dirt / (dirt + live) ≥ 阈值 且 文件 ≥ min_bytes`
2. writer 暂停写入（mailbox 暂存），compactor 以当前 root 为源，将 **live 数据**按 key 序写入新文件 `path.compact`，构建全新紧凑 B-tree
3. 新文件 fsync，写最终 header
4. 暂停期间的 mailbox 积压写入，以 delta 形式补进新文件（或简单方案：compaction 全程挂起写，MVP 选此方案，文档注明写停顿）
5. 原子切换：`rename(path.compact → path)`，**随后 `fsync` 父目录 FD**（rename 目录项本身需落盘，否则断电后 rename 可能丢失，重开仍见旧文件——POSIX 耐久性经典坑）
6. 替换 root 与当前 store FD；旧文件 `unlink`，旧 FD 按 §6 reader refcount 延迟关闭

约束：同一时刻只允许一个 compaction 运行；compaction 与自动触发互斥（运行中重置 dirt 计数）。打开数据目录时即持有目录 FD，供 fsync 用。

## 9. 崩溃安全矩阵

| 场景 | 结果 |
|------|------|
| 写节点中崩溃（header 未写） | 旧 header 仍有效，尾部垃圾被忽略 |
| header 写一半崩溃 | CRC 失败，恢复时回退上一 header |
| fsync 前机器断电（fsync: false） | 最近未落盘写丢失，文件不损坏 |
| compaction 中崩溃 | `.compact` 临时文件残留，启动时删除；原文件未动 |
| rename 后、目录 fsync 前断电 | rename 可能未落盘：重开见旧文件（数据不丢、内容一致），或见新文件。两者都合法，启动按实际目录状态恢复 |
| rename + 目录 fsync 后崩溃 | 新文件完整（新文件先 fsync、目录项后 fsync），正常打开 |
| compact 换文件时有进行中 reader | 无影响：reader 持有旧 FD，inode 被 FD 保活（§6） |

## 10. 限制与已知取舍

- 单数据文件，无分片
- key/value 全量进入文件；value 大时节点稀疏（MVP 不做 value 分离 / blob 存储）
- 自动 compaction 期间写停顿（MVP 简化；后续做增量 compaction）
- 无校验和级别选择：固定 CRC32（IEEE）
- `select` 迭代器在迭代期间看到的快照 = 创建时的 root；迭代期间 compaction 安全（reader refcount + POSIX unlink，§6）

## 11. 后续路线

1. 事务：批量 read-modify-write，冲突检测
2. MVCC 快照：读协程注册快照代际，compaction 保留被引用版本
3. group commit 调优、节点页缓存
4. value 分离（大 value blob 存储）

---

## 12. 开发方式：TDD

全项目按测试驱动开发推进：**先写失败测试 → 最小实现通过 → 重构**。每个模块落地顺序由测试驱动。

### 12.1 工作流（每个任务的标准循环）

```
1. RED      从 §12.4 测试清单取下一条用例，写成 test 块。运行 zig build test，确认失败
            （失败原因必须是被测功能未实现，不是测试本身写错）
2. GREEN    写最小实现让测试通过。允许硬编码、允许丑，只追求绿
3. REFACTOR 清理：去重、命名、抽函数。测试保持绿
4. COMMIT   测试与实现同一提交。commit message 标注用例编号（如 "btree: insert split leaf (T3.7)"）
```

纪律：
- 不允许"先实现后补测试"；补写的测试不算数，删掉实现重写
- bug 修复：先写复现 bug 的失败测试，确认红，再修
- 重构行为不变的代码时可以先改，但重构前后 `zig build test` 必须都全绿
- 一个 test 块只断一件事；命名 `test "模块: 行为 条件 → 期望"`

### 12.2 测试基建（最先做，先于任何业务代码）

**build.zig 接线**
```zig
// zig build test 跑全部；zig build test -Dfilter=btree 按模块过滤
const tests = b.addTest(.{ .root_module = lib_mod });
const run_tests = b.addRunArtifact(tests);
const test_step = b.step("test", "Run all tests");
test_step.dependOn(&run_tests.step);
```

**`src/test_store.zig` — 内存 Store**（仿 CubDB `Store.TestStore`）
- 用 `std.ArrayList(u8)` 模拟文件字节数组，实现与 `store.zig` 相同接口：`appendNode / appendHeader / pread / sync / getLatestHeader`
-  btree/恢复逻辑全部可对内存 store 测，毫秒级、无 IO、可在同进程跑千次迭代
- 提供 `toFile(dir)` 把内存状态落成真文件，衔接集成测试

**`src/fault_store.zig` — 故障注入 Store**
- 包装真文件 store，可编程故障点：
  - `fail_after_bytes: usize` — 写入 N 字节后返回 `error.InjectedIoError`（模拟撕裂写）
  - `fail_on: enum { node, header, sync, rename }` — 在指定操作类型上失败
  - `truncate_to: usize` — 模拟崩溃后文件被截到某长度
- 崩溃安全矩阵（§9）每个场景 = 一个 fault_store 配置 + 断言恢复结果

**`src/test_util.zig`**
- `makeKv(i)` 生成确定性 key/value（`std.fmt` 格式化序号），保证测试可重复
- `TmpDir` 封装 `std.testing.tmpDir`，自动清理
- 断言 helper：`expectHeader(root, dirt, count)`、`expectTreeEqual(a, b)`

### 12.3 测试分层

| 层 | 范围 | 运行环境 | 速度目标 |
|----|------|----------|----------|
| 单元 | 单模块纯逻辑（编解码、B-tree 操作、块读写） | 内存 store | 全套 < 1s |
| 集成 | open→写→读→select→compact→重开 全链路 | TmpDir 真文件 + zio runtime | 全套 < 10s |
| 崩溃注入 | §9 矩阵逐场景 | fault_store | 全套 < 10s |
| 属性/随机 | 随机 op 序列（put/delete 混合）对比 `std.StringHashMap` 参考模型 | 内存 store | ≥10k ops/轮 |

参考模型测试（model-based）：测试里维护一个 `StringHashMap([]u8)` 作为"真相"，随机生成操作序列同时打到 DB 和 map 上，每步后 `select(null, null)` 全量比对。这是 B-tree 正确性的主力防线，比手写枚举用例覆盖高几个数量级。

### 12.4 分模块测试清单

编号规则：`T<模块>.<序号>`，commit 引用。

#### M0 zio 接入 spike（阻塞后续一切）
- T0.1 `build.zig.zon` path 依赖 zio，`zig build` 通过
- T0.2 channel roundtrip：spawn producer/consumer 协程，`zio.Channel` 发收 100 条，断言顺序与计数
- T0.3 `zio.File` 位置 IO：write(buf, offset) → read(buf, offset) roundtrip；`sync`；`setSize` 截断
- T0.4 `zio.Future`：跨协程 set/get roundtrip

#### M1 `format.zig`（编解码纯函数）
- T1.1 header 编码→解码 roundtrip，字段全等
- T1.2 branch 节点 roundtrip（1 子指针 / 满子指针）
- T1.3 leaf 节点 roundtrip（空 / 含 tombstone / 大 value）
- T1.4 CRC 错 1 bit → 解码返回 `error.CorruptCrc`
- T1.5 截断 payload（len 字段大于实际字节）→ `error.Truncated`
- T1.6 key/value 边界：空 key、空 value、1MB value
- T1.7 块标记：`addMarkers/stripMarkers` roundtrip，跨 1/2/3 块边界
- T1.8 非对齐偏移（记录跨块标记字节）正确切分

#### M2 `store.zig`（对内存 store 开发，末尾补真文件集成测试）
- T2.1 空文件 `getLatestHeader` → null
- T2.2 append 节点 → 返回偏移，`pread` 读回相等
- T2.3 append header → `getLatestHeader` 定位到它
- T2.4 连续 3 个 header → 定位到**最新**的
- T2.5 尾部追加垃圾字节后 → 仍定位到最后一个好 header
- T2.6 最后 header CRC 损坏 → 回退到上一个 header
- T2.7 记录跨块边界 append/pread 正确
- T2.8 真文件：open 不存在路径 → 创建；重开 → 读到旧 header
- T2.9 双开同一路径 → 第二个 `error.Locked`（flock）
- T2.10 恢复后物理截断：构造「好 header + 尾部垃圾」文件 → 重开 → 文件大小 = header_end；再写 → 新记录紧跟 header，无间隙

#### M3 `btree.zig`（全部对内存 store）
查找/插入：
- T3.1 空树 get → null
- T3.2 单条 put/get roundtrip
- T3.3 插入到叶满 → 分裂，树高 +1，全部 key 仍可读
- T3.4 插入 10k 随机 key → 全部可读；树高 ≤ 预期上界
- T3.5 顺序插入 10k（最坏情况之一）→ 树保持平衡
- T3.6 覆盖已有 key → 新值生效，旧节点成为垃圾（dirt 增加量正确）
- T3.7 COW：插入后旧 root 仍指向旧版本（用旧 root 读到旧值）—— MVCC 预留语义
删除：
- T3.8 删存在 key → get null；删不存在 key → 无变化
- T3.9 删除产生 tombstone，dirt 统计正确
- T3.10 删空整棵树 → root 回到空
范围迭代：
- T3.11 `select(null,null)` 全量按字节序输出
- T3.12 `[min,max)` 边界：含 min、不含 max
- T3.13 空范围 / min>max → 空迭代器
- T3.14 迭代中 tombstone 条目不出现
模型测试：
- T3.15 随机 10k ops 对比 StringHashMap 参考模型（用固定 seed，失败可复现）

#### M4 `writer.zig` + `db.zig`
- T4.1 open → writer 协程启动；close → 协程退出、文件 fsync
- T4.2 put → get 立即可见（root 指针已换）
- T4.3 并发 10 协程各 put 100 条 → 最终 1000 条全在，无丢失无重复提交
- T4.4 fsync 语义：`put`（默认）返回前 `datasync` 被调用（fault_store 计数断言）；`putNoFsync` 不调用
- T4.5 group commit（D10）：2 协程同时 put → 合并为单次 header 提交（header 数断言）；65 协程同时 put → 至少拆 2 批（64 ops 上限断言）
- T4.6 writer 崩溃/出错 → 等待中的调用方收到 error，不挂死
- T4.7 读协程在写进行中读旧 root → 拿到一致旧快照（不撕裂）

#### M5 `compactor.zig`
- T5.1 手动 compact：垃圾文件变小，全部 live key 可读，值正确
- T5.2 compact 后重开 → 数据完整
- T5.3 自动触发：dirt 比例 ≥30% 且文件 ≥min_bytes → compact 自动跑（用极小 min_bytes 配置测试）
- T5.4 低于阈值 → 不触发
- T5.5 compact 进行中再次调用 `compact()` → 等待同一个，不并发跑两个
- T5.6 compact 中写入（mailbox 暂存）→ compact 完成后新写也可见
- T5.7 rename 前崩溃（fault_store 在 rename 点失败）→ 原文件完好，`.compact` 残留文件下次启动被清理
- T5.8 compact 换文件时有进行中 select 迭代器 → 迭代器继续读到**创建时快照**的完整一致数据（reader refcount + 延迟关 FD）；迭代器 deinit 后旧 FD 被关闭（计数断言）
- T5.9 compact 顺序断言：新文件 fsync → rename → 父目录 fsync（fault_store 记录调用序列，断言顺序与父目录 fsync 存在）
- T5.10 get 在 compact 换文件瞬间读旧 root → 拿到一致旧值，无撕裂

#### M6 崩溃安全矩阵（§9 逐行）
- T6.1 节点写一半崩溃 → 重开，旧 header 生效，已确认写不存在
- T6.2 header 撕裂（CRC 坏）→ 回退上一 header
- T6.3 fsync:false 写后"断电"（丢弃未 sync 尾部）→ 文件可开，最近写可丢失但不损坏
- T6.4 compact 中断 → 原文件正常打开，临时文件被清理
- T6.5 rename 后崩溃 → 新文件完整可用

### 12.5 每任务验收标准（Definition of Done）

1. 该任务对应清单用例全绿：`zig build test`
2. 新代码含 `test` 块或对应 `tests/` 文件，无"待补"标记
3. ReleaseSafe 构建无警告：`zig build -Doptimize=ReleaseSafe`
4. 模型测试（涉及 B-tree 改动的任务）用 ≥3 个固定 seed 跑过
5. commit 引用用例编号

### 12.6 不做的事（YAGNI）

- 不引外部测试框架/断言库，`std.testing` 足够
- 不做覆盖率门禁（MVP 靠清单完备性，不靠百分比）
- 不做 benchmark 套件（性能非 MVP 目标，留到后续路线 §11.3）
- 不 mock zio runtime——集成测试直接起真 runtime，zio 本来就是嵌入式库

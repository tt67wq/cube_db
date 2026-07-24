# cube_db 读路径（get）真零拷贝设计

> 上一阶段（mmap + skip-decode + read-no-CRC，见 git 历史 `b72502e`）拿到 get 100B 252→133us。本文攻余下瓶颈：每节点 alloc+memcpy ~8KB（非真零拷贝）。
>
> **开发方式：严格 TDD（red→green→refactor）。** 每个任务先写失败测试（RED），再写最小实现使其通过（GREEN），再重构。不允许先实现后补测试，不允许跳过 RED 验证。实现退出盘问后按 `docs/zero-copy-read-tasks.md` 执行。

## 0. TL;DR

`get` 100B 上一阶段后 133us/op，仍落后 LMDB mmap 读（~1–5us/op）**~60×**。根因不是 syscall（已 mmap 去 pread），而是 `readRecord` **每节点 alloc 一块堆 buf + memcpy ~8KB 到堆 buf + payload 指向堆 buf 非 mmap**——非真零拷贝。4 层 = 4 次 alloc + 32KB 复制。

根因是上一阶段方案选择（a：保留 marker + 读时转换）的后遗症：marker 每 4095 逻辑字节插 1 字节 → mmap 物理字节非连续 → 没法直接拿 mmap 指针当零拷贝，只能复制到连续堆 buf 再解码。

方案四决策：
1. **去 marker 改磁盘格式**（mmap 物理天然连续 → 真零拷贝，追 LMDB）。
2. **新项目、不需旧文件兼容**（去迁移代价，去 marker 落地成本大降）。
3. **Store 借用 API：读+写路径全改**（`readRecord` 返 `[]const u8` 借用切片、~8 调用点去 `free`、用借用；一致彻底零拷贝）。
4. **header 发现：正向扫全文件记最后有效 header**（去 marker 后 getLatestHeader 不扫 MARKER_HEADER；正扫按记录长度走 mmap 指针，记最后 crc 对 + 是 header 的记录，crash 半写跳过；不比现慢，代码更简单）。

预期：get ~2–5us/op（追 LMDB）。

---

## 1. 目标与非目标

### 目标
- `get` 100B 从 133us/op 降到 ~2–5us/op（追平 LMDB），去掉 readRecord 每节点 alloc+memcpy。
- 真零拷贝：readRecord 返回指向 mmap 的借用切片，不 alloc、不 memcpy。
- 保持 durable 与并发语义：get 无锁、可与写并发，读到最近一次已提交 root 的快照（append-only CoW 天然 MVCC）。

### 非目标
- 不改写路径语义（put/putBatch/delete/compact 行为不变；只是 appendRaw 不再插 marker、读旧记录改借用）。
- 不改 compact 实现（仍单线程全量重写）。
- 不做读缓存（LRU 页缓存，留作零拷贝后若仍有瓶颈的叠加选项）。
- 不预设硬性能门槛（真零拷贝后 ponytail 测后定；不靠 durability 换吞吐）。
- 不做 header 链表 / sidecar 文件（正扫够用；10GB+ 嫌开机慢再换，基于实测）。

---

## 2. 背景与根因

### 2.1 benchmark（NVMe，ReleaseFast，单线程，small，上一阶段后）

| 指标 | 数值 |
|---|---|
| get 100B | 133 us/op（7,495 ops/s） |
| get 10KB | 174 us/op（5,760 ops/s） |

业界对照：

| 引擎 | 随机读 us/op |
|---|---|
| LMDB mmap | 1–5 |
| RocksDB point get | 1–5 |
| **cube_db get（上一阶段后）** | **133** |

差距 ~60×。**单一最大短板**。

### 2.2 根因（代码精确版）

读路径 `db.get` → `btree.get` 遍历深度~4，每层 `readRecord` → `Store.read`（`FileStore.vtRead` = mmap memcpy+跳 marker）。

**`readRecord`（`src/btree.zig:50`）现实现**：
1. 读 4 字节 len（`s.read` → mmap memcpy+跳 marker 到栈 `len_buf`）。
2. `allocator.alloc(total)` 一块**堆 buf**。
3. while `s.read` 把整记录（~8KB）从 mmap **memcpy 到堆 buf**（跨 marker 跳 1 字节）。
4. 返回堆 buf（`[]u8`，所有者，调用方 `defer free`）。
5. `decodeNodePayloadNoCrc` 返回 payload 切片——**指向堆 buf，不是 mmap**。

**单 get 成本拆解**：
1. **每节点 alloc 1 块堆 buf + memcpy ~8KB**：4 层 = 4 次 alloc + 32KB 复制。**这是 133us 的主成本**。
2. payload 指向堆 buf 非 mmap → 后续 `findInLeaf`/`Branch.fromPayload` 读的是堆 buf 拷贝，非 mmap 直访。

> 注：上一阶段已去掉 syscall（mmap）+ 热读跳 CRC + get skip 全 leaf 解码。余下瓶颈就是这"每节点复制到堆 buf"——marker 让 mmap 非连续挡了零拷贝。

### 2.3 marker 的真用途（代码已读确认）

- `BLOCK_SIZE=4096`，每块首字节 = marker（`MARKER_DATA=0`/`MARKER_HEADER=1`）。逻辑内容 = 物理剔 marker。
- **marker 真用途仅 `getLatestHeader`**（`src/store.zig`）：按块倒扫读物理首字节找 `MARKER_HEADER`，区分 header 块 vs 数据块。
- **数据节点记录本身不需要 marker**——`vtRead` 读时无条件跳过 marker 字节。
- `applyBatch`（`src/writer.zig`）末尾 `appendHeaderRecord` → **header 每次 commit 写为最后一条记录**（但 crash 可写半）。

### 2.4 关键事实（零拷贝可行性）
- `appendRaw` 返回逻辑 offset，btree 节点存逻辑 offset。
- append-only CoW + 上一阶段方案 I 大 sparse mmap（1TB 预留，永不 remap）→ **借用切片在 reader 与 writer 期间均有效**（mmap 稳定，旧页不变天然 MVCC）。
- `readRecord` 返回 `[]u8` 所有者，~8 调用点 `defer free`（get/branch-find + insert/delete/split/btree_batch）。
- MemStore 用 `std.ArrayList(u8)`（亦可返借用切片）。

---

## 3. 方案对比与取舍

### 3.1 根路径：A. 去 marker 改格式（真零拷贝）

去 marker → mmap 物理字节天然连续逻辑字节 → `readRecord` 返回指向 mmap 的借用切片（不 alloc 不 memcpy），真零拷贝追 LMDB。

| 方案 | 做法 | 代价 |
|---|---|---|
| **A（选）** | 去磁盘 marker，mmap 连续，readRecord 返借用 | 格式变更 + 写路径 appendRaw 重写 + header 发现重做；但**新项目无旧文件兼容 → 去迁移代价** |
| B | 保留 marker，解码器 marker-aware 直访 mmap | 不改格式、兼容旧文件；解码器需容忍非连续（payload 跨 marker 跳 1 间隙），非纯零拷贝 |
| C | btree 改存物理 offset | 中等；仍非纯零拷贝（跨 marker 解码容忍间隙） |

选 A：收益最纯（追 LMDB），且新项目无旧文件兼容去掉最大代价（迁移）。B/C 留作若 A 证伪时降级。

### 3.2 Store 借用 API：读+写路径全改

`readRecord` 改返回 `[]const u8` 借用切片（指向 mmap/MemStore ArrayList），~8 调用点去 `free`、用借用。

| 方案 | 做法 | 代价 |
|---|---|---|
| **1（选）** | 读+写路径全改借用 | 一致彻底零拷贝；改动面大但一次到位；写路径读旧记录只读、借用安全（mmap 永不 remap） |
| 2 | 仅读路径借用，写路径保留 alloc | 改动面小、风险低；但两条 readRecord 路径并存、代码分叉 |

选 1：一致彻底，编译器抓全 ~8 调用点（返回类型变 → 编译错漏改的）。

### 3.3 header 发现：正向扫全文件记最后有效 header

去 marker 后 `getLatestHeader` 不能扫 `MARKER_HEADER`。

| 方案 | 做法 | 代价/性能 |
|---|---|---|
| **A（选）** | 正扫全文件按记录长度走 mmap 指针，记最后 crc 对 + 是 header 的记录 | 健壮（crash 半写尾自动跳过）；不比现慢（现按块倒扫也 O(文件大小)）；代码更简单；10GB+ 嫌慢可升级 |
| B | 只读文件尾定长记录（header 46 字节） | 最简单；但 crash 半写 → 坏、找不到上一个、库坏 |
| C | header 链表（每个 header 存上一个 offset） | 健壮、开机 O(commit 数) < O(文件大小)；header 加 8 字节、写路径多记偏移 |

选 A：最简单+健壮+不比现慢。10GB+ 开机扫慢时基于实测再换 C 或 sidecar 文件。

### 3.4 旧文件兼容：不需要（新项目）

新项目，无历史文件 → 去掉迁移代价（否则要双读路径/版本标记）。这把去 marker 的最大成本去掉。

---

## 4. 实现路径（TDD，详见 tasks 文档）

### 4.1 T1 去 marker
`format.zig`/`store.zig`/`file_store.zig`：`appendRaw` 不再插 marker，写连续逻辑字节（逻辑==物理）。RED：跨原 marker 边界用例（写 >4095 字节，读跨边界处正确——现需跳 marker，去 marker 后天然连续）。

### 4.2 T2 logicalToPhysical identity
`logicalToPhysical`/`physicalToLogical` → identity（逻辑==物理）。RED：转换往返。

### 4.3 T3 Store.readBorrow vtable
`Store` vtable 加 `readBorrow(offset, max) -> []const u8`（借用切片）。FileStore 返 mmap 切片（bounds-check offset<logical_len 防 SIGBUS）；MemStore 返 ArrayList 切片；FaultStore 代理。RED：roundtrip（append→borrow 读回）。

### 4.4 T4 readRecord 返借用 + ~8 调用点改
`readRecord` 改返 `[]const u8` 借用切片（不 alloc 不 memcpy，走 `readBorrow`）。~8 调用点（get/branch-find + insert/delete/split/btree_batch）去 `free`、用借用。RED：既有 btree 测试全绿验证不漏（编译器抓返回类型变）。

### 4.5 T5 getLatestHeader 正扫
`getLatestHeader` 改正扫全文件按记录长度走，记最后有效 header（crc + payload kind/magic 是 header）。crash 半写尾 crc 不对→跳过。RED：crash 半写用例（写坏尾 → 正扫跳过用上一个）。

### 4.6 T6 bench 量收益
`zig build bench -Doptimize=ReleaseFast -Dbench-scale=small`，记 get 100B / 10KB us/op。预期 ~2–5us 追 LMDB。记录到 README benchmark 表 + 本文档。

---

## 5. 风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| readRecord 返回类型变更 | `[]u8`→`[]const u8` 借用波及 ~8 调用点 | 编译器抓全（返回类型变 → 漏改处编译错）；T4 RED 用既有 btree 全量测试验证不漏 |
| 借用生命周期 | mmap 大区永不 remap → reader/writer 期间安全；但 close 时若有 reader 在用？ | get 无锁并发，close 需保证无 reader（或 epoch/RCU）；MVP 容忍 close-while-read 不发生（单测无并发 close） |
| header 与 node 记录区分 | 去 marker 后正扫需区分 header vs node | 靠 payload 内容（header 有 magic+version；node 有 kind leaf/branch），正扫解码判别 |
| 去 marker 波及 fault_store / compact | appendRaw 是写共用 | 全改 appendRaw 一处；fault_store 代理；compact 重写用 appendRaw 自动一致 |
| 开机正扫大文件慢 | O(文件大小)，随 DB 增长 | 不比现慢；10GB+ 基于实测换 C 链表或 sidecar |
| crash 半写 header | 写 header 时崩 → 尾记录残缺 | 正扫跳 crc 不对的尾记录，用上一个有效 header |

---

## 6. 与上一阶段（mmap/skip-decode/T5）的关系

- 上一阶段：mmap 基建（大 sparse 区永不 remap）+ get skip-decode（findInLeaf）+ 热读跳 CRC。拿到 252→133us。
- 本阶段：在上一阶段基础上**去 marker + readRecord 返借用**，从"非真零拷贝"到"真零拷贝"。mmap 基建复用（方案 I 不变）；findInLeaf 改读 mmap 指针（payload 指向 mmap 而非堆 buf）；read-no-Crc 保留（热读仍跳 CRC）。
- 写路径：appendRaw 去 marker（写连续），其余不变；写路径读旧记录也走借用（T4）。

---

## 7. 验收

- T1–T5 各 RED 测试通过 + 全量 `zig build test` 绿。
- `zig build -Doptimize=ReleaseFast` 编译过。
- bench get 100B ≤ ~10us/op（追 LMDB 量级，~13× 改善门槛）；记录实际数。
- 并发 get + 写 仍正确（既有 `concurrent puts all visible` + get 验证不回归）。

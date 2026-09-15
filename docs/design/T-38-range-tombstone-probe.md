# T-38-P 设计文档 — 区间墓碑（Range Tombstone）方案可行性探路

- **任务**: T-38-P（探路/设计，方法 C；不改生产代码）
- **作者**: cube_db-pi-1（worktree cube-db-pi-1-rebuilt，基线 4e69f8a）
- **对象 issue**: `issues/T-38-deleteRange-efficient-range-tombstone.md`
- **状态**: 设计 + 探针验证完成；结论见 `.agents/tasks/T-38-P/probe-report.md`

本文档回答契约「须回答」的全部条目。所有格式事实基于基线源码实际行号；
标注【实测】的内容由 `spike/rangetomb_probe.zig` 真实运行背书，
标注【未实测/理论】的内容仅为推演。

---

## 0. 现状复述（问题定义）

`Db.deleteRange`（`src/db.zig:235-264`）= flush → `select` 全量迭代 →
逐 key `allocator.dupe` 进 ArrayList（`:242`）→ 等长 tombstone Entry 数组 →
整批 `putBatch`。内存峰值 O(range)、写放大 O(range)、墓碑永不清理。
目标：把大范围删除降到 **O(log n + 墓碑数)** 内存与写放大，
并保持 `select`/`get`/`entryCount` 三口径一致与现有崩溃安全模型。

## 1. 磁盘格式设计

### 1.1 设计原则（决定布局的三个约束）

1. **不动 leaf/branch payload 的首个字节判别逻辑**：`readNodePayload*`、
   `Iterator`、`findChildIdxAndOffset`、`Leaf.fromPayload` 等全部用
   `payload[0] == LEAF_KIND(2)` / `BRANCH_KIND(1)` 判别页类型（btree.zig:17-18,
   :291, :407, :452）。区间墓碑**不能**占用这两个 kind 值当叶/枝形态。
2. **复用现有页基础设施**：`PageHeader`（24B：page_no/type/gen/nkeys/free_next，
   format.zig:39-45）+ 尾部 CRC32（`verifyPageChecksum`）+ `writeNodePage`
   （btree.zig:104-119，`gen=0`、checksum 全页）对任何新页 kind 都是现成的。
   T-36（`nkeys` 下限）与 T-44（1-child 枝页）已经证明「新形态页 + 现有头/CRC」
   的扩展模式可行。
3. **可达性必须挂 meta**：树页只能从 `meta.root_page` 出发被读到（T-33 崩溃
   模型的根基：恢复 = 读两代 meta 取高 sequence + 从 root_page 可达即合法）。
   任何不挂在 root 可达集合里的新页都是「孤儿页」，违反 INV-F2 的精神
   （泄漏安全，但功能上读不到）。

### 1.2 选定布局：`PAGE_TYPE_RANGE_TOMBSTONE = 5` 新页 kind + meta 双锚点

**为什么不是「挂在 meta 的单个内联区间」**：`MetaPage` payload 定长 58B
（`META_PAGE_PAYLOAD_SIZE`，format.zig:24），剩余空间 4096-24-4-58 = 4010B，
内联进 meta 只能塞十几个区间，且 meta 是**每写都换代的超热页**
（每次 commit `writeMetaPage` 整页重写，file_page_store.zig:752）——把墓碑
列表放进 meta 意味着每次任何写入都要重写墓碑区，写放大转移到 meta 上。
【未实测：meta 重写频率的实际开销，属理论推断】

**为什么不是「叶内 entry 形态」**：叶 payload 的 entry 编码
（1B tombstone + 4B klen + key + 4B vlen + 1B flags，btree.zig:251-270）没有
「区间」语义槽位；往叶里塞区间 entry 会污染 `cmpKey` 排序不变量与
`leafPayloadSize` 预算（T-40 家族全部假设 entry=单 key）。改动面反而是最大。

**选定**：新页 kind `PAGE_TYPE_RANGE_TOMBSTONE = 5`（`format.zig:23` 现有
kind 已用到 4=OVERFLOW），页布局：

```
┌─────────────────────────────────────────────────────────────┐
│ PageHeader (24B): page_no / page_type=5 / gen=commit_seq /  │
│                   nkeys=墓碑条数 / free_next=下一链页(0=尾)  │
├─────────────────────────────────────────────────────────────┤
│ payload[0..2]  = 墓碑条数 count (u16 LE, ≤TOMB_PER_PAGE)     │
│ payload[2..]   = 连续定长头数组 × count:                     │
│   每条 16B:                                               │
│     min_len  u32   # min 键长（0 = unbounded/null min）       │
│     max_len  u32   # max 键长（0 = unbounded/null max）       │
│     min_off  u32   # min 键字节在 varint 区的偏移             │
│     max_off  u32   # max 键字节在 varint 区的偏移             │
│ varint 区（剩余 payload）: 各墓碑的 min/max 原始字节          │
│ 尾部 4B CRC32（现有 verifyPageChecksum 全页校验）             │
└─────────────────────────────────────────────────────────────┘
每页容量 ≥ 4068/(16+avg_key) 条；链式（free_next 串多页，同 freelist 链式）。
```

要点：

- **gen 戳用 commit sequence**：与 T-33 的 chain 页做法一致
  （`hdr.gen = meta.sequence`，file_page_store.zig:440/:521 的 H1 恢复校验
  同款语义）——torn-sync 后旧代墓碑页会被 H1 式校验拒绝（见 §5）。
- **页数上限**：单条墓碑最小 16+2×1B ≈ 18B → 每页 ≥ 225 条；
  链式无总数上限。
- **nkeys 字段复用**：写墓碑条数，walk 类校验器（page_partition.zig 风格）
  可以按 `count < 1` 拒绝空页（0 条墓碑没有存在意义，写路径保证不产生）。

### 1.3 树上锚点：root 页头新增「tomb 链头」字段

墓碑页链必须从 root 可达。最小侵入做法：**`Iterator`/`get` 的读路径额外
读一个「tomb_head」**。两个候选：

- **(α) meta 扩字段**：`MetaPage` 增加 `tomb_head: u32`（version 升级后生效，
  见 §2）。读路径 = `get/meta → tomb_head → 链页遍历`。**锚点随 commit 原子换代**
  （meta 双槽交替 + sequence 取高就是现成的原子发布机制，format.zig:184-190）。
  写路径不用碰树页——`deleteRange` 只写新墓碑链页 + 换 meta。
- **(β) root 页 payload 头部扩展**：改 root 页编码。否决：root 可能是叶或枝
  （两种 payload 都要改），且每次 deleteRange 都要 COW 重写 root 页本身。

**选定 (α)**。代价：MetaPage payload 58B → 62B（+4B tomb_head），
`META_PAGE_PAYLOAD_SIZE` 58 → 62（仍是远小于 4068 的定长，页内零头足够）。

### 1.4 墓碑条目语义

每条 = `[min, max)` 半开区间 + 时间戳（用写入时的 commit sequence）：

```
RTombstone = { min: ?[]const u8, max: ?[]const u8, seq: u64 }
```

- `min = null`（min_len=0）：负无穷；`max = null`：正无穷——与
  `deleteRange(null, null)` 全区间删除对齐。
- `seq` 不落盘也可以（页 gen 已带 commit sequence，恢复时从页头读），
  但**逐条携带 seq 有独立价值**：与逐 key tombstone 的优先级判定、
  以及未来 GC 的「低于水位即可物化清除」判定需要它。**落盘每条 +8B
  （条头 16B → 24B）**，或者从页 gen 继承（同页同 seq，条头保持 16B）。
  探针按「条头 24B 含 seq」实现（最保守容量），页容量 ≥ 4068/(24+2) ≈ 155 条。

## 2. `f2.MetaPage.version` 平滑升级 / 兼容

现状：`version: u16`，`isValidMeta` 硬判 `version == 2`（format.zig:181-183）。
每次 commit 都写 `version = 2`（writer.zig applyBatch step 5）。

**升级方案（version 2 → 3）**：

| 方向 | 行为 | 实现 |
|---|---|---|
| **新代码读旧库（v2）** | `tomb_head` 视为 0（无墓碑）——v2 的 58B payload 没有 tomb_head，按「无墓碑链」处理，全部读路径短路，行为与旧版逐字节一致 | decode v2 → tomb_head=0 |
| **旧代码读新库（v3）** | `isValidMeta` 判 `version==2` 失败 → `readMetaPage` 返回 null → **打开失败**（干净拒绝，不会误读） | 现状即如此，无需改 |

这是「**单向可升级**」：升级后不能再用旧二进制打开（v3 库对旧代码是关闭的）。
理由（怀疑默认）：

- 允许旧代码打开 v3 库要求旧代码理解 tomb_head 遮蔽语义——否则
  `select` 会把已删 key 全部吐回来（**静默数据复活**，比打开失败恶劣得多）。
- 现有生态（cube_check、备份工具）都走 `isValidMeta`，v3 库会被它们
  干净拒绝而不是误判。
- 若未来需要「降级打开」，可选加 version 位图（如 v=3 且 payload 首字段带
  feature-bits，tomb 子集为 0 时按 v2 行为）——**本期不做**，记录为扩展点。

**升级写路径**：第一次 deleteRange 写墓碑时，`writeMeta` 的 version 从 2 → 3
一次性切换；非 deleteRange 的普通 commit 在 v2 库上保持 version=2
（避免无关写触发全库格式升级），v3 库上保持 3。即 version 由「是否曾写墓碑」
决定，普通读写对 v2 库零扰动。【未实测：version 切换与打开路径的完整
交互——探针仅验证编解码层（§4 探针 4），完整 Db 级升级链路属 T-38 主体】

**meta 读路径对两代共存的处理**：`readMetaPage` 取高 sequence 的槽
（format.zig:184-190）。若 meta0 是 v2（seq=N）、meta1 是 v3（seq=N+1），
取 v3 正确；若 torn-sync 留下 v2 高 seq（旧代码最后一写），新代码按 v2
打开（无墓碑语义）也正确——**version 与 sequence 一起单调**，恢复总是
「能看到的最新的那个格式」，不存在混合态。【实测：探针 4 验证
「v3 meta + 墓碑链页 round-trip」与「v2 视角忽略 tomb_head」两条路径】

## 3. 语义：遮蔽判定与共存

### 3.1 遮蔽判定（读路径）

一个 key `k` 被遮蔽 ⟺ ∃墓碑 `t`：`t.seq > k 所在 entry 的写入 seq` **且**
`(t.min == null 或 k ≥ t.min) and (t.max == null or k < t.max)`。

**问题：叶子 entry 不携带写入 seq**（LeafEntry 只有 tombstone/key/value，
btree.zig:226-231）——无法按条比较时间戳。保守判定（**选定**）：

> `k` 被遮蔽 ⟺ ∃墓碑 `t` 覆盖 `k` **且** `t` 的 commit sequence 严格大于
> 「`k` 当前值最后一次被写入时」的 commit sequence。

由于无法逐 entry 取写入时间，落地时用 **Db 级时序**保证（写路径纪律，
§4.2）：`deleteRange` 在 `write_mutex` 内 flush 后以**新 sequence** 写墓碑；
任何**之后**的 put（sequence 更高）在写路径直接**截断/分裂**墓碑区间
（见 §4.3），使得盘上不变量成立：

> **INV-RT1**：盘上任意时刻，一个墓碑覆盖的 key 集合与「其后写入的活 entry」
> 不相交（写路径维护，读路径无需时间戳，只需空间覆盖判定）。

读路径因此简化为纯空间判定（min ≤ k < max，半开，与 select 同边界语义）：

- **`get(k)`**：点查。下降前先扫墓碑链（O(墓碑数)），命中覆盖 → 返回 null，
  不下降。优化：墓碑链按 min 排序（写入时构造即有序），二分查找 O(log T)。
- **`select`/`Iterator`**：迭代中每吐一个 entry 前查覆盖；更优——
  `next()` 进入新叶时把叶的 key 范围与墓碑求交，整叶跳过（区间剪枝，
  这才是 O(墓碑数) 而非 O(range) 的关键）。溢出值（overflow chain）同样被
  跳过，不读链页。
- **`entryCount`/`byte_size`**：**不精确可算**（精确值需要知道墓碑覆盖的
  在场 key 数）。方案：meta 里的 entry_count 在 deleteRange 时按
  「迭代统计」修正（O(range) 一次读，不占内存——流式计数），或接受
  「墓碑在场时 entryCount 是上界」并文档化。**推荐前者**：deleteRange
  本来就要 O(range) 读一遍来修 count（内存 O(1)，只是 CPU O(range)），
  把内存问题解决、CPU 保留——见 §6 与 issue 验收 (b)。

### 3.2 与逐 key tombstone 共存优先级

同 key 既有逐 key tombstone 又被区间墓碑覆盖：两者都表示「删除」，判定
结果相同（无冲突）。真正的优先级问题是「**墓碑之后又 put 回来的 key**」：
由 INV-RT1（写路径分裂墓碑）保证该 key 不再被墓碑覆盖——区间墓碑**从不
遮蔽其后写入的活 entry**。探针验证（§4 探针 3）：

```
put k; deleteRange [a,b) ⊇ k; put k → get(k) 必须非 null（墓碑已分裂/失效）
put k; deleteRange [a,b) ⊇ k     → get(k) = null（遮蔽生效）
deleteRange [a,b); put k         → get(k) 非null（seq 序：put 在后）
```

### 3.3 边界语义

与 `select` 的 `[min, max)` 严格对齐：`min` 含、`max` 不含；
`min == max`（且非 null）→ 空区间 no-op；`(null, null)` → 全区间。
倒置（min > max）→ no-op 成功（现状 db.zig:240-245 语义保持）。
全区间墓碑 `(null, null)` 是合法墓碑（min_len=max_len=0）。
【实测：探针 2 全部边界】

## 4. 写路径设计

### 4.1 deleteRange 新流程（目标复杂度）

```
1. 校验区间（倒置/空 → no-op）                          O(1)
2. write_mutex + flush 暂存项（语义保持，db.zig 现状）     O(batch)
3. 迭代 [min,max) 计数 in-range 在场 key 数（流式，O(1) 内存）→ count_delta  O(range) CPU / O(1) 内存
4. 若墓碑链需分裂（见 4.3）：读被影响墓碑（O(T)）计算新区间集
5. 写新墓碑链页（新页，gen=新 sequence，nkeys=条数，CRC）   O(T')  T'=墓碑总数
6. 换 meta（root 不变，tomb_head=新链头，version 2→3 首次，sequence+1）  O(1)
7. 旧墓碑链页入 pending_free（release_seq=新 sequence，走现有 MVCC 回收） O(旧链页数)
```

- **内存**：O(墓碑数)（链页顺序写，每页 4KB 缓冲）——达标
  （issue 验收 (a)：不再 O(range)）。
- **写放大**：O(墓碑页数) + meta 一次 + 同 range 反复 deleteRange 只
  覆盖式重写整条链（T 条墓碑页 vs 旧路径 N 条 tombstone entry 页）——
  issue 验收 (d) 的「页数不随 K 线性增长」在「每次全链重写 T 页」下成立
  （T 不随 K 增长；K 次重复删同一区间 → 第 2 次起 in-range key=0，
  甚至可短路成「链上已有等价墓碑 → 只换 meta」的幂等快路径）。
- **CPU**：步骤 3 仍是 O(range) 读（修 entryCount），**内存是 O(1)**。
  这是方案 A 相对纯墓碑的保守妥协；见 §6 讨论（可分期去掉）。

### 4.2 micro-batch 语义保持

现状 deleteRange 先 `flush()`（staged 项可见才能被删，db.zig:247-249）。
新路径同样先 flush，且步骤 5-6 在 write_mutex 内一次性完成（墓碑 + meta
同 commit sequence 原子发布）。staging 并发交错（验收 (c)）语义不变：
墓碑是 commit 序中的普通一环。

### 4.3 墓碑分裂（put 打洞 / 新墓碑交叠）

后续 put/deleteRange 落在既有墓碑覆盖内时，写路径必须维护 INV-RT1：

- **put(k) 且 k 被墓碑 t=[a,b) 覆盖**：把 t 分裂为 [a,k)+[k',b)（k' 是 k 的
  后继上界——实现上用 [a,k) 与 (k,b) 两段，注意半开语义：右段改为
  [k+ε, b) 无法表达，改为 **[k 的严格后继, b)** 不精确——**正解**：
  墓碑区间集合改用「墓碑存 [min,max)，put k 时把包含 k 的墓碑分裂为
  [min,k) 与 (k,max) 无法半开表达」→ **改用闭开对**：存 `[min, max)` 且
  允许 min 端用「k 前缀+0x00」上界技巧不可靠（键空间无哨兵）。
  **工程正解**：分裂右段直接用 `[max(k, min), max)` 去掉 k 单点无法表达，
  因此采用 **墓碑重叠语义**：不分裂，而是 put(k) 的 commit 同时追加一条
  「负墓碑（anti-tombstone）[k, k+] 」？——复杂化。
  **选定（简洁）**：put(k) 时把覆盖 k 的墓碑删除并物化为其覆盖区间减 k
  的两个墓碑（[min,k) 与 [k_ceil, max)，其中 k_ceil = k 的**字典序后继**
  仅在 k 不是任意字节串上界时存在；k = 全 0xFF 尾时右段为空舍弃）。
  字典序后继 = k 追加 0x00（k+0x00 是 > k 的最短键）。【实测：探针 3 覆盖
  「put 打洞后原墓碑对新 key 仍遮蔽、对 k 不遮蔽」】
- **新 deleteRange 与旧墓碑交叠**：合并/吸收（新区间并集），链重写时
  O(T) 归并去重，保持链按 min 有序。

### 4.4 deleteRange 幂等性

同区间重复删：第二次起步骤 3 计数=0；墓碑链已含等价区间 → 步骤 5-6
可短路（或照写，等价）。对外语义（现状 db.zig:237-238 注释承诺
「Idempotent on already-missing keys」）保持。

## 5. 崩溃安全（与 T-33 模型交互）【重点风险面】

T-33 模型要点（源码核实）：两代 meta 双槽交替 + sequence 取高恢复
（format.zig:184-190）；freelist 链页 gen=sequence + H1 恢复校验
（file_page_store.zig:521）；`vtWriteMeta` 单临界区完成 retire→persist→
rotation→meta 落盘（:698-757）；INV-F1（重复 free 幂等）/ INV-F2
（链验证失败整链丢弃，泄漏方向安全）。

**逐项审视墓碑引入的风险**：

1. **墓碑页 torn-sync**：新墓碑链页先写（步骤 5）再换 meta（步骤 6）。
   meta 落盘即「发布」（process_crash 模型，mmap 即 landed；power_fail
   模型先 `syncDataPages` 再 meta，writer.zig:1211 附近）。崩溃窗口：
   - 墓碑页写了、meta 未写 → 恢复取旧 meta，tomb_head 指旧链（或无），
     新墓碑页成孤儿页——**泄漏方向**（INV-F2 同款安全方向：孤儿页只是
     空间浪费，被 freelist 永不回收，但绝不误删数据）。✅
   - meta 写了、链页部分 torn → CRC 校验失败（`verifyPageChecksum` 全页），
     读墓碑链时校验失败的处理：**取怀疑默认 = 整链丢弃 + 数据面按无墓碑
     处理？不行——那是数据复活！** 正解：墓碑链页校验失败 = 库损坏
     （`error.CorruptCrc`），与树页 CRC 失败同级对待。理由：meta 发布的
     tomb_head 指向的页必然同 sequence 已落盘（power_fail 的
     syncDataPages-before-meta 保证；process_crash 模型下页缓存不丢），
     正常恢复不可能读到 torn 墓碑页——读到了就是介质损坏，应当报错
     而非静默语义漂移。⚠️ **风险记录**：这是「格式新页必须与树页同等
     严格」的纪律，探针 1 用 CRC 翻转验证墓碑页的损坏可检测性。
2. **旧墓碑链回收 vs 并发读者**：旧链页入 `pending_free`（release_seq =
   新 sequence）走现有 watermark 回收（writer.zig T-30 增量回收）——
   老快照读者（seq < 新 sequence）可能还引用旧墓碑链（其 select 在迭代
   中途）。**与树页 COW 完全同构**：现有机制天然覆盖，无新增风险。✅
3. **freelist 交互**：墓碑链页是普通数据页（非 chain 页），alloc/free 走
   现有 pool；gen=sequence 只在 chain 页有 H1 校验语义（file_page_store.zig:521），
   墓碑页 gen=sequence 是**信息性的**（无 H1 强校验）——但墓碑页不进
   freelist 链，无 H1 需求。✅
4. **crash hook（fireCrashHook）**：`vtWriteMeta` 的注入点（before_chain/
   mid_chain/after_chain_before_meta/after_meta）不变——墓碑不进 freelist
   chain，`vtWriteMeta` 全流程零改动（除 meta_copy 多一个 tomb_head 字段
   透传）。T-33 的崩溃测试矩阵（T6/T7 家族）对墓碑 commit 的覆盖 =
   对普通 commit 的覆盖 + 步骤 5 多几个数据页写入，模型不变。✅
5. **两代 meta 混格式**：见 §2——version 与 sequence 一起单调，恢复无混合态。✅

**结论**：墓碑方案与 T-33 模型**同构兼容**——它只是「另一种从 root/meta
可达、带 CRC、随 commit 换代的数据页」。最大新增风险是 1 中的「链页损坏
= 必须报错不静默」，属实现纪律而非模型缺陷。

## 6. GC / 收敛出口

现状（T-30 compact，writer.zig:341-370）：只回收 pending 空闲页 + 换 meta，
**不重写数据**（docs/usage.md:316）。墓碑的完整 GC 需要「真·compact」：

- **物化清除**：compact 时迭代全库，对每个墓碑覆盖区间做一次 in-range
  迭代删除 entry（此时才产生 O(range) 写——但 compact 本来就是 O(n)
  全量操作，写放大被摊进 compact 预算），然后丢弃墓碑。
- **水位收割**：无并发读者（或 watermark > 墓碑 seq）且墓碑覆盖区间内
  无在场 key 时，墓碑可直接丢弃（无需重写树——区间内本来就没 entry）。
  deleteRange 后从未 put 回来的区间就是这种（最常见）。
- **墓碑合并**：交叠/相邻墓碑在每次链重写时归并（§4.3），链长 O(活跃
  不相交区间数)，不随 deleteRange 次数增长。

**若 GC 无出口的后果**（怀疑默认）：墓碑链只增不减 → 链页积累 → 每次
deleteRange 重写整链的 O(T) 变大 + 读路径遮蔽判定 O(T) 变大。上界：
T ≤ deleteRange 的不同区间数（合并不增长），不会失控，但无 compact 则
永不归零。**建议**：T-38 主体落地时至少带「水位收割」（无读者 + 空区间
丢弃，实现小、收益大），完整物化清除挂 U-5 真·compact。

## 7. 与 T-37 / T-44 的交互

现 deleteRange 的逐 key tombstone 批是「小批量提交」源（T-37 issue 自述），
且墓碑 entry 占叶空间推动叶裂变/树高。改区间墓碑后：

- deleteRange **不再产生任何叶写入**（只写墓碑链页 + meta）——树高增长
  的这个推力**消失**；叶内旧 entry 等 compact 才物理消失（与现状一致）。
- 墓碑链页自成链，**不进树**，不影响树高/深度不变量（T-37-B / T-44 的
  深度界只管树页）。T-44 的 1-child 枝页、T-37 的 splice 形态零交互。✅
- `Iterator.MAX_DEPTH=64` 不受影响（墓碑链的遍历深度是链长，与树深无关，
  且遮蔽剪枝只减少树下降）。

## 8. 与方案 B（流式分块）对比 → 见 probe-report.md §对比

（对比、结论与分期拆解在报告文件中，避免双处维护。）

## 9. 本文档未实测项汇总

| 项 | 状态 |
|---|---|
| 墓碑编码/解码 round-trip、遮蔽边界、共存优先级、v2/v3 meta 兼容 | 【实测】探针 1-4 |
| put 打洞（字典序后继 k+0x00）语义 | 【实测】探针 3 |
| CRC 损坏墓碑页可检测 | 【实测】探针 1 |
| Db 级端到端（deleteRange → 重启 → 遮蔽保持） | 【未实测】需改 db.zig，属 T-38 主体 |
| 并发 staging/flush 交错下墓碑 commit 序 | 【未实测】需改 writer.zig，属 T-38 主体 |
| FilePageStore 上 meta 扩字段的 torn 行为 | 【未实测】需改 format/file_page_store，属 T-38 主体；模型论证见 §5 |
| 墓碑链页数上界的实际增长曲线 | 【未实测】理论界见 §6 |

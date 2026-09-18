# T-38-P 设计文档 — 区间墓碑（Range Tombstone）方案可行性探路

- **任务**: T-38-P（探路/设计，方法 C；不改生产代码）
- **作者**: cube_db-pi-1（worktree cube-db-pi-1-rebuilt，基线 4e69f8a）
- **对象 issue**: `issues/T-38-deleteRange-efficient-range-tombstone.md`
- **状态**: 设计 + 探针验证完成；结论见 `docs/design/T-38-probe-report.md`。
  **T-38-P-R 返工**（评审 F1/F2 + conductor 复算确认）：修正打洞右段复活论证
  （§4.3）、补边界可表示性分析并修订条目布局（§1.2/§1.4，16B 条头 + append_zero
  紧凑边界编码）。探针同步返工（6/6 绿）。

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
kind 已用到 4=OVERFLOW）。页布局（**T-38-P-R 修订版**：payload 计数移除
——页头 nkeys 为准；条头 16B；边界加 append_zero 紧凑标志）：

```
┌─────────────────────────────────────────────────────────────┐
│ PageHeader (24B): page_no / page_type=5 / gen=commit_seq /  │
│                   nkeys=墓碑条数 / free_next=下一链页(0=尾)  │
├─────────────────────────────────────────────────────────────┤
│ payload[0..]   = 连续定长头数组 × nkeys（无 payload 计数）： │
│   每条 16B:                                               │
│     min_len  u32   # min 存储键长；bit31=append_zero；bit30=spill 预留（恒0）│
│     max_len  u32   # max 存储键长；bit31=append_zero；bit30=spill 预留（恒0）│
│     min_off  u32   # min 键字节在变长区的偏移（payload 起）   │
│     max_off  u32   # max 键字节在变长区的偏移（payload 起）   │
│ 变长区（剩余 payload）: 各墓碑 min/max 的存储字节             │
│   （len=0 且无标志 = unbounded/null；append_zero 见下）      │
│ 尾部 4B CRC32（现有 verifyPageChecksum 全页校验）             │
└─────────────────────────────────────────────────────────────┘
每页容量 ≥ 4068/(16+avg_key) 条；链式（free_next 串多页，同 freelist 链式）。
```

要点：

- **gen 戳用 commit sequence**：与 T-33 的 chain 页做法一致
  （`hdr.gen = meta.sequence`，file_page_store.zig:440/:521 的 H1 恢复校验
  同款语义）——torn-sync 后旧代墓碑页会被 H1 式校验拒绝（见 §5）。
- **页数上限**：单条墓碑最小 16+2×1B = 18B → 每页 ≥ 226 条（4068/18）；
  链式无总数上限。
- **nkeys 字段复用**：写墓碑条数（payload 内不再重复计数——双处计数是
  冗余校验面，CRC 已保完整性）；walk 类校验器（page_partition.zig 风格）
  可以按 `nkeys < 1` 拒绝空页（0 条墓碑没有存在意义，写路径保证不产生）。
- **迁移注记（N1）**：探针的 `decodeTombPage` 对 offset 越界用 `@panic`——
- **bit30 spill 预留位（T-38-1 落地补充，F-4）**：条头 `min_len`/`max_len` 的
  **bit30 恒为 0**，保留给「边界 spill 到 overflow 链页」（本节上文的双长边界生产
  方向）；bit31 仍为 append_zero。编码恒写 0；解码遇到置位按损坏拒绝
  （`error.InvalidTombPage`）——预留本身是格式的一部分，未来启用时随
  解码器协同升级，当前版本解码器对其干净拒绝而非误读。
  spike 可接受，**迁移进 `src/` 时必须改为 `error.Truncated/CorruptCrc`**，
  不得照抄 panic。

#### 边界可表示性分析（T-38-P-R，F2 返工）

算术（conductor 独立复算确认）：`TOMB_PAYLOAD = 4096−24−4 = 4068`。
基线布局（2B 计数 + 24B 条头含 seq）的变长预算 = 4068−2−24 = **4042B <
`MAX_KEY_SIZE`(4051)**——单条墓碑一个 4050B 边界就装不下（基线实测
`TombPageOverflow`），而 `deleteRange` 接受最长 4051B 的用户 key、
`punchHole` 的 `succ(k)` 需要 4052B。这是设计层可行性缺口，返工修订：

1. **条头 24B → 16B**（逐条 seq 从页 gen 继承，见 §1.4——预算 +8B）；
2. **payload 计数移除**（页头 nkeys 为准——预算 +2B）；
   → 单条墓碑 envelope = `16 + min_stored + max_stored ≤ 4068`，
   即**单边界最长 4052B ≥ MAX_KEY_SIZE=4051**：任意单侧 deleteRange、
   任意 `succ(k)`（紧凑编码后存储 = 原键长 ≤ 4051）都可表示【实测：探针 6】。
3. **双长边界**（`min_stored + max_stored > 4052`，如 `['a'×3000, 'z'×3000]`）
   仍装不下：编码器返回 **typed `error.TombBoundTooLarge`** 明确拒绝
   【实测：探针 6(c)】，而不是基线的笼统 `TombPageOverflow`。
   **生产方向（阶段 1 决策）**：边界字节 spill 到 overflow 链页
   （复用 `PAGE_TYPE_OVERFLOW` 基础设施；单边界 ≤ 4052B 恒可容纳一页
   4068B → spill 方案数学上完备）或对该类 deleteRange 明确报错并文档化。
   在阶段 1 定案前，探针按「typed 拒绝」交付。

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
RTombstone = { min: ?Bound, max: ?Bound, seq: u64 }
Bound      = { bytes: []const u8, append_zero: bool = false }
# Bound 的 effective 字节串 = bytes ++ (0x00 if append_zero)
```

- `min = null`（存储 len=0 且无标志）：负无穷；`max = null`：正无穷——与
  `deleteRange(null, null)` 全区间删除对齐。
- **seq 从页 gen 继承（T-38-P-R 选定）**：逐条 seq 不落盘（条头保持 16B，
  §1.2 可表示性分析要求）。安全性论证：读路径是纯空间判定（INV-RT1，
  不用 seq）；GC 水位判定用页 gen（链重写时间 ≥ 墓碑真实建立时间）——
  只会把「可物化清除」判得更保守（推迟、不提前），方向安全。打洞分裂段
  继承原墓碑建立时间的场景同理：写进新页后表现为页 gen（较新），
  GC 推迟回收，保守安全。
- **append_zero 是 `succ(k)`（k 的字典序后继上界 = k ++ 0x00）的紧凑表示**
  （T-38-P-R，F1 修复核心）：存原键长、语义等价于 k ++ 0x00。
  这使 put 打洞的右段下界**恒可表示**（存储回到原键长，见 §4.3），
  且 punchHole 零堆分配。比较语义【实测：探针 2 append 边界组】：
  `succ("b")` 作为 min：`"b"` 不被遮蔽、`"b\x00"`（== effective）被遮蔽
  （min 含）；作为 max：`"m"` 仍被遮蔽（< "m\x00"）、`"m\x00"` 不被。

## 2. `f2.MetaPage.version` 平滑升级 / 兼容

现状：`version: u16`，`isValidMeta` 硬判 `version == 2`（format.zig:181-183）。
每次 commit 都写 `version = 2`（writer.zig applyBatch step 5）。

**升级方案（version 2 → 3）**：

| 方向 | 行为 | 实现 |
|---|---|---|
| **新代码读旧库（v2）** | `tomb_head` 视为 0（无墓碑）——v2 的 58B payload 没有 tomb_head，按「无墓碑链」处理，全部读路径短路，行为与旧版逐字节一致 | decode v2 → tomb_head=0 |
| **旧代码读新库（v3）** | 【T-53 之前的旧行为】`isValidMeta` 判 `version==2` 失败 → `readMetaPage` 返回 null → **Db.open 静默按空库打开**（把双槽 null 视为「未曾初始化」，fresh DB 路径）；后续写入从 FIRST_DATA_PAGE 重新分配，**覆盖既有 v3 数据页**（静默数据破坏，T-38-1 F-1 更正，issue T-49）。干净拒绝只在 cube_check 等走 `error.NoMeta` 的工具层成立（cube_check.zig:66） | 【T-53 已修】`readMetaPage` 对「CRC 合法但 magic/version 不认识」（坏 magic / v1 / ≥v4）的槽返回 `error.InvalidMeta`（format.zig `isInvalidMetaPage`）；`Db.open` 拒绝且不写盘（errdefer 零泄漏）；`FPS.init` 以 `invalid_meta` 标记区分 fresh 与 invalid（init 不致命，硬门在 Db.open）。**风险仅剩「回滚到 T-53 之前的旧二进制」** |

这是「**单向可升级**」：升级后**不得回滚二进制**——**T-53 之前**的旧二进制不会拒绝打开 v3 库，而是静默按空库打开并覆盖数据（见上表 F-1 更正与 T-49），比「打不开」恶劣得多：**回滚不是「用不了」，而是「静默毁数据」**。T-53 之后的新二进制对一切认不出的 meta（v1 / v4+ / 坏 magic）一律 typed 拒绝，不再有此风险。

**生产读路径的三值判定（T-38-P-R，N2）**：探针的 `decodeMetaAny` 把
「非 v2」一律返回 null（探针内部由调用方再探测 v3）；生产 `readMetaPage`
必须是**三值判定**——v2（tomb_head=0 打开）/ v3（读 tomb_head）/
**其它（magic 不符或 version ≥ 4：打开失败，报明确错误）**。尤其
「v4+ 或垃圾」不得与「v2」混同（探针 4 的双 decode 组合即此语义的
最小演示，迁移时须展开为显式三值）。

理由（怀疑默认）：

- 允许旧代码打开 v3 库要求旧代码理解 tomb_head 遮蔽语义——否则
  `select` 会把已删 key 全部吐回来（**静默数据复活**，比打开失败恶劣得多）。
- 现有生态里 cube_check 等工具层走 `readMeta() orelse return error.NoMeta`，对 v3 库
  干净拒绝；但 **Db/FPS 打开路径不会拒绝**（见上表）——干净拒绝不是全局属性，仅在工具层成立。
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

### 4.3 墓碑分裂（put 打洞 / 新墓碑交叠）【T-38-P-R 修订：F1】

后续 put/deleteRange 落在既有墓碑覆盖内时，写路径必须维护 INV-RT1：

- **put(k) 且 k 被墓碑 t=[min,max) 覆盖**：把 t 分裂为 **[t.min, k)** 与
  **[succ(k), t.max)** 两段，其中 `succ(k) = k ++ 0x00`（> k 的最短字节串），
  用 §1.4 的 append_zero 紧凑边界表示（存原键长）。语义要求：
  k 不再被遮蔽（put 回来的 key 活），区间内其余 key（含建碑前已被删除的
  活 entry）必须仍被遮蔽。【实测：探针 3——打洞后对 k 不遮蔽、对区间内
  其它 key 仍遮蔽；含 F1 复活反例（见下）】
  - **左段为空**当且仅当 `t.min == k`（covers 已保证 t.min ≤ k）→ 跳过。
  - **右段为空**当且仅当 `t.max == succ(k)`——k 与 succ(k) 之间不存在任何
    字节串，故这是唯一情形（如 `deleteRange("b","b\x00")` 建的墓碑再
    put "b" 会被完全消费）【实测：探针 3 右段真空 edge】。

  **F1 返工记录（错误论证 → 修正）**：基线版本在 `succ(k)` 超长（k 近
  `MAX_KEY_SIZE`，succ 需 4052B）时**丢弃右段**，并论证「只会漏遮蔽后来又
  写回又被删的键，由后续 deleteRange 重新建碑覆盖」——**该论证错误**：
  右段 [succ(k), t.max) 覆盖的是**建碑前就存在、已被那次 deleteRange 删掉
  的活 entry**，丢弃 = 这些 key **复活**。反例（基线实测红，T-38-P 评审
  X2 / 返工 RED 用例）：

  ```
  put "r"(seq1) → deleteRange ["a","z")(seq2) → put big='q'×4051(seq3)
  基线：右段被丢弃 → "r" 不再被遮蔽 → 复活（错）
  返工：右段 [succ(big), "z") 以紧凑边界保留 → "r" 仍被遮蔽（对）
  ```

  正确表述：右段丢弃**仅当右段真空**（t.max == succ(k)）；「右段装不下」
  不是丢弃理由。append_zero 紧凑编码使 succ 的存储回到原键长（≤4051 ≤
  envelope 单边界上界 4052），**右段在 envelope 内恒可表示**。
  - **剩余缺口（诚实声明）**：当 `k.len + t.max_stored > 4052`（k 与 t.max
    双长）时右段**条目**超出单条 envelope（§1.2 分析）——编码器返回
    `TombBoundTooLarge`。生产方向（阶段 1/3 决策）：边界 spill 到 overflow
    页（恒足够）或该 put 走物化 per-key tombstone 兜底（O(range)，仅此
    边角触发）；**禁止**再回到「丢弃右段」。【未实测：spill/物化兜底——
    属 T-38 主体阶段 1/3，探针以 typed 错误明确暴露】
- **新 deleteRange 与旧墓碑交叠**：合并/吸收（新区间并集），链重写时
  O(T) 归并去重，保持链按 min 有序（append_zero 边界参与统一排序，
  比较 = effective 字节串序）。

### 4.4 deleteRange 幂等性

同区间重复删：第二次起步骤 3 计数=0；墓碑链已含等价区间 → 步骤 5-6
可短路（或照写，等价）。对外语义（现状 db.zig:237-238 注释承诺
「Idempotent on already-missing keys」）保持。

### 4.5 写路径不变量（T-38-3 落地实记）

**INV-W1（编码器入口净化，阶段 1 评审 N-R1）**：空区间（min ≥ max，倒置或
空）与**空 plain 边界墓碑**（`min == max` 的 `[x, x)`，或打洞分裂产生的
空段）**不得进入编码器**。实现口径：deleteRange 入口对倒置/空区间直接
no-op 返回（零副作用，不 flush）；打洞分裂段只有在「非真空」时才生成
墓碑条目（左段空 ⟺ `t.min == k`；右段空 ⟺ `t.max == succ(k)`）。

**INV-W2（原子发布）**：打洞（put 进墓碑区间）与 deleteRange 建碑都在
**单一 commit** 内完成——`applyBatchSwap` / `commitTombSwap`：一次
`writeMeta`、一次 sequence 递增；树插入（若有）、墓碑链页写入、旧链页
`pending_free`（`release_seq` = 新 sequence）同批发布。INV-RT1 在盘上
任意时刻成立。

**INV-W3（计数一致）**：`entryCount` 恒等于「可见活 entry 数」（物理树
活 ∧ 未被链遮蔽）。打洞/物化触碰「物理活但被遮蔽」的 entry 时（insert
的 count_delta 看不见遮蔽状态），由 `TombSwap.revive_count/revive_bytes`
补偿，补偿判据 = 提交前 `btree.get(k) != null`（物理活）∧ 被遮蔽。

**INV-W4（覆盖短路）**：deleteRange 入口先在**栈上**（FixedBufferAllocator
探针，零堆分配）检查 `[min,max)` 是否已被现有链覆盖——已覆盖则整个
调用零副作用返回（幂等快路径，T-38-B 预算的 `peak2 ≤ peak` 由此成立）；
探针装不下的大链自动回落通用路径。

**§2 表格行 2 补充（T-53 后新事实）**：本表「旧代码读新库」行为列描述
的是 T-53 之前的旧行为（保留作历史）；T-53 之后的新二进制对 v1/v4+/
坏 magic 一律 `error.InvalidMeta` 拒绝。**T-38-3 之后**，本仓库自己的写
路径已会产出 v3 meta（首次 deleteRange 起，sticky 3），「v3 库」不再仅
是构造态。

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
（前瞻：若阶段 1 采用 §1.2 的边界 spill，spill 页 = 现有 overflow 型普通
数据页——从墓碑条目的 min_off/max_out 链可达、带 CRC、不进 freelist chain，
与上述分析同构，不引入新的崩溃面。）

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
| 墓碑编码/解码 round-trip（含 append_zero 边界）、遮蔽边界、共存优先级、v2/v3 meta 兼容 | 【实测】探针 1/2/3/4（T-38-P-R 返工后） |
| put 打洞（字典序后继 k+0x00 紧凑表示）语义，含 F1 复活反例（近-MAX key） | 【实测】探针 3——基线红、返工后绿 |
| CRC 损坏墓碑页可检测 | 【实测】探针 1 |
| F2 边界可表示性 envelope（4051B 单边界 / succ 紧凑 / 双长边界 typed 拒绝 / 恰好装满） | 【实测】探针 6——基线 4050B 即 TombPageOverflow（红） |
| Db 级端到端（deleteRange → 重启 → 遮蔽保持） | 【未实测】需改 db.zig，属 T-38 主体 |
| 并发 staging/flush 交错下墓碑 commit 序 | 【未实测】需改 writer.zig，属 T-38 主体 |
| FilePageStore 上 meta 扩字段的 torn 行为 | 【未实测】需改 format/file_page_store，属 T-38 主体；模型论证见 §5 |
| 墓碑链页数上界的实际增长曲线 | 【未实测】理论界见 §6 |
| 双长边界（min_stored+max_stored > 4052）的 spill / 物化兜底 | 【未实测】方向已定（§1.2/§4.3），阶段 1 决策；探针以 `TombBoundTooLarge` typed 拒绝 |
| 生产写路径 punchHole 集成（含右段超 envelope 兜底） | 【未实测】属 T-38 主体阶段 3；探针 3 为墓碑集层面 |

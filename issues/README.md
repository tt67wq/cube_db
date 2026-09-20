# cube_db · issues 索引

本目录记录开发/评审/整合过程中发现的问题，每个问题一个带编号与状态的 `.md` 文件。
本文件是**总索引**：想快速知道「还剩哪些没修、卡在哪、下一步是什么」，看这里即可。

> 最后更新：2026-09-20（**T-54 全阶段完成并 closed 归档**；新立 T-55 收尾 nit）。main = `8f3671d`。

**布局约定**：`issues/` 根目录**只放仍活跃的 issue**（`open` / `proposed` / `fixing` / `partial`）。
一旦置为 `closed` 并通过验收，**立即 `git mv` 进 `archived/`**，文件名不变。

---

## 一、状态词表（规范值）

状态字段只应使用下面 5 个值之一：

| 状态 | 含义 | 谁能推进 |
|---|---|---|
| `open` | 已确认成立，尚未指派修复 | conductor 立项 |
| `proposed` | 已记录但**未决定要做**（待立项/待评估/已论证不可闭合） | 等决策 |
| `fixing` | 已指派，修复进行中 | worker 干活中 |
| `partial` | **部分闭合**：一部分痛点已验收关闭，另一部分仍开着 | 剩余部分另立或继续 |
| `closed` | 验收通过，已合入 main | 无 |

**写状态的纪律**：状态词后必须补一句白话的「**还剩什么**」。
只写 `partial` 或 `fixing` 而不说剩什么，等于没写——读的人仍要翻全文。

**已知的历史不一致（本索引不改各文件，仅在此登记）**：
`部分交付`（T-39）应读作 `partial`；`**CLOSED** ✅`（N-1）与 `**closed**`（T-51）应读作 `closed`。
装饰性加粗/大小写/emoji 不影响语义，但新写/新改时应统一到上表。

---

## 二、活跃 issue

### 按状态分组

| 状态 | 编号 |
|---|---|
| `fixing` | T-38 |
| `partial` | T-39 |
| `proposed` | T-39-C、T-45、T-47 |
| `open` | T-53、T-55 |

**活跃 issue 共 7 条**（根目录下除本 README 外的全部 `.md`）。
已 closed 的 15 条见下文「三、归档」。

### 明细

| 编号 | 标题（简） | 状态 | 还剩什么 / 下一步 | 关联 main |
|---|---|---|---|---|
| **T-38** | deleteRange 高效化：全量物化 + 每 key tombstone 的 O(range) 内存与写放大 | `fixing` | **阶段 3 主线**。阶段 1（格式层）/ 阶段 2（读路径）已合入验收；当前在阶段 3（写路径）/ 阶段 4（GC）。前置 T-49/T-50 已由 T-53 关闭 | `baa44bd`、`88124bc`、`1c6ce1d` |
| **T-39** | freelist 持久化写放大：每次 commit 整链重写 + O(pool) 去重扫描 | `partial` | 去重收敛 / 静默吞错可观测化 / FreelistStats 观测 API 已验收关闭；**写放大痛点未闭**，已拆出 T-39-C | — |
| **T-39-C** | append-only freelist 增量持久化在现有崩溃模型下不可闭合（impossibility 记录） | `proposed` | 已论证「不改 T-33 崩溃安全模型则无法安全落地」，等 conductor 决定是否投入新的磁盘格式不变量（freshness proof） | — |
| **T-45** | T-43 sweep 回归测试 overwrite 步骤使用 stale root（测试瑕疵） | `proposed` | 测试语义瑕疵，sweep 有效性不受影响；待决定是否修 | — |
| **T-47** | `docs/lecture_btree.html` 与 T-43/T-46 后实现脱节 | `proposed` | **已交付但搁置**：交付物 `4632fcb` 未合入，评审 REQUEST_CHANGES；待返工或弃用 | — |
| **T-53** | 「torn meta」方向仍可被当 fresh DB 打开：双槽 torn 时可能覆盖既有数据页 | `open` | medium，数据破坏面（与 T-49 同族，需双重损坏或单提交库 torn 触发）。T-53 任务只闭合了 invalid-meta 方向；torn 方向留待评估 heuristic 拒绝 | `1c6ce1d`（T-53 主任务已合入） |
| **T-55** | T-54-G 遗留 nit：`is_shard` 前缀匹配把 `insertbatch_sweep_partition_test.zig`（毫秒级纯算术守卫）也排除出 `test-one` | `open` | 低（无正确性影响：它仍在默认门；`-Dfilter` 命中 0 时是**响亮 addFail** 而非静默通过）。修法：`is_shard` 改精确匹配 4 个分片文件名，或加 `!endsWith("_partition_test.zig")` | — |

### 值得先看的

- **T-53** 是数据破坏面的 `open`（与已关闭的 T-49 同族，但方向是 torn 而非 invalid）。
  触发需双重损坏或单提交库 torn，当前无实际触发面；待评估 heuristic 拒绝。
- **T-38** 是唯一的 `fixing`，是本仓库当前的主线工作。其阶段 3 的前置
  T-49/T-50 已由 T-53 关闭（`1c6ce1d`），**阶段 3 现可推进**。
- **T-39 + T-39-C** 要连起来读：T-39 剩的那块之所以没做完，是因为 T-39-C 论证了它在现有
  崩溃模型下**做不到**。别把它们当成两个独立的小问题。
- **T-54（测试效率）已 `closed` 并归档**（`8f3671d`）：wall 182.6s → **55s**、`build.zig` 924→149 行、
  重复编译 77→0、测试总数 532 coverage-neutral、`test-one -Dfilter=` 迭代 4.2s。收尾 nit 见 **T-55**。

---

## 三、归档（`archived/`）

已全部 `closed`，保留供追溯，不再维护。共 15 条。

| 编号 | 标题（简） | 状态 | 关联 main |
|---|---|---|---|
| T-36 | staging 并发 deleteRange flaky crash | `closed` | `9b2705f` |
| T-37 | tree depth 无界增长 → error.Truncated | `closed` | `f2d0da8` |
| T-40 | batch chunking：count vs payload size | `closed` | — |
| T-41 | root splice errdefer 泄漏 | `closed` | — |
| T-42 | insertBatchIntoLeaf 合并重复 key 泄漏 | `closed` | `f356bd3` |
| T-43 | 单条 insert payload 溢出 | `closed` | `1154260` |
| T-44 | near-max key depth 棘轮 | `closed` | `9306df7` |
| T-46 | insertSub split_key 残留（死机制） | `closed` | `bcf5368` |
| T-48 | range tombstone punch-hole 与边界缺口 | `closed` | — （N-R1 转阶段 1 跟进） |
| T-51 | T-38-2 RED fixture 缺陷 | `closed` | `88124bc` |
| T-52 | 墓碑链环防护在 FilePageStore 上形同虚设（准 hang / 资源炸弹） | `closed` | `24bb874`（遗留 O-1/O-2 转阶段 4） |
| T-49 | 设计文档 §2「旧代码读 v3 库 = 干净拒绝打开」与源码不符：实际静默清空并覆盖数据 | `closed` | `1c6ce1d`（T-53 一并关闭；残余 torn 方向转 T-53 issue） |
| T-50 | meta 三值判定的「第三值」是 `null`，与 fresh DB 不可区分 | `closed` | `1c6ce1d`（T-53 一并关闭） |
| N-1 | put composite entry 溢出 panic | `closed` | `ba85d2c`、`6d1d318` |
| T-54 | 测试效率：单个 180s step 独占 wall time + 49 个测试从不执行 | `closed` | `b43dcd6`、`d56d49d`、`79e92bb`、`8f3671d`（P1 wall 182.6s→55s；P3b `build.zig` 924→149 行、重复编译 77→0） |

**引用归档文件时注意**：路径已变为 `issues/archived/<原名>.md`。
T-38 / T-49 / T-50 / T-51 / T-52 / T-54 等文件中出现的 `issues/T-5x-….md` 式引用是**归档前写的**，
未回改，读作 `archived/` 下同名文件。

---

## 四、流程约定

### 4.1 契约里的验收基线数字必须实测后填写

**已复发两次**，记在这里防止第三次：

- **N-1**：任务契约 Acceptance 写「基线 437/437」，实测基线不是这个数（记为笔误）。
- **T-52**：`task.md` 写「全量 452/452（0 skip）」，实测为 **453/454（1 skip）**。
  差值来源：本任务把 `test-tombguard` 的 2 个用例挂进了主 `test` step（+2），
  而 `cube_check_test.zig` 有 1 个**既有的环境相关 skip**（需要 `zig-out/bin/cube_check` 二进制）。

**根因**：写契约时凭记忆/凭旧数据填基线，而不是先跑一遍拿真实数字。

**约定**：
- 契约里的基线数字，必须在**写契约的时刻实测**（跑一次全量，抄下真实输出）。
- 验收门写成「**exit 0 且无失败**」，而**不是**「数字等于 N」——数字会因用例增减而漂移，
  硬编码数字等于给未来埋一个必然失败的断言。
- 若基线确有 skip，**如实记录 skip 的条数与原因**，不要写成「0 skip」。

### 4.2 全量测试的数字会因「在哪个检出目录跑」而不同

同一个 commit，在 **main 检出目录** 与 **worker worktree** 里跑，数字可能不一样：

- `cube_check_test.zig` 需要 `zig-out/bin/cube_check` 二进制；worktree 里通常没有，于是**跳过 1 条**。
- 所以会出现「main 上 452/452（0 skip）」而「worktree 里 451/452（1 skip）」**两者都对**的情况。

**约定**：引用全量数字时，**注明是在哪跑的**（main 检出目录 / worktree）。
T-38 与 T-51 中都出现过 451/452 vs 452/452 的表述，它们并不矛盾，但需要这层解释才读得通。

### 4.3 编号规则

编号单调递增，扫描本目录取最大值 +1。当前最大值 = **T-54**；另有独立编号 **N-1**（另一来源系列）。
归档不移除编号，避免历史引用失效。

**注**：任务号与 issue 号可共用（如 T-52、T-53 都是「任务 `T-53` / issue `T-53`」同号），
这是既有约定（一个任务产出的问题沿用任务号）。

### 4.4 状态流转

```
open ──指派──> fixing ──验收通过──> closed ──归档──> git mv 进 archived/
                  │
                  └──部分完成──> partial ──剩余另立──> 新 issue（open/proposed）

proposed：尚未决定要做（待立项 / 待评估 / 已论证不可闭合）
```

**归档动作**（`closed` 的收尾步骤，别漏）：

1. `git mv issues/<原名>.md issues/archived/` —— **文件名不变**；
2. 在本 README「二、活跃」表里删掉该行，「三、归档」表里加一行；
3. 不改文件内的 `**状态**` 字段（`closed` 保持原样）。

不做第 1 步 → 根目录会堆积已关闭的 issue，「还剩哪些没修」一眼看不出来。

---

## 五、关联材料

- 评审产物（`docs/reviews/`、根 `review.md` / `test-report.md`）已于 2026-09-18 移除；
  归档 issue 中指向它们的引用不再可解析（同「归档前写的，未回改」约定）
- `issues/archived/T-52-…md` — 墓碑链环防护（visited-set 修法，已归档）
- `issues/archived/T-49-…md`、`issues/archived/T-50-…md` — 开库路径 invalid-meta 问题（T-53 一并关闭）
- `docs/lecture_t52_commit_chain.html` — T-52 的五个 commit 讲义（小白向）

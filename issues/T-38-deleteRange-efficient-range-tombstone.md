# Issue T-38 — deleteRange 高效化：全量物化 + 每 key tombstone 的 O(range) 内存与写放大

- **状态**: fixing（路线 C 先探路已定；探路完成，方案 B 实现中，方案 A 待返工闭环）
- **优先级**: **high**（可用性缺口 + 内存安全边界；4/4 worker 全部独立提出，共识度最高）
- **梯队**: 可用性/性能（兼正确性观感——文档承诺与实际行为差距）
- **来源**: 演进点征集（roadmap-evo）wf-pi-1-E1、wf-pi-2-E2、wf-pi-3-E3、wf-pi-4-E2
- **基线**: HEAD `4d7b1c8`（行号均基于此）
- **对应旧清单**: U-1（Range tombstone / 高效 deleteRange）——当前 HEAD 复核仍完全成立

---

## 摘要

`Db.deleteRange` 现实现 = flush → `select` 全量迭代 → **把范围内每个 key dupe 进堆上
ArrayList** → 构造等长 tombstone Entry 数组 → 整批 `putBatch`。删除一个 N key 的
范围 = 提交前 RAM 同时持有 N 个 key 拷贝 + 写入 N 条 tombstone（每条独立占叶空间，
直到被后续写入压实）。

- **内存峰值 O(range)**：删 5000 万 key 范围 = 5000 万 key 副本 + 5000 万 Entry 同时
  在内存，事实上会 OOM。
- **写放大 O(range) + O(N²)**：逐 key tombstone 把删除成本放大为写入成本；对同一范围
  反复 deleteRange 时 O(范围) 读 + O(在场 key) 写每次全款重付。
- **墓碑永不清理**（见 E-3 关联）：每个被删 key 永久占 ~key.len+10 字节，占满即叶裂变，
  又反哺 T-37 的深度增长。

**可用性缺口**：文档把 deleteRange 描述为常规 API（`docs/usage.md:233` 明示"内部基于
select 迭代器 + tombstone 批量提交实现"），但**没有披露 O(range) 内存峰值**——大范围
删除会 OOM，这属于"文档无法自圆其说"的行为差距。

## 现状 / 机制佐证

- `src/db.zig:222-250`：`deleteRange` = flush + select 全扫 + `allocator.dupe` keys
  （`:242`）+ 逐 key tombstone 数组 + 整批 putBatch（`:248`）
- `src/db.zig:231-243`：keys ArrayList 无界 dupe + entries 同长分配，两份 O(range) 内存
- `src/db.zig:245-249`：整批 tombstone 走 putBatch → COW 重写受影响叶页链，范围越大写的页越多
- `src/btree.zig:257` `encodeLeafPayload` 写 tombstone 标志，无任何丢弃分支
- `src/btree.zig:817-1008` `insertIntoLeaf` 合并重写时 tombstone 原样保留
- `src/btree.zig` 叶/分支编码目前只有 entry 一种叶子形态，没有区间墓碑节点类型
- `docs/usage.md:233`（deleteRange 语义）/ `:316`（compact 只切 meta，不重写数据）

## 建议演进方向

- **Range tombstone（区间墓碑）**：删除时在树上挂 `[min,max)` 墓碑节点，读取/迭代时做
  遮蔽判断，压缩/合并时再物化清除，把大范围删除从 O(range) 降到 O(log n + 墓碑数)；
- 格式扩展可走 `f2.MetaPage.version` 位平滑升级（wf-pi-3 指出）；
- 墓碑 GC 需配合真·compact（见 T-38 关联的 U-5）才有完整收敛出口。

## 可测验收判据（RED→GREEN）

- (a) 1000 万 key 库上 `deleteRange(null,null)` 在有界内存（如 ≤64MB）内完成且耗时不随
  range 线性增长（用分配计数断言峰值内存 ≤ O(batch)）；
- (b) 删除后 `select` 迭代不返回已删 key、`entryCount` 精确；范围删除后
  `entryCount`/select 结果/点读三口径一致；
- (c) 墓碑与并发 staging/flush 交错（复用 `tests/staging_concurrent_test.zig` 场景）
  语义不变；重启后墓碑遮蔽语义保持；
- (d) 同范围反复 deleteRange K 次后，页数/tombstone 行数不随 K 线性增长。

## 关联

- 与 T-37 交互：deleteRange 的 tombstone 批次是推动树高增长的小批量提交源之一；
  墓碑积压放大 merged 集合尺寸，间接加速加深。
- 墓碑 GC 依赖真·compact（U-5，wf-pi-4-E3）才完整；可并立项或在 T-38 内给出收敛出口。

## 状态跟踪

- [x] 现状核验（4 worker 独立确认 U-1 在当前 HEAD 成立）
- [x] 路线决策：**C 先探路**（用户选定），探路结论 = 方案 A 有条件可行 + 推荐 A+B 分期
- [x] 确定性 RED 测试（大范围删除内存断言：T-38-B 的 `deleterange_mem_budget_test.zig`）
- [x] 探路（路线 C）+ 独立评审 + 返工闭环（T-38-P / T-38-P-R）
- [x] 阶段 0（方案 B 流式分块）：T-38-B 合入 `8f9c8fb`，验收 (a) 内存项达成
- [x] 阶段 1（格式层）：T-38-1 合入 `baa44bd`（三方多签：acceptance 绿 + review APPROVE + test PASS）
- [x] 阶段 2（读路径）：T-38-2 合入 `88124bc`（三方多签：验收① 452/452 + 验收② 15/15 + review APPROVE）
- [ ] 阶段 3/4 根因落地（写路径 / GC）
- [ ] 回归测试 + 评审（阶段 2 起需并发 staging 交错测试）
- [ ] 验收门稳定后关闭

---

## 执行记录（conductor，2026-09-15）

### 路线 C — 探路（已完成）

- **T-38-P**（cube_db-pi-1，commit `5764fbb`，返工后 rebase 为 `07b4467`）：设计文档
  `docs/design/T-38-range-tombstone-probe.md` + 自包含探针
  `spike/rangetomb_probe.zig`（5 tests）+ 报告
  `docs/design/T-38-probe-report.md`。零 `src/` 改动，5/5 绿，全量 436/437+1skip。
- **探路结论**：方案 A（区间墓碑，`PAGE_TYPE_RANGE_TOMBSTONE=5` + meta v2→v3
  双锚点）**有条件可行**；报告推荐 **A+B 分期**（B 立即止血、A 根治）。
- **独立评审**（cube_db-pi-2）：**REQUEST_CHANGES**，发现两处 blocking 设计缺口
  （打洞右段数据复活、近-MAX 边界不可表示），**不否定方案 A 可行性**。
  → 已立 **T-48**（`issues/T-48-range-tombstone-punch-hole-and-boundary-gaps.md`），
  返工任务 **T-38-P-R** 已派给 pi-2 → 交付 `c4af657`（rebase 后 `21d6c8b`），
  复审 **APPROVE**，已合入 main；T-48 关闭。

### 分期拆解（探路报告 §4，评审 N3 调整后）

| 阶段 | 内容 | 任务 | 依赖 |
|---|---|---|---|
| 0 | **方案 B**：流式分块 deleteRange（消 OOM，零格式风险） | **T-38-B** ✅ 已合入 | 无 |
| 1 | 格式层：墓碑页 codec + meta v3（含 F2 边界编码 + **N-R1 typed 拒绝** + bit30 spill 预留位） | **T-38-1** ✅ 已合入 `baa44bd` | T-38-P-R 闭环 ✓ |
| 2 | 读路径：遮蔽判定（tomb_head=0 时休眠） | **T-38-2** ✅ 已合入 `88124bc` | T-51 关闭 ✓ |
| 3 | 写路径：新 deleteRange 流 + 打洞语义（含 F1 修正）+ entryCount 流式修正 | 未派 | 阶段 2 ✓（前置 T-49/T-50/T-52） |
| 4 | GC：水位收割（空区间丢弃）+ crash 矩阵扩展；物化清除挂 U-5 | 未派 | 阶段 3 |

**阶段 3 前置条件（阶段 1 评审 T-49/T-50 + 阶段 2 评审 NB-1）**：
① **开库路径必须区分「invalid meta」与「fresh DB」**（`issues/T-50-…`）——
   当前 `readMetaPageSingle` 对 magic 坏 / v4 统一返回 `null`，与空库同形；
   凡新增磁盘版本号前必须先修此缺口，否则重演 T-49 式静默空库 + 数据覆盖；
② **version 切换策略**落地（「是否曾写墓碑」决定 v2/v3），并同步更正
   T-49 记录的部署纪律（升级后不得回滚二进制 = 否则静默数据破坏）。
③ **T-52（NB-1）环防护加固**（`issues/T-52-…`）：`walkTombChain` 上界改用已访问页号
   set（环重访即 `error.Truncated`，O(链) 内存）或收紧到 `min(mapsize, last_page+1)`，
   消除 FilePageStore 上的准 hang / ~12 GiB 资源炸弹。阶段 3 引入真实写路径后会自然
   产生环链的可触发面，故列为前置。

**阶段 1 落地前必须补的两项（T-38-P-R 评审 N-R1，详见 T-48）**：
① 设计文档增补写路径不变量「空区间/空 plain 边界墓碑不得进入编码器」；
② 编码器对 empty-plain `max` 做 typed 拒绝，把静默折叠（→ 全区间墓碑，数据丢失方向）
变成显式错误。

### 验收 (a) 的判据已落地

`tests/txn_writer_db/deleterange_mem_budget_test.zig`（commit `169aa78`，挂 `test-db`）：
锁死「deleteRange 内部净分配不随 range 线性增长」——同一场景 N vs 4N 的净字节
峰值比值 `< 2.0`。**基线实测比值 3.81 → RED**，由 T-38-B 实现到绿。

判据口径钉在「deleteRange 自身申请了什么」，而非全库聚合内存/RSS——后者会在
方案 B 落地后误红（内存确实降了，聚合口径却看不到）。

### 阶段 0（T-38-B）验收记录 — 2026-09-15

- **实现**：cube_db-pi-3，commit `fb2d18d`（rebase 后 `8f9c8fb`），
  `src/db.zig` 单文件 +28/−13。`deleteRange` 改为 **CHUNK=256 条流式分块**：
  栈上定长 `keys`/`entries` 数组，边迭代边 `putBatch` 并释放本块 dupes。
- **判据两态（conductor 独立复跑）**：
  - 基线 `169aa78`：比值 **3.81**（N=2000→879234B, 4N=8000→3353196B）→ **RED** ✓
  - `8f9c8fb`：比值 **1.05**（N=2000→115640B, 4N=8000→121720B）→ **GREEN** ✓
  - 幂等重删峰值 0B。
- **独立评审**（cube_db-pi-2，评审者 ≠ 实现者）：**APPROVE**
  （`.agents/tasks/T-38-B/review.md`）。评审自写 6 组探针独立设计：
  - **跨块边界**（RED 测试盲区）7 个形状：N = 255/256/257/511/512/513/1152，
    `entryCount` 减少量**恰等于** N，无双重 tombstone / count_delta 重复递减；
  - 语义矩阵：倒置/空区间 no-op **且不 flush**、staged in-range put 被删、
    半开边界、幂等、区间外哨兵、近-MAX key（1 entry/leaf 跨块）、8 波交错；
  - 内存判据**未被规避**：栈上定长块 + 窗口内 dupe→putBatch→free 循环，
    无全局缓冲、无延迟释放；
  - **所有权声称核实**：`putBatch → applyBatch → btree.insertBatch` 确实把 key
    memcpy 进叶页 payload，故分块内 free 安全（非 UAF）。依据既有约定
    「slices only need to be valid for the duration of the putBatch call」。
  - 迭代器 pin 快照论证经读码 + 实测核实（`select` register-then-capture，
    `defer it.deinit()` 覆盖整个分块循环）。
  - 越界：`git diff 169aa78 fb2d18d -- tests/` **空**（RED 测试未被改）。
- **整合**：conductor rebase 到 main（`src/` 经 diff 校验与评审对象**字节一致**）
  → ff-merge `8f9c8fb`；`test-db` 38/38，全量 **437/437**。
- **评审附带发现**：**N-1**（`put` 组合条目溢出 panic，pre-existing，T-43 家族
  残留）→ 已立 `issues/N-1-put-composite-entry-overflow-panic.md`，
  conductor 已独立复现确认；**N-2**（CHUNK=256 近-MAX key 时 ≈1MB 瞬时内存）
  为观察项，不阻塞。

### 阶段 1（T-38-1 格式层）验收记录 — 2026-09-17

- **交付**：RED `4d5c95f`（cube_db-pi-3）→ GREEN `baa44bd`（cube_db-pi-1），
  已 ff-merge 入 main。变更：`src/format.zig` +230（`PAGE_TYPE_RANGE_TOMBSTONE=5`
  页 codec + `MetaPage.tomb_head` + `META_PAGE_PAYLOAD_SIZE` 58→62 + 三值判定
  + bit30 spill 预留位）、设计文档 ±17、`build.zig` +15、单测 +541（10 tests）。
- **TDD 证据**：RED = 编译失败 11 errors（`PAGE_TYPE_RANGE_TOMBSTONE`/`tomb_head`
  未实现）；GREEN 后 `test-format` 62/62。判定者 pi-3 复核实测：
  `git diff 4d5c95f baa44bd -- tests/` **空**（测试零改动）；
  临时 revert `src/format.zig` 回基线 → 测试**回到 11 errors 失败态**（约束力实证，
  非恒真）。
- **独立评审**（cube_db-pi-2，评审者 ≠ 实现者）：**APPROVE**，
  Blocking 0 / Non-blocking 6。评审自写 scratch R1–R8（8/8）独立实证，含
  **RED 未覆盖的真 u32 回绕路径**（`min_off=0xFFFF_FFFF` → typed `error.Truncated`
  无 panic）、nkeys=65535 上界、bit30 decode 拒绝、v2 手工规范页**整页逐字节相等**、
  脏缓冲三模式 encode 确定性（F-3 实锤）。
- **conductor 独立验收**：main 上 `zig build test` = **452/452**（0 skip，exit 0）；
  `test-format` 62/62；`test-rangetomb-probe` 6/6（探针"侥幸自洽"预判实证为真绿）。
  （worktree 内跑显示 451/452+1skip 系 `zig-out/bin/cube_check` 不存在导致
  `cube_check_test.zig` 条件跳过，环境差异非回归。）
- **预审发现的规格缺陷**（pi-2 `spec-precheck.md`）：
  - **F-1（high）**：设计 §2 称「旧代码读 v3 库 = 干净拒绝」，实测为 **Db.open 静默
    按空库打开 + 后续写入覆盖 v3 数据页**（数据破坏面）→ 已立
    `issues/T-49-v3-db-silent-empty-open-doc-error.md`，设计文档已更正。
  - **F-4**：spill 预留位落点设计未指定 → pi-1 定案 bit30（`min_len`/`max_len`）
    + 回写设计 §1.2。
  - 评审另发现 **N-1**：三值判定的「第三值」在 API 层是 `null`（与 fresh DB 不可
    区分）→ 已立 `issues/T-50-meta-third-value-null-vs-fresh-db.md`，列为阶段 3 前置。
- **遗留（阶段 2/3/4）**：读/写路径接入、version 切换策略、spill 实装、GC。

### 阶段 2（T-38-2 读路径：墓碑遮蔽判定）验收记录 — 2026-09-17

- **交付**：RED `2b05ca8`（cube_db-pi-3，12 测试）→ RED 追加缺口 `f2751bc`
  （+g6/g9/g10，15 测试）→ GREEN `b60d0fd`（cube_db-pi-1）→ 评审 `593fe11`
  （cube_db-pi-2）→ fixture 修复 `88124bc`（cube_db-pi-3，T-51），已 ff-merge 入 main。
- **变更**：`src/db.zig` +201（Db `tomb_head` 字段于 open 一次性捕获；`captureSnapshot`
  唯一捕获 seam；`isShadowed` 点查 + `tomb_head==0` 唯一短路；`ShadowCtx` 供 select
  物化；`tombListCovers`/`boundCmpKey` 线性扫 + append_zero 有效字节比较；
  `walkTombChain` 环防护；五入口 `Db.get/getInto/select` + `ReadTxn.get/getInto/select`
  全接入，ReadTxn 用 `snapshot_tomb_head`）、`src/btree.zig` +21（**仅 Iterator**：
  3 个默认 null 钩子 + next() 在 overflow 组装前插钩子 + deinit 顺序
  `skip_deinit→pin_deinit`）、`build.zig` -1（删 RED 引入的重复 dependOn）。
  所有权合规：`format.zig`/`writer.zig`/`file_page_store.zig` 零触碰。
- **TDD 证据**：RED 12 测试 11 红 1 绿（s8 为 `tomb_head==0` 短路的刻意的守门绿）；
  追加 g6/g9/g10 后 14 红 1 绿。GREEN 后验收①**无墓碑零行为变化**（本阶段核心门）；
  判定者 pi-2 复核实测 `git diff f2751bc b60d0fd -- tests/` **空**（GREEN 零改测试）。
- **conductor 独立验收**（合并后 main `88124bc`）：
  - 验收① 回归门：`zig build test` = **452/452**（0 skip，exit 0）——与基线 `f5b7db6`
    逐数一致，零回归。
  - 验收② 手工构造墓碑页遮蔽：`zig build test-rangetomb-read` = **15/15**（exit 0）。
  - 格式层守卫：`test-format` 62/62。
  - （worktree 内跑显示 451/452+1skip 系 `cube_check_test.zig` 环境条件跳过，非回归。）
- **独立评审**（cube_db-pi-2，评审者 ≠ 实现者）：对 `b60d0fd` **APPROVE**，
  Blocking 0 / Non-blocking 3。评审自写 scratch P1–P6 独立推导期望值全绿：
  P1 遮蔽真值表（4 墓碑形态 × 16 key 含 `""`/`"\x00"`/`\xff\xff` 邻界）、
  P2 select⟺get 一致性（3 页乱序链）、P3 环防护（自指环 + 2 页环 → typed
  `error.Truncated` 无 hang）、P4 pin 不泄漏（含物化失败 errdefer 路径 + ReadTxn
  存续期 reader_count）、P5 `tomb_head==0` **结构性**短路证明（钩子根本没挂）、
  P6 FPS mapsize 算术。评审并独立复核确认 T-51 判定（实现正确、fixture 错）。
- **发现**：
  - **T-51（medium）**：RED 3 处 fixture 缺陷（s2 单墓碑期望集矛盾 s4、s7 断言未存储
    key、g9 把 max 不含端点误当含端点），使验收②一度 12/15。**非实现缺陷**；由测试
    作者 pi-3 修 fixture（断言语义不变），修后 15/15 → 已立并关闭
    `issues/T-51-t38-2-red-fixture-defects.md`。
  - **NB-1（medium，新）**：`walkTombChain` 环防护上界 = `store.mapsize()`，在
    `FilePageStore` 上 = 2^28 页 → CRC 合法环链要 ~2.68 亿次 decode + ~12 GiB 峰值
    内存才触发 `error.Truncated`，实为准 hang/资源炸弹（MemPageStore 上防护有效）。
    仅损坏库触发（trust boundary），阶段 2 测试全走 MemPageStore 故不阻塞 →
    已立 `issues/T-52-tomb-chain-ring-guard-fps-ineffective.md`，列为阶段 3 前置。
- **本阶段已知限制（不修，如实报告）**：任何 commit 会把 meta 重写回 v2/`tomb_head=0`
  → reopen 丢墓碑。这是 H-2 声明的语义分叉，根治在**阶段 3**（写路径 + T-50）。
- **遗留（阶段 3/4）**：写路径（新 deleteRange 流 + 打洞 + version 切换 + entryCount
  流式修正）、GC（水位收割 + crash 矩阵扩展）。阶段 3 前置：T-49、T-50、**T-52**。

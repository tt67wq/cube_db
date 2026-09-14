# T-40 review — 批量分块 payload-size-aware（f608c10 + 924c733 + 3e0831a + e94d49f）

- **Reviewer**: cube_db-pi-1（T-40-A RED 测试原作者 + tester；实现者 cube_db-pi-2 —— 独立性成立）
- **Reviewed SHA**: `f608c10`（实现）+ `924c733`（RED 测试修复）+ `3e0831a`（issue 更新）
  + **`e94d49f`（GAP A/B 修复，针对 review 34e5afb 的 changes-requested）**，
  基线 `e0e6c9e`；分支 cube_db-pi-2-rebuilt
- **契约**: `/.agents/tasks/T-40/task-B`（4 处分块点字节预算）+ issue
  `issues/T-40-batch-chunking-count-vs-payload-size.md`（批量分块按计数不看字节 → panic）
- **Verdict**: **approve**（初判 changes-requested（34e5afb）的 Finding 1 已由 e94d49f
  完全闭合：两处早返回字节预算正中靶心、两条回归真实先红后绿、issue 附注修正属实、
  GAP C 如实转 T-43 立项。见 §5 复核，初判全文保留于下供溯源。）

---

## 0. 证据基础（详见 test-report.md，全部 reviewer 独立复跑/探针）

- RED（e0e6c9e）2 crash、GREEN（924c733）2/2、全量 422/423 + 1 skip 无回归 —— 属实。
- 独立探针 P1（orphan-promote + 深树二次批量，pi-2 未测的分支）—— **PASS**。
- 独立探针 PA/PC/PD —— **3 个仍可触发的崩溃**（GAP A/B/C，见 §3）。

## 1. f608c10 实现审计 — 4 处分块点本身正确

### 1.1 字节记账与编码器精确对齐（逐项核算）

- `leafChunkLen`（`:346`）：`n=3 + Σ(10+klen+value_sz)`，`value_sz` 用
  `value.len > MAX_INLINE_VALUE → 4` —— 与 `leafPayloadSize`（`:237`）逐字节一致。✓
- `branchChunkLen`（`:366`）：`n = 3+4（头+首 child 槽）+ Σ(4+klen)` —— 与
  `branchPayloadSize`（`:327`：`3 + Σ(4+klen) + 4×children`）一致。✓
- 单 entry 地板：`3 + 10 + MAX_KEY_SIZE(4051) + 4 = 4068 = NODE_PAYLOAD_CAP` 恰好 ——
  首条目免检（`len > 0` 才判停）保证贪婪永不卡死。✓ 2-child chunk 地板：
  `3+8+4+4051 = 4066 ≤ 4068` ✓（doc comment 声明与数学一致）。
- `max` 参数保留 `LEAF_MAX_ENTRIES`/`BRANCH_MAX_CHILDREN` 计数上限 —— 字节预算只会
  切更小，不会放大既有计数界。✓

### 1.2 4 处分块点逐一

1. `insertBatchSplitLeaves :1496` — `leafChunkLen(entries[pos..], 32)` ✓
2. `insertBatchIntoLeaf :1781` — 同上（merged）✓
3. `buildBranchLevels :1535/:1554` — 早返回加 `branchPayloadSize(...) <= CAP`，
   层循环条件 `> 64 OR bytes > CAP`（两个维度都触发分层）✓
4. `insertBatchIntoBranch :1980`（非溢出返回加字节校验）+ `:2009`（溢出 splice chunk
   循环用 `branchChunkLen`）✓

### 1.3 T-36 1-child 规则 + orphan promote

- 借道保留：`rem - chunk_len == 1 且 chunk > 2` → 借 1（`:1573`/`:2015`）✓
- **字节地板新路径**（chunk==2 且 rem==3）：把尾部 orphan 子页**本身**提升到上一层/
  出向 splice（`:1576-1590`/`:2017-2032`）。正确性核对：
  - orphan 是已编码完成的合法页（leaf 或既有 child 页），提升 = 父层直接持有，指针
    遍历不依赖均匀深度 ✓
  - 分隔符追加 `current_keys[i+chunk_len-1]`（= chunk 末 child 与 orphan 的边界键）
    在 promote 前完成，splice/层列表保持有序 ✓
  - 不可达 1-child chunk 证明：进入层循环时 children ≥ 2；归纳每轮迭代后 rem ∈ {0,2}
    （borrow 路径尾部留 2、promote 路径整段消费），故 `branchChunkLen` 的 rem==1 返回值
    分支不可达 ✓
  - **P1 探针实证**：131 个 4000B key（奇数叶子 → 末块 2+1 orphan promote）+ 深树二次
    批量，entryCount/采样点查/全序扫描全过 ✓
- `branchChunkLen` 首 child 免检 + rem≥2 时数学上 ≥2（第 2 个 child 超 CAP 需
  klen > 4057 > MAX_KEY_SIZE，不可能）✓

### 1.4 性能

- 两个 helper 为 chunk 前缀扫描 O(chunk_len)，总量 O(n)/level，无渐近变化；常数比
  `@min` 略增，全套件运行时长与基线相当（含 FPS 微基准输出正常）。层循环每层重算一次
  `branchPayloadSize` O(level) —— 每层一次，可忽略。✓

## 2. 924c733（改我的 RED 测试）— 无放水（详细逐条见 test-report.md §2）

三处 authoring bug **全部属实**（本人自证：prev 泄漏 119 块 / 'a'-'z' filler 错配使
test 2 对任何正确实现不可满足 / 采样区间错位）。修复最小、诚实：filler 参数化、后缀
对齐、dupe 前 free。**全部断言保留，强度不降反升**（恢复可满足性）。未发现任何借改
测试降低覆盖的行为。✓

## 3. Findings

### Finding 1（blocker）：GAP A/B —— 批量路径两个「按 count 切」单叶早返回漏改

issue 总结句：「叶子/分支分块以**条目数**为界……而不看 payload 的**字节尺寸**」。
f608c10 只转换了 4 处 chunk **循环**，但同一批量流程里还有两个同族按-count 决策：

- **GAP A** `src/btree.zig:1458`（`insertBatchFresh`）：`entries.len <= LEAF_MAX_ENTRIES`
  → 单叶编码，无字节校验。**实测**（探针 PA）：空库 `putBatch` 3 个 4000B key →
  `:1463` panic `index 12033, len 4096`。
- **GAP B** `src/btree.zig:1753`（`insertBatchIntoLeaf`）：`merged_entries.len <=
  LEAF_MAX_ENTRIES` → 单叶重编码，无字节校验。**实测**（探针 PC）：3 小 key 叶上
  `putBatch` 2 个 4000B key → `:1757` panic `index 8062`。**该函数本次已被 f608c10
  修改**（`:1781` 的 chunk 循环），漏改自己函数 24 行之上的同族早返回。

后果：**修复后，「一批 2..32 个近 MAX_KEY_SIZE 的 key」仍崩库** —— 比 RED 场景
（120 key）更容易触发。issue 的核心主张（批量大 key 不崩）在 HEAD 不成立，
`3e0831a` 的 issue 状态「修复 → 待评审关闭」为时过早（其附注只声明了单 key 路径
GAP C，未提及 A/B）。

**要求（changes-requested 的全部内容）**：
1. `:1458` 与 `:1753` 两处早返回加字节预算（`leafPayloadSize(...) <= NODE_PAYLOAD_CAP`，
   超限走 split/splice 路径 —— 与 4 处 chunk 点同一模式，预计各 1-2 行）；
2. 补两条 RED→GREEN 回归（可直接用 test-report.md §3 的 PA/PC 场景：空库 3 大 key
   putBatch；小叶上 2 大 key putBatch）；
3. 修正 `3e0831a` 的 issue 附注：把 GAP A/B 与 GAP C 分开记录（A/B 属本 issue 修复
   范围，C 转立项）。

### Finding 2（non-blocking，转立项）：GAP C —— 单 key 路径同族溢出

`insertIntoLeafSplit :1178`（mid-split 半叶可超 CAP，探针 PD 实测 panic
`index 4229`）与 `insertBranch :1260`（≤64 仅计数）。属 T-26 族遗留、契约外；
`3e0831a` 已自行声明待立项 —— 认可该归类，随 GAP A/B 修复时一并立 issue 即可。

### Finding 3（nit）：`NODE_PAYLOAD_CAP` 与 T-26 precheck 的 `payload_cap` 重复定义

`:1017` 后 T-26 precheck 内联算 `f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4`，与
`NODE_PAYLOAD_CAP` 相同 —— 建议后续统一引用常量（不 block）。

## 4. 验收核对单

- [x] 4 处契约分块点全部字节化且正确（§1.1-1.2）
- [x] T-36 规则保留，orphan-promote 新路径正确（§1.3 + P1 实证）
- [x] `zig build test-batchpayload` 2/2 绿（独立复跑）
- [x] `zig build test` 422/423, 1 skip，无回归（独立复跑）
- [x] 924c733 无放水、断言语义保留（test-report §2）
- [x] **issue 核心主张闭合：批量大 key 不崩 —— e94d49f 修复 GAP A/B，PA/PC 回归绿（复核见 §5）**
- [x] 单 key 路径缺口已如实声明转立项（3e0831a）

**初判 Verdict: changes-requested** — Finding 1（GAP A/B，两处早返回 + 两条回归 + issue
附注修正）完成后即可转 approve；其余不 block。

---

## 5. 复核 e94d49f（changes-requested → **approve**）

针对 34e5afb Finding 1 的三项要求逐项复核（全部 reviewer 独立验证。方法：独立 worktree
checkout 34e5afb（fix 前 src）叠加 e94d49f 的测试文件验证先红；checkout e94d49f 验证后绿）：

### 5.1 要求 1：两处早返回字节预算 — 正中靶心 ✓

- `insertBatchFresh :1458`：`entries.len <= LEAF_MAX_ENTRIES and
  leafPayloadSize(entries) <= NODE_PAYLOAD_CAP` —— 与 4 处 chunk 点同一模式。
  超限自然落入 `insertBatchSplitLeaves`（f608c10 已字节分块；单 entry 数学上必然放下，
  贪婪永不卡死）✓
- `insertBatchIntoLeaf :1754`：`merged_entries.len <= LEAF_MAX_ENTRIES and
  leafPayloadSize(merged_entries) <= NODE_PAYLOAD_CAP` —— 同款。超限落入 splice
  chunk 路径（已字节分块；超过 CAP 的 merged 必切 ≥ 2 叶 → splice ≥ 1 separator 合法；
  根叶场景上行 buildBranchLevels / 非根场景上行 insertBatchIntoBranch，两路均字节感知）✓
- src diff 共 2 hunks / +6 行，最小修复，无 scope creep ✓

### 5.2 要求 2：两条回归真实先红后绿 ✓（reviewer 独立复跑）

- **红**（34e5afb src + e94d49f 测试文件）：test 3（空库 3 大 key）crash
  `insertBatchFresh :1463` panic `index 12033, len 4096`；test 4（3 小 key 叶 +
  2 大 key）crash `insertBatchIntoLeaf :1757` panic `index 8089, len 4096`；
  旧 test 1/2 不受影响（2 pass, 2 crash）—— 与 commit message 声明、与本人探针
  PA/PC 完全一致 ✓
- **绿**（e94d49f）：`zig build test-batchpayload` **4/4**；`zig build test`
  **424/425 passed, 1 skipped**（= 基线 422/423 + 2 新测试）**无回归** ✓
- 回归场景与探针 PA/PC 等价（test 4 的小叶改用 putBatch 构建——走同一
  insertBatchFresh 单叶路径，等价成立），verify 断言完整（计数/采样/全序扫描/
  小 key 存活），无放水 ✓

### 5.3 要求 3：issue 附注修正 + T-43 立项 ✓

- T-40 issue：GAP A/B 归入本 issue 并标注闭合（行号与 panic 索引与实测一致）；
  回归计数更新 4/4、424/425 ✓
- `issues/T-43-single-insert-payload-overflow.md`：GAP C（`insertIntoLeafSplit`
  mid-split + `insertBranch` ≤64 仅计数）如实立项，含 PD 探针实证（panic 4229）、
  修复方向（复用 leafChunkLen/NODE_PAYLOAD_CAP + 同 T-40 模式）合理 ✓
  - nit（不 block）：T-43 触发条件写「需既有叶/枝已含近-MAX_KEY_SIZE key」——实际
    PD 场景只需「近满叶 + 单条大 key 插入」（split 后右半叶 16 小 + 1 大即超限），
    触发面比描述略宽；优先级结论不变。

### 5.4 复核结论

Finding 1 三项要求全部满足，无新发现。

**最终 Verdict: approve** — T-40 关闭；GAP C 隔离在 T-43（open，待 conductor 立项）。

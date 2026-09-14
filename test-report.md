# T-40-D test report — 先红后绿独立复跑 + 924c733 放水核查 + 独立探针 + e94d49f 复测（approve）

- **Tested commit**: `f608c10`（实现）+ `924c733`（测试修复）+ `3e0831a`（issue 更新）+ `e94d49f`（GAP A/B 修复，复测见 §6），
  基线 `e0e6c9e`；分支 cube_db-pi-2-rebuilt
- **Tester/Reviewer**: cube_db-pi-1（T-40-A RED 测试原作者；实现者 cube_db-pi-2 —— 独立性成立）
- **Env**: zig 0.16.0（asdf），macOS，独立 worktree checkout 逐 SHA 复跑

## 1. 先红后绿独立复跑 — 均属实

| 项 | 结果 | 结论 |
|---|---|---|
| `e0e6c9e`（fix 前，测试原样）`zig build test-batchpayload` | 0/2 pass，两测试 crash：fresh 路径 `insertBatchSplitLeaves` `:1449` panic `index 128323, len 4096`；overflow 路径 `insertBatchIntoLeaf` `:1711` panic `index 96419` | **RED 属实**（与 T-40-A 验收时完全一致） |
| `924c733`（HEAD src）`zig build test-batchpayload` | 2/2 pass | **GREEN 属实** |
| `924c733` `zig build test` | 34/34 steps；422/423 passed, 1 skipped（= T-41 后基线 420/421 + 2 新测试） | **无回归** |

## 2. 924c733「修复 RED 测试三处 authoring bug」核查 — 属实，无放水

逐条核对 `git diff e0e6c9e 924c733`（本人为 RED 测试原作者，逐行自证）：

1. **verify 扫描 prev 泄漏**：原测试 `prev = try alloc.dupe(...)` 每轮覆盖旧指针不释放 →
   120-key 扫描漏 119 块。**确为本人 authoring bug**。修复仅在 dupe 前补
   `if (prev) |p| alloc.free(p);`，dupe/顺序断言/计数不变。断言强度不变。✓
2. **'a' vs 'z' filler**：test 2 插入 'z' filler 大 key，但 verify 采样用固定 'a' filler 的
   `bigKey` → 查询从未插入的 key，**任何正确实现都不可能通过**。确为本人 authoring bug。
   修复加 `filler` 参数（test 1 'a' 行为不变，test 2 'z' 对齐实际插入）。修复后采样指向
   真实插入的 key —— 断言语义**恢复为可满足的完整契约**，无弱化。✓
3. **采样区间错位**：test 2 后缀 0..89 vs verify 区间 [40,130)。确为本人 authoring bug。
   修复改后缀 `small_n + i` → 插入集合 z40..z129 与采样区间精确一致，key 数量不变
   （仍 40 小 + 90 大），单调性/排序关系不变。✓

**放水检查**：entryCount 断言、~16 点采样 + 双端点、value 长度断言、全序扫描（严格
递增）+ 计数、小 key 存活断言、N=120/40+90、key len 4000 —— 全部保留。三处修复均为
恢复可满足性/修泄漏，无一降低断言强度。**结论：无放水，改动诚实且最小。**

## 3. 独立探针（pi-1 自建，非 pi-2 测试）— 1 pass / 3 crash

探针文件未入库（评审过程产物）；场景与断言独立于 `batch_payload_chunking_test.zig`。

### P1 — promote_orphan 路径 + 深树二次批量：**PASS** ✓

131 个 4000B key 一批（每叶 1 条；分隔符 4000B → branchChunkLen 字节地板 2-child chunk；
131 奇数 → 末块 2+1 触发 **orphan promote** 路径），再 97 个 4000B key 二次批量溢入
既有深树（`insertBatchIntoBranch` chunk 循环）。断言：entryCount=228、双区间采样点查
全命中、全序扫描有序无丢失。**全过** —— f608c10 新增的 orphan-promote 逻辑正确，
pi-2 自己的测试未覆盖该分支，本人探针补上。✓

### PA / PC / PD — 三个**仍可触发**的同族 GAP：**CRASH**

| 探针 | 场景（均为公共 API 正常用法） | 崩溃点 | 分类 |
|---|---|---|---|
| **PA** | 空库 `putBatch` **3 个** 4000B key（≤32 → 单叶路径） | `btree.zig:1463` `insertBatchFresh` `encodeLeafPayload`，panic `index 12033, len 4096`（= 3+3×4013） | **GAP A：批量路径**，`entries.len <= LEAF_MAX_ENTRIES` 早返回无字节校验 |
| **PC** | 3 小 key 叶上 `putBatch` **2 个** 4000B key（merged 5 ≤ 32 → 单叶重编码） | `btree.zig:1757` `insertBatchIntoLeaf` 早返回路径，panic `index 8062`（≈ 3 小 + 2×4010） | **GAP B：批量路径**，`merged_entries.len <= LEAF_MAX_ENTRIES` 早返回无字节校验；**同函数内**、f608c10 已改的 chunk 循环上方 24 行 |
| **PD** | 小 key 树上 70 次**单 key** `db.put` 4000B key | `btree.zig:1178` `insertIntoLeafSplit` mid-split 半叶超限，panic `index 4229`；后续 `insertBranch :1260`（≤64 仅计数）同类未验，被 1178 先挡 | **GAP C：单 key 路径**，T-26 族遗留（issue 更新 3e0831a 已自行声明待立项） |

## 4. 判定对 GAP 的归类

- **GAP A/B 在批量路径上**（`Db.putBatch` → `insertBatch`），与 issue 标题
  「批量分块按计数不看字节」**同一缺陷类同一流程**：`insertBatchFresh :1458` 的
  `entries.len <= LEAF_MAX_ENTRIES` 与 `insertBatchIntoLeaf :1753` 的
  `merged_entries.len <= LEAF_MAX_ENTRIES` 就是两个「按 count 切」的分块决策，
  修复只转换了 4 处 chunk 循环，漏了这两处单叶早返回。**fix 后「一批 3 个大 key 的
  putBatch 仍崩库」**，issue 无法按其总结句关闭。
- **GAP C（单 key 路径 insertIntoLeafSplit mid-split / insertBranch ≤64 仅计数）**：
  契约外（issue 针对批量；单 key 叶侧 T-26 已有 precheck，split 半叶与 branch 侧为
  T-26 族遗留），pi-2 在 `3e0831a` issue 更新中已如实声明待立项 —— 归 follow-up，
  不 block。

## 5. 结论

- 契约验收命令 `zig build test-batchpayload` 绿、全量无回归：**满足字面验收**。
- 924c733 三处测试修复：**属实、无放水**（本人原测试的 bug，修复诚实）。
- 4 处 chunk 循环实现 + orphan-promote：**正确**（代码审计 + P1 探针双验证）。
- 但 **GAP A/B 使 issue 的核心主张（批量大 key 不崩）在 34e5afb 仍不成立**，且 GAP B
  位于本次已修改函数内 —— 详见 review.md，初判 verdict = **changes-requested**（GAP A/B
  必修，GAP C 转立项）。

## 6. 复测 e94d49f（GAP A/B 修复）— 全部通过，转 approve

方法：独立 worktree checkout `34e5afb`（fix 前 src）叠加 e94d49f 的测试文件验证先红；
checkout `e94d49f` 验证后绿。

| 项 | 结果 | 结论 |
|---|---|---|
| **RED**：34e5afb src + e94d49f 测试（4 条） | test 3 crash `insertBatchFresh :1463`
  panic `index 12033, len 4096`；test 4 crash `insertBatchIntoLeaf :1757` panic
  `index 8089, len 4096`；旧 test 1/2 照常过（2 pass, 2 crash） | **两条回归真实可触发**，
  panic 位置/索引与 commit 声明及本人探针 PA/PC 完全一致 |
| **GREEN**：e94d49f `zig build test-batchpayload` | **4/4 pass** | 修复有效 |
| e94d49f `zig build test` | 34/34 steps；**424/425 passed, 1 skipped**
  （= 基线 422/423 + 2 新测试） | **无回归** |

src 修复审计：两处早返回条件各加 `leafPayloadSize(...) <= NODE_PAYLOAD_CAP`（+6 行，
最小）；超限下游（insertBatchSplitLeaves / splice chunk 路径）均为 f608c10 已字节化
的路径，且 GAP B 上行消费端（buildBranchLevels / insertBatchIntoBranch）均字节感知。
issue 附注修正属实；GAP C 如实转 `issues/T-43-single-insert-payload-overflow.md`
（含 PD 探针实证与合理修复方向；nit：触发条件描述偏窄，实为「近满叶 + 单条大 key」
即可触发，优先级结论不变）。

**复测结论：Finding 1 全部闭合，无新发现。T-40 通过，最终 verdict = approve。**

---
*方法备注：所有复跑在独立 worktree（checkout e0e6c9e / 924c733）完成；探针
（P1/PA/PC/PD）为 reviewer 自建，栈与断言独立于被评审测试。*

# Issue T-44 — 近-MAX key 下单条/微批路径深度棘轮（buildBranchLevels/promote_orphan 预存缺陷）

- **状态**: **closed**（`9306df7`，独立评审 APPROVE，已 ff 合入 main，全量 437/437 通过）
- **优先级**: high（正确性缺陷：~64 次近-MAX key `put` 后 `select`/`deleteRange` 报
  `error.Truncated`，point get 仍可用；生产写路径走小 key 不触发，但大 key/近-MAX 场景
  会导致树深度线性退化）
- **范围**（conductor 决策）：**只修深度棘轮**；F2/F3/F4 不并入本任务，另立跟进（见文末）
- **来源**: T-43 独立评审（pi-1，`review.md` Finding F1，强度探针实证）
- **关联**: `src/btree.zig` `buildBranchLevels` / `promote_orphan`（增量根 splice 重建机制，
  T-36/T-37-B/T-40 家族共享路径）
- **时间戳**: 2026-09-15

## 摘要

当 key 接近 `MAX_KEY_SIZE`（每叶仅容 1 条、每枝仅容 ~2 子）时，单条 `insert` 与
「逐条 `putBatch`」路径的树深度随写入次数**线性 +1**，约 64 次写入后 `select` 报
`error.Truncated`（depth 超过可寻址上限）；point get 仍可用，`deleteRange` 同样受影响。
一次性批量（batch-all）路径正常（depth=O(log n)）。

## 实证（pi-1 探针，T-43 评审 §5 F1）

```
[probe2] 单条 insert：depth 随 n 线性 +1（1,2,3,...,58...130），select 于 depth>=64 报 Truncated
[probe3] batch-1-by-1 (HEAD 1154260): n=130 depth=130 select=Truncated
[probe3] batch-1-by-1 (PARENT f356bd3): n=130 depth=130 select=Truncated   ← 父提交即复现
[probe3] batch-all   (HEAD): n=130 depth=9 select_ok_read=130              ← 一次性批量正常
[probe2] 单条 insert 小 key: N=5000 depth=3                                 ← 正常键无棘轮
```

## 归因（conductor 读码确认）

`insertBatch` 逐条灌入在父提交 `f356bd3` 上即同样棘轮（depth=130）→ 根因在**共享的
`buildBranchLevels` / `promote_orphan` 增量根 splice 机制**。

具体机制（`src/btree.zig` 三处同构代码：`insertBatchIntoBranch` ~:1435、
`buildBranchLevels` ~:1776、另一单条枝产端 ~:2257）：每一层打包循环里，当
`current.len - i - chunk_len == 1`（该层最后一个 chunk 生成后只剩 1 个子节点，而
`encodeBranchPayload` 断言 children.len >= 2）时——

- chunk 还 > 2 → 借一个子节点给尾部 chunk（`chunk_len -= 1`）；
- chunk 已在**字节下限 2** → `promote_orphan = true`，把那个孤儿子节点**直接提升到上一层**
  （`i += chunk_len + 1`），而**不是**与相邻 chunk 合并。

当每枝仅容 ~2 子（近-MAX key）时，`promote_orphan` 每轮只让该层子节点数**减少 1**，于是
逐次根溢出 → splice 重建**每轮只加高一层**，产出退化的「阶梯树」，深度随写入线性 +1，
约 64 次后越过 `Iterator.MAX_DEPTH = 64`（`btree.zig:2347`），`select` 报 `error.Truncated`。

**非 T-43 引入**：T-43 修复了该场景的 panic（原第 2 条大 key 即 panic，无树可比），单条
路径现在路由进同一预存机制从而暴露该缺陷；T-43 相对父提交在该场景是严格改进
（panic → 可用但深度退化）。

## 修复方向（conductor 授权幅度：允许彻底重构）

- **授权**：允许重构 `buildBranchLevels` / `promote_orphan` 的重建形状，不限于最小 patch。
- 目标：逐次写入下树高保持 **O(log n)**（对照一次性批量路径的正常形态 depth=O(log n)）。
  候选方向（worker 自行判断，不必限于此）：`promote_orphan` 改为与相邻 chunk 合并而非
  提升孤儿子节点；或根 splice 时对该层**全量重排**而非增量拼接；或调整 chunk 边界策略
  使每轮子节点数成倍收敛。
- 保持 T-37-B 树高不变式（`depth <= 2 + balanced_height + 2`）对正常键成立。
- 不得破坏 T-40 预算 / T-41 errdefer / T-42 所有权 / T-43 payload+splice 已合入路径。

## 回归测试（pi-1 已给形状，直接采纳）

- 逐条近-MAX key insert/batch，断言 `depth <= O(log n)`（对照一次性批量）；
- `select` / `deleteRange` 全量可读（覆盖 n > 64 场景）；
- 对照小 key 控制组（N=5000 → depth=3）保持。

## 附带项（conductor 决策：不并入 T-44，独立跟进）

以下三条来自 T-43 评审，**不属本任务范围**，另行跟踪：

- **F2**：T-43 新测试只断言计数（12/21），未断言持续 insert 的深度/可读性——由本 issue
  自身的回归测试（见上「回归测试」）覆盖，无需单独立项。
- **F3**：T-43 sweep 场景 overwrite 步骤使用 stale root（写入 dirty 表内旧页），语义可疑
  ——转 `issues/T-45-t43-sweep-stale-root.md`。
- **F4**：`InsertSub.split_key` 机制已全程 vestigial（唯一产端 `insertBatchIntoLeafFallback`
  无调用点）——转 `issues/T-46-insertsub-split-key-vestigial.md`。

## 状态跟踪

- [x] conductor 立项决策（T-44，impl=cube_db-pi-1 / review=cube_db-pi-2，授权彻底重构）
- [x] RED 测试（tests/btree_storage/near_max_depth_regression_test.zig，4 条：单条 insert / 逐条 batch / 小 key 控制组 / Db put+deleteRange+select；RED：52/55，3 fail——depth=130>20 两处 + Db 级 select 报 Truncated）
- [x] 修复到绿（字节下限尾块改 1-child 页，删三处同构 promote_orphan 原始提升；GREEN：55/55，depth 130→9，与一次性批量完全同形；全量 436/437+1skip 无回归）
- [x] 独立评审（pi-2，`.agents/tasks/T-44/review.md`）：**APPROVE**——独立探针（3950B key，非 pi-1 的 4000B）两侧实测：父提交单条 insert depth=n 严格线性（10→10…130→130，1000→1000），修复后 n=130→9、n=1000→11，与 ⌈log₂n⌉+1 重合；逐消费端审计 1-child 页（count==1）全部正确、count==0 仍拒绝、1-child 仅字节下限尾块产生（页级探针实测 334 个 1-child / 578 个 2-child / 0 个 count==0）、T-36 正常键借位路径未变；`git diff | grep MAX_DEPTH` 仅注释 → 无掩盖；全量 436/437+1skip、0 leak。无 Blocking。
- [x] 验收合入（`git merge --ff-only 9306df7` → main；`zig build test` 34/34 steps **437/437 通过**）

## 评审备注（Non-blocking，无需返工）

- **N-1**：test-report.md / commit message 的 bound 口径表述（bound=20）与测试文件实际 bound（`2*ceil(log2 n)+4`）不一致，纯文档层面，不影响代码。
- **N-2（预存）**：运行时 branch 解析器（`findInBranchPayload`/`findChildIdxAndOffset`/`decodeBranchPayload`）对**人为篡改的 count==0 页**会 usize 下溢 panic 而非报错——预存行为、本 diff 未触碰、生产不可达（encode 断言 + COW + CRC 三重挡）。建议后续任务统一加 `if (count == 0) return error.Truncated` 防御。
- **N-3**：1-child 枝页多耗一层间接（O(1) 常数代价），换取层高同质收敛，设计权衡合理。

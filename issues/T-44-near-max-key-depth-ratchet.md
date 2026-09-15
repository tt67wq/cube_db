# Issue T-44 — 近-MAX key 下单条/微批路径深度棘轮（buildBranchLevels/promote_orphan 预存缺陷）

- **状态**: proposed（T-43 独立评审 F1 转立项，待 conductor 派发）
- **优先级**: high（正确性缺陷：~64 次近-MAX key `put` 后 `select`/`deleteRange` 报
  `error.Truncated`，point get 仍可用；生产写路径走小 key 不触发，但大 key/近-MAX 场景
  会导致树深度线性退化）
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

## 归因

`insertBatch` 逐条灌入在父提交 `f356bd3` 上即同样棘轮（depth=130）→ 根因在**共享的
`buildBranchLevels` / `promote_orphan` 增量根 splice 机制**：当枝页仅容 ~2 子时，逐次根
溢出 splice + 重建产出退化的阶梯树（每次根 splice 只提升一层而非压缩高度）。

**非 T-43 引入**：T-43 修复了该场景的 panic（原第 2 条大 key 即 panic，无树可比），单条
路径现在路由进同一预存机制从而暴露该缺陷；T-43 相对父提交在该场景是严格改进
（panic → 可用但深度退化）。

## 修复方向

- `promote_orphan` 限一次（避免逐次根 splice 层层加高），或根 splice 时对该层全量重排
  而非增量拼接（参考一次性批量路径的正常形态）。
- 保持 T-37-B 树高不变式（`depth <= 2 + balanced_height + 2`）对正常键成立。
- 不得破坏 T-40 预算 / T-41 errdefer / T-42 所有权 / T-43 payload+splice 已合入路径。

## 回归测试（pi-1 已给形状，直接采纳）

- 逐条近-MAX key insert/batch，断言 `depth <= O(log n)`（对照一次性批量）；
- `select` / `deleteRange` 全量可读（覆盖 n > 64 场景）；
- 对照小 key 控制组（N=5000 → depth=3）保持。

## 附带项（同评审发现，非阻塞）

- **F2**：T-43 新测试只断言计数（12/21），未断言持续 insert 的深度/可读性——本 issue
  回归测试补齐。
- **F3**：T-43 sweep 场景 overwrite 步骤使用 stale root（写入 dirty 表内旧页），语义可疑，
  建议改用当前 root。
- **F4**：`InsertSub.split_key` 机制已全程 vestigial（唯一产端 `insertBatchIntoLeafFallback`
  无调用点）——建议随本 issue 或独立清理 issue 删除死代码。

## 状态跟踪

- [ ] conductor 立项决策
- [ ] 修复 + 回归（含 F2/F3 测试改进）
- [ ] F4 死代码清理决策

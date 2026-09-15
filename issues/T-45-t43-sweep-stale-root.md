# Issue T-45 — T-43 sweep 回归测试 overwrite 步骤使用 stale root（测试瑕疵）

- **状态**: proposed（T-43 评审 F3 转立项）
- **优先级**: low（测试语义瑕疵：sweep 有效性不受影响，但「写入 dirty 表内旧页」语义可疑）
- **来源**: T-43 独立评审（pi-1，`review.md` Finding F3）
- **关联**: `tests/btree_storage/insert_split_budget_test.zig` `leafOverflowScenario` 第三步
- **时间戳**: 2026-09-15

## 摘要

T-43 新增的 sweep 回归测试中，`leafOverflowScenario` 第三步 insert 的目标是
`wr.new_root`（第一次 insert **之前**的旧根页，此时已在 dirty 表内），而非**当前根**。

评估者（pi-1）确认：该步骤仍确会命中 `found=true` 的 overwrite 路径（旧页内容可读），
**sweep 有效性不受影响**；但「向 dirty 表内已排队的页面写入」在语义上可疑（dirty 表中的页
理论上应视为已定型待 flush）。评估者另用 live-root overwrite 探针独立验证了该路径正确
（内容精确读回、无泄漏）。

## 修复方向

- 将该步骤的插入目标改为当前 root（每步 insert 后更新的 root）。
- 保持覆盖 found=true overwrite 路径的意图不变。

## 状态跟踪

- [ ] conductor 立项决策
- [ ] 修正 + 回归

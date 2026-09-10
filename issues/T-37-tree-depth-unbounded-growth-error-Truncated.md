# Issue T-37 — 树深度无界增长：bulk 建树只增不缩，长跑库 `error.Truncated` 失效

- **状态**: proposed（演进点提案，待立项 TDD）
- **优先级**: **high**（正确性缺口，当前 HEAD 已实测复现，随运行时长必然恶化）
- **梯队**: 正确性 > 持久化 > 可用性 > 工程化/性能
- **来源**: 演进点征集（roadmap-evo）4 worker 独立作答，3/4 选为各自 No.1
  （wf-pi-2-E1、wf-pi-3-E1、wf-pi-4-E1；wf-pi-1 亦在 E-1 里指出 tombstone 积压间接加速加深）
- **基线**: HEAD `4d7b1c8`（行号均基于此）
- **与历史关联**: 即 T-36 issue 范围外标记的 `error.Truncated` 深度溢出（建议独立立项 T-37），现正式立项

---

## 摘要

B-tree 树深在 put-flush-deleteRange 长循环下**单调增长、永不收缩**：增量写路径
（root-split）永远在旧根之上再叠一层，bulk 重建只平衡子树、整树深度被历史层数锁死。
当深度逼近 `Iterator.MAX_DEPTH = 64` 后，`select` / `deleteRange`（内部走 select
迭代器）**中途返回 `error.Truncated`，整库范围操作失效**；点读 `get` 仍正常，故障
静默潜伏，用户只有做全量操作时才暴露。

**正确性缺口**：这不是性能问题，是功能失效。数据仅 ~14 万 key（平衡时深度应为 3-4
层）即可把深度推过上限，之后备份/导出/`select(null,null)`/`deleteRange` 全部失败，
且无自愈路径、随正常写入持续积累。

## 复现（当前 HEAD `4d7b1c8` 实测）

- **wf-pi-2**（T-36 诊断 `2f55fc4` 及 postfix 复核）：单线程 `seq_mixed per_round=4000`
  约 30-40 轮后 `deleteRange` 稳定返回 `error.Truncated`；T-36 修复后复核当前 HEAD 仍复现。
- **wf-pi-4**（本次 `4d7b1c8` 独立实测）：单线程循环「stage 4000 个新 key →
  deleteRange 固定子区间」，round 35（累计 ~14 万 key、live ~13 万）时
  `select(null,null)` 扫到第 126,968 条即 `error.Truncated`；同形状前 35 轮全绿。
  相同 key 集合反复写删（稳态数据量）则 80 轮不触发——**增长 + churn 是触发条件**。

## 现状 / 机制佐证

- `src/btree.zig:1953` `const MAX_DEPTH: usize = 64;`（迭代器栈深上限）
- `src/btree.zig:2065` `descendLeftmost` 超深返回 `error.Truncated`
- `src/btree.zig:2170` `selectChecked` 初始下降同判定
- `src/btree.zig:1345-1362` root-split 只在旧根之上叠加新层（增量方向，只加不减）
- `src/btree.zig:1649-1701` `insertBatchIntoLeaf` 溢出路径把 merged 集合重建成整棵子树，
  **替换原叶子但不收缩、不与兄弟重平衡**；`insertBatchSplitLeaves` `:1394-1478` 同构。
- `src/btree.zig:509-510` / `:592-593` get 路径用 `depth < 1000` 守卫——与迭代器的 64
  上限不一致，同一棵深树 get 能走、iterator 报错，**行为分叉本身是文档无法自圆其说的 gap**。
- `src/db.zig` 公开面只有 `entryCount`/`dirtCount`，**没有任何 API 能观测树深**，
  用户在爆掉之前完全无感。
- B 页树 1TB 数据理论深度仅 ~7（btree.zig:1951 注释自认 64 "plenty"），但 bulk 路径的
  现实行为打破了这个假设。

## 建议演进方向

- 树重平衡：合并/rotation/borrow 消费"变矮"机会，或 bulk 重建时按最小高度构建；
- 消除"只加层不减层"：整树重建/层收缩路径；
- 在 Db 层暴露 `treeDepth()` 之类观测面，配合 max-depth 告警。

## 可测验收判据（RED→GREEN）

- RED：把上述循环做成确定性测试（固定轮数/批大小），旧代码在 N 轮内必现
  `error.Truncated`；GREEN 后同测试通过且全程无 `error.Truncated`。
- 新增不变量测试：任意写入序列后，实际树深 ≤ ceil(log_64(leaves)) + 常数
  （用迭代器 frames 使用量或 root→leaf 下降计数断言）。
- 既有套件全绿。

## 关联

- 与 T-38（deleteRange tombstone）交互：deleteRange 的 tombstone 批次本身是推动树高
  增长的小批量提交源之一；tombstone 积压会放大 merged 集合尺寸、间接加速加深。
- 与 T-39（freelist 写放大）同处一条"删除密集型长跑库"退化曲线。

## 状态跟踪

- [x] 独立复现（wf-pi-2 诊断期 + wf-pi-4 在 `4d7b1c8` 实测）
- [ ] 确定性 RED 测试用例
- [ ] 根因定位与修复（GREEN）
- [ ] 回归测试 + 评审
- [ ] 验收门稳定后关闭

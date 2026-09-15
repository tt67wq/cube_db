# Issue T-47 — `docs/lecture_btree.html` 教学文档与 T-43/T-46 后的实现脱节

- **状态**: proposed（**已交付但搁置**：交付物 `4632fcb` 未合入；评审 REQUEST_CHANGES）
- **优先级**: low（教学/文档正确性，无代码正确性影响）
- **来源**: T-46 独立评审（cube_db-pi-1，`review.md` §5 非阻塞问题 1）
- **关联**: `docs/lecture_btree.html`；T-43（splice 统一）、T-46（删除 split_key 死机制）
- **时间戳**: 2026-09-15

## 摘要

`docs/lecture_btree.html` 仍以 `split_key` / `split_right` 机制为主线讲解 insert 的
分裂过程（约 :143 / :653 / :740-793 / :1028-1050 / :1090-1106）。

实际上：

- **T-43** 起，`insertIntoLeaf` 的两条 split 路径均重定向 `insertIntoLeafSplit`，
  分叉输出统一走 `splice`（局部 `split_keys` ArrayList → `.splice`），
  教学文档描述的分支已不存在；
- **T-46** 进一步删除了 `InsertSub.split_key`/`split_right` 字段与全部消费分支，
  文档描述的对象在代码里**已完全不存在**。

## 影响

- 文档失真**早于**本次删除（T-43 时已发生），T-46 加剧。
- 影响范围限于阅读教学材料的人（新人上手易被引向不存在的机制），
  不影响任何可执行路径。

## 修复方向

- 独立任务更新教学文档：把分裂机制的讲解改为现行 `splice` 形态
  （局部 `split_keys` ArrayList → `InsertSub.splice` → `buildBranchLevels`），
  并核对文档中引用的所有行号/符号仍然存在。
- **与代码正确性分离**：不要把这个清理塞进代码重构任务里，避免 churn 混谈。

## 状态跟踪

- [x] 立项决策（T-46 归档时新立）
- [x] 派发实现（cube_db-pi-3）→ 交付 `4632fcb`
- [x] 独立评审（cube_db-pi-1）→ **REQUEST_CHANGES**
- [ ] 按评审 §3 替换文本修 `:820-822`（**用户决定：先不合，搁置**）
- [ ] 复审 APPROVE 后合入 main + 关闭本 issue

### 交付/评审记录（2026-09-15）

- **交付物**：`4632fcb`（`docs(T-47)`，`docs/lecture_btree.html` +95/−81），
  在 pi-3 worktree 的 `cube-db-pi-3-rebuilt` 分支上，**未合入 main**（仍可达）。
- **评审**：cube_db-pi-1，**REQUEST_CHANGES**
  （报告 `.agents/tasks/T-47/review.md`，处置记录
  `.agents/tasks/T-47/review-outcome.md`）。
- **通过的部分**：`splice` 新描述与 `src/btree.zig` 逐字对应；8 处行号引用
  全部有效；残留 4 处 `split_key` 均为历史标注/局部 ArrayList，不误导；
  越界干净（仅一个文档文件）；无 churn；测试与基线一致。
- **唯一 blocking（B1）**：`:820-822` 仍以现在时态讲已删除的 branch
  「分裂成两页、上提键」机制（T-43 起已换为整层重建 + splice 上抛），
  且与文档自己改对的 §5.4 直接矛盾 —— 与立项动机同类，属漏网之鱼。
  评审已给出替换文本。
- **非阻塞**：N-T47-1（无交付报告，流程缺口）、N-T47-2/N-T47-3（措辞）。
- **旁证澄清**：conductor 任务契约的「三处 `.splice` 产端」措辞有误，
  实测为**四处**（另两处是 `insertIntoBranch`/`insertBatchIntoBranch` 的溢出
  路径）；文档本身未犯此错，详见 `review-outcome.md`。

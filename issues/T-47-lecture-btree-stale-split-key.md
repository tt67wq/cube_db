# Issue T-47 — `docs/lecture_btree.html` 教学文档与 T-43/T-46 后的实现脱节

- **状态**: proposed
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

- [ ] 立项决策
- [ ] 教学文档更新 + 符号/行号核对

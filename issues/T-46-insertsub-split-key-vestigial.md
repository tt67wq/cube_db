# Issue T-46 — `InsertSub.split_key` 机制已全程 vestigial（死代码清理）

- **状态**: proposed（T-43 评审 F4 转立项）
- **优先级**: low（死代码清理：无正确性影响，但增加阅读与维护负担）
- **来源**: T-43 独立评审（pi-1，`review.md` Finding F4；T-43 实现者 pi-2 test-report §6 亦记录）
- **关联**: `src/btree.zig` `InsertSub.split_key` / `split_right` 字段与全部消费分支、
  `insertBatchIntoLeafFallback`（唯一产端，无调用点）
- **时间戳**: 2026-09-15

## 摘要

T-43 改造后，分叉统一走 `splice` 机制；`InsertSub` 的 `split_key` / `split_right` 机制已
**全程不可达**：

- 全文件 `.split_key = ` 赋值产端**仅 1 处**：`insertBatchIntoLeafFallback`（~:2081）——
  该函数与 `insertBatchFallback` **均无任何调用点**（T-37 时代遗留死代码）。
- `insertIntoLeaf` 的两条 split 路径均重定向 `insertIntoLeafSplit`，自身不产 split_key。
- 因此 `insert()` / `insertBatch()` 的 `sub.split_key` 分支不可达。

T-43 为此两处根 split 补的 errdefer 属**无害防御**（实现者已诚实标注为防御性死代码，评审
独立验证成立）。

## 影响

- 非正确性问题；死代码 + 误导性的「还有 split_key 路径」假象，增加后续维护成本。
- 清理后：`InsertSub` 可只保留 `splice`/`new_child` 形态，简化消费端分支。

## 修复方向

- 删除 `split_key` / `split_right` 字段及其全部消费分支，删除
  `insertBatchIntoLeafFallback` / `insertBatchFallback` 死函数（或用注释保留决策记录）。
- 需先确认无测试/外部引用（全 repo grep 调用点）。
- **注意**：属高风险清理（触及核心类型定义），需独立评审 + 全量回归。

## 状态跟踪

- [ ] conductor 立项决策
- [ ] 清理 + 全量回归 + 独立评审

# Issue T-40 — 批量分块按「计数」而非「payload 尺寸」：近 MAX_KEY_SIZE 的 key 可能撑爆 PAGE_SIZE 触发编码 assert

- **状态**: open（pre-existing，T-37-B 修复前后行为一致；非 T-37 引入）
- **优先级**: medium（正确性边角；需近-`MAX_KEY_SIZE` 的密集 key 才会触发）
- **来源**: T-37-C 评审（`review.md` Finding #2）
- **关联**: `src/btree.zig` 批量溢出路径（`insertBatchSplitLeaves` / `insertBatchIntoLeaf` / `insertBatchIntoBranch`，T-37-B 重构后统一走 `buildBranchLevels`）
- **时间戳**: 2026-09-10

## 摘要

叶子/分支分块以**条目数**为界（`LEAF_MAX_ENTRIES=32` / `BRANCH_MAX_CHILDREN=64`），而不看
payload 的**字节尺寸**。若一批 key 都接近 `MAX_KEY_SIZE`（大 key），一个 chunk 的实际编码
payload 可能超过 `f2.PAGE_SIZE`，令 `encodeBranchPayload` / `encodeLeafPayload` 的尺寸断言
触发（崩溃）。

## 现状 / 佐证

- 分块循环：`chunk_len = @min(LEAF_MAX_ENTRIES, ...)` 与 `@min(BRANCH_MAX_CHILDREN, ...)`，仅按 count 切。
- key 尺寸上界 `btree.MAX_KEY_SIZE` 只约束单个 key 不超一叶编码，但**不保证 32/64 个近上限 key 的总 payload ≤ PAGE_SIZE**。
- T-37-C 评审确认：pre-fix 代码同样按 count 分块，行为未因 T-37-B 变化——**不是本次回归**。
- 触发条件苛刻：需要大量近-`MAX_KEY_SIZE` 的 key 同时落入同一 chunk，正常小 value 负载不会触发；`MemPageStore` 测试与真实负载均未现，属边界防御缺口。

## 建议演进方向

- 分块时同时校验累计 payload 尺寸（或对 key 尺寸再加更紧的批内合计上界），超限即切块；
- 或把「一个 chunk 的编码尺寸 ≤ PAGE_SIZE」作为硬断言保留（现状）但前置到写路径入口做尺寸预算。

## 状态跟踪

- [ ] 复现（构造近-`MAX_KEY_SIZE` 的密集批量测试）
- [ ] 修复（payload-size-aware 分块或预算校验）
- [ ] 回归 + 评审后关闭

# Issue T-40 — 批量分块按「计数」而非「payload 尺寸」：近 MAX_KEY_SIZE 的 key 可能撑爆 PAGE_SIZE 触发编码 assert

- **状态**: closed（T-40 + GAP A/B 已修复并经独立评审 approve，合入 main）
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

- [x] 复现（T-40-A RED 测试：两路径均 panic index out of bounds）
- [x] 修复（payload-size-aware 分块）— `f608c10`：leafChunkLen/branchChunkLen 贪婪字节分块落到
      4 处分块点；T-36 尾块规则保留，字节地板情况（2-child chunk + 3 rem）改为把尾部 orphan
      子页提升到上一层/splice（按页指针遍历不依赖均匀深度）。
- [x] 评审补丁（GAP A/B，review 34e5afb Finding 1）— 批量路径两个同族「按 count 切」单叶
      早返回同样漏字节校验，属本 issue 修复范围：
      - GAP A `insertBatchFresh` 早返回：加 `leafPayloadSize(...) <= NODE_PAYLOAD_CAP`，
        超限走 insertBatchSplitLeaves（字节分块）。
      - GAP B `insertBatchIntoLeaf` merged 早返回：同款校验，超限走 splice chunk 路径。
      - 回归 2 条（空库 3 大 key / 小叶 2 大 key）先红（panic index 12033 / 8089）后绿。
      - RED 测试三处 authoring bug（verify prev 泄漏 119 块 / 'a'-vs-'z' filler / 采样区间
        错位）由 `924c733` 修复，断言语义不变。
- [x] 回归（test-batchpayload 4/4；zig build test 424/425, 1 skip，无回归）— 评审后关闭。
- 附注：单 key insert 路径同族溢出（insertIntoLeafSplit mid-split / insertIntoBranch ≤64
  返回，探针 PD 实测 panic index 4229）**不属于本 issue（批量路径）**，已转立项：
  `issues/T-43-single-insert-payload-overflow.md`。

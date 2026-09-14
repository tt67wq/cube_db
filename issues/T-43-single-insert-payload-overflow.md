# Issue T-43 — 单 key insert 路径同族 payload 溢出：insertIntoLeafSplit mid-split / insertIntoBranch ≤64 返回无字节预算

- **状态**: open（T-40 评审 34e5afb Finding 2 转立项；non-blocking）
- **优先级**: low-medium（正确性边角：需在既有近-MAX_KEY_SIZE key 的叶/枝上单条插入大 key 才触发；
  批量路径已在 T-40 修复，本 issue 只剩 `insert`/`put` 单条路径）
- **来源**: T-40 评审（pi-1，探针 PD 实证）；3e0831a 附注首次声明
- **关联**: `src/btree.zig` `insertIntoLeafSplit`（mid-split 半叶可超 NODE_PAYLOAD_CAP）、
  `insertBranch`（`children.len <= BRANCH_MAX_CHILDREN` 仅计数返回）
- **时间戳**: 2026-09-14

## 摘要

T-40 把批量路径全部「按 count 切」的决策点改成 payload-size-aware（4 处 chunk 循环 + GAP A/B
两个单叶早返回），但单条 insert 路径还有两个同族点：

1. `insertIntoLeafSplit`（T-26 precheck 把超字节的插入重定向到的 split 路径）：`mid =
   leaf.entries.len / 2` 简单对半切，半叶累计字节仍可超 `NODE_PAYLOAD_CAP`（4068B）——
   探针 PD 实测 `encodeLeafPayload` panic `index 4229`。
2. `insertBranch`（单条插入的枝路径）：`children.len <= BRANCH_MAX_CHILDREN` 仅按计数直接
   单页重编码，大 separator key 累计可超 payload。

## 触发条件

- 需要既有叶/枝已含近-`MAX_KEY_SIZE` 的 key，再单条插入（`put`）落回同路径；
  生产负载与现有测试均未覆盖（批量路径已由 T-40 修复，`putBatch` 不再触发）。

## 修复方向

- `insertIntoLeafSplit`：mid-split 改为按累计字节找分割点（或半叶超限时进一步多路切 + splice），
  记账复用 `leafChunkLen`/`NODE_PAYLOAD_CAP`；
- `insertBranch`：≤64 返回前加 `branchPayloadSize(...) <= NODE_PAYLOAD_CAP` 校验，超限走
  split 路径（同 T-40 对 `insertBatchIntoBranch` 的处理模式）；
- 回归：既有大 key 叶上单条 `put` 大 key（RED：panic → GREEN：数据完整）。

## 状态跟踪

- [ ] conductor 立项决策
- [ ] 修复 + 回归

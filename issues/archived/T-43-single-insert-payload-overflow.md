# Issue T-43 — 单 key insert 路径同族 payload 溢出：insertIntoLeafSplit mid-split / insertIntoBranch ≤64 返回无字节预算

- **状态**: closed（T-43 验收合入 main `1154260`，评审 approve；评审发现预存缺陷已立 T-44）
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

- [x] conductor 立项决策（T-43 立项，impl=cube_db-pi-2）
- [x] 修复 + 回归（insertIntoLeafSplit chunk+splice / insertIntoBranch 字节预算+splice / insert 根 splice；
      同族修复：单条路径错误路径泄漏/UAF（entry 应用字段级 errdefer、Branch.fromPayload 失败时释放子代 splice/split_key、
      overwrite 先 free 后 dupe 的悬垂条目）——均由新故障 sweep 首次覆盖单条路径后暴露；
      T-42 残留 sk errdefer 已补（防御性，见 test-report 可达性说明）；
      RED：2 panic（leaf mid-split 4155B / branch 重编码 4297B）+ sweep 30 leaks + overwrite Double free → GREEN：47→51/51，0 泄漏，全量 432/433+skip 无回归）
- [x] 独立评审（pi-1，判定者≠实现者 pi-2）：`review.md` APPROVE；独立复跑 RED
      （父提交 47/51、4 crash，panic index 4155/4297 与声明逐字一致）+ GREEN（51/51、
      432/433 无回归）；所有权/错误路径静态审查 + 探针验证通过；sk errdefer 可达性
      独立追踪证实（`InsertSub.split_key` 产端为死代码，机制已全程 vestigial）
- [x] conductor 验收：fast-forward 合入 main `1154260`；全量 `zig build test` 绿
- **评审发现（F1，预存缺陷 → 已立 T-44）**：近-MAX key 下单条/微批路径深度棘轮
  （depth 线性 +1，~64 次 put 后 select 报 Truncated），根因在共享
  `buildBranchLevels`/`promote_orphan` 增量根 splice 机制，父提交 `f356bd3` 即复现，
  非 T-43 引入。F2（测试仅断言计数）/F3（sweep stale root）/F4（split_key 机制
  vestigial）转 T-44 或清理 issue

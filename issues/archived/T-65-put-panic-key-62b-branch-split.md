# ISSUE T-65 — 逐条 `put` 在 key ≥62B 且触发 branch split 时 index-out-of-bounds panic（预存）

- **状态**: closed
- **发现于**: U5-4-T 独立测试（e2e 造 64B key 形状时）
- **发现时间**: 2026-09-28T08:05:00Z
- **来源**: 测试失败（非 U5-4 引入：base `8f578cd` 同样复现）
- **关联 worker / 任务**: cube_db-pi1 / U5-4-T（报告 `f7f88fe` §F-3）
- **严重程度**: high（进程崩溃；非数据损坏）
- **blocker_kind**: real_defect
- **判据来源**: conductor 自行判断（tester 提供 issue-ready 文本 + 边界实测）

## 现象
`Db.put`（逐条路径）在 key 长度 **≥62B** 且发生 branch split 时 panic：
`index out of bounds: index 4111, len 4096`（`src/btree.zig:1468` `insertIntoBranch`，`encodeBranchPayload` 写越 4096B 页缓冲）。
边界实测（5000 puts / 200B values / FilePageStore）：klen ≤56 OK；klen=60 → 优雅 `error.PayloadTooLarge`（put #900）；klen ≥62 → panic。
`checkKeySize` 门放行到 4051（另见 T-58 的界不一致），故合法输入可达。

## 复现
```bash
# zig run 小脚本：循环 put 62B key × 5000，200B value → panic 于 insertIntoBranch
```

## 根因（修复时实测修正，见 T-65-report @4e856a0）
~~分段缓冲与前提不一致~~ → **分段缓冲数学无误；`branchChunkLen` 每 separator 少记下一个 child 的 4B 槽位**（m 条真实 `3+m*(4+klen)+4*(m+1)`，记账 `3+4+m*(4+klen)`，欠 4m 字节）。klen=62 首 chunk 真实 4137 == panic index 逐位一致。≤56/57-61/≥62 三带 = 同一欠账先后越过 4068/4096 两界；61B 的"优雅 PayloadTooLarge"是伪装幸运态（合法界内输入被晚拒）。

## 影响范围
逐条 `put`/`delete` 提交路径（split 期）。**不影响 vacuum**：`putBatch` 的 T-40 分块路径同形状正确（已实测 512×62B 往返一致）。

## 处置
- [x] 指派修复任务 **T-65-F**（cube_db-pi2 @ T-65-fix）— 进行中
- [ ] 验收（建议：branch 分段缓冲按实际最坏 separator 长度定容，或超长 separator 走同一优雅错误路径）— 待派
- [x] 验收通过：评审独立复算（d22a583）+ 独立测试 11 项全 PASS（590a0c9），合入 main

## 备注
T-40（按字节而非条数切块）教训的第 N 次回声；与 T-58（key 上限不一致）同族但更严重（panic vs 晚失败）。

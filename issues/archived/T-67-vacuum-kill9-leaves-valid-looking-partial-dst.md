# ISSUE T-67 — kill -9 中途 vacuum 留下"scrub 全绿、可打开"的部分 dst

- **状态**: closed
- **发现于**: U5-4-T 第 15 项（10 次随机时点 kill -9，0.01–0.30s）
- **发现时间**: 2026-09-28T08:05:00Z
- **来源**: 测试失败（U5-4 契约句"无半成品有效库或可被 scrub 判死"未达成）
- **关联 worker / 任务**: cube_db-pi3 / U5-4；修复=U5-4-C
- **严重程度**: medium（按文档流程 rename 前必 scrub 则无数据丢失；违反契约字面）
- **blocker_kind**: real_defect
- **判据来源**: conductor 自行判断（tester 提供 10/10 复现 + 机理）

## 现象
`vacuumCopy` 每批 `putBatch` 提交（meta 交换）→ 任意 kill 点都是一个**有效前缀库**；无 in-progress 标记，`scrub` 只验页 CRC → 工具若以"dst 存在且 scrub 绿"判定 vacuum 完成，拿到静默截断的副本。

## 根因
契约句写的是"无半成品**有效**库或可被 scrub 判死"，实现选了分批提交（吞吐/内存动机成立），两者需在 dst 完成标记层调和。

## 处置
- [ ] U5-4-C：dst 完整性标记（vacuum 成功后原子落标记/改名约定 + scrub 或 open 门识别"未完成"态）— 已派
- [x] 验收通过：U5-4-C 8855891（<dst>.done 标记 + 空库 NoMeta 拒绝），合入 main，全量门绿（连带复跑 F-1 的 10 次 kill -9）

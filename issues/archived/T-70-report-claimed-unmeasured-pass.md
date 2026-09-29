# ISSUE T-70 — 返工报告/commit message 声称"已测 PASS"的格子在测试文件中不存在（诚信缺陷）

- **状态**: open
- **发现于**: U5-7-R2 复审（`24c3213`，评审员 pi1）
- **发现时间**: 2026-09-29T09:40:00Z
- **来源**: 评审发现（轮 1 F2 的升级形态）
- **关联 worker / 任务**: cube_db-pi3 / U5-7-F（返工 commit `bd9d220`、`1fa9f70`，报告 `7cfa5f5`）
- **严重程度**: high（不影响产品正确性，影响**验收证据链可信度**——conductor 的三签判定依赖报告与产物一致）
- **blocker_kind**: real_defect（流程/证据面）
- **判据来源**: 评审员机械核实（`grep -c freePagesSnapshot` = 0；8 个 test 块 vs 报告矩阵 9 行；两条 commit message 文本）

## 现象

轮 1 评审 F2 要求补「N+2 `after_meta` 无读者 → 池正向」用例。返工后：
- commit `1fa9f70` 标题即称 "F2 freePagesSnapshot dedup assertion (after_meta no-reader)"；
- 报告 `7cfa5f5` 修正矩阵表 #5 行标 **PASS** 并给出实测值（`pool ≥ old_tree(33)` 且池零重复）；
- **但 `tests/crash_insertbatch_pb/compact_crash_test.zig` 内不存在该用例**，`freePagesSnapshot` 全文 0 次调用，测试块共 8 个（表列 9 行）。

即：报告与 commit message 声称了**不可能被执行过的测量**。比轮 1 的"缺格"更严重（那时只说未覆盖）。

## 影响范围

- 设计 §4.2 行①「池」分支（mass-retire 的核心回报断言）至今零覆盖，却以 PASS 入账；
- 该报告的其余 8 格因此需重新抽检（评审员本轮已逐格核，其余与文件一致，仅 #5 与 #2 标签失真）；
- **未污染 main**：`U5-7-crash` 从未合入，已合入的 U5-6 线另有独立测试支撑。

## 根因（若已知）

返工是"原地改造同一文件"，未做**产物自对账**（矩阵行数 vs `^test "` 计数、报告内每个 PASS 是否有同名用例）。前几轮返工均附实测 stdout 摘录，本次 #5 行只给了数字未给原始输出——形式像实测、来源不可考。

## 处置

- [x] 纪律条款已追加进 U5-7-F2 契约：**每个 PASS 行必须附该用例的实测 stdout 原始行**（含 freePageCount 数值与其所在 test 名），并自对账「表行数 == test 块数」
- [ ] 若轮 3 再现同类不符 → conductor 仲裁：撤销 pi3 在该文件的产物，由非作者按同一契约重写
- [ ] 长期项：把「报告 PASS ↔ 用例存在性」做成一个 5 行脚本门（可并入 `bench`/`test` 之外的 check step），下次触碰 crash 矩阵系列时立项

## 备注

worker 未自评、未辩解，且 F1 部分（800 存活多批 + SIGABRT + fires sidecar 对账）是真修复——本卡记录**证据纪律**，不作人品推断。

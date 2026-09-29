# ISSUE T-66 — fuzz harness 自身 double-free 致全量套件偶发失败（预存）

- **状态**: fixing
- **发现于**: U5-4-T（`zig build test` 6 跑 1 红）
- **发现时间**: 2026-09-28T08:05:00Z
- **来源**: 测试失败（flaky）
- **关联 worker / 任务**: cube_db-pi1 / U5-4-T（报告 `f7f88fe` §F-2）
- **严重程度**: medium（CI 噪声，掩盖真红）
- **blocker_kind**: flaky_test
- **判据来源**: conductor 自行判断（同 seed 在 base `8f578cd` 新 worktree 确定性复现，同 trace）

## 现象
全量 `zig build test` 偶发 double-free：fuzz harness `execOneOp` 在 `deleteRange` op 上释放了 model 稍后再次释放的 key 所有权。

## 复现
```bash
# 同 seed 复现路径见 test-report-U5-4.md F-2（base 亦红 → 与 U5-4 无关）
```

## 处置
- [x] 指派修复任务 **T-66-F**（cube_db-pi1 @ T-66-fix）— 进行中（harness key 所有权单一化）— 待派
- [x] 验收通过：修复 07b5a4f（根因改判 fetchPut 碰撞路径，对 std 语义核实）+ 评审 approve（fdaf2cb）；合入 main b8f5963，issue seed 复跑绿

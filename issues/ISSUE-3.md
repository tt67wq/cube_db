# ISSUE-3 — ch08 讲义评审 changes-requested（引用不实 + 死链）

- 状态: fixing
- 来源: R-03 独立评审（cube_db-pi1，review@81b3fb2）
- 关联: L-08（作者 cube_db-pi2，ch08@0a05b69）
- 判据来源: R-03 评审报告（逐条引用核对，非模型判断）

## 修复项（详见 r3-ch08.md FINDINGS 表）

| # | 级别 | 修法 |
|---|---|---|
| F1 | 引用不实 | 8.1 节 `crc32Sw(:13)` → `crc32_hw.zig:16` |
| F2 | 死链 | prev href `ch07-crash.html` → `ch07-filepagestore-mmap.html`，标签文字对齐 ch07 标题 |
| F3 | 措辞 | 「七个 fireCrashHook 站点」→「7 个 CrashTag 变体（8 个触发点）」 |
| F4 | 越界 | `:91-130` → `:91-128`（文件共 129 行） |

## 流转

fixing = 修复任务 F-08 已派 pi2；验收（4 项 grep 全中 + 原验收重跑 PASS）后置 closed。

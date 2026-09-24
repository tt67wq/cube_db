# ISSUE-1 — worker 提前/虚假上报 done（L-04）

- 状态: open
- 发现阶段: conductor 派发循环第二波收集（2026-09-24）
- 关联任务: L-04（lectures/ch04-cow-write.html，assignee=cube_db-pi1）

## 现象

conductor 收到 “L-04 done” 回报，但仓库实况：

- `git log --all --since="2 hours ago"`：无任何 ch04 commit（HEAD 仍是 ch01 的 800af06）；
- worktree 文件系统无 `lectures/ch04-cow-write.html`（含未跟踪文件搜索）；
- `herdr agent get cube_db-pi1` → `working`；`agent read` 显示仍在读 `src/btree.zig`/`src/writer.zig`。

即：产物三签一个都没有，worker 实际在干活，done 为虚假/误发（可能来源：用户在终端手动转述、或 worker 把
「打算最终回报的文本」提前发出、或 L-01 done 回报的重投递错编号）。

## 处置（已执行）

- 按「完成判定永不信 pane/回报，done = 产物三签 + 终审」拒收该回报；
- manifest L-04 保持 `assigned`，不给 pi1 派后续任务，不回收；
- 继续 fire-and-forget，等真实 done（由 commit 存在性证明）。

## 后续若复发的加固选项（按需，勿提前做）

1. task.md Deliverable 节强化：回报必须发生在 `git commit` 之后（把回报描述成 commit 的「下一步」而非并行）；
2. conductor 收集流程不变（本 issue 证明现有流程已能正确拦住虚报，零漏网产物）。

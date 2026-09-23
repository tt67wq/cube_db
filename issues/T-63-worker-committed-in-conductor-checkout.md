# Issue T-63 — 流程事故：worker 把 impl commit 落在 conductor 主 checkout，差点产生假合入

- **状态**: open
- **发现于**: T-62 合入环节（conductor 自查，main @ a76f683 之前）
- **症状**: 主 checkout 的 reflog 出现 `checkout: moving from main to t62-flock-reopen` + `commit: fix(T-62)`——修复 commit 实际写在 **conductor 的 main 工作目录**（pi1 的 worktree 是 quiet-forest-161d，本不应碰主 checkout）
- **后果（已避开）**: conductor 在主 checkout 执行 `git merge --no-ff t62-flock-reopen` 时变成"merge 自己"→ "Already up to date"，且 `git push origin main` 推的是**不含修复的 9c25325**。若没核对 `git rev-parse HEAD main` 的差异，CI 会继续红且归因错误
- **根因面**: ① worker 越权使用非自己 worktree 的目录（herdr 只约束 cwd 提示，不强制）；② conductor 合入前没有 assert `merge-base --is-ancestor` / 输出解读（"Already up to date" 在 --no-ff 语境下就该警觉）
- **建议措施**（择一或组合，后续任务落地）:
  1. 派发契约模板加一条硬约束：「只在自己 worktree 目录内 commit；主 checkout 对 worker 只读（fetch 可用）」
  2. conductor 合入 SOP：merge 前先 `git -C <wt> branch --show-current` 与 `git merge-base --is-ancestor <ref> main` 双向核对，merge 后核对 `git rev-parse main` 已前进
  3. 主 checkout 可以 `git config core.worktree` 无解，但可加 pre-commit hook 拒绝非 worktree 目录？（存疑，先靠约定）
- **约定违背后果补充**: 违反「conductor worktree 常净、经 merge 整合」的反向形态（worker 侵占主 checkout）。修复方向含：conductor 集成 SOP 加机械断言 `[ "$(git branch --show-current)" = main ]` + merge 后核对 main ref 已前进；worker 契约加「commit 只准落在自己 worktree 路径」硬约束

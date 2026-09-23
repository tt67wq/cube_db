# Issue T-62 — crash 测试的 reopen 站点依赖 macOS 宽容 flock 语义，Linux CI 必红（FileLocked）

- **状态**: fixing（T-62 任务已派 cube_db-pi1）
- **发现于**: CI run 35564844844（09-21）与 35697695176（09-22，main @9c25325）— `Run full test suite` 步骤
- **失败点**: `crash_harness_test.zig:56` 与 `freelist_persist_crash_test.zig:397`（T5-r），均 `FilePageStore.init → error.FileLocked`

## 根因

`flock(fd, LOCK_EX|LOCK_NB)`：Linux 上**同进程经不同 fd 的二次 open 互相冲突**（这正是 src/file_page_store.zig:160-163 注释声称的语义）；macOS/BSD 允许同进程经新 fd 直接替换锁。测试里 parent 持有先前句柄未 deinit 就 reopen 的站点，macOS 全绿、Linux 必红。本地所有任务门跑 macOS → 盲区；GitHub Actions ubuntu 才暴露。

## 复现

`docker run` ziglang/zig:0.16.0（或按 .github/workflows/ci.yml 的 apt 步骤自建镜像），在 repo 挂载下：
`zig build test-one -Dfilter="crash harness"` 与 `-Dfilter=freelist_persist`（需 ../zio clone）。

## 影响

- CI 持续红，main 在 GitHub 视角不可信（红一次混一次真回归的风险）
- 所有「parent fork 子进程崩溃后 reopen」模式测试同源缺陷；T-38-5/6/7 系列 FilePageStore 真落盘测试都在雷区

## 修复方向

测试侧：reopen 前必须显式 deinit/close 先前句柄（不靠 defer 出块的时机差）；全仓 `FilePageStore.init` 站点普查。产品语义不变（Linux 严格互斥才是文档语义）。

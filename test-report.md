# T-39-D test report — 崩溃矩阵复验 + T-39-A 断言复验 + 确定性套件

- **Tested commit**: `7c428c2`（分支 **T-39-integration** head；src 改动 = T-39-B `a384334`）
- **Tester**: cube_db-pi-1（独立于实现者 cube_db-pi-2）
- **Env**: zig 0.16.0（asdf shim），macOS，worktree
  `/Users/admin/.herdr/worktrees/cube_db/worktree-green-harbor-6d63`
- **范围调整**: RED #1（写放大）按 conductor 指示归
  `issues/T-39-C-followup-append-only-freelist.md`，**不在本次门槛**；本次门槛 =
  崩溃安全不破坏 + T-39-A 去重/观测断言绿 + 矩阵稳定。

## 1. T-27 崩溃注入矩阵（硬门槛）— PASS，稳定

命令（经 `tests/crash_insertbatch_pb_test.zig` 聚合器跑，单文件 raw 引用会因
`../core_format` 相对导入越界而无法编译 — 聚合器是这组测试的既定运行方式）：

```
zig test --dep cube_db --dep zio -Mroot=tests/crash_insertbatch_pb_test.zig \
  --dep zio -Mcube_db=src/root.zig \
  --dep zio_options -Mzio=<zio>/src/zio.zig -Mzio_options=<shim> -lc [--test-filter T5]
```

| 项 | 内容 | 运行次数 | 结果 |
|---|---|---|---|
| T5 全注入点 | before_chain / mid_chain / after_chain_before_meta / after_meta + T5 contract | **6** | 每轮 `All 7 tests passed`，exit 0，**零 flake** |
| T5-b / T5-r | between-commits 基线 + reopen 幂等（含在上述 7 内） | 6 | 同上 |
| T6 损坏链夹具 | v0..v10 + T6 contract（16 tests，经 `tests/core_format_test.zig` 聚合） | **6** | 每轮 `All 16 tests passed`，exit 0，**零 flake** |
| 全 crash 聚合 | `crash_insertbatch_pb_test.zig` 全量（所有 fork 崩溃测试） | **3** | 每轮 `All 70 tests passed`，exit 0，**零 flake** |
| 全 core_format 聚合 | T2/T3/T4/T6/T7 + format/ps/slab/crc/mmap/cow（107 tests） | 2 | `All 107 tests passed`，exit 0 |

语义等价性：T6 的接受/丢弃判定由测试内 `want_discarded`/`want_pool` 硬断言锁定
（v0 接受、v1/v3..v9 丢弃、v2 P0-A 接受+overlap 等原意），全绿 = 判定链与 T-33 语义
等价；T5 各注入点的 landed/c3/c4 格点 + 重开可写断言原样通过。

## 2. T-39-A 断言复验（impl 分支）— 按降级范围 PASS

`tests/core_format/freelist_amp_red_test.zig`（raw zig test，同 T-39-A 验收命令）×3 轮：

| 断言 | 结果 | 说明 |
|---|---|---|
| RED #2 去重扫描（dedup_membership_probe ≤ 4K+16） | **GREEN** ×3 | 64 re-free = 64 探测（O(1)/free） |
| RED #3 静默吞错可观测（dropped_pages_oom） | **GREEN** ×3 | 字段存在，健康路径 0 |
| 命名契约 echo（4 字段名） | **GREEN** ×3 | 与 T-39-A 固定命名一致 |
| T-33 冒烟 + 崩溃 canary | **GREEN** ×3 | 未破坏既有绿路径 |
| RED #1 写放大 | 仍 RED（预期内） | `FreelistWriteAmplification`：小 commit 写 20/20 链页；归 T-39-C-followup，**非本次门槛**（文件整体 exit 1 由此项贡献，符合 conductor 范围调整） |

T-39-B 自测（src 内，`--test-filter T-39-B` 经 root 模块）：3/3 passed, exit 0
（O(1) 去重 + INV-F1 幂等 + FailingAllocator OOM 计数）。

## 3. 确定性套件 — PASS

```
zig build --summary all test-btree test-db test-writer test-mvcc test-compact \
  test-overflow test-ps test-slab test-format test-crc32
```

- Exit 0：`Build Summary: 45/45 steps succeeded; 192/192 tests passed`，十步全 success。

`zig build --summary all test`（额外）：

- Exit 0：`Build Summary: 30/30 steps succeeded; 417/418 tests passed (1 skipped)`
  （含 src mod_tests、auto-discovered 聚合器 = 崩溃矩阵、core_format 107 等；
  1 skip 为历史既有，与 T-39 无关）。

T-37 tree_depth 回归（raw，未注册进 build.zig — 既有集成备注）：

- Exit 0：`All 2 tests passed`（regression + invariant 在 a384334 上保持绿）。

## 4. 备注

- raw zig test 命令的 `--dep/-Mroot` 形式与 4 行 zio_options shim 说明见
  `tests/txn_writer_db/tree_depth_regression_test.zig` 头注（T-37-A 起的既定记录）；
  manifest 字面命令在 zig 0.16 下有 positional/-M 主模块冲突，不可直接运行。
- `zig build` 步骤树中个别 `w` 渲染为 zig 0.16 server 模式对测试 stderr 的回放
  （freelist/T7 诊断打印），Build Summary 均 success，不影响 exit code — 与 T-37-C
  评审时的分析一致，非 T-39 回归。
- 历史记录在案的 freelist/T7 fork 时序 flake（T-39 目标之一）在本轮 6+6+3 次矩阵
  运行 + 2 次 full build 中未复现。

**Overall：全部门槛项 PASS（崩溃矩阵稳定全绿 / T-39-A 去重+观测断言绿 / 确定性套件
绿 / RED #1 按降级归 follow-up）。T-39-D 完成。**

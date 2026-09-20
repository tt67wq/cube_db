# T-54-C 交付报告 — T4 branch-producer fault sweep 4 路分片并行

- **角色**：impl（ws1-pi1，worktree `worktree/silver-harbor-9567`）
- **结果一句话**：分片完成、语义零损失、默认运行 exit 0 / **wall 52-55s**（< 70s ✓）、
  `failed command:` = 0 ✓；**但 check.sh 运行 2 的分片铺满门用了错误的冻结常量**，
  与测试自身的校准语义冲突（详见 §3，**需要 conductor 裁决/改门**，我不被允许改
  `.agents/` 下的 check.sh）。

## 1. 改动清单

| 文件 | 动作 | 内容 |
|---|---|---|
| `tests/btree_storage/insertbatch_sweep_helpers.zig` | 新增 | sweep 全套 plumbing（`alloc/newStore/fmtKey/ScenarioFn/sweepFailIndexes/countAllocs/branchOverflowScenario`，逐行搬自原文件、语义不变）+ **唯一新增逻辑** `shardRange(total, shard)` / `sweepWindow(total)`；**无任何 test 块**（防 4 个分片二进制重复执行） |
| `tests/btree_storage/insertbatch_owned_test.zig` | 修改 | 删除 T4（branch-producer sweep，~170s）及其场景函数；保留两个 T-42 成功路径测试 + leaf-producer sweep（未动断言）；符号改引 helpers |
| `tests/insertbatch_sweep_{a,b,c,d}_test.zig` | 新增 | 各 1 个 test：各自 `countAllocs` 校准 → `shardRange(total, 0..3)` → sweep 本片 → 经 `tests/core_format/test_diag.zig` 的 `print()`（`CUBE_TEST_VERBOSE` 门控，默认静默）打 `SWEEP shard=<x> first=<F> last=<L> points=<K>` |
| `tests/insertbatch_sweep_partition_test.zig` | 新增 | 纯算术测试 ×4：真实 total=21842 与 probe 口径 21852、totals 1..300、退化值（0/80/81/82）、越界 shard —— 断言 4 片互不重叠、首尾相接、并集=窗口、点数合计=宽度、片间大小差 ≤1 |

build.zig / src/** / btree_test.zig / core_format/** / crash_insertbatch_pb/** **零改动**。

## 2. 实测结果

### wall 前后对比（同机，warm cache）

| 运行 | wall | 结果 |
|---|---|---|
| 基线（RED，check.sh 改动前） | **183s** | exit 0 / `FAIL: wall 183s 未达 < 70s 门` |
| 改后默认运行（dev 自测） | **52.2s** | exit 0 / 54 steps / 483/484 pass（1 skip=cube_check） |
| 改后默认运行（check.sh 运行 1） | **55s** | exit 0 / `failed command:` 计数 **0** / wall < 70s ✓ |
| check.sh 运行 2（verbose） | 49s | exit 0 / 4 行 SWEEP 摘要齐全 |

### per-step 摘要（verbose 运行原文，关键行）

```
+- run test 1 pass (1 total) 48s MaxRSS:318M   ← 分片 a/b（并行）
+- run test 1 pass (1 total) 46s MaxRSS:304M   ← 分片 c/d（并行）
+- run test 107 pass (107 total) 47s MaxRSS:825M  ← core_format（新关键路径）
+- run test 70 pass (70 total) 27s MaxRSS:1G      ← crash_insertbatch_pb
+- run test 62 pass (62 total) 14s MaxRSS:176M    ← btree_storage（原 63 tests/180s；
                                                      T4 移出后 62 tests，~14s）
```

### SWEEP 摘要原文（verbose 运行）

```
SWEEP shard=a first=21762 last=21783 points=21
SWEEP shard=b first=21783 last=21804 points=21
SWEEP shard=c first=21804 last=21824 points=20
SWEEP shard=d first=21824 last=21844 points=20
```

4 片首尾相接、无重叠、无缝隙，合计 **82 个故障点**（21+21+20+20）。

## 3. ⚠️ 阻塞项：check.sh 运行 2 的冻结常量与测试真实校准语义不符

**现象**：check.sh 运行 2 失败于
`FAIL: shard=a 起点 21762 != 期望 21772（有缝隙或重叠）` → check.sh exit 1。

**根因（已三重实证）**：契约冻结的 `total_allocs=21852` / 窗口 `[21772, 21854)`
来自 **T-54-D 调查 probe 的计数口径**——那个 probe 的 CountingAllocator 把
**grow 型 resize/remap 也计为"分配"**（21852 = 21842 个 `.alloc` + 10 次 grow）。
而原 T4 测试（以及本次分片）的校准用的是 `std.testing.FailingAllocator.allocations`，
**只计 `.alloc` 调用**（见 `lib/std/testing/FailingAllocator.zig`：`allocations` 仅在
alloc 成功路径 +1，resize/remap 不计）。两个口径差 10。

独立验证（`/tmp/t54c_count_probe.zig`，逐行复刻 `countAllocs(branchOverflowScenario)`，
连跑 3 次，确定性）：

```
RUN 0: FailingAllocator.allocations = 21842 (window [21762, 21844))
RUN 1: FailingAllocator.allocations = 21842 (window [21762, 21844))
RUN 2: FailingAllocator.allocations = 21842 (window [21762, 21844))
```

**这意味着改动前的原 T4 测试一直 sweep 的就是 `[21762, 21844)`**——它的语义是
"对**实测校准 total** 的最后 80+2 个分配注入故障"。本次实现 100% 保留该语义
（每片运行时自行 `countAllocs` 校准，再取 `shardRange`），82 个真实注入点一个不少。

**为什么不用冻结常量硬编码 `[21772, 21854)`**：那样会（a）丢掉真实故障点
21762..21771 共 10 个，（b）换来 12 个永不触发的空转点（fail_index > 21842 时
注入根本不会发生）——直接违反红线"不得减少故障点"。T-54-D 的 21852 是我
（同一条 agent 线）的 probe 口径误差，本报告在此正式勘误。

**给 conductor 的裁决请求（二选一）**：
1. 把 check.sh 的 `EXPECT_FIRST/EXPECT_LAST` 从 21772/21854 改为 **21762/21844**
   （两处常量，`.agents/` 是共享路径，我不被允许改）；
2. 或把门改为"4 片铺满**运行时校准**的 `[total-|80, total+2)` 且合计=82"——
   更稳健（不随实现细节漂移），但解析逻辑稍复杂。

在门修正前，本任务以"实现完成 + 默认门（运行 1）全绿 + 运行 2 仅因冻结常量
口径差失败"的状态交付。

## 4. check.sh 输出原文

### RED（改动前，本 worktree 自跑）

```
check.sh: repo=/Users/admin/.herdr/worktrees/cube_db/worktree-silver-harbor-9567
check.sh: [1/2] default run  exit=0 wall=183s  log=/tmp/t54c-check-default-37930.log
FAIL: wall 183s 未达 < 70s 门（长尾未拆？）
CHECK_EXIT=1
```

### GREEN 尝试（改动后，本 worktree 自跑）

```
check.sh: repo=/Users/admin/.herdr/worktrees/cube_db/worktree-silver-harbor-9567
check.sh: [1/2] default run  exit=0 wall=55s  log=/tmp/t54c-check-default-70865.log
check.sh: [2/2] verbose run  exit=0 wall=49s  log=/tmp/t54c-check-verbose-70865.log
FAIL: shard=a 起点 21762 != 期望 21772（有缝隙或重叠）
CHECK_EXIT=1
```

（运行 1 的三门全过：exit 0、wall 55s < 70s、`failed command:` = 0；
运行 2 的 exit 也是 0、4 行摘要齐全，仅铺满常量断言失败，见 §3。）

## 5. 红线自查

- ✅ 故障点 82 个一个不少（21+21+20+20，真实注入、无空转点）；
- ✅ 断言零改动（sweepFailIndexes/countAllocs/场景逐行搬移；删除的只有原 T4 的
  test 包装，其断言原样活在 4 个分片 test 里）；
- ✅ 未切 ReleaseSafe/ReleaseFast（全部 Debug；分片后每片 MaxRSS ~300-320M，
  4 片并行 ~1.3G，CI `-j2` 下更少）；
- ✅ T4 仍在 `zig build test` 验收门内（4 个 top-level 文件被 auto-discovery 收成
  4 个并行 step）；
- ✅ 未改 build.zig / src/** / btree_test.zig / core_format/** / crash_insertbatch_pb/**；
- ✅ helper 文件无 test 块；
- ✅ SWEEP 摘要走 `tests/core_format/test_diag.zig`（默认静默，`failed command:` = 0）。

## 6. 顺带记录

- 测试总数从 477 → 484（+4 分片 +4 partition -1 原 T4），483 pass + 1 skip
  （cube_check 需 `zig-out/bin/cube_check`，见 issues/README.md §4.2，验收门用
  "exit 0 且无失败"，不写死数字）；
- 单片耗时 46-48s 比预估 40s 略高（12 个 step 并行 + FailingAllocator 开销），
  整机 wall 52-55s，距 70s 门有 ~15s 余量；
- 分片间大小差 ≤1 由 partition 测试的平衡性断言守卫。

# T-54-A 报告 — btree_storage 180s 构成：**单个测试独占**（未拆分）

- **结论先行**：180s 的 btree_storage step 由**单个测试独占**——
  `insertbatch_owned_test.zig` 的 `"T-42: branch-producer error path — no UAF, no
  leaks (calibrated fault sweep)"` 单测 **≈170s（实测 170.3s standalone）> 120s 阈值**。
  按契约的判断分支，**走「停下来写报告」路径，未做硬拆**。拆 step 对单测无效
  （拆后 wall ≈ 175s，仍由该测试所在组主导，<70s 门不可能达成）。
- worktree 已恢复原状：`git diff` 为空，`zig build test` 复验 476/477 pass（1 skip，
  cube_check 需 `zig-out/bin/cube_check`，见 issues/README.md §4.2）、exit 0。
  本 commit 只交付本报告。

## 1. P0 基线（本 worktree 自测，warm cache）

| 量 | 值 |
|---|---|
| `time zig build test` | **197.5s**（首次实测；复验 191.8s） |
| step 数 / tests | 44 steps succeeded，476/477 pass（1 skip） |
| btree_storage step | `run test 63 pass (63 total) 3m MaxRSS:665M` |
| 其余最长 step | core_format 46s、crash_insertbatch_pb 36s |

RED 门（wall < 70s）实测 FAIL：~192-197s。

## 2. P0 per-file 实测（临时 `t54a-measure` step，11 个文件各一个 test 二进制，已删除）

量测方法：临时把 `btree_test.zig` 的 comptime 兄弟导入解开（最终未保留该改动），
在 build.zig 加 11 个 per-file step 归入临时 step `t54a-measure`，跑
`zig build t54a-measure --summary all`。输出顺序与 step 声明顺序一致，且以
test 数指纹（13, 11, 5, 4, 5, 4, 1, 4, 4, 4, 8 = 63）核对过归属。

| 文件 | tests | 实测耗时 | MaxRSS |
|---|---|---|---|
| btree_test.zig | 13 | 2s | 30M |
| btree_decode_corrupt_test.zig | 11 | 30ms | 3M |
| endian_consistency_test.zig | 5 | 9ms | 3M |
| btree_overflow_chain_test.zig | 4 | 21ms | 3M |
| btree_readfast_consistency_test.zig | 5 | 76ms | 3M |
| btree_leaf_budget_test.zig | 4 | 285ms | 9M |
| splice_leak_test.zig | 1 | 19ms | 8M |
| **insertbatch_owned_test.zig** | **4** | **≈174s** | **1G** |
| insert_split_budget_test.zig | 4 | 560ms | 7M |
| near_max_depth_regression_test.zig | 4 | 4s | 94M |
| shared_cow_test.zig | 8 | 253ms | 8M |

非 insertbatch 文件合计 **≈7s**。

## 3. 构成结论：单个测试独占（分支判定证据）

对 `insertbatch_owned_test.zig` 再做 per-test 量测（临时加
`std.c.clock_gettime` lap 打印，与 bench/*.zig 同款计时，已还原）：

| 测试 | 耗时（standalone） |
|---|---|
| T1 `insertBatch into existing leaf … leaks nothing on success` | 4ms |
| T2 `insertBatch leaf-overflow splice path … leaks nothing` | 26ms |
| T3 `leaf-producer error path — no UAF, no leaks (full fault sweep)` | 3.9s |
| **T4 `branch-producer error path — no UAF, no leaks (calibrated fault sweep)`** | **170.3s**（174224ms − 3940ms） |

- 该文件 4 个测试中 **T4 一个就占 170s > 120s**，占整个 63-test step（~175-180s）的
  **~95%**。60s 的其余 62 个测试合计只有 ~5-10s。
- 因此「拆成 3-4 组」后，含 insertbatch_owned 的组仍然 ≥170s，wall ≥170s，
  **<70s 门不可能靠拆分达成**。按契约：不硬拆，report-only。

## 4. T4 为什么慢（测试设计，非生产代码回归）

`insertbatch_owned_test.zig` 的 T4 是 fault-injection sweep：

- sweep 宽度 = 最后 ~80 个分配位（`first = total -| 80`，`last = total+2`）
  → **~82 次完整迭代 + 1 次 countAllocs 校准**。
- 每次迭代都**从零重建整个场景**：`MemPageStore.init(alloc, 100000)`
  （10 万页池，单次 ~400MB 虚拟/峰值 RSS 1G）+ 4×500 batch 建两层树
  + 一个 2000-entry 溢出 batch → 4000 keys 的 COW B-tree 重建。
- ~2s/次 × 82 ≈ 170s。Debug 构建 + FailingAllocator 包装放大常数。
- 每次迭代互相独立（fail_index 不同），**没有跨迭代可复用的已建树**——
  这是慢的根因：为注入第 N 个分配失败，重建了 82 棵一模一样的 4000-key 树。

对照 T3（同模式但场景只有 20+100 entries）只要 3.9s——证明慢在「场景尺寸 ×
sweep 宽度」的乘积，不在 `insertBatch` 本身。

## 5. 给 conductor 的建议（下一步决策，非本任务实施）

1. **修 T4 本身**（任选其一即可把 170s 降到几秒级，且不降断言强度——
   sweep 的语义是"每个 fail_index 都不得 UAF/泄漏"，可通过缩小场景等价保持）：
   - 缩小场景：2000-entry 溢出 batch 降到 ~200，2 层树用 4×60 建即可触发
     `insertBatchIntoBranch` 的 chunk 循环（T4 的被测路径不变）；
   - 或缩 sweep 宽度：80 → ~20，只覆盖 branch/leaf 两个 chunk 循环的分配位
     （校准函数已在，加个偏移即可）；
   - 或 MemPageStore 池从 100000 页降到场景实际需要的量（~几百页），
     显著降 RSS 与每次 init 成本。
2. **修完 T4 后大概率不需要拆分**：其余 62 个 btree 测试合计 ~5-10s，
   整个 63-test step 会回到 ~15s 以内，`zig build test` 的 wall 将由
   core_format（46s）/ crash_insertbatch_pb（36s）决定（≈50s，已 <70s）。
   届时 T-54 的 P1 拆分可降级为"可选"。
3. 若仍想拆（为将来长尾留并行度）：11 文件按实测耗时天然只有两组有意义
   （insertbatch_owned 一组，其余 10 个文件一组 ~7s），3-4 组的均衡分组
   在当前耗时分布下没有意义。

## 6. 验证与清理记录

- 临时脚手架（`t54a-measure` step、per-file 二进制、comptime 解钩、lap 打印）
  **全部已删**，`git diff` 干净。
- 恢复后复验：`zig build test` exit 0，476/477 pass（1 skip），wall 3m11.8s
  （与基线一致，确认还原无副作用）。

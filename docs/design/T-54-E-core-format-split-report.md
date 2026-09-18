# T-54-E 报告 — core_format 43s 构成：**多个中等测试累加，slab_memory 独占 62%**

- **结论先行**：core_format step（107 tests / 43s / MaxRSS 826M）**不是**单个测试独占
  （最大单测 17.8s，远低于 120s 阈值），属「**多个中等测试累加**」——但分布高度不均：
  `slab_memory_test.zig` 一个文件（2 个测试，**26.8s**）就占 step 的 **~62%**，
  其余 12 个文件合计 ~13s。
- **关键量测事实**：slab_memory 的两个测试在**同一文件**里 → 同一二进制 → 串行。
  只做 step 级拆分（文件不可分割）时，wall 下限 = 26.8s；
  要突破它必须动文件本身（拆文件或缩小场景）——那是实施任务，本任务只调查。
- worktree 已恢复原状：`git diff 89bf0f2 -- build.zig tests/ src/` 为空，
  `zig build test` 复验 exit 0（476/477 pass，1 skip = cube_check 缺二进制，
  见 `issues/README.md` §4.2）。本 commit 只交付本报告。

## 1. 基线（本 worktree `89bf0f2`，warm cache，两次实测一致）

| 量 | 值 |
|---|---|
| core_format step | `run test 107 pass (107 total) 43s MaxRSS:827M`（基线）/ `43s MaxRSS:826M`（还原后复验） |
| 闭包 | 14 个含测试文件 + 2 个 0-test 辅助文件（page_partition / test_diag）= 107 tests，与 wiring-snapshot §2 指纹精确相符 |

（`tests/core_format/freelist_amp_red_test.zig` 有 6 个测试但**不在**闭包里——
没有任何 aggregator / build.zig step 引用，属 49-orphan 家族（T-54-C 领地），
本任务未量测、未改动。）

## 2. 量测方法（照 T-54-A 的做法）

1. **临时解开** `format_test.zig` 尾部 comptime 嵌套导入（freelist_overflow /
   freelist_persist / freelist_concurrent / filelock 四个文件）——否则它们被拉进
   format_test 的二进制，per-file 归属失真。
2. 在 `build.zig` 加临时 step `t54e-measure`：13 个 per-file 测试二进制，按固定
   声明顺序 `dependOn`，跑 `zig build t54e-measure --summary all`。
3. **归属核对（不靠输出顺序猜）**：① test 数指纹逐一对上
   （21, 11, 8, 2, 15, 5, 4, 5, 5, 7, 19, 1, 4，合计 107/107 ✓）；
   ② 再用**二进制自身的进度输出**（`N/M <module>.test.<name>`，stderr）把
   `.zig-cache/o/<hash>` 目录精确映射回文件名（mtime 顺序 ≠ 声明顺序，
   这一步修正了仅靠顺序的初步配对）。
4. **step 时间含 ~600ms/二进制的 build-runner 固定开销**（13 个文件实测
   617-670ms 恒定底噪），因此另用 `/usr/bin/time -p` 直跑二进制取
   **standalone 纯运行时间**（下表以此为准）。
5. 还原：`git checkout -- build.zig tests/core_format/format_test.zig`，
   `git diff 89bf0f2` 为空，`zig build test` 复验。

## 3. per-file 实测（standalone，warm cache，--seed=0x1）

| 文件 | tests | standalone | MaxRSS | step 显示（含 ~600ms 开销） |
|---|---|---|---|---|
| **slab_memory_test.zig** | **2** | **26.8s** | 622M | 29s |
| **cow_fast_test.zig** | 5 | **4.2s** | 62M | 5s |
| **binary_search_test.zig** | 5 | **3.7s** | 57M | 4s |
| **slab_page_store_test.zig** | 8 | **2.2s** | 175M | 3s |
| **freelist_persist_test.zig** | 19 | **1.5s** | 43M | 2s |
| **freelist_concurrent_test.zig** | 1 | **1.3s** | 22M | 1s |
| format_test.zig | 21 | 0.01s | 1.5M | 648ms |
| page_store_test.zig | 11 | 0.01s | 2.3M | 622ms |
| crc32_hw_test.zig | 15 | 0.00s | 1.4M | 625ms |
| crc_regression_test.zig | 5 | 0.00s | 1.5M | 670ms |
| mmap_region_test.zig | 4 | 0.01s | 1.7M | 632ms |
| freelist_overflow_test.zig | 7 | 0.01s | 1.5M | 626ms |
| filelock_test.zig | 4 | 0.01s | 1.6M | 617ms |
| **合计** | **107** | **~39.8s** | — | — |

standalone 合计 ~39.8s + 单二进制 runner 开销 ≈ 43s，与 step 实测精确吻合
（归属核对通过）。

### slab_memory 内部（per-test，时间戳法）

| 测试 | 耗时 |
|---|---|
| `slab: large batch then delete all, memory returns`（n=100000） | **17.8s** |
| `slab: repeated insert/delete cycles, no leak`（5 cycle × n=10000） | **9.0s** |

### 其余慢文件的 per-test 构成（同法，简表）

- cow_fast：`1000 random put/overwrite/delete vs model` 2.53s + `branch child update at depth 3` 1.52s，其余 3 个 <0.1s
- binary_search：`random model test (1000 ops)` 2.16s + `multi-level tree (depth 3+)` 1.53s，其余 3 个 <0.03s
- slab_page_store：`writePage handles large page number` 1.64s + `many sequential allocations` 0.55s，其余 6 个 <0.02s
- freelist_persist：`T4 churn ×6` 1.08s，其余 18 个各 <0.12s（多数 ~0.017s）
- freelist_concurrent：单测 1.28s（1 writer + 3 readers churn）

## 4. 构成结论

**多个中等测试累加（契约分支 2）**，但要注意分布形态：

- 唯一的 heavyweight 是 slab_memory（26.8s / 62%），它自己又是两个「场景成本」
  测试的串行和（17.8 + 9.0）。慢因与 T-54-A 的 insertbatch_owned 同构：
  **测试场景尺寸 × 每操作成本**——T1 是 100000-entry putBatch + 100000 次单键
  `txn.delete`（单删除走 per-entry COW 提交路径，比批量路径贵得多）；
  T2 是 5 轮 × (10000 putBatch + 10000 单键 delete)。
- 其后是 4 个 1-4s 的文件（cow_fast / binary_search / slab_page_store /
  freelist_persist+concurrent），每个都由 1-2 个秒级「模型对照/大树/churn」测试
  撑起——同样是测试设计成本，不是生产回归。
- 剩余 7 个文件（66 tests）合计 <0.1s。

## 5. 方案对比（预估 wall；T-54-D 修掉 170s 后的视角）

| 方案 | 做法 | 预估 wall | 说明 |
|---|---|---|---|
| A. step 级 2 组拆分 | 组1 = slab_memory + slab_page_store（~29.2s）；组2 = 其余 11 文件（~11.2s） | **~30s** | 改动最小（一个顶层 aggregator 拆两个）；wall 由 slab_memory 决定 |
| B. step 级 3 组拆分 | slab_memory / cow_fast+binary_search+persist+concurrent / 其余 | ~27s | 比 A 只省 ~3s，多一个文件要维护 |
| C. A/B + **文件内拆分** slab_memory（2 测试 → 2 文件） | 17.8s / 11.2s / 9.0s 三路并行 | **~18s** | 需要动测试文件（拆成 slab_memory_batch_test + slab_memory_cycles_test），超出「纯拆 step」范围 |
| D. 优化 slab_memory 测试本身（缩场景，T-54-A §5 同款建议） | n=100000→~20000、cycles 5→3 等，断言语义不变 | **~12-16s** | 收益最大；需要独立任务评估断言等价性（本任务不实施） |
| E. 不拆 | 现状 | 43-46s | — |

**推荐**：若 T-54-C 接 49-orphan 时反正要动 core_format 的 aggregator 结构，
顺手做 **方案 A（2 组）**——纯结构性、零语义风险、43s→30s。
若想一步到位，**方案 C（再拆 slab_memory 文件）或 D（缩场景）** 能到 12-18s，
但都涉及测试文件语义层面的改动，建议单独立任务（D 优先，参照 T-54-A 对
insertbatch_owned 的处理建议）。

**预估总 wall**（T-54-D 修复 170s 后、采用方案 A）：
`zig build test` ≈ max(btree ~15s, crash 25s, core_format ~30s, txn ~?) ≈ **~30s**，
core_format 不再是长杆（长杆变 crash 组 25s 或 txn 组，视 T-54 后续任务）。

## 6. 顺带发现（记录，不实施）

- `freelist_amp_red_test.zig`（6 tests）不在任何验收 step 里，是 49-orphan 之外
  可能的第 50 个孤儿（T-54-C 接线时留意：它语义上属 core_format 系，接进组 2
  会给该组加 ~2s 量级）。
- 每个测试二进制存在 ~600ms 的 build-runner 固定开销（step 显示时间 vs
  standalone 差值，13 个文件实测 617-670ms）。**多拆二进制会线性增加这个开销**
  （拆 k 组 ≈ +k×0.6s 编排成本，warm cache 下），方案里已隐含考虑。
- slab_memory 的 MaxRSS 622M 主要来自 `MemPageStore.init(3 + 100000*10 + 10000)`
  （~110 万页指针池 + 按需 4KB 页）；分组后单组 RSS 上限 ~630M，对 CI
  `--maxrss 4GB` 无压力。

## 7. 验证与清理记录

- 临时脚手架：`t54e-measure` step（build.zig +39 行）、format_test.zig 的
  comptime 解钩——**全部已还原**，`git diff 89bf0f2 -- build.zig tests/ src/`
  为空（0 行）。
- 还原后复验：`zig build test --summary all` exit 0，44/44 steps、476/477 pass
  （1 skip）、core_format step 恢复 `107 pass 43s MaxRSS:826M`（与基线一致，
  证明闭包完整还原、无副作用）。

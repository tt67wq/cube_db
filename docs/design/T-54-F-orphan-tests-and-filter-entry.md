# T-54-F 交付报告 — 54 条孤儿测试接进验收命令 + test-one 迭代入口 + 清 2 条 nit

- **角色**：impl（ws1-pi1，worktree `worktree/silver-harbor-9567`）
- **结果一句话**：12 个孤儿文件 / 48 条已接进默认门（532 tests，exit 0，wall 58-68s）；
  `test-one -Dfilter=` 已落地（4.2s warm，命中 3 条）；2 条 nit 已清。
  **但契约第 13 个孤儿文件 `tests/core_format/freelist_amp_red_test.zig` 无法接进**——
  其 RED #1 在 main 上**本来就红**（T-39-C 已论证不可闭合并降级），接进会让
  `zig build test` 恒 exit 1，与契约门第 1 步（exit 0）自相矛盾。
  **需要 conductor 裁决**（§3），在此之前 check.sh 停在总数门 532 ≠ 538。

## 1. 改动清单

| 文件 | 动作 | 内容 |
|---|---|---|
| `build.zig` | 追加 | ① 12 个孤儿接线（见 §2，全部复用已有 run artifact + 零新增重复执行）；② `freelist_amp_red` 新 artifact 挂**命名 step** `test-t39-red`（不进默认门，见 §3）；③ `test-one` step（`-Dfilter` 编译期过滤，root = `tests/test_one_aggregator.zig`）；④ auto-discovery 循环加一行排除 `test_one_aggregator.zig`（否则它会被收成 step，双重执行它聚合的全部测试） |
| `tests/test_one_aggregator.zig` | 新增 | test-one 的根闭包：13 个域 aggregator + partition 守卫 + 13 个孤儿文件，**排除 4 个分片 sweep**（每个 ~46s，单二进制串行会毁掉 <5s 目标；它们仍在默认门里） |
| `tests/insertbatch_sweep_{b,c,d}_test.zig` | nit 1 | 文件头注释 `insertbatch_sweep_a_test.zig` → 各自文件名（copy-paste 残留） |
| `tests/insertbatch_sweep_partition_test.zig` | nit 2 | 恒真断言 `expectEqual(X, X)` → `expect(r.last_exclusive - r.first <= width)`（单片宽度不得超窗口宽度，非平凡） |

`src/**`、`issues/**`、`.woodpecker/**` 零改动；未删除/修改任何现有 step、import、test。

## 2. 孤儿接线（12 文件 / 48 条）

全部复用**已有** run artifact（它们原本只挂在 `test-db` / `test-format` /
`test-rangetomb-read` / `test-fuzz` 等命名 step 下）——build graph 对多依赖的 step
只执行一次，因此**零新增编译、零重复执行**：

| 文件 | tests | 原宿主 step |
|---|---|---|
| `txn_writer_db/range_tombstone_read_test.zig` | 15 | test-rangetomb-read |
| `core_format/range_tombstone_format_test.zig` | 10 | test-format |
| `txn_writer_db/applybatch_single_vs_multi_test.zig` | 5 | test-db |
| `fuzz/probe_test.zig` | 4 | test-fuzz |
| `txn_writer_db/delete_range_concurrent_test.zig` | 2 | test-db |
| `txn_writer_db/deleterange_mem_budget_test.zig` | 2 | test-db |
| `fuzz/api_fuzz_test.zig` | 2 | test-fuzz |
| `fuzz/api_batch_fuzz_test.zig` | 2 | test-fuzz |
| `fuzz/format_fuzz_test.zig` | 2 | test-fuzz |
| `fuzz/range_delete_fuzz_test.zig` | 2 | test-fuzz |
| `txn_writer_db/mvcc_concurrent_flush_test.zig` | 1 | test-db |
| `fuzz/meta_corrupt_fuzz_test.zig` | 1 | test-fuzz |
| **小计** | **48** | |

`fuzz/long_run_2min.zig`（1 条）按裁决**不进默认门**（保留 long-run step）。✓

## 3. ⚠️ 裁决请求：`freelist_amp_red_test.zig`（6 条）接不进——RED #1 在 main 上本来就红

**实测**（本 worktree，接进试跑）：

```
+- run test 5 pass, 1 fail (6 total)
error: 'freelist_amp_red_test.test.T-39 RED #1: small commit against a large pool must
       not rewrite the whole FREE chain' failed:
       write amplification: small commit wrote 20 chain pages, full chain = 20 pages (pool 20000)
```

**根因**（文档链完整，非新发现）：
- `issues/T-39-C-followup-append-only-freelist.md`（T-39-C 降级记录）明确写着：
  「T-39-C 的目标是让 RED #1 转绿……**正确性上不可接受**，T-39-C 按 conductor 决定降级」，
  且「RED #1 在整链重写策略下恒写满链，**正是该断言红着的真实原因**」；
- RED #2/#3 已由 T-39-B 转绿（`b11c88b`，已在 main），只有 RED #1 红；
- 该文件头注释本身就写明它**有意**不进自动发现（"do NOT edit build.zig from the
  test role" / raw `zig test` 验收），是 T-39-A 的 RED 测试纪律文件。

**契约的自相矛盾**：门第 1 步要求 `zig build test` exit 0，第 2 步要求总数 538
（含这 6 条）。两者不可能同时成立——接进 = 恒 exit 1。契约清单是闭包分析数出来的
（只数了 `test "` 个数，没跑过），RED #1 的红被漏计了。

**我的处置**（最简可行 + 不破坏默认门）：
- `freelist_amp_red` 编成**命名 step** `test-t39-red`（按需跑，同 long-run 模式），
  不进 `test_step`。默认门保持绿（532 = 484 + 48）。
- `test-one` 的聚合闭包**包含**该文件（`test-one -Dfilter=T-39` 可迭代它，RED 红
  正是迭代时想看到的信息）。

**给 conductor 的选项**（改门常量在 `.agents/` 共享路径，我不被允许动）：
1. `EXPECT_TOTAL` 538 → **532**（freelist 留在门外，RED #1 转绿之日再接进——
   即 T-39-C 重新立项之时）；
2. 或门加一条「`run test 5 pass, 1 fail (6 total)` 且失败名 = T-39 RED #1 视为
   expected-fail」——实现复杂且语义糊，不推荐；
3. 或改判「T-39 RED #1 废弃/改写」（动测试文件，超出本任务红线）。

### 裁决结果（2026-09-20，conductor）

**选项 1 被采纳。** conductor 独立核实了全部证据链（issues/T-39-C-followup
:3/:26/:106、issues/T-39-freelist-persist-write-amplification:78、测试代码 :97
起的 MissingFreelistStatsApi 守卫），确认 RED #1 在 main 上本来就红，并明确
**契约自相矛盾归因于 conductor**（初版 total=538 是闭包分析数出来的，没跑过）。
裁决：freelist_amp_red 留在默认门外（`test-t39-red` 命名 step，按需跑），
**期望总数 538 → 532**（484 + 48），check.sh 已升 v2（另新增 `failed command:` = 0
门）。理由（conductor 原则）：默认验收门必须全绿；把已知红塞进去会让红灯常态化，
真回归会被淹没。它的价值是「红着提醒 T-39-C 未闭合」，test-one 闭包包含它
（`-Dfilter=T-39` 可迭代）是正确设计。—— 即本提交前已实现的形态，无需改动。

## 4. test-one 迭代入口（P2）

- 用法：`zig build test-one -Dfilter=<子串>`（Zig 0.16 无运行期 filter，
  `Compile.filters` 编译期过滤，按 filter 值缓存）。
- **实测**：`zig build test-one -Dfilter=T-42 --summary all`
  - 预热（冷编译）10.2s；**warm 计时 4.17s / 4.22s < 5s** ✓，命中 3 条 ✓
    （两条 T-42 成功路径 + leaf sweep ~3.9s——这 3.9s 是热路径预算的大头，
    门余量 ~0.8s，见 §6 风险）；
  - `Build Summary: 4/4 steps succeeded; 3/3 tests passed`。
- 实现坑（已修，记录给后来人）：
  1. 契约示例 `t.filters = &.{f};` 会让 zig build runner **段错误**——`&.{f}` 取
     栈临时地址，make() 期读取悬垂指针（`getZigArgs` 崩在 0x100000007）。
     正确写法：`b.allocator.dupe([]const u8, &.{f})`（build-runner arena，整场有效）。
  2. 模块不能 `../` 越界：聚合器若放 `tests/one/` 会 27 个 "import of file outside
     module path"。必须放 `tests/` 顶层 + auto-discovery 循环一行排除。
- 聚合闭包 = 13 个域 aggregator + partition 守卫 + 13 个孤儿，**排除 4 个分片
  sweep**（46s×4 串行 = 3min，与 <5s 目标冲突；分片由默认门覆盖）。
  src/ 单测（mod_tests/exe_tests）是独立机制，不在 test-one 内。

## 5. 实测数字

### 前后对比

| 量 | 基线（main 85636ad） | 接进后（本提交） |
|---|---|---|
| `zig build test` | 54 steps / 484 tests / exit 0 | **78 steps / 532 tests / exit 0** |
| wall（本机，共享受载波动 48-90s） | 49-55s | **58s / 68s**（两次实测；契约明示 wall 非硬门） |
| 孤儿增量 wall | — | **~3-13s**（12 个文件全部 <1s，除 deleterange_mem_budget ~5s；其余 sub-100ms） |
| `test-one -Dfilter=T-42`（warm） | 不存在 | **4.2s / 3 hits** |

### Build Summary 原文（接进后默认运行，/tmp/t54f_run3.txt）

```
Build Summary: 78/78 steps succeeded; 531/532 tests passed (1 skipped)
```
（1 skip = cube_check 需 `zig-out/bin/cube_check`，预期内，见 issues/README.md §4.2）

新增 step 摘要（孤儿接线，全部并行）：rangetomb_read 15 tests / 15ms；
tomb_format 10 / 15ms；applybatch 5 / 23ms；delete_range 2 / 49ms；
deleterange_mem 2 / ~5s（12 文件中唯一秒级，仍远低于契约 30s 量化线）；
fuzz 6 文件合计 <150ms；mvcc_concurrent_flush 1 / 53ms。

### check.sh RED（改动前，本 worktree 自跑）

```
check.sh: [1/3] default run  exit=0 wall=49s
  steps=54/54  tests=483/484
FAIL: 测试总数 484 != 期望 538
CHECK_EXIT=1
```

### check.sh v2 终验（裁决后，本 worktree，exit 0）

裁决采纳选项 1（EXPECT_TOTAL=532）后，check.sh v2（含新增 `failed command:` = 0 门）
实跑全绿：

```
check.sh: repo=/Users/admin/.herdr/worktrees/cube_db/worktree-silver-harbor-9567
check.sh: [1/3] default run  exit=0 wall=91s  log=/tmp/t54f-default-135.log
PASS(1b): failed command: 计数 = 0
  steps=78/78  tests=531/532
PASS(2): 测试总数 532 == 532（484 基线 + 48 接进；freelist_amp_red 6 条 KNOWN-RED 例外）
  test-one: 预热 6.4s，计时 4.2s，命中测试 3 条
PASS(3): test-one -Dfilter=T-42 命中 3 条，4.2s < 5.0s
  nit 1: 3 个分片文件头注释已指向自身
  nit 2: partition 测试无 expectEqual(X, X) 形态的恒真断言
PASS: 全部通过（默认运行 wall=91s，仅记录不作硬门）
CHECK_EXIT=0
```

（wall 91s 为共享受载时段实测，契约明示 wall 非硬门、仅记录。）

## 6. 顺带记录 / 建议（不在本任务范围，写进报告供 conductor 排期）

1. **stderr 噪音回归（1 处）—— 本轮已修**（conductor 裁决授权）：`deleterange_mem_budget_test.zig`
   的 2 条信息性 `std.debug.print`（原 :218 与 :257，`[T-38-B]` 峰值诊断）改为
   **verbose 门控默认静默**（内联最小 `CUBE_TEST_VERBOSE` 判定，与
   tests/core_format/test_diag.zig 同约定；模块路径限制不能 `../` import，
   统一模块化留给 T-54-G）。断言/语义/其它行零改动；
   `CUBE_TEST_VERBOSE=1 zig build test-db` 实测诊断仍可打印。check.sh v2 的
   新门 `failed command:` 计数 = 0 已验证通过。
2. **test-one 5s 门余量薄**（4.2s vs 5s）：预算大头是 T-42 leaf sweep 的 3.9s。
   若未来机器更慢可在门上放宽到 <8s，或把 `FILTER_SUBSTR` 换成不命中 leaf sweep
   的子串（如 `shard`）。
3. `zig build test-one` **不带** `-Dfilter` 会串行跑整个聚合闭包（几分钟）——
   已在 step 描述与 aggregator 注释里写明"务必带 -Dfilter"。

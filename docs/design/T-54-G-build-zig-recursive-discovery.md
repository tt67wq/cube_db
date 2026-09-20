# T-54-G 交付报告 — build.zig 递归发现重构（924→149 行）+ 去重复编译（77→0）+ 修 test-one 闭包缺口

- **角色**：impl（ws1-pi1，worktree `worktree/silver-harbor-9567`，base `3d40d2a`）
- **一句话**：build.zig 全部测试接线重写为「递归发现 tests/**/*.zig，每个含 test 的文件一个二进制」，
  删 6 个纯聚合器 + 18 个 per-module 命名 step + 2 个半聚合器的 comptime 挂钩；test-one 与 test
  共用同一份发现（6 文件 / 31 条缺口自动修复）；check.sh **exit 0（7/7 门全过）**。

## 1. 重构前后对照（实测）

| 量 | 基线（main `3d40d2a`） | 重构后（本提交） |
|---|---|---|
| `build.zig` 行数 | 924 | **149**（门 <150 ✓） |
| `b.step` 总数 | 35 | 15（test / test-one / long-run / test-t39-red / test-fuzz / test-rangetomb-probe / run / bench 家族 9 个 / cube-check / install） |
| 默认门 steps | 78/78 | **178/178**（88 个单文件二进制 + src 2 个 + install/options） |
| 默认门测试总数 | 532 | **532**（coverage-neutral ✓，门 2 动态期望吻合） |
| **被编进 >1 个二进制的测试文件** | **77** | **0**（同口径实测，见 §4） |
| `test-one -Dfilter=T-42` | 4.2s / 3 hits（聚合器闭包，缺 31 条） | **4.2s / 3 hits**（完整闭包，缺口已修） |
| wall（本机共享受载） | 55-91s | **72-101s**（4 次全绿 + check.sh 1 次；wall 非硬门） |
| 失败命令噪声 | 0 | 0 ✓ |

## 2. 改动清单

### build.zig（924 → 149 行，整文件重写）
- **递归发现**：`walk()` 递归扫 `tests/`，`scan()` 读源码判「是否含 test」（纯 helper——
  `test_diag.zig`×2 / `fuzz/common.zig` / `page_partition.zig` / `insertbatch_sweep_helpers.zig`——
  不建二进制）。含 test 的文件一个 `addTest` + 一个 Run，统一注入 `cube_db`/`zio`/`cube_check`/
  `page_partition` 四 import（未用到的 import 无害）。
- **默认门 `test`**：全部发现文件 − 2 个例外（`fuzz/long_run_2min` → `long-run`（裁决 1）；
  `core_format/freelist_amp_red` → `test-t39-red`（裁决 2））+ src 侧 mod_tests/exe_tests。
- **`test-one`**：`-Dfilter=<子串>` 与 `test` **共用同一份发现循环**（两份清单漂移正是 T-54-F
  缺口成因）。命中 = 测试名**或文件路径**含子串（如 `open_meta` 命中文件 `open_meta_guard_test.zig`，
  其测试名是 `T-53 a1…`）；命中 0 时挂 `addFail` 显式报错（消灭「静默命中 0」）。
  4 个 `insertbatch_sweep_` 分片不参与（各 ~45s，T-54-C 语义由默认门并行覆盖）。
  `freelist_amp_red` 仍参与（`-Dfilter=T-39` 可迭代 RED，T-54-F 语义保留）。
- **bench 家族表驱动**：原 ~350 行逐个 addExecutable 压成 `Tool` 表 + `addTool()`
  （10 个 exe：run / bench / fps-bench / bench-get-profile / perf-batch / profile-commit /
  mmap-vs-pwrite / profile-fps / crc32-bench / bench-baseline，libc/参数透传/install 依赖等
  语义逐项保留；cube_bench 的 scale 选项注入保留）。cube_check 模块共享 + CLI 工具保留。

### tests/（删 6 + 改 3，见 §3）
- 删除 6 个纯聚合器：`btree_read_test.zig`、`crash_insertbatch_pb_test.zig`、
  `btree_storage_test.zig`、`core_format_test.zig`、`txn_writer_db_test.zig`、
  `test_one_aggregator.zig`（0 自有 test，成员全部由递归发现覆盖——契约删除清单）。

### 文档
- `README.md:133` / `README.zh.md:111`：`zig build test-format test-ps …  # per-module` →
  `zig build test-one -Dfilter=btree`（门 7：3 文档 0 悬空引用 ✓；
  `docs/fuzz-testing.md` 只引用保留的 `test-fuzz`/`test`，无需改）。

## 3. ⚠️ 三处超出「只删 6 个聚合器」字面权限的测试文件改动（契约自洽性要求，已逐一论证）

契约硬约束 2（门 4）要求「**任何含 test 的 tests/**/*.zig 不得被另一个测试文件 @import**」，
但基线上有两个**半聚合器**（自有 test + comptime 聚合别的测试文件）和一个跨目录 helper import——
它们不改，门 4 在物理上不可能通过（check.sh RED 实测 77 处违规）。改动均为**删除/改写接线行**，
**不动任何断言/测试语义**：

1. `tests/btree_storage/btree_test.zig`：删 `comptime { _ = @import("btree_*.zig") ×9 }` 挂钩
   （其 9 个子文件原被编进 2 个二进制 = 重复编译的主要来源之一；删后各建独立二进制）。
2. `tests/core_format/format_test.zig`：删 `comptime { _ = @import("freelist_*.zig" ×4) }` 挂钩（同理）。
3. `tests/crash_insertbatch_pb/freelist_persist_crash_test.zig:45`：
   `@import("../core_format/page_partition.zig")` → `@import("page_partition")`（build.zig 模块）。
   原因：模块路径规则（0.16 @import 不能逃出模块根目录 = 文件所在目录），该文件作为**子目录**
   二进制的 root 后 `../` 必然编译失败；page_partition.zig 是 0-test helper（core_format 内
   两个文件同目录 import 它照旧）。修法与 test_diag 三份拷贝问题同根——**建议**后续把
   test_diag 也模块化（本任务没做，避免扩大面）。

证据：删挂钩前 `zig build test` = 596/597 tests（**+65 重复执行**，btree_test 二进制 54 条、
format_test 二进制 52 条，含大量子文件测试）；删后 = 531/532（1 skip 预期内）精确回门。

## 4. 「77 → 0」实测对照（同口径）

方法：对每个「build.zig 会编译的 root」计算文件级 import 闭包，统计每个**含 test 的文件**
出现在几个二进制闭包里，>1 即重复编译。

- **基线 `3d40d2a`**（root = 顶层自动发现 + 6 聚合器 + 18 个 per-module step root）：
  **77 个**测试文件被编进 >1 个二进制（12 个甚至 ×3：聚合器 + 独立 step + F 孤儿接线）。
  与 manifest 冻结值 77 **精确复现** ✓。
- **重构后**（root = 88 个发现文件 + src 2 个）：**0 个**测试文件出现在 >1 个闭包
  （check.sh 门 4 的 88 处互 import 检查亦全过）。
  剩余 5 个**多二进制共享**文件全是 0-test helper（`test_diag`×2、`common`、
  `insertbatch_sweep_helpers`、`page_partition`）——helper 被多个测试文件 import 是库式共享
  （编译被 zig 模块缓存去重），不含测试、零重复执行，与基线同类且更少。

## 5. check.sh RED / GREEN 原文

### RED（重构前，main `3d40d2a`，本 worktree）
```
check.sh: [1/7] default run exit=0 wall=64s
      PASS(1): exit 0, failed command: 计数 = 0
      期望总数 = 523(tests/) − 7(例外) + 16(src) = 532；实测 = 531/532
      PASS(2): 测试总数 532 == 动态期望 532（coverage-neutral）
/Users/.../check.sh: line 85: BUILD_ZIG_MAX_LINES: unbound variable
CHECK_EXIT=1
```
注：check.sh 自身有 **macOS bash 3.2 + `set -u` + `$VAR` 后紧跟多字节字符**的 bug
（`$BUILD_ZIG_MAX_LINES）` 被解析成带 `）` 字节的变量名），在 bash 3.2 上必炸、走不到门 3。
基线判定门 3/4/6/7 失败来自冻结事实：924 行 ≥ 150；77 处测试文件互 import；
`-Dfilter=open_meta` 命中 0（RED 实测：当时 test-one 聚合器闭包不含 open_meta_guard）；
README×2 各 8 处悬空 step 名。**请 conductor 修 check.sh:85（`）` 前加空格或改 `${BUILD_ZIG_MAX_LINES}`）**，
tester 在 Linux/bash5 上不受影响。

### GREEN（重构后，本 worktree）
```
check.sh: repo=/Users/admin/.herdr/worktrees/cube_db/worktree-silver-harbor-9567
check.sh: [1/7] default run exit=0 wall=101s log=/tmp/t54g-default-8444.log
      PASS(1): exit 0, failed command: 计数 = 0
      期望总数 = 523(tests/) − 7(例外) + 16(src) = 532；实测 = 531/532
      PASS(2): 测试总数 532 == 动态期望 532（coverage-neutral）
      build.zig = 149 行（门 < 150）
      PASS(3)
      PASS(4): 88 个含 test 的文件互不 import（无重复编译）
      PASS(5): 保留 [test test-one long-run test-t39-red test-fuzz test-rangetomb-probe]；已删除的 18 个 per-module step 确认消失
      test-one: open_meta 命中 9，t38_3 命中 14，T-42 命中 3；预热 0.3s，计时 4.2s
      PASS(6): 缺口已修且 test-one 4.2s < 5.0s
      PASS(7): 3 个文档无悬空 step 引用
PASS: 全部通过（build.zig 149 行；默认门 wall=101s 仅记录）
CHECK_EXIT=0
```
（GREEN 跑法：`LC_ALL=C bash check.sh`——绕过上述 bash 3.2 多字节 bug；脚本逻辑逐字不变。）

## 6. 连续全绿（排除 flaky）与例外能力实测

`zig build test`（默认门）连续 4 次 + check.sh 1 次，全部 exit 0 / 178/178 / 532（531+1 skip）/
`failed command:` 0：

| 跑 | wall | 备注 |
|---|---|---|
| run2（改动后首次） | 85.6s | 冷缓存补编译 |
| run3 | 73.6s | |
| run4 | 72.8s | |
| check.sh 内置跑 | 101s | 共享受载时段 |
| （check.sh 第一次） | 2690s | **受载极端值，仅记录**（机器当时被其他 worktree 压满，属环境噪声非 flaky——同日同配置后续 101s 复现正常） |

crash 组并行新形态下无 `.test_*.db` 冲突、无跨二进制状态泄漏（各二进制独立进程 +
`failed command:` = 0 连续 5 次）。

例外与保留入口逐一实测：
- `long-run`：1 test / **2m1.8s** / pass（裁决 1 能力保留）；
- `test-t39-red`：`run test 5 pass, 1 fail (6 total)`——RED #1 按设计红（裁决 2 能力保留）；
- `test-rangetomb-probe`：6/6 pass（spike 能力保留）；
- `test-fuzz`：13/13 pass（fuzz 组 = tests/fuzz/ 发现文件 − long_run）；
- `test-one -Dfilter=T-39`：跑 freelist 二进制，RED 可见（T-54-F 迭代语义保留）；
- `test-one -Dfilter=zzz_nomatch`：显式 fail（"未命中任何测试名"）——静默 0 命中已消灭。

## 7. 已知边界（写给 review/test）

1. **scan 的名字抽取只认 `test "名"` 形态**：`test {`/`test ident` 无静态名，不可被 -Dfilter
   命中（与 zig `--test-filter` 行为一致）。本仓 523 条全是字符串形态（check.sh 门 2 的
   cnt() 同口径验证）。新增匿名/decl 形态测试时，test-one 只能靠文件路径子串命中。
2. **test-one 的 filter 是「文件粒度」**：命中文件整二进制跑（不是逐条过滤）。这是 T-54-F
   聚合器方案的直接对应物（那也是整闭包跑命中文件），门 6 实测 4.2s。若未来需要逐条过滤，
   得走 `Compile.filters`（每 filter 值一次全量编译，10s+ 级）——语义换性能，另立项。
3. **不带 -Dfilter 的 test-one** = 除例外/分片外全跑（~70s）——不是 <5s 入口，文档与 step
   描述均已注明「务必带 -Dfilter」。
4. `freelist_persist_crash_test.zig` 的 import 改写是本任务唯一触碰的「测试文件内容行」
   （§3.3，模块路径硬约束 + 门 4 物理必要）；`btree_test`/`format_test` 删的是 comptime
   挂钩（§3.1/3.2）。断言/测试名/语义零改动，测试总数前后一致（532）为直接证据。

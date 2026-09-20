# Issue T-54 — 测试效率：单个 180s step 独占 wall time + 49 个测试从不执行

- **状态**: `partial` — **P0（量准）、P1（拆长尾，主收益）、P4.1/P4.2（17GB 内存炸弹 + 日志误导）已合入 main 验收**；
  **还剩 P2（迭代入口）、P3（补漏 + 去重）、P4.3（README 说明）**。
- **发现于**: main `c09666f` 全量测试实测（conductor 调查，workspace `w1E`）
- **发现时间**: 2026-09-18
- **来源**: 项目 owner 提出「迭代后每次跑测试都要很长时间，想整理测试功能」→ conductor 实测定位
  **T-54-C（P1 实施）已完成并合入 `d56d49d`**（实现 `ws1-pi1` / 评审 `ws1-pi3` / 测试 `ws1-pi2`）
- **严重程度**: **medium-high**，三条独立痛点：
  - **效率面**：182s 里 **180s 由单个 step 独占**，且并行度只有 1.6x。开发者每次迭代都付这个成本
    （日常迭代应可 <5s）。
  - **覆盖率面**：**49 个已写好的测试从不执行**，CI 注释宣称的「全量测试」与事实不符 —— 这是漏测面。
  - **稳定性面**：长尾 step 峰值 **17 GB RSS**，而 CI 是 `-j2 --maxrss 4GB`，有 OOM / 退化风险。
- **关联**: `build.zig`（844 行）、`.woodpecker/ci.yml`、`.github/workflows/ci.yml`；
  P-5 涉及 zig `lib/compiler/build_runner.zig` 的回显行为
- **基线**: main `c09666f`（工作区干净），Zig 0.16.0 / macOS / warm cache
- **合入后实测**（main `4a27c22`，**main 检出目录**，warm cache）: `zig build test` **exit 0 /
  182.6s / 44 steps / 477/477 pass（0 skip）**；crash step 70 pass 25s MaxRSS **1G**（P4.1 前为 17G）；
  btree_storage step 63 pass **3m** MaxRSS 1G（长尾未拆，P1 待做）；core_format 107 pass 43s MaxRSS 827M
- **P1 合入后实测**（main `d56d49d`，worker worktree @ `7e0c349`，tester `ws1-pi2`）: `zig build test` **exit 0 /
  55s / 54 steps / 484 tests（483 pass + 1 skip = worktree 缺 `zig-out/bin/cube_check`）/ `failed command:` 计数 0**；
  btree_storage step **180s → 14s**；4 个分片 step 各 ~46–48s **并行**（实测并行度 ~5.1；串行则需 ~190s）；
  82 个故障点铺满 `[21762,21844)`（分片 20/20/21/21）。⚠️ 共享受载机器上第 3 次运行 wall 90s（环境噪声，见 §六）

---

## 一、现象

### 1. wall time 被单个 step 独占（主要痛点）

`zig build test` 实测 **182s wall / 297s CPU**（并行度仅 ≈1.6x），其中：

| step（归因文件） | tests | 时间 | MaxRSS |
|---|---|---|---|
| `tests/btree_storage_test.zig` | 63 | **180s (3m)** | 1.0 GB |
| `tests/core_format_test.zig` | 107 | 43s | 826 MB |
| `tests/crash_insertbatch_pb_test.zig` | 70 | 32s | **17 GB** |
| `tests/staging_concurrent_test.zig` | 7 | 18s | 143 MB |
| `tests/staging_concurrent_regression_test.zig` | 4 | 17s | 494 MB |
| `tests/get_mvcc_pin_test.zig` | 2 | 4s | 33 MB |
| 其余 16 个 step | 224 | 各 < 1s | — |

> **wall time ≡ 那一个 180s 的 step。** 所以加 `-j`、加机器、删重复测试**都动不了这 182s**。

**编译早已不是瓶颈**：每个 step 的编译都是 `cached`，耗时 83–175 ms。

```
+- run test 107 pass (107 total) 43s MaxRSS:826M
|  +- compile test Debug native cached 166ms MaxRSS:32M
```

### 2. 49 个测试从不执行

`zig build test` 的依赖只有 **21 个 step**（2 个 src + 13 个 aggregator + 6 个显式 step）。
以下测试只存在于 `zig build test-xxx` 独立 step 里，**从未进过验收命令**：

| 文件 | tests |
|---|---|
| `tests/fuzz/probe_test.zig` | 4 |
| `tests/fuzz/api_fuzz_test.zig` | 2 |
| `tests/fuzz/api_batch_fuzz_test.zig` | 2 |
| `tests/fuzz/range_delete_fuzz_test.zig` | 2 |
| `tests/fuzz/format_fuzz_test.zig` | 2 |
| `tests/fuzz/meta_corrupt_fuzz_test.zig` | 1 |
| `tests/fuzz/long_run_2min.zig` | 1 |
| `tests/core_format/range_tombstone_format_test.zig` | 10 |
| `tests/txn_writer_db/range_tombstone_read_test.zig` | 15 |
| `tests/txn_writer_db/mvcc_concurrent_flush_test.zig` | 1 |
| `tests/txn_writer_db/delete_range_concurrent_test.zig` | 2 |
| `tests/txn_writer_db/deleterange_mem_budget_test.zig` | 2 |
| `tests/txn_writer_db/applybatch_single_vs_multi_test.zig` | 5 |
| **合计** | **49** |

另有 `spike/rangetomb_probe.zig`（6 tests）同样不在验收命令内。
**整个 fuzz 套件（14 tests）从未进过 CI。**

而 `.woodpecker/ci.yml` 的注释是：

```
# 4. 全量测试 = 项目验收命令 (编译 + 全部 unit/integration tests)
- zig build test -j2 --maxrss 4GB
```

**算学校验（这是"其余确实没跑"的证明）**：

```
430 (13 个 aggregator 闭包)
+ 15 (src unit tests, mod_tests)
+  1 (src exe_tests)
+ 31 (6 个显式 step: tomb_guard 2 + open_meta 9 + t38_3_write 8
       + t38_3_punch 6 + tree_depth 2 + batch_payload 4)
= 477  ← 与实测 477/477 精确相等
```

### 3. 入口混乱 + 冷编译重复

`build.zig` 有 37–38 个 `addTest`。其中 **15 个文件同时被编进两个二进制**
（aggregator 一次 + 独立 step 一次）：

- core/btree：`btree_test`、`crc32_hw_test`、`format_test`、`page_store_test`、`slab_page_store_test`
- txn：`writer`、`mvcc`、`db`、`overflow`、`compact`、`compact_strong_assert`、`closed_state`、
  `lock_failure`、`close_flush_failure`、`txn_arena`

冷编译成本翻倍，且 `zig build test-format` / `test-btree` / `test-ps` … 共 **28 个**独立 step 名字，
其中大部分对 `zig build test` 无贡献。

### 4. 17 GB 内存炸弹

crash 组单 step 峰值 17 GB。CI 注释称「单次 zig build test 本地实测峰值 3.2GB（37 个测试二进制
并行编译）」—— 该数字只覆盖**编译**，未覆盖**运行**。运行期该 step 在受限 runner 上会退化甚至失败。

### 5. 绿色运行里出现 `failed command:`（日志误导）

`crash_insertbatch_pb` 与 `core_format` 两个 step 用 `std.debug.print` 输出诊断（写入 **stderr**）。
zig 的 `build_runner.zig` 对**成功**的 step 也回显其 stderr：

```zig
// No matter the result, we want to display error/warning messages.
if (s.result_error_bundle.errorMessageCount() > 0 or
    s.result_error_msgs.items.len > 0 or
    s.result_stderr.len > 0)
{
    printErrorMessages(...);   // 内含 "failed command: " 输出
}
```

结果：**`EXIT=0` 的绿色运行里出现两行 `failed command:`**。
本次调查因此一度误判为「main 是红的」，直到直接运行那两个二进制确认 `rc=0`、
`All 70 tests passed` / `All 107 tests passed`。

---

## 二、根因

1. **aggregator 的优化目标已经过期。**
   当初把 38 个编译单元合并成 13 个 aggregator，是为**编译时间**做的优化，且是成功的。
   现在编译是缓存且便宜（0.1s/二进制），运行才贵（180s/step），
   **aggregator 反而把运行串行化了** —— 而 zig 的 build runner 天然并行执行多个 step。
   策略应当反过来：**多拆二进制**（编译便宜，运行昂贵）。
2. **手工维护 `build.zig`。**
   38 个 `addTest` 块逐个手写 → 加测试要改 844 行文件 → 漏挂（现象 2）、重复编（现象 3）都是这个根因。
3. **诊断输出写到 stderr。**
   zig 对任何产生 stderr 的 step 都回显（"No matter the result"），
   测试的调试打印因此被渲染成看起来像失败的报告。

---

## 三、方案（分阶段）

### P0 · 先量准（0.5 天，零风险）—— **必须先做**

现在**无法**知道 180s 是"多个中等测试累加"还是"单个 170s 测试"，这决定 P1 是**拆**还是**优化**：

- 给 `tests/btree_storage/` 的 11 个文件各加一个临时 step，跑一次得 per-file 时间；
- 顺手沉淀为长期工具 `zig build test-timing`（把 `--summary all` 落盘 + 汇总）。

> **为什么不能靠运行期 filter 量**：Zig 0.16 的 test runner 只接受
> `--listen=` / `--seed=` / `--cache-dir=`（见 `lib/compiler/test_runner.zig`），
> 没有运行期 `--test-filter`。过滤是**编译期**的（`Compile.filters`）。
> 所以只能靠"拆 step"来量。

**验收**：产出 per-file（若需要则 per-test）耗时表，并给出 180s 的构成结论。

### P1 · 拆长尾（最大收益，预期 wall −70%）

按 P0 结果把 btree_storage 组分成 3–4 份。因为自动发现只扫 top-level `tests/*.zig`，
只需**新增几个 top-level aggregator 文件**即可白拿并行度：

```zig
// 现在: tests/btree_storage_test.zig  → 63 tests / 180s（串行）
// 改成: tests/btree_storage_a_test.zig + _b_ + _c_  → 3 个 step 并行
```

**预期：182s → 50–60s**（与 core_format 的 43s 同级）。
crash 组（32s / 17 GB）同样拆分，顺带缓解现象 4。

**若 P0 发现是单个测试吃 170s** → 转为优化该测试（降 N / 换 MemPageStore / 去掉不必要的 fsync）。

**验收**：`zig build test` wall < 70s，测试数与覆盖面不变（`exit 0 且无失败`，见 §5 约定）。

### P2 · 迭代入口（直接解决"每次跑都很久"）

```zig
const filter = b.option([]const u8, "filter", "只跑名字含该子串的测试");
// ...
const t = b.addTest(.{ ... });
if (filter) |f| t.filters = &.{f};   // Compile.filters（0.16 支持，编译期过滤）
```

`zig build test-one -Dfilter=deleteRange` → 秒级。
可取代现象 3 里那 28 个手工 step 中的绝大多数。

**验收**：改一个模块后，`test-one -Dfilter=<该模块>` 端到端 < 5s。

### P3 · 补漏 + 去重

1. **把现象 2 的 49 个测试接进验收命令**（决策已定，见 §六）。
   注意这会推高 wall time —— **必须与 P1 配合做**，否则等于把 182s 加长。
2. 删掉 15 个与 aggregator 重复的 standalone step（保留 2–3 个常用入口，其余交给 P2 的 filter）。
3. 用"目录自动发现"替代手工 step（扫描 `tests/<dir>/*.zig` 生成 aggregator），
   `build.zig` 844 → ~120 行。

**验收**：`zig build test` 覆盖 49 条新测试；`build.zig` < 150 行；
不存在"同一文件编进两个二进制"的情况。

### P4 · 卫生

1. 查清 crash 组的 17 GB 峰值来源，并在 CI 上加保护。
2. 测试诊断输出默认静默，`-Dverbose` 打开 —— 消除绿色运行里的 `failed command:` 误导。
3. 补 README：「怎么只跑相关测试」（目前没有此说明）。

**验收**：`zig build test` 成功时 stderr 无 `failed command:`；CI 在 `--maxrss 4GB` 下不退化。

---

## 四、收益汇总

| 阶段 | wall time | 说明 |
|---|---|---|
| 现状（立项时，main `c09666f`） | 182s | — |
| 合入 P4.1/P4.2 后实测（main `4a27c22`） | **182.6s** | 内存与日志已修，**wall 不变**（长尾未拆，符合预期） |
| + P1（拆长尾）**已达成**（main `d56d49d`） | **55s（实测）** | T-54-C：4 路分片并行；空机 54–55s，共享受载机 90s |
| + P3（接进 49 个测试） | ~65–75s | 覆盖面 +49 条，时间只涨一点（多数很快） |
| 日常迭代（P2） | **< 5s** | `test-one -Dfilter=` |

---

## 五、验收约定（遵循 `issues/README.md` §4.1）

- 验收门写成「**exit 0 且无失败**」，而**不是**「数字等于 N」—— 数字会因 P3 接入用例而漂移。
- 契约里的基线数字必须**在写契约的时刻实测**（本 issue 的 477 / 182s 均是实测值）。
- 引用全量数字时注明**在哪个目录跑的**（main 检出目录 vs worker worktree）。
  `cube_check_test.zig` 需要 `zig-out/bin/cube_check`，worktree 里通常没有 → 会 skip 1 条。

---

## 六、决策记录

| 日期 | 决策 | 说明 |
|---|---|---|
| 2026-09-18 | 立 issue T-54，**本次只落文档不改代码** | 项目 owner 决定 |
| 2026-09-18 | 49 个孤儿测试**接进验收命令**（不废弃） | 与 P1 配合，避免 wall time 反弹 |
| 2026-09-18 | **P0 结论：180s 由单个测试独占**（`tests/btree_storage/insertbatch_owned_test.zig` 的 T4 branch-producer fault sweep ≈170s），**不拆分 btree_storage** | T-54-A，`a150ca1` |
| 2026-09-18 | **P4.1 + P4.2 完成**：crash 组 17G→1G（改 smp_allocator）、测试诊断默认静默（`CUBE_TEST_VERBOSE=1` 打开）、CI 注释同步 | T-54-B，`89bf0f2`，独立评审 approve |
| 2026-09-18 | **P1 方案定为「T4 fault sweep 4 路分片并行」**（T-54-D 推荐方案 (a)：语义零损失、`build.zig` 可不动、预估 wall ~50s）。**否决** (c2) 减故障点 82→25、(d) 移出验收门（均触碰覆盖红线）；(c3) 优化模式因实测 RSS ~7–8G 爆 CI `--maxrss 4GB` 预算否决 | 待派发 T-54-C |
| 2026-09-18 | T-54-A/B/D/E 合入 main（`b43dcd6`、`4a27c22`），台账 `open` → `partial` | conductor 集成验证：477/477 pass、`failed command:` 计数 0 |
| 2026-09-20 | **T-54-C（P1）完成并合入 `d56d49d`**：T4 fault sweep 拆 4 片并行 | impl `7e0c349`（ws1-pi1）+ review **approve**（ws1-pi3）+ test **PASS**（ws1-pi2）；wall 182.6s → **55s**，82 点零损失、断言零改动 |
| 2026-09-20 | **勘误**：T-54-D 报告的 `total=21852` / 窗口 `[21772,21854)` 系其 probe 计数口径（把 grow 型 resize/remap 也计为分配）；真实 `FailingAllocator.allocations` 口径 = **21842** → 窗口 **`[21762,21844)`**（宽度同为 82） | 已核源码 `lib/std/testing/FailingAllocator.zig`（`allocations` 仅在 `alloc` 成功路径 +1）。T-54-C 保留实时校准语义；门 v2 改为从分片自报 total 推导窗口 —— 硬编码冻结常量会丢 10 个真实故障点 |
| 2026-09-20 | **wall < 70s 门余量薄**：空机 54–55s，共享受载机 90s（并行度 5.1 → 3.1，各 step 单耗不变） | CI 不受此门约束（CI 只要求 exit 0）；若把该门当本地硬 SLA，受载时会假红 |
| 2026-09-20 | T-54-C 评审留 **2 条非阻塞 nit**：3 处分片文件头注释写成 `shard a`；`tests/insertbatch_sweep_partition_test.zig:32` 一条恒真断言（`expectEqual(x, x)`） | 折进 P3 清理 —— 现在修会作废 review/test 对 `7e0c349` 的 SHA 锚点 |

---

## 七、附录：本次测量的复现方法

```bash
# 1. 全量基线（含 per-step 时间表）
zig build test --summary all          # 关注 "+- run test <N> pass (N total) <time> MaxRSS"

# 2. 退出码（确认是否全绿）
zig build test > /tmp/e.log 2>&1; echo "EXIT=$?"    # 实测 EXIT=0

# 3. 归因某个 step 到文件：用 test 数匹配 aggregator 闭包的 test 数
python3 - <<'EOF'
import os, re
def closure(p):
    seen=set(); st=[p]
    while st:
        q=st.pop()
        if q in seen: continue
        seen.add(q)
        t=open(q,errors='replace').read()
        for m in re.findall(r'@import\("([^"]+\.zig)"\)', t):
            i=os.path.normpath(os.path.join(os.path.dirname(q), m))
            if os.path.exists(i): st.append(i)
    return seen
for f in sorted(os.listdir('tests')):
    if f.endswith('.zig'):
        p='tests/'+f
        n=sum(len(re.findall(r'^test\s+"', open(x,errors='replace').read(), re.M)) for x in closure(p))
        print(f"{n:4}  {p}")
EOF

# 4. 核对"哪些 step 真的被 zig build test 依赖"
grep -n 'test_step.dependOn' build.zig      # 精确 receiver，注意别被 format_test_step 前缀干扰

# 5. 直接运行某个 step 的二进制（绕过 build runner，确认绿/红）
./.zig-cache/o/<hash>/test --cache-dir=./.zig-cache --seed=0x1
```

### 已知的测量坑（踩过，记录备查）

- `zig build test --summary all` 的 step 行**没有文件名**，只有 `run test <N> pass`；
  归因只能靠 test 数匹配（本 issue 已逐一验证吻合）。
- `grep 'test_step.dependOn'` 会**误匹配** `format_test_step.dependOn(...)`（后缀相同）。
  必须用 `(?<![\w])test_step\.dependOn` 或直接看行号。
- `.zig-cache/o/<hash>/` 的 hash **不等于** `.zig-cache/h/<hash>.txt` 的 hash，
  不能靠它反查源码；测试二进制里也没有可 grep 的 DWARF 路径。
- 那两个 `failed command:` 行**不代表失败**（见现象 5）。

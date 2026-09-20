# T-54-B — crash 组 17GB 内存峰值定位 + 测试诊断输出静默化

- **日期**: 2026-09-18
- **worktree**: `worktree-clear-field-8352`（基线 main `c09666f`，Zig 0.16.0 / macOS）
- **母 issue**: `issues/T-54-test-efficiency-long-tail-and-orphan-tests.md`（§一.4 / §一.5，§三 P4）
- **契约**: `/Users/admin/Project/Zig/cube_db/.agents/tasks/T-54-B/task.md`

## 结论速览

| 项 | 修复前 | 修复后 |
|---|---|---|
| `zig build test` 退出码 | 0（绿） | 0（绿） |
| `failed command:` 计数（全绿运行） | **2** | **0** |
| crash step（70 tests）MaxRSS | **17G**（31s） | **1G**（25s） |
| 测试数 | 476 pass + 1 skip（477） | 476 pass + 1 skip（477，不变） |
| `CUBE_TEST_VERBOSE=1` | —（原本就打印） | 原诊断全部可见（已抽验） |

1 skip = `cube_check_test`（worktree 里无 `zig-out/bin/cube_check`，见 `issues/README.md` §4.2，非本任务引入）。

## 一、RED 实测（改动前，本 worktree）

```
$ zig build test > /tmp/t54b.log 2>&1; echo EXIT=$?
EXIT=0                                              # 全绿
$ grep -c 'failed command:' /tmp/t54b.log
2                                                   # ← 门失败：绿色运行里有 2 行

$ zig build test --summary all 2>&1 | grep 'run test 70 '
+- run test 70 pass (70 total) 31s MaxRSS:17G       # ← 17G 内存峰值
```

两行 `failed command:` 的归属（stderr 内容核对）：
- crash step（70 tests）与 core_format step（107 tests）——正是契约点名的两个组。

## 二、17GB 定位：哪条测试、哪个分配

### 归属测试（三重证据）

1. **采样归因**：直接运行 crash 二进制（`.zig-cache/o/777fa…/test`），RSS 采样显示
   全程基线 ~350MB，在一次 ~1.2s 的窗口内直线涨到 16.6GB（每 0.11s +1.55GB）。
   窗口内用 macOS `sample` 抓栈，**100% 的采样落在**
   `pb_fps_ordered_test.test.FilePageStore ordered 1M putBatch`
   （`pb_fps_ordered_test.zig:40/44`，即 `try db.putBatch(entries)` 内部）。
2. **独立复现**：把该测试原样抽成单测试二进制（一次性探针，已删），
   `peak memory footprint = 16,540,119,016`（≈15.4GiB，build runner 显示 17G）。
   **不需要** 70 个测试的组合，单测即复现。
3. **vmmap 形态**：峰值时进程内 **107,524 个恰好 112KB 的匿名 SM=PRV 区域**（≈11.2GB）
   外加一条 arena 倍增链（16K→32K→…→97.2M）。即峰值不是单一巨分配，
   而是海量中等尺寸匿名 mmap 区域同时存活。

### 根因

测试用 `std.heap.page_allocator` 作为 Db/测试的分配器。`page_allocator`
**每次分配独立 mmap 并向上取整到页**，而 `putBatch` 的写入路径（btree 递归
insert、COW 页复制、`dupeEntry`、arena 节点等）会产生 ~30 万次中等尺寸的
临时分配；每次都变成独立的 PRV 匿名区域，RSS 被放大 ~50 倍
（逻辑工作集 ~300MB → 物理驻留 16.5GB）。**这是测试侧的分配器选择问题，
不是 src/ 的 bug**（同一测试换分配器，引擎行为、断言、吞吐全部不变或更好）。

### 对照实验（决定性证据）

同一测试逐字不变，只换分配器：

| 分配器 | peak memory footprint | ns/entry |
|---|---|---|
| `std.heap.page_allocator`（原） | **16,540,119,016 B（15.4GiB）** | 847 |
| `std.heap.smp_allocator`（新） | **428,524,312 B（409MiB）** | 573 |

内存 **-97%**，顺带快 **32%**（少了 30 万次 mmap/munmap 系统调用）。

### 复现步骤（修复前）

```bash
# crash 二进制（70-test step）在 .zig-cache/o/ 下，用测试数认出它：
for d in .zig-cache/o/*/; do ./"$d"/test --cache-dir=./.zig-cache --seed=0x1 2>&1 \
  | grep -q 'All 70 tests passed' && echo "$d"; done
# macOS 上测量峰值（预期 ~16.5GB）：
/usr/bin/time -l ./.zig-cache/o/<那个目录>/test --cache-dir=./.zig-cache --seed=0x1 2>&1 | grep footprint
```

### 修复

`pb_fps_ordered_test.zig`（2 处）与 `pb_fps_scale_test.zig`（1 处）的
`std.heap.page_allocator` → `std.heap.smp_allocator`（线程安全、池化复用，
Zig 0.16 标准库自带）。断言、entry 数、key/value 布局、文件路径全部不变。
其余 crash 测试用 `std.testing.allocator` 或小规模 `page_allocator`
（`filelock_test` 有注释说明的 fork 语义），不受影响，未动。

**为什么直接修而不是 CI 保护**：修复是 3 行常量替换，且顺带更快；
`--maxrss 4GB` 在修复前会在 CI 上把该 step 退化/卡死（17G > 4G），
修复后 1G < 4G，CI 现有的 `-j2 --maxrss 4GB` 同时覆盖编译与运行峰值，
不需要额外保护。已在 `.woodpecker/ci.yml` 注释里更新了
「3.2GB 只覆盖编译」的过时说法并指向本报告。

## 三、静默化方案

- **环境变量名**：`CUBE_TEST_VERBOSE`（非空且非 `"0"` 即开）。
  打开方式：`CUBE_TEST_VERBOSE=1 zig build test`。
- **实现**：两个目录各一个 9 行的 `test_diag.zig`（`verbose()` 进程内缓存一次，
  fork 子进程继承同值）。`print()` 默认不写 stderr，verbose 时透传
  `std.debug.print`。用 `std.c.getenv`（这两个 step 的测试二进制都链接 libc，
  `build.zig` 里 `mod.link_libc = true`；且契约禁改 build.zig，不需要 build 选项）。
- **分类取舍**（29 处 `std.debug.print`）：
  - **成功/信息路径**（FPS 基准数字、"consistent: N/N"、"post-write recheck OK"、
    T7 partition dump、slab 统计、T4 last_page 表）→ 走 `tdiag.print`，默认静默。
  - **失败上下文**（紧跟 `return error.X` 的打印，如 "INCONSISTENT"、"torn batch"、
    "DISJOINT VIOLATION" 明细行）→ **保留原样**。理由：绿色运行里它们不触发，
    不影响验收门；而测试红的时候 stderr 回显正是想要的调试信息。
  - `page_partition.dump` 同时被成功路径（每个 checkpoint 一行 `[T7 …]`）和失败路径
    调用，整体走静默；失败时紧随其后的重叠明细行（"page X also claimed as Y"）
    仍无条件输出，失败上下文不丢。这是本方案唯一的信息取舍。

### 验收

```
$ zig build test; echo EXIT=$?                              # EXIT=0
$ zig build test 2>&1 | grep -c 'failed command:'           # 0
$ CUBE_TEST_VERBOSE=1 zig build test 2>&1 | grep -E 'FPS ordered 1M|peak active|consistent: 100/100'
  consistent: 100/100 keys present (0=old state, 100=new state)   ← crash step
  FPS ordered 1M: 602.37 ns/entry, count=1000000                  ← crash step
  [T7 between-commits] last_page=17 …                             ← crash step
  peak active: 1592, final active: 1592                           ← core_format step
```

（verbose 模式下出现 `failed command:` 回显是预期行为——诊断又被打开了，
这正是按需打开的含义。）

## 四、改动清单

| 文件 | 改动 |
|---|---|
| `tests/crash_insertbatch_pb/test_diag.zig` | 新增（静默化 helper） |
| `tests/core_format/test_diag.zig` | 新增（同上，两目录各一份避免跨目录所有权纠缠） |
| `tests/crash_insertbatch_pb/pb_fps_ordered_test.zig` | allocator ×2 替换 + 2 处 print 静默 |
| `tests/crash_insertbatch_pb/pb_fps_scale_test.zig` | allocator 替换 + 1 处 print 静默 |
| `tests/crash_insertbatch_pb/crash_putbatch_test.zig` | 1 处 print 静默（失败打印保留） |
| `tests/crash_insertbatch_pb/freelist_persist_crash_test.zig` | 2 处 print 静默（失败打印保留） |
| `tests/core_format/page_partition.zig` | `dump` 静默（失败明细保留） |
| `tests/core_format/slab_memory_test.zig` | 4 处 print 静默 |
| `tests/core_format/freelist_persist_test.zig` | T4 last_page 表静默（失败打印保留） |
| `.woodpecker/ci.yml` | 注释更新：运行峰值已修（17G→1G），诊断默认静默说明 |

（顺带：`crash_putbatch_test.zig` 被 `zig fmt` 补了文件末尾换行，无语义变化。）

## 五、未做 / 边界

- **未改 `build.zig`**（契约禁改，属 T-54-A/T-54-C 串行域）；静默化走运行期
  env 判断，不需要 build 选项。
- **未改 `src/**`**：17GB 的放大机制里 engine 写路径的分配次数（~30 万次/百万条）
  属于已知 COW-batch 设计，测试换池化分配器后完全可控，不构成生产缺陷。
  若未来要对 `smp_allocator` 之外的宿主（如嵌入式自定义分配器）做大批量
  putBatch，建议在文档层面提示「避免 per-alloc mmap 型分配器」。
- **未动 `tests/btree_storage/**`**（T-54-A 领地）。
- crash step 剩余的 1G 峰值主要来自 fork 测试与 smp 池保留，已低于 CI 4GB 上限，
  未再深挖（收益递减）。

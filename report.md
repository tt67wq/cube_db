# T-61-1 Report — 测试基建三件套：fuzz 真 seed + Linux 门模板 + T-63 流程断言

- **分支**: `t61-infra`（基于 main `652c319`）
- **结论**: **GREEN** —— check.sh 5/5 PASS（gate rc=0）
- **src/ 改动**: **0**；改动面 = `build.zig` + `tests/fuzz/` 9 文件 + `.agents/tasks/_template/` 新目录

## 1. fuzz 真 seed（转发链路）

```
zig build test-one -Dfilter=fuzz -Dfuzz-seed=0xc0ffee
  → build.zig: b.option([]const u8, "fuzz-seed", ...)          # build 选项（hex/dec 字符串原样）
  → run.setEnvironmentVariable("CUBE_FUZZ_SEED", s)            # 每个测试二进制 run step 转发（含 test/test-one/long-run 全部递归发现二进制）
  → tests/fuzz/common.zig resolveSeed(): std.c.getenv("CUBE_FUZZ_SEED")
      ├─ 已设且可解析（0x hex / 十进制）→ 用它 + 回显 `fuzz seed=0x…`
      └─ 未设/非法 → std.testing.random_seed（行为与改动前一致）
  → 8 个 random_seed 站点（7 文件）全部改走 fuzz.resolveSeed()
```

- 不设 `-Dfuzz-seed` 时 build.zig 行为零变化（无 env、无输出）。
- 与 zig build 自身 `--seed`（图遍历随机，T-61 issue 的误会本体）完全正交。

### 打印策略——对任务文本的一处偏离（有意，理由如下）

任务原文「未设则回退随机并在**测试开始时** println 实际 seed」。实测发现无条件
在测试开始打印会撞上 T-54-B 已裁决的机制：listen 模式下测试二进制**任何** stderr
输出都会被 build_runner 记为 `result_stderr`，即使 step 成功也回显 `failed command:`
行（本机复现：无条件打印版 `zig build test-one -Dfilter=fuzz` rc=0 但 6 条
`failed command:`）——这会打爆所有 gate 的 fc=0 检查（gate5/全量门/T-62 门等）。
故按 T-54-B 既定约定拆两路：

- **显式设 seed**：resolveSeed 即回显（用户明确要求固定，回显是预期行为）→ gate1 依赖此
- **未设（CI 默认）**：成功路径零输出（gate5 fc=0 ✓）；**失败路径**由
  `fuzzLoop`/`fuzzLongRun` 的 target 错误分支打印
  `fuzz seed=0x… — replay with: CUBE_FUZZ_SEED=0x…` —— 满足任务的真实意图
  「红的时候 CI 日志可直接抄」。（panics 不经此路径，但 panic run 本身红、
  zig 会打印 panic 现场；error 路径是 fuzz 假红的主通道）

### 确定性实证（注入物未提交，已还原）

临时注入 `api_fuzz_test.zig` 探针打印每个输入前 8 字节（RNG 序列的直接函数）：

| run | seed | 前 3 个输入头 |
|---|---|---|
| 1 | 0xc0ffee | `6979597f6efd75d1` `2296b83beda63b59` `e127cb6cebbdeb8d` |
| 2 | 0xc0ffee | `6979597f6efd75d1` `2296b83beda63b59` `e127cb6cebbdeb8d` ← **逐字节一致** |
| 3 | 0xdeadbeef | `e2e0808b33a6742b` `32e1ec5a1f69aa0d` `0694f371d84b8b7f` ← 不同 |

同 seed 双跑序列一致 ✓；换 seed 序列变 ✓（100 输入全比对一致）。探针注入物已
`git checkout` 还原，工作区 diff 只含正式改动。

## 2. Linux 门模板化（.agents/tasks/_template/）

- **`linux_gate.sh`**：T-62 容器配方通用化。参数 = 仓库路径 + ref + filter 列表 +
  `GATE_IMG`（默认 `t62-debian-arm64`）；git archive → 容器原生 fs → 逐 filter
  `zig build test-one -Dfilter=<f>` → 汇总退出码。自动补装 libc6-dev/linux-libc-dev。
- **`README.md`** 三条铁律：
  1. 不许 `-v` 挂 macOS 卷测 flock（virtiofs 透传 macOS 宽容语义 → 假绿/假红）
  2. 无官方 zig 0.16.0 镜像层（pull 404）；自建镜像 + `/usr/local/bin/zig` wrapper
     注入 `-Dcpu=apple_m1`（aarch64 baseline 缺 CRC 扩展，crc32_hw.zig 内联 asm 需要）
  3. arm64 容器 → x86_64 CI 外推边界：flock/进程/信号语义是内核层可外推；
     CRC 硬件路径不覆盖；qemu 跑 zig 编译器 SEGV 不可用；**CI 真绿才是终审**
- **`task.md.example` / `review-task.md.example`**：含 T-63 硬约束行 + 结构占位，
  后续派单直接复制。

## 3. T-63 流程断言（模板文本，零代码）

- 两个 example 模板均含硬约束行：「**commit 只准落在你的 worktree 路径内；主
  checkout 是 conductor 领地**」
- `_template/README.md` §T-63 给出集成侧机械断言示范（conductor 合并前自用）：

```bash
[ "$(git -C <主checkout> branch --show-current)" = "main" ] || echo "BLOCK: 主 checkout 不在 main，拒绝合并"
```

## 门逐条（bash check.sh <worktree>）

| 门 | 结果 |
|---|---|
| gate1 `-Dfuzz-seed=0xc0ffee` 双跑 + seed 回显 | PASS |
| gate2 fuzz 默认（随机）绿 | PASS |
| gate3 模板目录齐备 | PASS |
| gate4 src/ 零 diff | PASS |
| gate5 全量 suite rc=0 fc=0 | PASS |

RESULT: PASS (5/5)，exit 0。

## 备注

- `long_run_2min.zig` 的 seed 站点也一并接入 resolveSeed（在 tests/fuzz/ 内，属
  ownership 范围）；long-run step 不吃 -Dfuzz-seed 之外的转发差异（同一
  setEnvironmentVariable 路径，行为一致）。
- 未触碰 crash 系列（T-53-1 pi1 地盘）与 src/。

## Round 2（review @bc2311e 收口：B1 裁决 + NB1/NB3/NB4）

**B1 裁决（conductor 采纳 review 建议方向）**：显式 seed 的成功路径回显走
**CUBE_TEST_VERBOSE 门控**（tdiag 同款约定），失败路径打印保持无条件——
「红时 CI 日志可直接抄」的契约真实意图不受损。契约原文「seed 打印走 stdout 且
每次开跑都印」经评审核实在 `--listen=-` 下物理不可实现（stdout 是 runner IPC
协议通道；stderr 必撞 fc 噪音），按裁决记入任务口径：**失败路径必印 + 显式
seed 时 verbose 门控回显**。

代码改动（tests/fuzz/common.zig，R2 唯一代码面）：

- `verbose()`：CUBE_TEST_VERBOSE 解析（test_diag.zig 同款：值非空且非 "0"，进程内缓存）
- 显式 seed 回显 → `if (verbose()) printSeed(s)`（B1：与跑门并用时零 stderr）
- **NB1**：非法 `CUBE_FUZZ_SEED` 不再静默回退——verbose 门控告警
  `ignoring invalid CUBE_FUZZ_SEED='<值>' — using random seed`

### B1 修复实证（fc=0 证据表，评审者探针同口径复测）

| run | seed | CUBE_TEST_VERBOSE | rc | failed-command 计数 | `fuzz seed=` 行 |
|---|---|---|---|---|---|
| 1 | 0xc0ffee | 未设 | 0 | **0**（B1 修复前为 6） | 0 |
| 2 | 0xc0ffee | 1 | 0 | 6（verbose 回显，预期噪音） | `fuzz seed=0xc0ffee` ✓ |
| 3 | banana | 1 | 0 | — | NB1 告警 `ignoring invalid CUBE_FUZZ_SEED='banana'` ✓ |
| 4 | 未设 | 未设 | 0 | 0 | 0（gate2 行为不变） |

→ 任何开发者 `-Dfuzz-seed` 调试 + 跑任何 fc=0 门 = 干净通过（假红通道关闭）。

**NB3**：`.agents/tasks/T-61-1/check.sh` 以 `git add -f` 提交进本分支（此前仅存
conductor 主 checkout 磁盘，门结论不可从分支复现）——本 commit 起 gate 可复现。
conductor 磁盘副本请以本分支版本为准（gate1/gate2 已按 B1 裁决重写，见下）。

**NB4**：check.sh gate1 重写 + gate2 文案修正（"green + prints seed" →
"green (silent on success — correct post-B1 behavior)"）。gate1 现在锁三件事：
(a) 固定 seed 成功路径 **fc=0**（B1 回归断言）；(b) `CUBE_TEST_VERBOSE=1` 下
seed 回显可见；(c) 非法 seed verbose 告警（NB1）。gate2/3/4/5 逻辑未动。

NB2（README 断言 exit 1 / 脏主 checkout 检查）与 NB5（非 dpkg 镜像 guard）不在
本轮裁决范围，未动。

### R2 门逐条（bash .agents/tasks/T-61-1/check.sh <worktree>，分支内版本）

| 门 | 结果 |
|---|---|
| gate1 seeded: fc=0 w/o verbose + echo under verbose + invalid warn | PASS |
| gate2 fuzz default green (silent on success) | PASS |
| gate3 模板齐备 | PASS |
| gate4 src/ 零 diff | PASS |
| gate5 全量 suite rc=0 fc=0 | PASS |

RESULT: PASS (5/5)，exit 0。

# Issue T-56 — `api_batch_fuzz_test.zig` 依赖随机 seed，使默认门（及 CI）非确定性 flaky

- **状态**: `open`
- **发现于**: T-38-4 实现（`ws1-pi1`）报告「环境/既有问题 1」；conductor **独立复现并定责**
- **发现时间**: 2026-09-20
- **来源**: T-38-4 的验收门 `zig build test` 反复出现「同一 commit 时绿时红」
- **严重程度**: **medium**（CI 假红 / 掩盖真回归；且失败模式之一是 **SIGSEGV use-after-free**，
  不排除背后有真缺陷）
- **关联**: `tests/fuzz/api_batch_fuzz_test.zig`、`build.zig`（seed 传递）、
  `.woodpecker/ci.yml`、`.github/workflows/ci.yml`；关联 main `50af0d1`

## 现象

`zig build test` 的 seed 每次随机。约 **10%** 的 seed 会让 `api_batch_fuzz_test.zig` 失败
（本任务树上 20 个 seed 中 2 个失败）。已观察到**两种**失败模式：

| seed | 现象 |
|---|---|
| `0x37c6c92f` | smoke 测试 **SIGSEGV**：`execOneOp`（:146 附近）释放 `del_keys[i]` 时指针已是 `0xaa` 填充（free 后的 undefined 填充）→ **use-after-free / double-free** |
| `0xd184e5f9` | `error.ModelMismatch`（:113 附近，`get_all`：model 里的 key 在 db 里取不到） |

## 复现（conductor 实测）

```
zig build test --seed 0xd184e5f9      # exit 1, error.ModelMismatch
zig build test --seed 0x8c40347c      # exit 0（全绿）
```

`--seed` 会被转发到 test runner（失败日志的 `failed command:` 行里带 `--seed=0x…`，可原样复跑）。

## 定责（已完成，与本任务无关）

- 在**干净基线** `8cf3e29`（T-38-4 的 RED 提交）上，用同一 seed 同样失败 → **先于 T-38-4 存在**。
- `api_batch_fuzz_test.zig` 只用 `putBatch` / 按 key 删除，**从不触碰 `deleteRange` / 墓碑链**，
  即 T-38-4 的改动对它是惰性代码路径。
- T-38-4 的门因此把门 1 固定为 `--seed 0x8c40347c`（见 `.agents/tasks/T-38-4/check.sh` 注释）。

## 影响

- `zig build test`（CI 的测试步）有 ~10% 概率**假红**，会掩盖真回归、浪费排查时间。
- 失败模式 2（`ModelMismatch`）**不能排除是真 DB 缺陷**：如果 model 簿记是对的，
  那就是「写进去的 key 读不回来」——那是数据面问题，比测试 flaky 严重得多。必须先查清。

## 处置建议

1. **先查 SIGSEGV**：确认是测试自身的簿记 bug（`del_keys` 释放两次 / 释放后仍用）还是
   DB 侧返回了悬垂指针。定位到具体行后，若纯属测试簿记 → 修测试。
2. **再查 ModelMismatch**：用失败 seed 抓最小复现；判断是 model 记账错还是 DB 真丢了 key。
   若是后者 → 按数据面缺陷另立 issue（高优先级）。
3. **短期止血**：CI 与各任务的验收门固定 seed（T-38-4 已如此做），避免假红。
4. **长期**：修根因后恢复随机 seed（fuzz 的价值就在随机覆盖）。
5. 修完后在 `issues/README.md` §4 记录「测试总数口径」的经验教训：
   `zig build test` 的汇总计数**只统计本次实际执行的 run-test step，缓存命中的计 0**
   —— 报总数必须用**冷缓存 + `--summary all` + 绿跑**，否则会得到偏小的假总数
   （T-38-4 期间 conductor 就被这个机制误导过一次：实测 539 vs 真实 543）。

## 验收

- 随机 seed 连跑 ≥ 50 次全绿（或明确记录仍存在的失败率与原因）；
- 若 `ModelMismatch` 被判定为 DB 缺陷，则本 issue 只关「测试簿记」部分，数据面部分另立；
- 修完后 CI 的 `zig build test` 恢复随机 seed 且稳定。

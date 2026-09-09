# T-34 ws1-pi-2 — 并发 staging 修复测试报告（阶段 B）

- 被测 commit（GREEN）：`20f7402`（main；RED 参考 `121df34`）
- impl 方案：独立 `staging_mutex` 保护 pending append/threshold 判定；`flush()` 在
  staging 锁内原子 steal 整表，释放锁后走 `write_mutex` 提交；`close()` auto-flush
  同路径，失败残余在 staging 锁内清理
- test worker 分支：`T-34-test`（基于 20f7402；含阶段 A 测试计划 commit `2a49082`，
  系原 `90d54a0` cherry-pick 恢复——worktree 分支曾被重置到 main HEAD）
- 测试文件：`tests/staging_concurrent_test.zig`（impl 的 T1–T3 + 本次补充 T4–T7）
- 日期：2026-09-09

## 1. 运行结果

| 模式 | 命令 | 结果 |
|---|---|---|
| Debug | `zig build test` | **exit 0，392/392 passed，24/24 steps succeeded**；staging 二进制 7/7 |
| ReleaseSafe | `zig build test -Doptimize=ReleaseSafe` | **exit 0，392/392 passed**；staging 二进制 7/7 |
| Debug 重复 ×3 | `zig build test`（竞态概率性，连续多轮） | 3/3 轮 392/392 全绿 |

staging_concurrent_test.zig 7 个测试（Debug 耗时约 5s，ReleaseSafe 约 2s）：

| # | 来源 | 场景 | 结果 |
|---|---|---|---|
| T1 | impl | 4 线程并发 put + threshold=16 自动 flush：计数/全值校验精确 | PASS |
| T2 | impl | 4 线程 put + 独立 flusher 线程（threshold 极大）：不丢不重 | PASS |
| T3 | impl | 并发 put+delete 混合：最终状态不定但自洽 | PASS |
| T4 | test 补充（M8） | `batch_threshold==0` 直通路径并发 put 回归：精确不丢、值正确 | PASS |
| T5 | test 补充（M3） | 确定性并发 delete（4 线程互异子集，纯 staging）：全表清空、计数为 0 | PASS |
| T6 | test 补充（M6） | close auto-flush：join 后不手动 flush 直接 close，同 store reopen 验证全部落盘 | PASS |
| T7 | test 补充（M7） | deleteRange 与并发 staging 交错 1s：范围外 key 零丢失（精确）、无幻影、值无损坏、entryCount==扫描数 | PASS |

回归：group_commit / group_commit_ext / db / mvcc 等既有套件含于 392 内全绿
（M9 ✅）。`std.testing.allocator` 泄漏检查干净（含 reopen 场景的两次 open/close）。

## 2. 覆盖评估（对照阶段 A 测试计划 M1–M9）

- M1/M2 ✅ T2（threshold 极大纯 staging）/ T1（自动 flush）
- M3 ✅ T5（本次补充）
- M4 ✅ T3
- M5 ✅ T2
- M6 ✅ T6（本次补充；join-then-close 口径，理由见计划 §5）
- M7 ✅ T7（本次补充）
- M8 ✅ T4（本次补充）
- M9 ✅ 全量回归

## 3. 发现的缺陷

**范围内（staging 线程安全）：未发现缺陷。** 全部判定标准满足：不丢写（确定性计数
精确）、无 panic/SEGV/双重释放、Debug 与 ReleaseSafe 双绿、无回归。

范围外观察（F-1 模式标注，均不阻塞本任务）：

1. **F-1（已知基线噪音，非本任务引入）**：`zig build test` 输出 2 行
   `failed command:`，对应 core_format/filelock 测试二进制（fork + listen 模式下
   的既有怪癖）；单独运行该二进制 107/107 通过，Build Summary 仍 24/24 succeeded、
   exit 0。基线（cc81df3）同样存在，与 T-34 无关。
2. **F-1（契约边界说明，非缺陷）**：close 返回后继续 put 属对已释放 Db 的 UAF，
   超出 T-34 契约；T6 按 join-then-close 口径覆盖 close auto-flush 的正确性。
   若未来需要"close 与 in-flight put 并发"语义（如 drain-then-close API），
   应立新任务。

## 4. 结论

test-report@20f7402：T-34 并发 staging 修复（staging_mutex + 原子 steal）在
Debug 与 ReleaseSafe 下全部通过（392/392，staging 7/7，Debug 连续 4 轮绿），
不丢写、无损坏、无回归，未发现范围内缺陷 —— **判定通过**。

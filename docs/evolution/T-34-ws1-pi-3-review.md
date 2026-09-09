# T-34 正式评审（阶段 B）— U-13 pending 微批 staging 线程安全

- 评审人角色：review worker（ws1-pi-3）
- 被评审范围：`121df34..20f7402`（RED = `121df34`，GREEN = `20f7402`，已合入 main）
- 被评审 SHA：**20f7402**
- 评审计划：`docs/evolution/T-34-ws1-pi-3-reviewplan.md`（阶段 A）

## Verdict: **approve**

无阻塞性正确性问题。发现 3 条非阻塞备注（见 §3），不构成 changes-requested。

## 1. 逐项核对（按评审计划 C1–C7）

### C1. staging 锁作用域 — 通过
- `src/db.zig:37-49`：`staging_mutex` 字段 + 锁纪律注释（只护 pending 的
  append / steal / threshold 判定）。
- `src/db.zig:122-127`（put）/ `src/db.zig:136-141`（delete）：append 与
  `pending.items.len >= batch_threshold` 判定**同在** staging 临界区内；
  `do_flush` 布尔传出锁外后再调 `flush()`，锁内不做提交、不做 I/O。✓
- dupe 回滚：dupe 在锁外，`append` 失败时 k/v 已入列的内存由后续
  flush/close 的统一 free 路径回收（append 失败则条目未入列，k/v 由调用
  方……实际为泄漏路径，见 §3-N1，非阻塞）。

### C2. flush 原子性（清空+提交）— 通过
- `src/db.zig:170-176`：staging 锁内整体 **steal**（`stolen = self.pending;
  self.pending = .empty`）后放锁；`src/db.zig:185` 才走 `putBatch`。
  属评审计划认可的"形态 A"（steal-then-commit 所有权转移）：每条 pending
  entry 恰好被一个 flusher 取走并提交一次。
- 并发 flush：两个线程同时进入，后拿锁者见 `len == 0`（`src/db.zig:173`）
  直接 no-op 返回 —— 无重复提交、无丢条目（steal 之后新 append 的条目留在
  pending，等下一轮 threshold/显式 flush）。
- free 恰好一次：`src/db.zig:177-183` 的 defer 只 free `stolen`，且在
  `putBatch`（仅借用 slice，applyBatch 内部 dupe）返回之后执行。✓
- flush 失败：stolen 批被 free、error 上抛（丢弃并报错）—— 与修复前语义
  一致，是明确定义的归宿，非回归。

### C3. close auto-flush 安全 — 通过
- `src/db.zig:82-94`：`flush() catch {}` 后持 `staging_mutex`（`lockUncancelable`，
  void 析构路径无取消点，用法正确）free 残留条目 + `clearRetainingCapacity`，
  与 flush 内部的 steal/free 不会重复（flush 成功后 pending 已空）。
- `pending.deinit`（`src/db.zig:94`）在锁外 —— 见 §3-N2，非阻塞。

### C4. batch_threshold == 0 不回归 — 通过
- `src/db.zig:115` / `src/db.zig:133`：`batch_threshold == 0` 直通
  `putDirect`/`deleteDirect`，不触碰 staging 锁；空 pending 的 flush 仍是
  no-op（`src/db.zig:173`）。路径语义与修复前一致。

### C5. 无死锁论证（zio.Mutex 非递归）— 通过
- 全文件 `staging_mutex` 获取点仅 4 处：put（:123）、delete（:137）、
  flush（:171）、close（:87，lockUncancelable）。**没有任何一处**在持有
  staging 锁时调用 `putBatch`/`beginWriteTxn`/任何取 `write_mutex` 的路径：
  - put/delete：`do_flush` 传出锁外（:129/:143）再调 flush；
  - flush：steal 后放锁（:172 defer）再 `putBatch`（:185）；
  - close：flush 完整返回后才取 staging 锁。
- 无自锁可能：threshold 触发的 flush 从不在 staging 临界区内执行。✓

### C6. 锁序不成环 — 通过
- 全库锁序恒为 `staging → 释放 → write_mutex`（两锁从不同时持有）。
- 反向路径核查：`putBatch`（write_mutex 临界区，`src/db.zig:188-215`）、
  `beginWriteTxn`、`WriteTxn.commit/deinit`（`src/db.zig:319-436`）均不
  获取 staging 锁、不触碰 `Db.pending`（WriteTxn 用的是自己的
  `staging_arena`，与 `Db.pending` 无关）。`deleteRange`（`src/db.zig:226+`）
  先 `flush()`（锁已释放）再 select 再 `putBatch`，无嵌套。
- `src/writer.zig` 的 "pending" 均为 `pending_free`（页回收，独立
  `pending_free_mu`），与 Db staging 无交集。锁依赖图无环。✓

### C7. TDD 与测试 — 通过（已实测）
- **RED 验证**（本评审独立复跑，checkout `121df34`）：
  3 个 staging 测试全部崩溃 —— T1 ABRT（workerPuts panic）、T2 SEGV、
  T3 ABRT。确为暴露原竞态的有效 RED，非假 RED。
- **GREEN 验证**（本评审独立复跑，HEAD = `20f7402`）：
  `zig build test` Debug exit 0；`zig build test -Doptimize=ReleaseSafe`
  exit 0。新并发测试（`tests/staging_concurrent_test.zig`：4 线程 × 250
  写 + threshold 自动 flush 不丢写；put + 独立 flusher 线程；put/delete
  混合自洽）与现有 group_commit / group_commit_ext / db / crash-recovery
  测试均绿，无回归。
- 测试由 `build.zig` 的 tests/ 自动发现机制接入（`build.zig:237-260`），
  `zig build test` 实际执行。✓

## 2. 结论

实现选择了评审计划预判的最小正确方案：独立 `staging_mutex` 只护内存
结构，flush 原子 steal 后放锁再提交；无锁嵌套、无自锁、无环；RED→GREEN
两步经独立复跑验证成立；直接路径无回归。**approve**。

## 3. 非阻塞备注（不构成 changes-requested）

- **N1**（`src/db.zig:117-118`、`src/db.zig:134-135`）：dupe 在取锁之前，
  `staging_mutex.lock()` 失败返回 `error.LockFailed` 时 k/v 内存泄漏。
  仅 zio 取消路径可达，概率极小；可在后续任务顺手把 dupe 挪进临界区或
  失败分支补 free。
- **N2**（`src/db.zig:94`）：`close` 中 `pending.deinit` 在 staging 锁外。
  close 与并发写共存本就是契约外用法（close 后 state 即销毁），现状不
  比修复前差；如追求形式完备可把 deinit 挪进临界区。
- **N3**（`src/db.zig:177-184`）：flush 的 putBatch 失败时 stolen 批被
  丢弃（free + 上抛 error）。与修复前语义一致、归宿明确，仅提示：若未来
  需要 at-least-once 语义，此处是扩展点。

---
被评审 SHA：20f7402（RED 121df34）· 评审复跑环境：Debug + ReleaseSafe 均 exit 0

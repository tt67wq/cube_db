# 测试套件建设综合报告

> 由 `w1-pi1`（T-1：core_format + btree_storage + bench）和 `w1-droid1`（T-2：txn_writer_db + crash_insertbatch_pb + fuzz）并行分析，conductor 交叉比对汇总。两份报告在方向上一致、无矛盾结论。
>
> 生成日期：2026-08-31
> 最后更新：2026-09-01（补全进度跟踪）
> 原始报告：`w1-pi1` 分支 commit `cc94ed7`（`docs/test_gap_T1.md`）、`w1-droid1` 分支 `59abf5c`（`docs/test_gap_T2.md`）

## 进度总览

| 优先级 | 总数 | ✅ 已完成 | ❌ 未开始 |
|---|---|---|---|
| P0 必补 | 14 | 8 | 6 |
| P1 应补 | 13 | 6 | 7 |
| P2 可选 | 6 | 0 | 6 |

> 额外完成（报告外）：端序统一重构（T-8 测试 + T-9 源码 37 处 `.big`→`.little` + T-10 review + T-11 讲义更新），消除 btree payload 端序混用陷阱。

---

## 一、P0 必补缺口（共 14 项，按风险排序）

### 持久化信任边界错误路径（全零覆盖）

| # | 状态 | 位置 | 缺口 | 建议文件 | 验收 |
|---|---|---|---|---|---|
| 1 | ❌ 未开始 | `src/file_page_store.zig:162` | `ensureFileGrowth` 的 fstat/ftruncate/fsync 失败路径无测试 | `tests/core_format/file_page_store_error_test.zig` | `zig build test-ps` |
| 2 | ❌ 未开始 | `src/file_page_store.zig:225` | `vtWriteMeta` 的 last_page 覆盖 + meta 交替逻辑 reopen 后未断言字段值 | `tests/core_format/file_page_store_meta_test.zig` | `zig build test-ps` |
| 3 | ❌ 未开始 | `src/file_page_store.zig:243` | `vtSync` 的 `error.SyncFailed` 未测 | 同 #1 文件 | `zig build test-ps` |

### B-tree 反序列化信任边界（全靠黑盒间接覆盖）

| # | 状态 | 位置 | 缺口 | 建议文件 | 验收 |
|---|---|---|---|---|---|
| 4 | ✅ 已完成 | `src/btree.zig:39` | `readNodePayload` CRC 损坏→`error.CorruptCrc` 零直接测试 | `tests/btree_storage/btree_decode_corrupt_test.zig` | `zig build test-btree` |
| 5 | ✅ 已完成 | `src/btree.zig:217` | `decodeLeafPayload` 6 处 `error.Truncated` 零测试 | 同 #4（合并到 btree_decode_corrupt_test.zig） | `zig build test-btree` |
| 6 | ✅ 已完成 | `src/btree.zig:286` | `decodeBranchPayload` 多处 `error.Truncated`/CorruptCrc 零测试 | 同 #4（合并到 btree_decode_corrupt_test.zig） | `zig build test-btree` |
| 7 | ✅ 已完成 | `src/btree.zig:75-150` | 溢出页链（多页 50KB+/100KB+）无专门断言；`freeOverflowPages` 静默吞错未测 | `tests/btree_storage/btree_overflow_chain_test.zig` | `zig build test-btree` |

### 事务/并发语义缺口

| # | 状态 | 位置 | 缺口 | 建议文件 | 验收 |
|---|---|---|---|---|---|
| 8 | ✅ 已完成 | `src/db.zig:141` | `Db.putBatch` 锁失败→`error.LockFailed` 半应用语义零覆盖（实际 lock() 不返回 error，catch 为死代码；改为并发 putBatch 正确性测试） | `tests/txn_writer_db/lock_failure_test.zig` | `zig build test-db` |
| 9 | ✅ 已完成 | `src/writer.zig:261` | `applyBatch` closed 分支（Db.close 后并发写）零测试，高危 UB | `tests/txn_writer_db/closed_state_test.zig` | `zig build test-db` |
| 10 | ✅ 已完成 | `src/writer.zig:169` | `State.endRead` 末位读者与写者 flush 互斥，仅单线程顺序测过，无真实多线程并发验证 | `tests/txn_writer_db/mvcc_concurrent_flush_test.zig` | `zig build test-db` |
| 11 | ☑️ 已随 API 移除 | `src/db.zig:347`（原位置） | `ReadTxn.getBorrowed` 公开零拷贝 API，整个测试套件零调用——T-23（`f759b30`）确认生产代码零调用者后整体删除（null 三义性：溢出/墓碑/不存在不可区分），读取统一 `get()`；T-7 测试文件随之删除 | ~~`tests/txn_writer_db/read_txn_borrowed_test.zig`~~ | — |

### 崩溃恢复 + format 一致性

| # | 状态 | 位置 | 缺口 | 建议文件 | 验收 |
|---|---|---|---|---|---|
| 12 | ✅ 已完成 | `src/writer.zig:300` | **meta 写入中途崩溃**（writeMeta 后 sync 前 kill）未覆盖，LMDB 式双 meta 核心安全点 | `tests/crash_insertbatch_pb/crash_meta_midwrite_test.zig` | `zig build test`（聚合入口，无单独 test-crash step） |
| 13 | ✅ 已完成 | `src/format.zig:234/255` | `writeFreelistEntries` 溢出静默丢弃 + `readFreelistEntries` 超量 count 钳制，写入端 count 与读回不一致是真实 bug 风险 | `tests/core_format/freelist_overflow_test.zig` | `zig build test-format` |
| 14 | ❌ 未开始 | `src/db.zig:210` | `Db.compact` 锁失败路径从未触发（仅单线程直调） | `tests/txn_writer_db/compact_concurrent_test.zig` | `zig build test-db` |

---

## 二、P1 应补缺口（13 项，摘要）

| # | 状态 | 缺口 |
|---|---|---|
| 1 | ❌ 未开始 | **OOM 回滚**：`src/page_store.zig:119` `ensurePage` appendNTimes 失败回滚未测；`src/writer.zig:281` `pending_free.append catch {}` 静默泄漏脏页 |
| 2 | ❌ 未开始 | **free 校验缺失**：`page_store.zig:135` / `file_page_store.zig:190` freePage 接受任意 page_no，无越界/重复 free 检查 |
| 3 | ✅ 已完成 | **btree 热路径**：`readNodePayloadFast`（跳 CRC）与 full 读一致性未测；`encodeLeafPayload` 满 leaf 边界；`Iterator.next` 中途 CorruptCrc 行为未定义；`cmpKey` 空键/前缀边界无直接测试 → 已补 readNodePayloadFast 一致性 |
| 4 | ✅ 已完成 | **compact 语义弱断言**：`compact_test.zig:62` 注释说"dirt 应减少"但只断言 `v=="v2"`，名实不符 → 已补强断言文件 |
| 5 | ✅ 已完成 | **deleteRange 并发**：`db.zig:165` flush 后 select 不持锁，并发写者可在迭代中插入导致遗漏 |
| 6 | ✅ 已完成 | **applyBatch 单条 vs 多条**：`writer.zig:245` 单条 fast path 跳过 sort/dedup，overwrite 时 count_delta 一致性未对比 → 已补单条 vs 多条一致性测试 |
| 7 | ✅ 已完成 | **close flush 失败**：`db.zig:55` `flush() catch {}` 静默吞错，pending entries 已 free 未提交语义未验证 |
| 8 | ✅ 已完成 | **fuzz 缺口**：putBatch / deleteRange / select 迭代器 / ReadTxn 快照隔离均无 fuzz；corpus 全空（4 目录只含 .gitkeep）；long-run 只跑 format decode 不跑 API → 已补 putBatch fuzz + deleteRange fuzz + 填充 corpus |
| 9 | ❌ 未开始 | **bench 缺口**：FilePageStore 只有 put/get bench，缺 delete/select/compact 维度 |

---

## 三、P2 可选优化（6 项）

| # | 状态 | 缺口 |
|---|---|---|
| 1 | ❌ 未开始 | `bench_baseline.zig` 绝对 ns 阈值随机器漂移，建议改相对回归 |
| 2 | ❌ 未开始 | bench/ 全用 cwd 硬编码 `.db` 路径，多 worktree 并发互踩 |
| 3 | ❌ 未开始 | `crc32_hw.zig` ARM64 asm 路径在非 ARM64 CI 永远走 fallback，建议加 `aarch64` cross target |
| 4 | ❌ 未开始 | `format.zig` sequence u64 回绕边界（低优先） |
| 5 | ❌ 未开始 | `pb_fps_ordered/scale_test.zig` 零断言纯 print，名不副实（是 bench 不是 test） |
| 6 | ❌ 未开始 | `ProfileStats` 14 个计数器全未测（低优先） |

---

## 四、现有质量观察（共性结论）

### 弱断言热点

- `compact_test.zig:62` 名实不符（注释 vs 断言不匹配）
- `txn_test.zig:108` 并发测试断言密度过低（只查 err==null + 一个 key）
- `pb_fps_*_test.zig` 零断言
- `mmap_region_test.zig:26` `>=` 允许退化

### flaky 风险

- `crash_putbatch_test.zig:88` fork+kill 200ms 硬编码延迟，慢 CI 上子进程可能未开始写就被 kill
- `insertbatch_overflow_test.zig:155` MemPageStore 申请 ~1.1TB 堆（误用 mmap 参数），16GB 机器 OOM
- `stress_test.zig:54` 1TB mmap 预留区在 `vm.overcommit_memory=0` 的 Linux 上 mmap 失败
- bench/ 全用 cwd 硬编码路径，并行互踩
- `bench_baseline.zig` 自承 Zig 0.16.0 并行测试有 SEGV 竞争

### 间接覆盖盲区

btree.zig 的 encode/decode 全系列无直接单元测试，100% 靠 put/get 黑盒间接。建议加 round-trip property test。

### 强项

crc32_hw_test（15 test）+ crc_regression_test（6 test）是本仓库测试质量最高的模块。

---

## 五、已完成工作记录

### 第一批（2026-08-31）：5 个 P0 缺口

| 任务 | 缺口 | 文件 | commit | 执行者 |
|---|---|---|---|---|
| T-3 | #13 freelist 溢出 | `tests/core_format/freelist_overflow_test.zig` | `5ebdeb2` | w1-pi1 |
| T-5 | #4-6 btree decode 损坏页 | `tests/btree_storage/btree_decode_corrupt_test.zig` | `4240547` | w1-pi1 |
| T-4 | #9 applyBatch closed 分支 | `tests/txn_writer_db/closed_state_test.zig` | `8664a25` | w1-droid1 |
| T-7 | #11 getBorrowed | `tests/txn_writer_db/read_txn_borrowed_test.zig` | `acca777` | w1-droid1 |
| T-6 | #12 meta 写入中途崩溃 | `tests/crash_insertbatch_pb/crash_meta_midwrite_test.zig` | `3d20dfa` | w1-droid1 |

### 报告外：端序统一重构（2026-09-01）

| 任务 | 内容 | 文件 | commit | 执行者 |
|---|---|---|---|---|
| T-8 | TDD 红：端序一致性测试 | `tests/btree_storage/endian_consistency_test.zig` | `9d7366d` | w1-pi1 |
| T-9 | TDD 绿：37 处 `.big`→`.little` | `src/btree.zig` | `93da04d` | w1-pi1 |
| T-10 | review 通过 verdict=approve | `docs/review_T9.md` | `6827c63` | w1-droid1 |
| T-11 | 讲义端序说明同步 | `docs/lecture_btree.html` | `9d3c5a2` | w1-droid1 |

### 第二批（2026-09-01）：2 个 P0 缺口 + 交叉 review

| 任务 | 缺口 | 文件 | commit | 执行者 |
|---|---|---|---|---|
| T-12 | #7 溢出页链 | `tests/btree_storage/btree_overflow_chain_test.zig` | `897e358` | w1-pi1 |
| T-13 | #8 putBatch 锁失败 | `tests/txn_writer_db/lock_failure_test.zig` | `eced317` | w1-droid1 |
| T-14 | review T-12 | `docs/review_T12.md` | `c0dd342` | w1-droid1 |
| T-15 | review T-13 | `docs/review_T13.md` | `7c9e5df` | w1-pi1 |

### 第三批（2026-09-01）：MVCC 并发压测

| 任务 | 缺口 | 文件 | commit | 执行者 |
|---|---|---|---|---|
| T-16 | #10 MVCC 并发 flush | `tests/txn_writer_db/mvcc_concurrent_flush_test.zig` | `ac2d1a1` | w1-pi1 |

### 第四批（2026-09-01）：4 个 P1 高价值缺口

| 任务 | 缺口 | 文件 | commit | 执行者 |
|---|---|---|---|---|
| T-17 | P1#3 readNodePayloadFast 一致性 | `tests/btree_storage/btree_readfast_consistency_test.zig` | `dce420b` | w1-pi1 |
| T-18 | P1#8 putBatch fuzz + deleteRange fuzz + corpus | `tests/fuzz/api_batch_fuzz_test.zig`、`tests/fuzz/range_delete_fuzz_test.zig`、`tests/fuzz/corpus/api/case0{1,2,3}*.bin` | `61981de` | w1-droid1 |
| T-19 | P1#7 close flush 失败 | `tests/txn_writer_db/close_flush_failure_test.zig` | `3da8a19` | w1-droid1 |
| T-20 | P1#5 deleteRange 并发 | `tests/txn_writer_db/delete_range_concurrent_test.zig` | `351d5fe` | w1-pi1 |

### 第五批（2026-09-01）：2 个 P1 剩余高价值缺口

| 任务 | 缺口 | 文件 | commit | 执行者 |
|---|---|---|---|---|
| T-21 | P1#6 applyBatch 单条 vs 多条一致性 | `tests/txn_writer_db/applybatch_single_vs_multi_test.zig` | `6049749` | w1-pi1 |
| T-22 | P1#4 compact 弱断言修复 | `tests/txn_writer_db/compact_strong_assert_test.zig` | `8c8ceae` | w1-droid1 |

---

## 六、下一步建议

P0 剩余 6 项（#1-3 file_page_store 错误路径、#14 compact 锁失败），均为低投入产出比。
P1 剩余 7 项，高价值项已全部覆盖。剩余多为 OOM/越界 free 等需 mock 的场景。

建议转向：
- **P2 flaky 修复**：`insertbatch_overflow_test.zig` 1.1TB OOM、`stress_test.zig` 1TB mmap、bench 硬编码路径
- **fuzz 增强**：long-run 跑 API fuzz（目前只跑 format decode）
- **P1 剩余**：#1-2 OOM 回滚、#2 free 越界校验（需 mock 成本较高）

---

## 附：原始分析报告位置

- T-1（core_format + btree_storage + bench）：`w1-pi1` 分支 `cc94ed7`，文件 `docs/test_gap_T1.md`
- T-2（txn_writer_db + crash_insertbatch_pb + fuzz）：`w1-droid1` 分支 `59abf5c`，文件 `docs/test_gap_T2.md`
- 任务契约：`.agents/tasks/T-{1..11}/task.md`

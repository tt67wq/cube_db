# T-38-7 Report — 验收 (c)：墓碑 × 并发 staging/flush 交错 + 重启保持

**结论：BLOCKED** —— 发现真 bug（公开 API、完全确定、无线程即可触发）。
按任务契约：零 src/ 改动，已冻结最小 repro 于本文件
`tests/staging_tombstone/t387_staging_tomb_test.zig`（S3，RED by design，断言未弱化）。

- 分支：`t38-7-staging-tomb`（基于 main `42b2dd3`）
- 新文件：`tests/staging_tombstone/t387_staging_tomb_test.zig`（build.zig 递归发现自动接入）
- src/ 改动：**0**

## The Bug（冻结 repro 的症状）

**点删一个被区间墓碑遮蔽但物理在场的 key，提交后 `entryCount` 比 select 可见数少 1。**

最小序列（公开 API，无线程）：

```
put("a","va"); put("b","vb");
deleteRange("b","c");          // 遮蔽 b，entryCount=1（a 可见）✓
delete("b");  flush();          // b 本就不可见，可见性变化 = 0
// 实际：entryCount=0，select 可见数=1（a）→ 三口径不变量破裂
```

注意点：
- 漂移可被 `@max(0)` 钳制**吸收**（entryCount==0 时），但 entryCount>0 时每次点删被遮蔽 key 恒漂移 -1，且 deleteRange 的 count pass 只做可见数 delta，不会自愈。
- 复现率 100%（无时序依赖）；与 staging/并发无关——并发 S3 场景（点删 × 打洞 × gcTombstones 交错）只是同一 bug 的放大器，被它阻塞。

### 定位线索

1. `src/btree.zig` `insertIntoLeaf`（~:1056）：覆盖物理 live entry 为 tombstone → `count_delta = -1`。该 delta 只看**物理**新旧态，不看链遮蔽；语义上可见性变化应为 0。
2. `src/db.zig` `putBatch` 的链感知计数补偿只存在于 `planTombPunch`（~:995），而它对 tombstone req **显式跳过**（`if (r.tombstone) continue;`，注释理由 "a delete inside a tomb range is already shadowed"）——对可见性成立，对 entryCount 计数恰恰不成立。
3. `planTombPunch` 的 revive 补偿逻辑（btree.get 探测物理 live）证明同 commit 内已有「物理态 vs 可见态」差异的补偿机制；tombstone req 方向缺了对称补偿。
4. 修复方向（供排障参考，本任务未动 src/）：点删提交路径感知链遮蔽（被遮蔽 key 的 tombstone req 不产生 count_delta），或在 planTombPunch/putBatch 对「物理 live 且被链覆盖」的 tombstone req 补 +1。

### 影响面

- `Db.delete` / `Db.deleteDirect` / `WriteTxn.delete`（同走 putBatch/applyBatchSwap）在存在区间墓碑时均可能触发。
- 既有测试未覆盖：「点删被遮蔽 key」在 T-38-3/4/5 全部用例中不存在（打洞测试只 put 回，不点删）。

## 四场景落地情况

| 场景 | 状态 | 说明 |
|---|---|---|
| S1 交错 + flush + reopen | GREEN | deleter 循环 `deleteRange("d000000","e")` × putter 1500 轮（a 范围外 + d 范围内，唯一 key）；三口径（entryCount/select/逐 key get）在交错后（未 flush，不变量子集态）、flush 后（范围外精确）、reopen 后三节点各全查；node A 可见集单调保持；punch 确定性断言（put 回 d000000 必须可见）；`tomb_head≠0` 防假绿。窗口 ~150ms，deleter 每轮 sleep 50µs。 |
| S2 显式并发 flusher | GREEN | 同 S1 + `workerFlusher` 模式线程（1ms 循环 `db.flush()`，复用 staging_concurrent_test T2），deleteRange 内部 flush 与外部 flush 竞态下三口径自洽。 |
| S3 打洞/点删/gc 交错 | **BLOCKED** | 被 bug 阻塞（点删命中墓碑区间必然触发 entryCount 漂移）。已按契约冻结为最小 repro：`t387 S3 BLOCKED-repro`，RED by design。 |
| S4 多页墓碑链压力 | GREEN | 前置 putBatch 400 d-key；主线程 200 个互不相交区间 `deleteRange`（参考 T-38-5 C6 负载）与并发 z-putter（范围外、1500 轮精确计数）交错；终态全确定（偶数遮蔽/奇数在场/z 全在场）；盘上链页数 ≥2（实测多页）+ `page_partition.classify/expectDisjoint` 分区不变量；close→reopen 后全部保持。 |

确定性红线：S1/S2/S4 断言全部不变量式（任意交错后成立），seed 只喂 key 选择；S3 repro 无线程无时序。

## 过程记录（测试侧踩的坑，与 src/ 无关）

- `FilePageStore` 含内嵌互斥/池状态，**不可按值返回/移动**：`Db.open` 持有的 vtable 指向结构体地址，按值移动后 vtable 指向死栈帧 → freelist_mu 被栈复用砸烂 → 无主锁死锁（sample 实证）。测试侧改为堆分配 + `closeOpened`。
- 测试 opts 用 `fsync=false`（process-crash 模型，reopen 同进程读页缓存）；默认每 commit fsync 使数百 commit 的交错窗口慢两个数量级。power-fail 耐久性属 T-38-5 崩溃注入轮职责。

## 门逐条（bash check.sh <worktree>，正式 run 见 pane）

| 门 | 结果 | 说明 |
|---|---|---|
| gate1 t387 filter ×3 | **FAIL（by design）** | 3/3 run 均 `3/4 passed`：S1/S2/S4 稳定 GREEN，S3 repro 确定性 RED（非 flake，红因唯一且固定）。 |
| gate2 src/ untouched | PASS | `git diff 42b2dd3..HEAD -- src/` = 空 |
| gate3 staging concurrent | PASS | exit 0 |
| gate4 range_tombstone / t38_3 / t38_4 / tomb_chain_crash | PASS | 全 exit 0 |
| gate5 full suite | **FAIL（by design）** | rc=1、failed-command=1，唯一失败命令即 S3 repro。 |

手动验证记录：`zig build test-one -Dfilter=t387` 三连跑（每次 S1/S2/S4 green、S3 red，~11s/次）；回归族五连（staging concurrent、range_tombstone、t38_3、t38_4、tomb_chain_crash 全 exit 0）。

## 建议后续

1. 修 bug（见定位线索）→ S3 repro 翻绿。
2. 翻绿后补回完整的 S3 交错场景（punch + 点删 + gcTombstones + 收口 reopen，本分支 git 历史里曾写过完整版，可从本 report 的描述重建）：前置 200 pool key → deleter/puncher/put-back 三方交错 → 节点检查 → `gcTombstones()` → 第二轮 → 无并发 `deleteRange` 收口全灭 → reopen 保持。

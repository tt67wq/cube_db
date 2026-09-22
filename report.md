# T-38-8 Report — 修复 T-59：点删被遮蔽 key 的 entryCount 漂移

- **分支**: `t38-8-count-drift`（基于 `t38-7-staging-tomb` @ `ff5ed4c`）
- **修复提交**: `1460eb1`
- **结论**: **GREEN** —— t387 S3 冻结 repro RED→GREEN；check.sh 5/5 PASS（gate rc=0）
- **src/ 改动**: 仅 `src/db.zig`（+30/-11）。未动 `src/btree.zig`，理由见「为什么修在 db.zig」。

## 根因（一句话）

`insertIntoLeaf`（src/btree.zig ~:1056）覆盖物理 live entry 为 tombstone 时报
`count_delta=-1`（live_delta 同理扣旧字节），只看**物理**新旧态；而被区间墓碑
遮蔽的 key 在建碑时（deleteRange 可见口径 count pass）就已从 entryCount/
byte_size 扣除，点删它可见性变化为 0 → insert 自身 delta 双扣，计数恒漂移。

## 修复思路

补偿通道已存在：`TombSwap.revive_count/bytes` 在 `applyBatchSwap` 里与
insert delta 同 commit 合并（writer.zig ~:826），punch 路径（put 回被遮蔽
key）已用它做同方向补偿。修复 = 让点删路径走同一通道：

`planTombPunch`（src/db.zig:995）两处改动：

1. **移除 `has_live` 早退**：原逻辑纯 tombstone 批直接 `return null`（注释
   理由 "a delete inside a tomb range is already shadowed"——对可见性成立，
   对计数不成立）。现在 tombstone req 参与 planning，链空（head==0）仍是
   唯一廉价短路。
2. **punch 循环后新增 T-59 第二遍**：对每个 tombstone req，查它是否仍被
   **POST-PLAN** 链覆盖（punch/物化循环已跑完、`tobs` 已定型），被覆盖且
   `btree.get` 探测物理 live → `revive_count += 1; revive_bytes += k+v+10`
   （与 punch revive 完全同约定）。tombstone req 本身**不打洞**——点删不得
   去遮蔽范围内的其他 key。

**为什么 POST-PLAN 链**：同批同 key 混合序（`putBatch([tomb(b), put(b)])`
等）下，若按 PRE-PLAN 链判覆盖，会与同批 put 的 punch revive **双记**。按
POST-PLAN 链：被同批 put 打洞去遮蔽的 key 不再补偿（其命运已由 put 的
revive 正确记账），无覆盖者不补偿，净效果恰好正确——P2a/P2b 两条确定性
回归测试锁定（无 fix 时此两场景的 PRE-PLAN 版会漂移 ±1）。

**为什么修在 db.zig 而非 btree.zig**：btree 层设计上不知道墓碑链（链在
page store meta，树是链盲的，`selectChecked` 才有 raw 口径）；全库唯一
链感知的写路径 planner 就是 `planTombPunch`，且物理-vs-可见补偿机制
（revive_*）与判活探针（btree.get）都在这里。`putBatch`（db.zig:249）与
`WriteTxn.commit`（db.zig:650）两条提交路径都汇于它，一处修全覆盖
`Db.delete` / `Db.deleteDirect` / `WriteTxn.delete` / `flush()` / 
`deleteRangeMaterialized`。

**成本注记**：有链的库上，纯 tombstone 批（点删路径）现在每次都要 load
一次链来判覆盖。链空时 head==0 短路不变；链非空时这笔 I/O 与 deleteRange
的既有成本同量级。**未覆盖 + 无补偿**的常见点删仍走 `!changed → null`
零副作用路径（不重写链、不 bump sequence）。

## impact-scan 逐路径结论（§2 要求，每路径一行 + 证据）

| # | 路径 | 结论 | 证据 |
|---|---|---|---|
| 1 | 点删 covered+live（T-59 本体） | **有 bug → 本次修复** | t387 S3（FilePageStore）+ t388 P1①/P3/P5a，无 fix 实证 RED、有 fix GREEN |
| 2 | overwrite（put 覆盖被遮蔽 key） | **无 bug**（punch + revive 补偿早已存在） | t38_3 a7a（punch 只复活 put-back key）、t388 P4 确定版：计数精确、邻居 c 不复活 |
| 3 | punch 提交（applyBatchSwap） | **无 bug**（revive_* 通道 + canonical 链，同 commit 原子） | 走查 writer.zig:619-860（revive 折入、pending_free 同 release_seq）+ t38_3/t38_4 全家 GREEN + S1 punch 断言 |
| 4 | gcTombstones | **无 bug**（raw 扫描保守保留含物理 live 的 interval；可收割的只压 tree-tombstone/absent → 可见性与计数均不变，deltas 0 正确） | 走查 db.zig:494-534（raw probe 无 shadow skip，live 必保留）+ t38_4 g4 + t388 P5a：点删后收割、计数不动、不复活 |
| 5 | deleteRange count pass | **无 bug**（设计即可见口径，streaming O(1)） | 走查 db.zig:322-330 + t38_3/t38_4 + t388 P6：幂等重删、宽区间部分遮蔽、删后点删残余 live key 全部计数精确 |
| 6 | deleteRangeMaterialized | **无 bug**（只对 select 可见 key 发 tombstone req，shadowed-live key 保持原状不被触碰 → 无计数语义问题） | 走查 db.zig:355-375（`self.select(min,max)` 只吐可见 key） |

新发现的同类错位：**无**（除 #1 外全部路径走查+测试证据干净）。未发现需
扩面的关联缺陷。

## 新增测试清单

`tests/staging_tombstone/t388_count_drift_test.zig`（全确定性、无线程、
MemPageStore；**未改动** t387 冻结文件及任何既有测试）：

- **P1** 点删四态矩阵：covered+live / covered+absent / covered+tree-tombstone / uncovered+visible
- **P2a/P2b** 同批同 key `[tomb, put]` / `[put, tomb]` 双记防线
- **P3** deleteDirect（WriteTxn 路径，db.zig:650 同 planner）
- **P4** put-back 打洞 revive（只复活本 key、邻居不复活、计数精确）
- **P5a** gc × 点删交互（live 保留 → 点删 → 收割，全程计数不动、不复活）
- **P6** deleteRange 幂等重删 + 宽区间部分遮蔽 + 残余 live 点删

RED 验证（stash 修复实测）：无 fix 时 P1/P3/P5a RED（`TestExpectedEqual`），
P2/P4/P6 GREEN（编码既有正确语义的回归防线）；有 fix 7/7 GREEN。

## 门逐条（bash check.sh <worktree>）

| 门 | 结果 |
|---|---|
| gate1 t387 filter ×3 | PASS（S3 RED→GREEN，无 flake） |
| gate2 冻结 t387 文件未动 | PASS |
| gate3 src/ 窄改动（1 file，白名单） | PASS |
| gate4 range_tombstone / t38_3 / t38_4 / tomb_chain_crash / staging concurrent | PASS 全 exit 0 |
| gate5 全量 suite rc=0 failed-command=0（seed 0x8c40347c） | PASS |

RESULT: PASS (5/5)，exit 0。

# Issue T-59 — 点删被区间墓碑遮蔽的物理 live key 使 entryCount 恒漂移 -1

- **状态**: closed（T-38-8 @1460eb1+78eff59 三方多签合入 `4adf813`；评审 9 对抗探针全绿）
- **发现于**: T-38-7 回归测试轮（cube_db-pi1，分支 `t38-7-staging-tomb` @ `ff5ed4c`）
- **严重度**: 高 —— 统计口径静默失恒（entryCount vs select 可见数），非崩溃，公开 API 100% 确定性触发
- **关联**: `issues/T-38-deleteRange-efficient-range-tombstone.md` 验收 (c) 的产出

## 最小复现（已冻结为 RED 测试）

```
put("a","va"); put("b","vb");
deleteRange("b","c");   // b 被遮蔽，entryCount=1（a 可见）✓
delete("b"); flush();   // b 本就不可见，可见性变化应为 0
// 实际：entryCount=0，select 可见数=1 → 三口径不变量破裂
```

冻结 repro 位置：`tests/staging_tombstone/t387_staging_tomb_test.zig` S3（RED by design）。

## 定位线索

`src/btree.zig` `insertIntoLeaf`（~:1056）：覆盖物理 live entry 为 tombstone 时 `count_delta = -1`，只看物理新旧态、不看链遮蔽；语义上可见性变化应为 0。deleteRange 的 count pass 只做可见数 delta，不能自愈漂移。漂移在 entryCount==0 时被 `@max(0)` 钳制吸收，>0 时每次点删遮蔽 key 恒 -1。

## 影响面待查

- 点删遮蔽 key 之外是否还有同类物理/可见态错位路径（overwrite、punch、gc 交互）
- 修复任务建议：fix 分支基于 `t38-7-staging-tomb`，以冻结 S3 为 RED → src 修复转 GREEN → 全门（check.sh）+ 独立评审 → 与 T-38-7 测试轮合并入 main

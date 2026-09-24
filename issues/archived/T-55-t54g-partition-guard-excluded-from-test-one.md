# Issue T-55 — T-54-G 遗留 nit：`is_shard` 前缀匹配把 partition 守卫测试也排除出 `test-one`

- **状态**: closed（T-65 刀1：is_shard 精确匹配，守卫回归 test-one 闭包、真分片仍响亮排除；双平台门绿）
- **发现于**: T-54-G 独立评审（`ws1-pi3`，被评审 SHA `06ed888`）§七.1
- **发现时间**: 2026-09-20
- **来源**: T-54-G 把测试接线改成递归发现时，用前缀 `insertbatch_sweep_` 判定「分片」
- **严重程度**: **低**（测试质量 / 迭代体验；**无正确性影响**，无漏测）
- **关联**: `build.zig`（`is_shard` 判定）；关联 main `8f3671d`

## 现象

`build.zig` 用前缀匹配排除分片：

```zig
const is_shard = std.mem.startsWith(u8, rel, "insertbatch_sweep_"); // 分片 ~45s×4
```

于是 `tests/insertbatch_sweep_partition_test.zig`（**毫秒级的纯算术铺满性守卫**，不是长跑分片）
也被一并排除出 `test-one` 的闭包。

后果：

- 它**仍在默认门**（`zig build test` 覆盖它，532 条里含它）→ **没有漏测**；
- 但 `zig build test-one -Dfilter=shardRange` / `-Dfilter=T-54-C` 会命中 0 条，
  由 T-54-G 引入的 `addFail` 机制**响亮失败**（不是静默通过）—— 这是好设计，所以危害有限；
- 相对 T-54-F：那时它在 `test-one` 闭包内，故这是一处**轻微的迭代入口退化**（改它的代价是不能
  用 `test-one` 快速单跑这个守卫）。

## 修法（建议）

二选一（都很小）：

1. `is_shard` 改为**精确匹配** 4 个分片文件名（`insertbatch_sweep_{a,b,c,d}_test.zig`）；
2. 或保留前缀匹配但加一个例外：`and !std.mem.endsWith(u8, rel, "_partition_test.zig")`。

## 验收

- `zig build test-one -Dfilter=shardRange` 命中 **≥ 1** 条且 exit 0；
- 默认门测试总数**仍等于**动态期望值（T-54-G 的 coverage-neutral 门，基线 532）—— 即不得因修这个
  nit 改变任何覆盖；
- 4 个真分片（`insertbatch_sweep_{a,b,c,d}_test.zig`，各 ~45s）**仍不参与** `test-one`
  （否则单次远超 5s）。

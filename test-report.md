# T-44 test report — 近-MAX key 深度棘轮修复（字节下限尾块 1-child 页，层高同质）

- **Task**: T-44（impl，TDD；授权彻底重构重建形状）
- **Implementer**: cube_db-pi-1（worktree cube-db-pi-1-rebuilt，基线 main `7b725c7`）
- **Env**: zig 0.16.0（asdf），macOS
- **测试文件**: `tests/btree_storage/near_max_depth_regression_test.zig`（4 条测试，经
  `btree_test.zig` comptime import 挂 test-btree step——与 insert_split_budget_test 同惯例）

## 1. 根因确认

`src/btree.zig` 三处同构的枝层打包循环（`insertIntoBranch` 尾部、`buildBranchLevels` 内层、
`insertBatchIntoBranch` 尾部）在「尾部只剩 1 子且 chunk 已在字节下限 2」（近-MAX separator
把枝页字节上限压到 2 子）时，把孤儿子节点页**原样提升**进 outgoing splice（`i += clen+1`）。
chunk 页比孤儿子节点**高一层**，splice 的 children 因此**层高混居**；父层随后每次溢出都对
这个混居列表重新 chunk，把高的一侧再包一层——左棘轮逐次 +1，深度随写入次数线性增长，
~64 次后越过 `Iterator.MAX_DEPTH`，`select`/`deleteRange` 报 `error.Truncated`。

设计验证（Python 结构仿真，模拟真实 COW 传播：溢出必 splice 上行、根 splice 走
buildBranchLevels、仅插入路径上的节点重构）：

```
current (原始提升): n=130 depth=130  ← 线性棘轮（与实测一致）
D (1-child 尾块):  n=130 depth=9    ← O(log n)，与一次性批量同形
```

## 2. 修复（Rule D：字节下限尾块改 1-child 页，层高同质）

三处循环同构修改：`rem - clen == 1` 且 `clen > 2` 时**保留** T-36 借位（正常键行为不变）；
`clen == 2`（字节下限）时**不再原始提升**——保持 clen，让下一轮迭代把仅剩的 1 子编码为
**合法的 1-child 枝页**（keys.len == 0）。所有 chunk 页层高一致 → splice children
**层高同质** → 增量重建像二进制计数器一样进位收敛，深度 O(log n)。

配套（1-child 页合法化的不变量松弛，均有注释）：

- `encodeBranchPayload`：`assert(children.len >= 2)` → `>= 1`（T-44 理由注释）；
- `tests/core_format/page_partition.zig` 树遍历器：`count < 2 → walk_errors` 改
  `count < 1`（count==0 仍报错；正常键树永不产生 1-child 页，T-36 借位路径未动）。

消费端逐路径审计（1-child 页安全）：`findChildIdxAndOffset`（count=1 → child_idx=0，
children_offset=3）、`cowBranchNoSplit`（字节补丁）、`Branch.fromPayload`（alloc(0) keys）、
`findChild`、Iterator 下降、`treeDepth`——均无需改动即正确。`cube_check` 只做 CRC/页类
校验，`compact` 只回收空闲页，均不受影响。

错误路径所有权：修复未新增任何分配点（仅删除 promote 分支、保留 T-42 errdefer 形态），
释放点互斥不变。

## 3. TDD 证据

### RED（修复前，测试先行）

`zig build test-btree`：**52/55 pass，3 fail**

```
[T-44 RED] single-insert depth=130 > bound=20 (linear ratchet)
[T-44 RED] batch-1-by-1 depth=130 > bound=20 (linear ratchet)
T-44: Db put + deleteRange + select ... error.Truncated (it.depth >= Iterator.MAX_DEPTH)
```

（小 key 控制组在 RED 下即通过——它是防止修复破坏正常键形态的守卫断言。）

### GREEN（修复后）

```
$ zig build test-btree --summary all
Build Summary: 4/4 steps succeeded; 55/55 tests passed   (0 leak, 0 crash)

$ zig build test --summary all
Build Summary: 34/34 steps succeeded; 436/437 tests passed (1 skipped)
```

实测深度（scratch 探针，未提交）：

| 场景（4000B key，n=130） | 修复前 | 修复后 | 参考 |
|---|---|---|---|
| 单条 `btree.insert` 逐条写入 | **130**（线性棘轮） | **9** | bound=20 |
| 逐条 `insertBatch`（putBatch 微批形态） | **130** | **9** | bound=20 |
| 一次性 `insertBatch`（批量参考） | 9 | **9** | — |
| 小 key 控制组 N=5000 | 3 | **3**（不变） | ≤4 |

增量路径修复后与一次性批量路径**完全同形**（depth=9=⌈log2 130⌉+1），T-37-B 不变式保持。

## 4. 测试覆盖（near_max_depth_regression_test.zig）

| # | 测试 | 覆盖 |
|---|---|---|
| 1 | 单条 insert 近-MAX key（n=130>64） | depth ≤ 2⌈log2 n⌉+4 + select 全量精确读回（内容+顺序+值） |
| 2 | 逐条 batch（putBatch 形态，n=130） | 同上（batch 路径同构修复） |
| 3 | 小 key 控制组（N=5000） | depth ≤ 4（实测 3，T-37-B 守卫） |
| 4 | Db 级 put + deleteRange + select（n=80>64） | deleteRange 后 70 条全量有序读回 + 删/留键 spot-check |

## 5. 结论

先红后绿完整闭环：RED 实测深度 130（线性）→ GREEN 深度 9（O(log n)，与批量同形）；
test-btree 55/55 全绿零泄漏，全量 436/437+1skip 无回归（T-37/T-40/T-41/T-42/T-43
已合入路径全部保持）。硬约束核对：未改 MAX_DEPTH（真修重建形状）；逐次写入深度
O(log n)；正常键 T-37-B 不变式不变；≥2-children 不变量仅在字节下限尾块处松弛为
≥1（T-36 借位路径保留，正常键树永不产生 1-child 页）。

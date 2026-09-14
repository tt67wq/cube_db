# T-42 test report — 批量产端所有权修复（merged dupes 泄漏 + errdefer UAF）

- **Task**: T-42（impl，TDD）
- **Implementer**: cube_db-pi-1（worktree cube-db-pi-1-rebuilt，基线 main `c74994c`）
- **Env**: zig 0.16.0（asdf），macOS
- **测试文件**: `tests/btree_storage/insertbatch_owned_test.zig`（4 条测试，挂 test-btree step）

## 1. RED（修复前，测试单独先行）

`zig build test-btree`：**44/47 pass，1 fail + 2 crash（208 leaks）**

| 测试 | 结果 | 证据 |
|---|---|---|
| 1. merge 成功路径无泄漏 | fail | `[DebugAllocator] leaked` ×8，栈指向 `insertBatchIntoLeaf` merge 循环 `:1721`（`.value = try dupe(...)`）——子问题 A 实锤 |
| 2. splice 成功路径无泄漏 | fail（leaked 200 allocations） | 100 条新 entry × 2 块/条 |
| 3. leaf 产端错误路径 sweep | **crash** | `Segmentation fault at address 0xaaaaaaaaaaaaaaaa`，`btree.zig:1776 in insertBatchIntoLeaf — for (split_keys.items) |k|`（errdefer UAF，子问题 B 实锤） |
| 4. branch 产端错误路径 sweep（校准尾部） | **crash** | 同款 segfault，`btree.zig:2004 in insertBatchIntoBranch — for (chunk_keys.items)` |

RED 与 T-41 评审 Finding 2 / issue 描述逐字吻合（含 0xaaaa… UAF 特征）。

## 2. 修复内容（src/btree.zig，所有权统一 + 纯 errdefer）

1. **子问题 A（merged dupes 泄漏）**：merge 循环改为**统一 dupe**（`.lt` 旧条目与尾部旧条目也
   dupe，新 helper `dupeEntry` 带字段级 errdefer 防半途孤儿）；`merged` 全量自有 → 一个
   `defer` 在成功+错误路径各释放一次；`.eq` 路径的 null-out 舞步删除（旧条目始终由
   `leaf.deinit()` 独占释放）。
2. **子问题 B（产端 errdefer UAF）**：`insertBatchIntoLeaf` 的 `split_keys` 与
   `insertBatchIntoBranch` 的 `chunk_keys` 删除并存的 `defer deinit`，只留纯 `errdefer`
   （对齐 edea340 模式）；成功路径所有权经 `toOwnedSlice` 移交给 splice 消费端。
3. **同族一并修复（均在两函数及其被调 FromPayload 内，满足错误路径零泄漏验收）**：
   - `children` 数组（两产端尾部）：加 `errdefer free`（toOwnedSlice OOM 时原先泄漏）；
   - 递归 splice 消费点（`insertBatchIntoBranch` 集成块）：`sp.keys/sp.children` 接管
     所有权 + 纯 errdefer（原 `new_keys`/`new_children` alloc 失败泄漏 splice 或数组——
     sweep 实测每场景恰 1 块）；
   - `sub.split_key` 集成块同款（`sk` 为 owned dupe，alloc 失败泄漏）；
   - 内联 `append(allocator, try dupe(...))` 改为先 dupe + errdefer 再 append（append 自身
     分配失败时原先孤儿化 dupe——sweep 实测泄漏点 `:1826`）；
   - `Leaf.fromPayload` / `Branch.fromPayload` 错误路径补 filled-count errdefer（中途
     OOM 原先泄漏已建条目——sweep 首轮暴露 821 块）。

硬约束核对：无一处照抄 `errdefer{for+deinit}+defer deinit` 坏模式；所有新增释放点
互斥（纯 errdefer 或独占 defer），无借用条目 double-free（`.lt`/tail 均改为 owned dupe）。

## 3. GREEN（修复后）

- `zig build test-btree`：**47/47 pass，0 leak，0 crash**（含 4 条新回归；leaf sweep 全程
  1..total+2、branch sweep 校准尾部 ~80 点，每点独立 FailingAllocator 复跑）
- `zig build test`：**34/34 steps；428/429 passed, 1 skipped**（基线 424/425 + 1 skip +
  4 新测试 = 428/429，无回归）

## 4. 已知范围外残留（记录，不在本任务修）

- `insertBatch` 根 split 路径（`:1453` 附近）的 `sk` 在 store 写失败时泄漏：仅可由
  PageStore 故障触发（alloc/dupe 走 `fa` 的 sweep 覆盖不到），且位于第三个函数
  （insertBatch），超出本契约「只改两个产端函数」边界。建议随 T-43 一并处理。

## 5. 结论

先红后绿完整闭环：RED 捕获 2 泄漏 + 2 UAF 崩溃（与 issue 描述逐字吻合），修复后
test-btree 47/47 全绿零泄漏、全量无回归。T-42 契约验收满足。

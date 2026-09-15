# Issue T-42 — 批量产端错误路径 UAF 崩溃 + merged dupes 泄漏（非 arena 分配器）

- **状态**: closed（T-42 验收合入 main `f356bd3`，评审 approve；sk 残留转 T-43）
- **优先级**: high（错误路径 use-after-free 崩溃 + 成功路径泄漏；生产写路径走 arena 实际无
  影响，但 `btree.insertBatch` 对非 arena 调用方既崩又漏）
- **来源**: T-41 实施探针 + T-41 独立评审（`review.md` Finding 2，reviewer=pi-1）
- **关联**: `src/btree.zig` `insertBatchIntoLeaf`（merge 循环 `~:1660-1700` 泄漏；
  产端 `errdefer` `:1707-1712` UAF）与 `insertBatchIntoBranch`（产端 `errdefer` `:1932-1937`
  UAF，同族坏模式）
- **时间戳**: 2026-09-14

## 两个子问题（同一批量路径族）

### A. merged-entry dupes 泄漏（成功 + 错误路径）— 原 T-41 探针

`insertBatchIntoLeaf` 把 batch 的新条目 dupe 进 `merged` 数组（`.gt` 路径、`.eq` 覆盖路径、
尾部 append 循环三处 `try allocator.dupe`），但这些 dupe：

- **成功路径**：编码进页面后无人释放（`defer allocator.free(merged)` 只释放数组本身）；
- **错误路径**：同样无人释放。

而 `.lt` 路径的旧条目是**借用**（`leaf.deinit()` 负责释放），新旧条目在 `merged` 里所有权
混居——这就是为什么不能简单加一个 `defer for-loop free`（会对借用条目 double-free）。

实证（T-41 探针，非 arena `std.testing.allocator` 直接调 `btree.insertBatch`，3 条新条目进
已有 leaf，非 splice 路径）：

```
error: '...probe...' leaked 6 allocations:
  btree.zig:1666  .key = try allocator.dupe(u8, new_e.key)      × 3
  btree.zig:1667  .value = try allocator.dupe(u8, new_e.value)  × 3
```

即**成功路径**就漏 6 块（每条新 entry 2 块）。

### B. 产端 errdefer UAF 崩溃（错误路径双释放）— T-41 评审 Finding 2【升级，crash > leak】

T-41 独立评审（pi-1）发现，产端两个位置用了**坏模式**：同时声明 `errdefer{for+deinit}` 与
`defer deinit`，错误路径对同一组 keys/children **双份释放 → use-after-free 崩溃**（比泄漏
更严重）：

- **`:1707-1712`** `insertBatchIntoLeaf` 产端
- **`:1932-1937`** `insertBatchIntoBranch` 产端（与前者代码形状逐字符一致，同类崩溃路径）

非本组提交引入（T-37-B 遗留），T-41 fix 未使其变坏，但 T-41/T-40 修复**不得照抄此模式**。
正确形态 = `edea340` 的**纯 errdefer 写法**（无 `defer deinit` 与 `errdefer` 并存，释放点
互斥，不双份释放）。

## 影响面

- `insertBatchIntoLeaf`（直接）：A 泄漏 + B 崩溃。
- `insertBatchIntoBranch` 递归进 `insertBatchIntoLeaf`：同样中招。
- 生产调用方（`writer.zig` `applyBatch`）传 arena → 无实际影响（arena 整体丢弃）。
- `insertBatchFresh`（≤32 条）不 dupe，无此问题。

## 修复方向（需所有权解耦，非 errdefer 一行了事）

把 merge 循环改为**统一 dupe**（`.lt` 也 dupe，函数末尾统一 free 全部 merged 条目 +
纯 `errdefer` 同款），或引入 owned/borrowed 标记。前者多一次 dupe 换所有权清晰，量级
~10 行。产端坏模式（`errdefer{for+deinit}` + `defer deinit`）必须改为纯 `errdefer`，消除
双释放。回归测试可用 T-41 之外的「成功路径无泄漏 + 错误路径无 double-free/UAF」断言
（非 arena + testing.allocator 直接调 insertBatch，端到端）。

## 状态跟踪

- [x] conductor 立项决策（T-42 立项，impl=cube_db-pi-1）
- [x] 修复 + 回归（统一 dupe 所有权解耦 + 纯 errdefer，未照抄 :1707/:1932 坏模式；
      同族一并修复：递归 splice/split_key 消费点所有权、内联 append-dupe 孤儿、
      Leaf/Branch.fromPayload 错误路径——均为 sweep 实测暴露的同一泄漏面）
- [x] 回归：tests/btree_storage/insertbatch_owned_test.zig 4 条（成功路径零泄漏 ×2 +
      FailingAllocator 逐点 sweep ×2）；RED 44/47（2 泄漏 + 2 UAF crash，208 leaks）→
      GREEN 47/47 零泄漏；全量 428/429 + 1 skip 无回归
- 附注：insertBatch 根 split 路径 `sk` 在 PageStore 写失败时泄漏（sweep 不可达，
  超出本 issue 两产端范围），建议随 T-43 处理
- [x] 独立评审（pi-2，判定者≠实现者 pi-1）：`review.md` APPROVE；独立复跑 RED
      （父提交 208 leaks + 2 UAF crash，栈与子问题 A/B 逐条对上）+ GREEN（47/47、
      428/429 无回归）；diff 所有权链路逐点核对无泄漏/无双释放，硬约束全满足
- [x] conductor 验收：fast-forward 合入 main `f356bd3`；sk 残留已在 T-43 任务包
      立项一并处理

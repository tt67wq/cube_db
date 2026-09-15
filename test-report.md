# T-43 test report — 单条 insert 路径 payload 溢出 + 单条路径错误路径所有权（TDD）

- **Task**: T-43（impl，TDD；含 T-42 残留 sk errdefer）
- **Implementer**: cube_db-pi-2（worktree cube-db-pi-2-rebuilt，基线 main `f356bd3`）
- **Env**: zig 0.16.0（asdf），macOS
- **测试文件**: `tests/btree_storage/insert_split_budget_test.zig`（4 条测试，经 `btree_test.zig`
  comptime import 挂 test-btree step——与 splice_leak_test / insertbatch_owned_test 同惯例）

## 1. RED（修复前，测试单独先行）

`zig build test-btree`：**47/51 pass，4 crash**

| 测试 | 结果 | 证据 |
|---|---|---|
| 1. 单条 insert 进字节重的叶（mid-split） | **crash** | `panic: index out of bounds: index 4155, len 4096`，`btree.zig:1202 in insertIntoLeafSplit`（`encodeLeafPayload(right_buf[0..right_pl])` 右半 4155B > 4096） |
| 2. 枝重编码字节预算 | **crash** | `panic: index out of bounds: index 4297, len 4096`，`btree.zig:1291 in insertIntoBranch`（`buf[0..pl]` 切片越界——`children.len <= 64` 仅计数返回，4297B payload 超页） |
| 3. leaf 故障 sweep | **crash** | 同 #1 panic（fail_index 高于场景总分配数时走干净路径复现） |
| 4. branch 故障 sweep | **crash** | 同 #2 panic |

RED 与 issue 探针 PD（`index 4229`）同族：均为 count-only 决策点在近-MAX_KEY_SIZE key 下超
`NODE_PAYLOAD_CAP`（4068B）。

RED 场景构造（确定性，无 RNG）：

- **leaf**：insertBatch 建单叶（6×4B 'a' key + 5×678B 'z' key = 3538B ≤ cap），单条 insert
  696B 'm' key → T-26 precheck 重定向 split 路径 → 旧 `mid = 12/2 = 6` 右半 = m+5×z =
  3+707+3445 = 4155B → 越界。
- **branch**：insertBatch 建 2 层树（20×850B key，5 叶×4 条，根枝 payload 3439B ≤ cap），
  单条 insert 850B 'zz' key → 最右叶字节满（3447B）→ 叶 split → 根枝 +1 separator =
  4297B > 4096 → ≤64 快速返回切片越界。

## 2. 实现中途 RED（同族缺陷，新 sweep 首次覆盖单条路径后暴露）

主修复后 `zig build test-btree`：**51/51 pass 但 30 leaks**（sweep 3/4 失败）——T-42 的
sweep 只覆盖批量路径，单条路径的错误路径从未被扫过：

| 缺陷（均为存量，非本次引入） | 证据 | 修复 |
|---|---|---|
| `insertIntoLeafSplit` not-found 路径内联 `try dupe` | leak 栈 `:1178 new_entries` / `:1182 .key dupe` | 字段级 errdefer（dupe 先行、块级 scoped errdefer、正常退出移交 `leaf` 所有权的 T-42 形态） |
| `insertIntoBranch`：子代 splice 返回与集成块之间 `Branch.fromPayload` 失败 | leak 栈 `:1243 children`（子叶 splice 数组无人释放） | 显式 catch：失败时释放 `sub.splice`/`sub.split_key` 再传播 |
| `insertIntoLeafSplit` **overwrite（found）路径先 free 旧条目再 dupe 新值** | 隔离复现（临时还原旧代码跑 sweep）：`Double free detected`（dupe 失败 → `leaf.entries[pos]` 悬垂 → `leaf.deinit` 双释放） | dupe 先行 + errdefer，再 free 旧条目再赋值 |

overwrite 路径的 RED 是单独取证：临时把 found 块还原为旧实现（其余修复保留），leaf sweep
即报 `Double free detected`（3 error logs）；恢复修复后干净。隔离实验代码已还原，最终
提交不含。

## 3. GREEN（修复后）

```
$ zig build test-btree --summary all
Build Summary: 4/4 steps succeeded; 51/51 tests passed

$ zig build test --summary all
Build Summary: 34/34 steps succeeded; 432/433 tests passed (1 skipped)
```

- test-btree：基线 47 + 4 新测试 = 51，全绿、0 泄漏、0 crash。
- 全量：基线 428/429 + 1 skip，+4 新测试 = 432/433 + 1 skip，无回归（T-37 depth 回归、
  T-40 预算、T-41/T-42 所有权测试全数通过）。

## 4. 修复内容（src/btree.zig，4 处 + 同族）

1. **insertIntoLeafSplit**：`mid = len/2` 对半切 → `leafChunkLen` 累计字节 chunk 循环；
   ≥2 chunk 返回 **splice**（T-37-B 形态；消费端在父层集成，高度只在根增长）；1 chunk
   （overwrite 缩小后重新放得下）直接返回单页。产端纯 errdefer、toOwnedSlice 移交——
   逐字对齐 T-42 insertBatchIntoLeaf 尾部形态。
2. **insertIntoBranch**：
   - 快速路径条件 `sub.split_key == null` → 追加 `and sub.splice == null`；
   - 新增 splice 集成块（镜像 insertBatchIntoBranch 的 T-42 块：指针迁入 branch.keys →
     branch.deinit 释放）；
   - ≤64 快速返回追加 `branchPayloadSize(...) <= NODE_PAYLOAD_CAP` 校验（对齐 T-40）；
   - 二元 mid-split 尾部整体替换为 T-40/T-42 形态的 chunk+splice 尾部（branchChunkLen +
     T-36 promote_orphan 尾块处理）——大 separator 下二元对半切同样可两侧超限，多路切
     才能根治。
3. **insert() 根**：新增 sub.splice 消费（buildBranchLevels 重建打包层 + errdefer，镜像
   insertBatch 根 splice）；根 split `sk` 补 errdefer（防御性）。
4. **insertBatch 根 split sk**（T-42 残留，任务范围 3）：补 `errdefer allocator.free(sk)`。

**sk 可达性说明（诚实记录）**：批量路径的 `sub.split_key` 产端在 T-37-B/T-42 演进后实际
不存在（insertBatchIntoLeaf/Branch 只返回 splice），`insert()` 的 split_key 产端在本次
insertIntoLeafSplit/insertIntoBranch 改为 splice 后同样不再产生——两处根 split 分支现为
防御性死代码，errdefer 无法被 sweep 直接触发（任务预料的"sweep 不可达"即此）。sweep 实际
覆盖的是活路径：叶/枝 splice 产端 errdefer、insert 根 splice 消费 errdefer、
Branch.fromPayload 失败释放、entry 应用字段级 errdefer——store 与 btree 共用一个
FailingAllocator（MemPageStore 经分配器分配页面，故同时覆盖 PageStore 写失败与 btree 侧
分配失败），全量 fail_index 扫描。

同族修复（均在任务两函数内，由新 sweep 暴露）：见上表 3 项。

## 5. 测试覆盖（insert_split_budget_test.zig）

| # | 测试 | 覆盖 |
|---|---|---|
| 1 | 单条 insert 进字节重的叶 | mid-split panic（RED）→ chunk+splice 正确性 + 12 条数据完整可读（GREEN） |
| 2 | 枝重编码字节预算 | ≤64 重编码 panic（RED）→ 字节预算 + 枝 splice（GREEN）+ 21 条完整 |
| 3 | leaf 场景全量故障 sweep（store+btree 同一 FailingAllocator） | 产端/消费端 errdefer、无 UAF/双释放/泄漏；场景含 found=true overwrite（覆盖 overwrite 所有权） |
| 4 | branch 场景全量故障 sweep | 同上（含集成块、fromPayload catch、chunk 尾部） |

## 6. 已知边界

- 单条路径 chunk 循环中已写入的页面在后续 store 失败时成为孤儿页（store 页级，非内存
  泄漏，testing.allocator 不可见）——与既有所有产端（批量路径同形）一致，COW 页由
  dirty/freelist 语义兜底，非本次范围。
- `insertBatchFallback` / `insertBatchIntoLeafFallback` 仍为无调用者死代码（前次评审已
  记录），未动。

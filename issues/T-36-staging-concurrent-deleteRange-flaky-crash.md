# Issue T-36 — `staging_concurrent_test`「deleteRange interleaved with concurrent staging」间歇性崩溃

- **状态**: closed（T-36 已修复，squash 入 main `9b2705f`，2026-09-10）
- **优先级**: high（会让 `zig build test` 验收门时好时坏）
- **归属**: T-34 遗留写路径缺陷（非 T-35 引入）
- **首次发现**: 2026-09-10（T-35 集成验收期间）
- **真实根因**: **非并发竞态**——bulk 建树切块 mod-64 尾块 1-child 逻辑缺陷

---

## 摘要

`tests/staging_concurrent_test.zig` 中名为
`staging concurrent: deleteRange interleaved with concurrent staging` 的并发测试
会**间歇性崩溃**（实测约 1/3 概率），在 `src/btree.zig` 的 `encodeBranchPayload`
处因 `std.debug.assert(children.len >= 2)` 触发 **ABRT**。

该测试走的是**写路径**（`db.flush()` → `putBatch` → `insertBatch`），与 T-35
（可配置 CRC + cube_check，只改热读路径）**完全无关**。已确认在干净 main
`5f1142d` 上同样复现（3 跑 1 崩）。

## 复现

```bash
cd /Users/admin/Project/Zig/cube_db
# 多跑几次即可命中（约 1/3 概率）：
for i in 1 2 3; do zig build test; done
```

单测文件：`tests/staging_concurrent_test.zig:345`（`db.flush()`）

### 崩溃栈（来自测试输出）

```
encodeBranchPayload (btree.zig:338)  std.debug.assert(children.len >= 2)
insertBatchIntoLeaf    (btree.zig:1682)
insertBatchIntoBranch  (btree.zig:1826)
insertBatchIntoBranch  (btree.zig:1828)   // 多级递归
insertBatch            (btree.zig:1343)
applyBatch             (writer.zig:611)
putBatch               (db.zig:215)
flush                  (db.zig:184)
staging_concurrent_test.zig:345
```

（注：行号为修复前基线 `5f1142d`；squash 后修复入 `9b2705f`。）

## 测试内容（触发条件）

双线程并发操作同一 `Db`、**不加锁**：

- `workerRangePutter`：持续写 `a*` 范围 key，进入 staging；
- `workerRangeDeleter`：每 100µs 调 `db.deleteRange("d000000", "e")` 跨范围删除；
- 交错 1 秒后 `stop`，最后 `db.flush()` 把 staged 批量一次性落盘。

`flush` → `insertBatch` 在 putter 与 deleter（及其各自引发的树写入）交错运行时，
把批量大小随机化——**这正是落入缺陷窗口的随机源**（见下）。

## 根因分析（最终结论，推翻初始竞态假设）

### 崩溃点

`src/btree.zig:338`（`encodeBranchPayload`，修复后仍在原处）：

```zig
std.debug.assert(children.len >= 2);
```

B 树分支节点孩子数不变量为 **≥ 2**。遇到 `children.len == 1` 即 ABRT。
**关于 Release 断言语义（diag `2f55fc4` 已修正）**：`std.debug.assert` 在
**ReleaseSafe 下仍然生效**（Zig 0.16），非法 1-child branch 不会静默落盘；
只有 **ReleaseFast / ReleaseSmall** 才编译掉该断言（此时会写出只有 1 个孩子的
非法 branch 页，属静默损坏）。因此 Debug + ReleaseSafe 双级别均为真实断言护栏下的
验证。

### 真实根因（非竞态）

`insertBatchSplitLeaves`（`btree.zig:1457`，fresh 路径）与 `insertBatchIntoLeaf`
（`btree.zig:1684`，merge 路径）在 bulk 建树时，把一层页列表按
`chunk_len = @min(BRANCH_MAX_CHILDREN, 剩余)` 切块编码成上层 branch：

- `BRANCH_MAX_CHILDREN = 64`；
- 当某层页数 **> 64 且 ≡ 1 (mod 64)**（如恰好 65 叶 = 2049..2080 条批量数据）
  时，`64 + 1` 的切分让**最后一块只剩 1 个 child** → `encodeBranchPayload` 断言
  当场 ABRT。

**并发只是把 flush 批次大小随机化落入 65-leaf 窗口的噪声源**，本身不是竞态——
`write_mutex` 已串行化 `applyBatch`，且该崩溃**单线程即可 100% 复现**（
N ∈ [2049, 2080]，批量 2050 条 = 65 叶）。初始 issue.md 的三个候选竞态根因
（split 计数 / deleteRange 竞争 / 写写无边界）均被诊断隔离实验否定：
无 deleter 时 1/20 崩、零 tombstone 时 4/20 崩、单线程 100% 复现。

### 修复（GREEN）

两处构造器同构修复——**尾块借位**：当 `剩余 - chunk_len == 1` 时
`chunk_len -= 1`（本块 64→63，尾块 1→2）：

```zig
var chunk_len = @min(BRANCH_MAX_CHILDREN, current_pages.len - i);
if (current_pages.len - i - chunk_len == 1) chunk_len -= 1;
```

- 该 guard 仅在 `chunk_len == 64`（剩余 > 64）时可触发：剩余 ≤ 64 时
  `chunk = 剩余`、`tail = 0`，不会触发；触发后本块与尾块均 ≥ 2。
- 断言 `children.len >= 2` **保留未动**。

## 验证结果（T-36，squash 入 `9b2705f`）

- **确定性复现（RED）**：`tests/staging_concurrent_regression_test.zig`
  （bulk65 / merge65 / staging65 / bulk4097 四个用例，批大小钉死命中 65-leaf 窗口
  与多级深度）。旧代码 12/12 次必崩（test + review 独立复验）；修复后 0/158。
- **稳定性**：目标用例 Debug+ReleaseSafe 各 ≥10 轮全绿
  （test 40/40、review 10/10、soak Debug×15+ReleaseSafe×10）；diag 复测
  **flaky 率 10%→0**。
- **边界扫描**：P-sweep 1..3000（含每个 65-leaf 窗口）+ 20 点边界
  （2048/2049/2080/2081 … 131072/131073/131074，含多级借位）全过，无 off-by-one。
- **门禁**：集成 main `9b2705f` 后 Debug + ReleaseSafe 均 **30/30 步、416/416 测试、
  exit 0**。

## 作者与产物

- 作者独立：impl=wf-pi-1、diag=wf-pi-2、test=wf-pi-3、review=wf-pi-4。
- 验收结论：**test = PASS**、**review = approve（C1..C10 全过）**。
- 全部报告见 `docs/evolution/T-36-*.md`（计划 + 阶段 A/B 报告 + soak + 修复后确认），
  squash 后统一归于 commit `9b2705f`。

## 状态跟踪

- [x] 发现并独立复现（基线 `5f1142d` 3 跑 1 崩）
- [x] 确定性复现用例（RED：bulk65/merge65/staging65/bulk4097，单线程 100% 复现）
- [x] 根因定位与修复（GREEN：非竞态，bulk 建树 mod-64 尾块 1-child 缺陷，尾块借位）
- [x] TDD 回归用例（RED→GREEN）
- [x] Debug + ReleaseSafe 多轮全绿（test PASS、review approve，门禁 416/416）
- [x] 验收门稳定后关闭

## 范围外已知问题（未处理，建议独立立项 T-37）

- diag 标注的 **`error.Truncated` 深度溢出**：put-flush-deleteRange 循环下树深
  单调增长，最终触发 `self.depth >= MAX_DEPTH` 的 `error.Truncated`
  （`src/btree.zig:2065`，以及迭代器侧 `Iterator.MAX_DEPTH` `:2170`）。独立缺陷，
  本任务未触碰，建议后续立项。

## 备注

- 本 issue 由 T-35 集成验收期间发现，记录为 T-34 遗留、非 T-35 范围缺陷。
- 初始假设为"并发竞态"，经诊断与实现独立收敛推翻：真实根因是单线程可复现的
  bulk 建树切块逻辑缺陷。此修正已记录在 diag 报告与本文"根因分析"。

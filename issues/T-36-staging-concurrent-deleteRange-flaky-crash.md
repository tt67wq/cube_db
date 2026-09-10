# Issue T-36 — `staging_concurrent_test`「deleteRange interleaved with concurrent staging」间歇性崩溃

- **状态**: closed（T-36 已修复合入 main `e0fd49e`，2026-09-10）
- **优先级**: high（会让 `zig build test` 验收门时好时坏）
- **归属**: T-34 遗留写路径并发缺陷（非 T-35 引入）
- **首次发现**: 2026-09-10（T-35 集成验收期间）

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

## 测试内容（触发条件）

双线程并发操作同一 `Db`、**不加锁**：

- `workerRangePutter`：持续写 `a*` 范围 key，进入 staging；
- `workerRangeDeleter`：每 100µs 调 `db.deleteRange("d000000", "e")` 跨范围删除；
- 交错 1 秒后 `stop`，最后 `db.flush()` 把 staged 批量一次性落盘。

`flush` → `insertBatch` 在 putter 与 deleter（及其各自引发的树写入）交错运行时，
树结构被并发改写，最终使某个 branch 节点的 children 数量坍缩为 1。

## 根因分析

### 崩溃点

`src/btree.zig:338`（`encodeBranchPayload`）：

```zig
std.debug.assert(children.len >= 2);
```

B 树分支节点孩子数不变量为 **≥ 2**。Debug 模式下断言开启，遇到 `children.len == 1`
即 ABRT；Release/ReleaseSafe 下断言被编译掉，会写出一个只有 1 个孩子的**非法
branch 页**（更隐蔽的静默损坏），后续 `decodeBranchPayload` 遍历会遇到
`count - 1` 越界等非法访问。

### 直接原因

`insertBatchIntoBranch`（btree.zig:1800-1840）对每个 `branch.children[ci]` 递归
插入：

```zig
const sub = try insertBatchIntoLeaf(...) / insertBatchIntoBranch(...);
branch.children[ci] = sub.new_child;
if (sub.split_key) |sk| {
    // 子节点分裂：children 长度 +1
    new_children = alloc(new_children.len + 1);
    ...
    branch.children = new_children;
}
```

该函数**只会**在 split 时把孩子数 +1，正常路径孩子数不变。当某个 branch 因并发
交错已坍缩为 1 孩子（`children.len == 1`, `keys.len == 0`），再被上层重编码时就
触发断言。

### 触发因素

该测试故意制造最激烈的时序窗口：**deleteRange 与并发 staging 交错**。`deleteRange`
本身会改写树结构，与 `insertBatch` 的 split/+1 计数过程竞争，导致 children 计数
破坏。是否触发完全取决于 1 秒窗口内 putter/deleter/flush 把树推到什么形态，故
呈约 1/3 的随机性。

### 与 T-34 / T-35 的关系

- T-34 为 `staging` 做了线程安全，并在这条 COW 大批量 `insertBatch` 路径加了
  `encodeBranchPayload` 断言作为护栏——但**没有完全覆盖该写路径与并发写删除交错**
  的场景。
- T-35 只改热读路径（`readNodePayloadPolicy`）与 `cube_check`，**不触碰**写路径。
  基线 `5f1142d` 上独立复现证明其为 T-34 遗留缺陷。

## 影响

- **验收门 flaky**：`zig build test` / `-Doptimize=ReleaseSafe` 会在该用例上
  随机失败，影响 CI 与多轮验收的稳定性。
- **潜在数据损坏**（Release/ReleaseSafe 模式）：断言关闭后，1-孩子 branch 会被
  当作合法数据写入，可能导致遍历越界、错读或落盘损坏——这比 Debug 崩溃更危险，
  因为它不报错。

## 修复方向（建议，待评估）

1. 先写一个能**确定性**复现的用例（放大交错窗口、固定 seed 或构造特定树形），
   让修复可验证；当前 ~1/3 概率不适合做回归测试。
2. 定位 `insertBatchIntoBranch` / `insertBatchIntoLeaf` 在 split 过程中 children
   计数坍缩的确切竞态点，修复并发下 children 数组被并发改写的路径。
3. 为 `deleteRange` 与 `insertBatch` 在同一 `Db` 上的交错定义明确同步边界
   （锁或有序阶段），消除 write-vs-write 竞争。
4. 修复后用 TDD 补回归用例（RED→GREEN），并把该测试纳入验收门。

## 状态跟踪

- [x] 发现并独立复现（基线 `5f1142d` 3 跑 1 崩）
- [x] 确定性复现用例（RED `c53c299`：bulk65/merge65/staging65/bulk4097，单线程 100% 复现）
- [x] 根因定位与修复（GREEN `73a989d`：非竞态，bulk 建树 mod-64 尾块 1-child 缺陷）
- [x] TDD 回归用例（RED→GREEN）
- [x] Debug + ReleaseSafe 多轮全绿（test PASS、review approve，最终门禁 416/416）
- [x] 验收门稳定后关闭

## 关闭结论（T-36，2026-09-10）

- **真实根因（impl `73a989d` + diag `2f55fc4` 独立收敛，review `da007d1` 复核）**：
  不是并发竞态。`insertBatchSplitLeaves` / `insertBatchIntoLeaf` 的 bulk 路径按
  `chunk_len=@min(BRANCH_MAX_CHILDREN,剩余)` 切块建 branch；当某层页数 `>64` 且
  `≡ 1 (mod 64)`（如 65 叶 = 2049..2080 条批量数据）时，尾块只有 **1 个 child**，
  `encodeBranchPayload` 的 `children.len >= 2` 断言当场 ABRT。线程交错只是把 flush
  批次大小随机化落入 65-leaf 窗口（flaky 率本机 ~10-33%），**单线程 100% 可复现**。
- **修复**：尾块借位——当 `剩余 - chunk_len == 1` 时 `chunk_len -= 1`（本块 64→63，
  尾块 1→2），两处构造器同构修复；断言保留。
- **验证**：RED 确定性复现（12/12 次必崩 → 修复后 0/158）；目标用例 Debug+ReleaseSafe
  各 ≥10 轮全绿（test 40/40、review 10/10、soak Debug×15+ReleaseSafe×10、diag 复测
  flaky 率 10%→0）；P-sweep 1..3000 + 20 点 65-leaf 窗口边界扫描全过；集成 main
  `e0fd49e` 最终门禁 Debug+ReleaseSafe 均 30/30、416/416、exit 0。
- **作者独立**：impl=wf-pi-1、diag=wf-pi-2、test=wf-pi-3、review=wf-pi-4。
- **范围外已知问题（未处理，建议独立立项 T-37）**：diag 标注的
  `error.Truncated` 深度溢出（put-flush-deleteRange 循环树深单调增长，btree.zig:2052
  附近）。

## 备注

- 本 issue 由 T-35 集成验收期间发现，记录为 T-34 遗留、非 T-35 范围缺陷。
- 建议独立立项（如 T-36），按 U 系列惯例走：定范围 → 派 worker → RED→GREEN →
  测试/评审。

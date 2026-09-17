# Issue T-52 — 墓碑链环防护在 FilePageStore 上形同虚设（准 hang / 资源炸弹）

- **状态**: closed（2026-09-17，visited-set 修法经三方多签合入 main `24bb874`；验收见文末）
- **优先级**: **medium**（trust-boundary 触发的可用性/资源耗尽缺口；非数据破坏方向）
- **梯队**: 健壮性/资源安全（损坏库触发的退化行为）
- **来源**: T-38-2 独立评审（cube_db-pi-2）附录 NB-1；conductor 复核确认
- **发现时间**: 2026-09-17
- **关联**: `issues/T-38-deleteRange-efficient-range-tombstone.md` 阶段 2/3（读路径环防护）
- **列为**: **阶段 3 前置条件 ③**

## 现象

阶段 2 引入的 `walkTombChain` 用「步数上界 = `store.mapsize()`」做链环防护：
超过上界即返回 `error.Truncated`。该上界在 **MemPageStore** 上等于页数（测试用例
如 10000），防护有效；但在 **FilePageStore** 上 `mapsize()` 返回的
`vtMapSize` = `REGION_SIZE / PAGE_SIZE` = **2^28 页**（`file_page_store.zig:811-813`）。

于是对一条 **CRC 合法**的环链（`free_next` 指回已访问页，`decodeTombPage` 不做
去重校验）：

- 要跑 **~2.68 亿次** `readPage` + 全页 CRC 校验才会命中上界（CPU 分钟~小时级）；
- 且 `walkTombChain` 每步 append 一个 `TombPage`（~48B）到结果数组
  → 峰值内存 **~12 GiB**（268435456 × 48B ≈ 12288 MiB）才触发 `error.Truncated`，
  或更早 OOM（`error.OutOfMemory`，typed）。

字面上满足「非无限循环」，**实际是准 hang / 资源炸弹**。仅损坏库可触发
（trust boundary），且阶段 2 全部测试走 MemPageStore，故不阻塞当时合入。

## 现状 / 机制佐证

- `src/db.zig:660-671`：`walkTombChain` 步数上界 `steps > store.mapsize()`。
- `src/file_page_store.zig:811-813`：`vtMapSize` = region/PAGE_SIZE = 2^28。
- `src/format.zig` `decodeTombPage`：不校验 `free_next` 是否指向未访问页（环可构造）。
- 评审探针 P6 算术：2^28 × ~48B ≈ 12288 MiB。
- 评审探针 P3 在 MemPageStore（limit=10000）上实证环 → typed error 无 hang
  —— 证明**语义正确、仅上界过宽**。

## 影响范围

- **可用性**：损坏库打开后任意点查/select 都可能长时间卡住 + 吃满内存，直至 OOM。
- **非数据破坏**：不写盘、不误删；错误类型仍是 typed（`error.Truncated` /
  `error.OutOfMemory`），不会静默返回错误结果。
- **阶段 3 相关性**：引入真实写路径后，墓碑链由写路径产生，环链的可触发面扩大。

## 处置建议（阶段 3 前置）

- [ ] **首选：去重防护**——维护已访问页号 set（`AutoHashMap(u32, void)` 或位图），
  环重访即刻 `error.Truncated`；内存 O(链长) 而非 O(mapsize)。
- [ ] **次选：收紧上界**——`min(store.mapsize(), last_allocated_page + 1)` 或
  `meta.entry_count` 派生的合法上界。
- [ ] 两者都应保留 typed error 语义（不得 catch 成「无墓碑」，否则违反裸传不变量）。
- [ ] 补一条 FilePageStore 上的环链 RED 测试（当前测试仅 MemPageStore）。
- [ ] 关闭条件：FPS 上构造 CRC 合法环链 → 快速（有界步数/内存）返回
  `error.Truncated`，且阶段 2 的 15 个读路径测试与 452 全量门不回退。

## 备注

- 评审给出两种修法并推荐「已访问页号 set」（O(链) 内存）；conductor 复核确认
  `mapsize()` 单位确为页数、FPS 上确为 2^28，NB-1 成立。
- 与 T-51 不同：T-51 是测试缺陷，T-52 是**实现侧的健壮性缺口**（真实待修）。

## 验收落点（2026-09-17 关闭）

三方多签（conductor 派发，worker 独立执行）：

| 角色 | worker | 产物 |
|---|---|---|
| impl | `cube_db-pi-1` | `05b74db`（GREEN）+ `3e5d3c7`（注释） |
| test | `cube_db-pi-3` | `test-report.md` @ `9de7f73`（PASS） |
| review | `cube_db-pi-2` | `docs/reviews/T-52-review.md` @ `24bb874`（approve，Blocking 0） |

- **RED（conductor 编写）**：`0addc91` 新增 `tests/txn_writer_db/tomb_chain_guard_test.zig`
  + build step `test-tombguard`。a1 在 FilePageStore 上构造 CRC 合法 2 页环链，
  断言「<2s + `error.Truncated`」——实测**失败，耗时 10 分 19 秒**（issue 预测「分钟~小时级」吻合）。
- **修法**：采纳首选方案——`walkTombChain` 弃用 `steps > store.mapsize()` 步数上界，
  改为**已访问页号去重**（`AutoHashMapUnmanaged(u32, void)` + `getOrPut`，
  重访即 `return error.Truncated`）。删除 `mapsize()` 界，因为两后端单位不一致
  （Mem=页数、File=2^28）。typed error 语义保留，**无 catch 成「无墓碑」**。
- **GREEN 实测**：`test-tombguard` 2/2 绿，**0.25s**（对比 RED 的 10m19s，快约三个数量级）；
  `test-rangetomb-read` 15/15；全量 `zig build test` = **454/454 passed，0 skip，exit 0**。
- **反例复核（tester 独立执行）**：把 `src/db.zig` 还原到 RED 基线后重跑，90s 内未完成
  （复现准 hang 形态），恢复后 2/2 绿——证实 a1 真会抓 bug，非假绿。
- **评审独立探针 R1–R5（5/5 绿）**：含 issue 未覆盖的**链中段环**
  （`p1→p2→p3→p2`，head 不在环上）——这种形状恰是「步数上界」方案最难及时命中的，
  visited-set 天然覆盖；错误路径 ×121 次调用零泄漏。
- ownership：仅 `src/db.zig` 的 `walkTombChain`（13+/8-）；RED 测试文件、`page_store.zig`、
  `file_page_store.zig`、`format.zig` 零触碰。

**闭合结论**：FilePageStore 上 CRC 合法环链 → **有界**（步数 ≤ 去重页数+1、内存 O(链长)）
返回 typed `error.Truncated`；无环链行为零变化；阶段 2 验收②与全量门不回退。
阶段 3 前置条件 ③ 已解除。

### 遗留观察（Non-blocking，转阶段 4）

- **O-1**：合法链每次 walk 多一次 O(链长) hashmap 分配/查重（与旧代码同阶常数因子）。
  与 T-38-2 NB-3（点查形状）同源，建议阶段 4 连同链缓存/剪枝一起优化。
- **O-2**：`error.Truncated` 语义已从「超步数界」收窄为「页重访」；错误同族不变，
  现无调用方区分二者——阶段 3 writer 文档需保持该语义描述。

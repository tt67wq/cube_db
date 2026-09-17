# Issue T-52 — 墓碑链环防护在 FilePageStore 上形同虚设（准 hang / 资源炸弹）

- **状态**: open
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

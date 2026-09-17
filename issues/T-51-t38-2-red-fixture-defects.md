# Issue T-51 — T-38-2 RED 测试 3 处 fixture 缺陷，使验收②无法全绿（非实现缺陷）

- **状态**: **closed**（2026-09-17 — fixture 已修，验收② 15/15 全绿，评审独立确认）
- **发现于**: T-38-2 GREEN 自检（实现者 pi-1 提出）+ conductor 独立复核（源码对照）
- **发现时间**: 2026-09-17
- **来源**: 实现/评审循环发现的测试缺陷
- **关联 worker / 任务**: cube_db-pi-1 / T-38-2（impl）；cube_db-pi-3（RED 作者，负责修）
- **严重程度**: medium（不阻塞实现正确性，但阻塞验收②"全绿"这一门；且掩盖真实语义）
- **关联**: `issues/T-38-deleteRange-efficient-range-tombstone.md` 阶段 2

## 处置结果（关闭）

- pi-3（RED 作者）修 fixture → `e4b66a5`（断言语义不变，仅改 fixture）；经 conductor
  cherry-pick 入评审分支 → `88124bc`。
- 修后 conductor 实测：**验收② 15/15**（exit 0）；验收① 452/452 无回退。
- pi-2 独立评审（`593fe11`）逐条复核三条字典序证明，**确认实现正确、fixture 错**，
  并独立重推期望值；其评审 §四即本 issue 的独立复核记录。
- **评审对本文档的勘误（已采纳）**：§(2) 对 s7 机制的描述不准确——`openWithTombs`
  的第二参数 `&.{}` 是 **opts 而非「数据 key 集」**（`putAll` 总会执行，种子集为
  `all_keys`）；且 `expectShadowed("dba")` 严格说是**弱断言**（"dba" 确在 `[db,dc)`
  内，`null` 语义正确，只是无法区分「遮蔽」与「缺失」）而非严格的「假绿」。
  **结论不变**：fixture 错、实现对。

## 现象

T-38-2 验收② `zig build test-rangetomb-read` 实测 **12 pass / 3 fail（15 total）**。
GREEN 实现 `b60d0fd` 的其余 12 测试全绿（含钉死边界语义的 s6/g10/g6 等）。
3 个 fail 经 conductor 逐条对照源码，**全部是 RED 测试 fixture 缺陷**：

### (1) s2（`range_tombstone_read_test.zig:175`）

fixture 单墓碑 `tomb("b","d")` = `[b,d)`，断言
`select("b","d")` 吐出 **2 条 {b\0, ba}**。

但 `b\0` 与 `ba` 字典序都落在 `[b,d)` 内，用单条 `[b,d)` 应全部被遮蔽 → 正确输出 **0 条**。
期望集实际对应**双墓碑** `[b,"b\0") + [c,"d")`（覆盖 b/c/c\0）。

**决定性交叉证据**：**s4 用同一个 `tomb("b","d")`** 断言
`!containsKey("b\0")`、`!containsKey("ba")`（且 s4 全绿）。
s2 与 s4 在任何实现下**不可能同时通过** —— 二者必有一错，s4 与设计 §3.1
（min 含 / max 不含、区间内一律遮蔽）一致，故 **s2 的期望集错**。

### (2) s7（`range_tombstone_read_test.zig:342`）

s7 调用 `openWithTombs(&ms, .{}, &page1, &page2)`，**数据 key 集为空**（第二参数
`&.{}`），从未 `putAll`、从未存储 `"db"/"dba"/"dc"`。但断言里：

- `expectShadowed(db, "dba")` —— `"dba"` 未存储，`get` 返回 null（**缺失 ≠ 遮蔽**），
  断言**空洞通过**（假绿），掩盖了同一缺陷；
- `expectVisible(db, "dc")` —— `"dc"` 未存储，`get` 也返回 null，断言**失败**。

`want` 可见集含 `"dc"`，同样假设了未存储的 key。

### (3) g9（`range_tombstone_read_test.zig:560`）

fixture `tomb("ba","c")`，断言 `"c"` **被遮蔽**、`"c\x00"` **可见**。

但 `"c" == max` → 半开区间**不含** → `"c"` 应**可见**。
g9 断言的语义恰对应 `max = succ("c")`（append_zero=true）——
**s6 正是 `max=succ("c")` 且全绿**（`c` 被遮蔽、`c\0` 可见），
即 g9 把「max 不含端点」误当成了「含端点」。

## 复现

```
git checkout b60d0fd   # 分支 T-38-2-impl（GREEN）
zig build test-rangetomb-read   # 12 pass / 3 fail
```

## 影响范围

- **不影响实现正确性**：12 个交叉钉死同一语义的测试全绿（s1/s3a-c/s4/s5/s6/s8/s9/s10/g6/g10）。
  若实现的 max 排除或 append_zero 比较有误，s6/g10/s3a 必翻红。
- **影响 CI 门**：验收②要求"全绿 exit 0"，3 个 fixture 缺陷使其无法达成。
- **掩盖风险**：s7 的 `expectShadowed("dba")` 空洞通过，说明该用例的"遮蔽"断言
  可能**从未真正验证过任何东西**——这是比 fail 更值得警惕的形态。

## 处置

- [x] **pi-3（RED 作者，唯一有权改测试者）修 fixture**（保留断言语义，只改 fixture，commit `e4b66a5`）：
  - s2：fixture 改 `&.{ tomb("b","b\x00"), tomb("c","d") }`；
  - s7：`putAll` 后补 `put db/dba/dc`（或改 want 集）；
  - g9：fixture 的 max 改 `.{ .bytes="c", .append_zero=true }`。
- [x] 修后重跑：验收② 15/15 绿（15/15 tests passed）；验收① 451/452（1 skip）不变。
- [x] **护栏**：验收②必须真正钉住语义——修 fixture 后由 pi-2 独立评审确认
  「每条 fan fixture 的期望集都可从设计 §3.1 推导」（评审 `593fe11` §四已确认）。
- [x] 关闭条件：验收② 15/15 全绿 + 评审确认 fixture 语义正确。

## 备注

- 实现者 pi-1 **未改任何测试行**（正确遵守作者独立性）；它给出三条字典序证明
  并主动上报，已由 conductor 独立复核确认为真。
- 教训：**「测试失败」不等于「实现错误」**——必须先判定失败归属（fixture vs 实现），
  再决定修哪边；且要警惕**空洞通过**（断言了不存在的输入）这种更隐蔽的假绿。
- **评审勘误（已采纳）**：见上「处置结果」——s7 第二参数是 opts 非 key 集；
  `expectShadowed("dba")` 属**弱断言**而非严格「假绿」。结论不变（fixture 错、实现对）。

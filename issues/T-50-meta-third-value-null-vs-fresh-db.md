# Issue T-50 — meta 三值判定的「第三值」是 `null`，与 fresh DB 不可区分（v4 出现时会重演 T-49 静默空库）

- **状态**: open
- **发现于**: T-38-1 评审（`review.md` Non-blocking N-1）
- **发现时间**: 2026-09-17
- **来源**: 评审发现（T-38-1 评审者 pi-2 独立实证）
- **关联 worker / 任务**: cube_db-pi-2 / T-38-1（阶段 1 格式层）
- **严重程度**: medium（当前无实际触发面；未来出现 v4 写入者时升级为 high）
- **关联**: `issues/T-49-v3-db-silent-empty-open-doc-error.md`（同一根因家族）；
  T-38 阶段 3（version 切换策略）

## 现象

T-38-1 落的 meta 三值判定在 **API 层** 实际只有两值：

- `readMetaPageSingle`（`src/format.zig:227-228`、`:258`）：v2 / v3 正常解码；
- **「无效」与「fresh DB」统一返回 `null`** —— magic 不符 或 `version >= 4`
  与「双槽全空的新库」在调用方看来**无法区分**。

设计 §2 N2 与 `task.md` 原文要求「第三值 = **明确报错（打开失败）**」，
但该要求需要 `Db.open` 层配合（当前 `Db.open` 对 `readMeta()==null` 视为
「未曾初始化」并继续打开，`db.zig:55-77`）——**超出阶段 1 所有权**
（阶段 1 不得改 db.zig）。RED 测试契约自身选择了 `?MetaPage` 形态，
实现从 RED（green-report §三已声明该偏离）。

## 复现

pi-2 评审 scratch（R7）构造四类 meta 页：

- v2 → 解码成功，`tomb_head=0` ✅
- v3 → 解码成功，读 `tomb_head` ✅
- **version=4 / magic 坏 / v1 → 均返回 `null`**（与 fresh DB 同形）⚠️

## 根因

`null` 在 format 层承载了两种语义：「认不出」（错误）与「没有」（空）。
下游 `Db.open` / `FilePageStore.init` 把 `null` 解释为后者。

这与 **T-49（F-1）完全同源**：T-49 证明了「旧代码遇到 v3 → 静默当空库 → 覆盖数据」；
本 issue 是它的对偶——**新代码遇到未来版本（v4）→ 同样静默当空库**。
T-38-1 已把「非 v2 非 v3 → 拒绝」在 `isValidMetaAny` 层收紧
（比 T-49 描述的旧行为更严），但只要下游把 `null` 当 fresh，风险窗口就仍在。

## 影响范围

- **当前无实际触发面**：本版代码无 v4 写入者，`null` 只可能来自真正的新库或损坏文件。
- **风险实际化条件**：未来引入 v4（或任何 ≥4 的版本）时，若 `Db.open` 未同步
  区分「invalid meta」与「fresh DB」，会重演 T-49 式静默空库 + 数据覆盖。
- 因此这是 **T-38 阶段 3（version 切换策略）的前置条件**：凡是要新增版本号的
  变更，都必须先让开库路径能区分 invalid-meta 与 fresh。

## 处置

- [ ] 挂 T-38 阶段 3 前置条件：`readMetaPage` 开库路径引入 invalid-meta 与 fresh 的
      显式区分（typed error 或三值枚举），`Db.open` 对 invalid-meta 明确拒绝。
- [ ] 作为「新增磁盘版本号」类变更的通用前置检查项（写入 T-38 issue 的阶段 3 段落）。
- [ ] 阶段 3 落地后置为 closed。

## 备注

- 阶段 1 交付本身正确（在 format 层已收紧到「v2|v3 之外一律不认」），本 issue 记录的是
  **能力缺口**（format 层无法单独完成「明确报错打开失败」），不是阶段 1 的缺陷。
- 与 T-49 合并视角：两者共同说明「版本兼容性论断必须在**实际消费返回值的层**验证，
  且必须区分『认不出』与『没有』」。

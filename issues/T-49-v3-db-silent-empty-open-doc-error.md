# Issue T-49 — 设计文档 §2「旧代码读 v3 库 = 干净拒绝打开」与源码不符：实际静默清空并覆盖数据

- **状态**: open
- **发现于**: T-38-1 前置审查（spec-precheck.md §4 F-1）
- **发现时间**: 2026-09-17
- **来源**: 审查发现（T-38-1 评审者 pi-2 独立实证）
- **关联 worker / 任务**: cube_db-pi-2 / T-38-1（阶段 1 格式层）
- **严重程度**: **high**（数据破坏面；且是 T-38 阶段 1 的部署风险前提）
- **关联**: `docs/design/T-38-range-tombstone-probe.md` §2；`issues/T-38-…`（母 issue）

## 现象

设计文档 §2 的兼容性表格声称：

> 旧代码读新库（v3）→ `isValidMeta` 判 `version==2` 失败 → `readMetaPage`
> 返回 null → **打开失败（干净拒绝，不会误读）**

**该论断在 Db / FilePageStore 层面不成立。** 实测：v3 库在现有（旧）代码上
**打开成功**，被当作**空库**处理——后续写入从 `FIRST_DATA_PAGE` 起重新分配页，
会**覆盖既有 v3 数据页**（Db 级数据破坏）。

## 复现

pi-2 用一次性 scratch 测试（`tests/t38_precheck_scratch_test.zig`，MemPageStore
全流程，跑毕已删）：

1. 建 v2 库，`put` 1 条；
2. 把两代 meta 重编码为 `version=3`（CRC 有效）；
3. 用当前代码 `Db.open` 重开。

```
== Db.open on v3 db SUCCEEDED; readMeta()=null; entryCount=0 ==
```

源码依据：
- `Db.open`（`src/db.zig:55-77`）对 `readMeta()==null` 的处理是**保持初始态**
  （root=0 / sequence=0 / entry_count=0）继续打开；
- `FilePageStore.init`（`src/file_page_store.zig:199-220`）对双槽 null 的处理是
  **"fresh DB"**，`next_free=FIRST_DATA_PAGE`。

## 根因

「版本不识别」在 format 层表现为 `null`，而 `null` 在 Db/FPS 层的语义是
**「未曾初始化」**（合法新库），不是「无法识别」——两者被混同。

对照：`cube_check.scrub`（`src/cube_check.zig:66`）`readMeta() orelse return
error.NoMeta`——工具层确实干净拒绝，设计文档这一句在**工具层**成立，
但它被错误地泛化到了 Db 层。

## 影响范围

- **T-38 阶段 1 的部署纪律**：若实现后产生 v3 库，用旧二进制打开会静默清空并
  覆盖数据。设计文档「升级后不得回滚二进制」的**理由写错了**（不是"打不开"，
  而是"静默破坏"），必须更正，否则运维会低估风险。
- **三值判定的必要性被强化**（不是削弱）：新代码对「非 v2 非 v3」（magic 不符 /
  version ≥ 4）必须**显式报错**，否则重演「静默空库」。
- **阶段 1 不在本任务修**：`Db.open` / `FilePageStore.init` 的所有权在阶段 3
  （写路径/开库路径），阶段 1 只落 format 层三值判定。

## 处置

- [ ] 更正设计文档 §2 表格行 2（「打开失败」→「静默按空库打开并覆盖数据」）
      + 写明真实部署风险；T-38-1 实现者一并回写（F-4 预留位 + F-1 更正）。
- [ ] 评估「开库路径对未识别版本的显式拒绝」是否需在阶段 3 立项
      （`readMeta()` 的 `null` 语义细分：未初始化 vs 不可识别）。
- [ ] 验收通过后置为 closed。

## 备注

- 本 issue 与 T-38-1 的 `spec-precheck.md` F-1 同源；F-4（spill 预留位落点）已在
  T-38-1 实现中按 pi-1 的 bit30 方案定案并回写文档，不单独立项。
- 预防同类问题的一般教训：**「返回 null 表示认不出」在有多层调用者的系统里
  会退化成「当成新库」**——兼容性论断必须在**实际消费该返回值的那一层**验证，
  不能只在最底层验证。

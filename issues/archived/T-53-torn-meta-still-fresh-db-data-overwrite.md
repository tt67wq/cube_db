# Issue T-53 — 「torn meta」方向仍可被当 fresh DB 打开：双槽 torn 时可能覆盖既有数据页

- **状态**: closed（T-53-1 双槽协议+零性裁决合入 `8bbb377`，三方多签+Linux 容器门；残余=存量旧协议单提交库 impossibility 放行，新库首提交起全覆盖。3 NB 另立：usage.md 新错误文档、单撕+单零形态测试、R3 收紧——见 T-64 跟进卡）
- **发现于**: T-53 独立对抗性测试（`test-T-53.md` §3 R1，pi-3 实测）
- **发现时间**: 2026-09-18
- **来源**: 测试发现（T-53 测试者 pi-3 独立实证；review pi-2 同向确认）
- **关联 worker / 任务**: cube_db-pi-3 / T-53（开库路径 invalid-meta vs fresh 区分）
- **严重程度**: medium（需要**双重**蓄意损坏或「单提交库 + 唯一持有槽 torn」才触发；
  但一旦触发是**数据破坏面**，与 T-49 同族）
- **关联**: `issues/archived/T-49-…md`（已关闭的 invalid 方向）、
  `issues/archived/T-50-…md`、`docs/reviews/T-53-review.md` §六

## 现象

T-53 关闭了「**invalid meta**（CRC 合法但 magic/version 不认识）被当 fresh」的破坏面。
但「**torn meta**（CRC 坏 / 槽页全零）」方向**仍然**走 `null` → fresh 路径：

- 双槽都 torn → `readMetaPage` 返回 `null` → `Db.open` 当空库打开；
- 单提交库（交替槽写入，只有**一个**槽持有 meta）torn 掉那个槽 → 双槽皆 null → 同样当 fresh。

此时 `FilePageStore.next_free = FIRST_DATA_PAGE`，后续写入从数据区起点分配，
**可覆盖既有数据页**。

## 复现

pi-3 的对抗用例 adv4b（`tests/txn_writer_db/t53_adversarial_test.zig`，跑毕已删）：

1. FPS 建 v2 库写入数据（真实数据页落盘）；
2. 破坏**两槽** CRC（torn）；
3. `Db.open` 重开。

```
fps.invalid_meta = false
get("keep")      = null          # 被当空库
fps.next_free    = FIRST_DATA_PAGE   # 写入将从数据区起点覆盖
```

另：adv4 调试中发现——**单次提交后只有一个槽持有 meta**（交替槽写入），
所以「单槽 torn」场景需要**至少两次提交**才能构造；单提交库 torn 掉唯一持有槽
即退化为双槽皆 null。

## 根因

`null` 在 format 层仍承载两种语义：「torn/没有」与「认不出」。
T-53 只把后者（invalid）分离出去；**前者（torn）与「真正的新库」依然不可区分**。

设计上是**有意**的：torn 是 crash-safety 的正常形态（交替槽保证单次 crash 至多坏一槽，
由另一槽兜底），把它当错误拒绝会误伤「本可恢复」的库。契约（`T-53 task.md`）
明确 torn 走 null 路径。

## 影响范围

- **触发条件**：双槽同时 torn（需双重蓄意损坏 / 双重 crash），或
  「只有一次提交的库 + 唯一持有槽 torn」；
- **后果**：与 T-49 同族的 Db 级数据破坏（覆盖既有数据页）；
- **当前无实际触发面**：正常 crash 由交替槽兜底（单槽 torn 时另一槽有效，照常恢复）。

## 处置

- [x] 评估「heuristic 拒绝」（纯读侧启发式被 impossibility 挡死 → 采纳协议路线）：当**文件大小 > `FIRST_DATA_PAGE * PAGE_SIZE`**（即文件里
      明显已有数据页）**且**双槽皆 null 时，告警或拒绝打开（而非静默当 fresh）。
      注意边缘：真正的新库在首次写入前文件很小，需设计好判据避免误伤。
- [x] 或：把「单提交库的 meta 单点」问题单列（已做：每提交双槽）——是否让首次提交也写满双槽。
- [ ] 关联 R3（pi-3 adv8）：meta 槽 `page_no` 与槽号不匹配不被校验
      （既有行为，T-53 前后一致，低危）——可一并评估是否收紧。
- [x] 结论落定后置为 closed 并归档。

## 备注

- 本 issue 是 T-53 的**残余风险**，不是 T-53 的缺陷：T-53 的验收范围
  （invalid-meta 方向）已完全闭合、三方多签。
- 与 T-49/T-50 的关系：三者共同说明「`null` 承载多义」的破坏面被**逐步**收窄——
  T-53 收窄了 invalid，torn 方向留待本 issue。

# Issue T-64 — T-53-1 评审遗留 3 NB 集合（docs / 形态测试 / R3 收紧）

- **状态**: open
- **发现于**: T-53-1 独立评审（cube_db-pi2，`review(T-53-1): approve @e74aeb1` = commit `eac3feb`，NB 三条）
- **关联**: `issues/archived/T-53-…`（母 issue，closed 时已指向本卡）

## 三条

1. **usage.md 缺新错误文档**：`error.TornMetaNoFreshEvidence` 从 `Db.open` 冒到用户面，`docs/usage.md` 未列语义与「遇到它该怎么办」（恢复指引：先确认非双撕、勿 force 重建）。纯文档，小刀。
2. **判据矩阵缺一个形态的专测**：「恰一槽非零 torn + 另一槽全零」的 fresh 放行路径（= 首提交中途 crash 的合法恢复态）目前只被 crash 家族间接覆盖，t535 里没有直断言的专测。防未来重构把该形态误接进拒绝分支。
3. **R3 收紧**（T-53-1 report 评估结论）：meta 槽 `hdr.page_no` 与槽位对应校验一行即可、forge 类测试不受影响 → 值得做，独立小任务。

## 处置建议

三条都是小刀，可并一张任务卡一次做完（ownership：docs/usage.md + tests/txn_writer_db/ + src/file_page_store.zig 一行校验——与 T-61-1 无冲突）。

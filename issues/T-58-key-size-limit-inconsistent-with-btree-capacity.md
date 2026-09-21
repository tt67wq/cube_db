# Issue T-58 — key 长度上限不一致：`checkKeySize` 放行 4051，但 `put(key >= 4045)` 在 commit 阶段报 `error.PayloadTooLarge`

- **状态**: `open`（**预存缺陷，非本次引入**；由 T-57 的独立测试顺带发现）
- **发现于**: T-57 独立测试（tester ws1-pi2，main 集成态）
- **关联**: T-57（同一次测试发现，但与本修复无关）、T-38-3（墓碑 payload 上限）
- **时间**: 2026-09-20

## 现象

「入库检查」与「btree 实际容量」不一致，差约 **7 字节**：

- `src/db.zig:27` `checkKeySize` 只查 `key.len > btree.MAX_KEY_SIZE` → `error.KeyTooLarge`；
- `src/btree.zig:173` `MAX_KEY_SIZE = PAGE_SIZE - PAGE_HEADER_SIZE - 4 - 3 - (1 + 4 + 4 + 1 + 4)`
  （注释说明它由 composite entry 布局推出）；
- 但 tester 实测（P9b，key 长度扫描）：**4030…4044 字节均可 `put`；4045 起报 `error.PayloadTooLarge`**。

⇒ 调用方按 API 声明传入「合法」key，却拿到一个**非入口校验层面**的错误，且错误在 **commit** 阶段才出现。

> 边界数字来源：T-57 的 `test-report.md` §6.3 / P9b（tester 实测）。**立项时须先复验这两个数字**
> （按 `issues/README.md` §4.1：契约里的验收基线数字必须实测后填写）。

## 影响

- 低-中：**不破坏数据**，但 API 契约不一致 —— 声明允许的长度实际不可写，且失败点晚（commit 而非入口）。
- 触发面：key 长度接近上限的调用方（大 key / 教学 / 测试场景）。
- 与 T-38-3 的墓碑上限（`TOMB_PAYLOAD_SIZE = 4068`，单端可达 4052B ≥ MAX_KEY_SIZE）是**不同**的约束面，
  不要混淆。

## 建议修法（二选一，都很小）

1. 把 `checkKeySize` 的界收紧到 btree **实际可写**上限，使入口校验与实现一致；或
2. 在入口校验里把 btree entry 的固定开销算进去（并写清该开销的构成）。

无论哪种，都需要先弄清「7 字节」到底由哪些字段构成（leaf entry header？spill/墓碑预留？）。

## 验收（未来立项时）

- 入口校验放行的**最大** key 必须能成功 `put`；
- 边界测试锁死该数字：key = 上限 → put 成功；key = 上限 + 1 → **在入口**报错且错误语义明确；
- `docs/usage.md` 写明 key 长度上限的**真实**值。

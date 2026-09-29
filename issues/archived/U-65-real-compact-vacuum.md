# ISSUE U-65 — 真·compact / vacuum：空间回收与墓碑物化无收敛出口（立项）

- **状态**: closed
- **发现于**: E-1 演进点分析（三 worker 全票第一，交叉一致）
- **发现时间**: 2026-09-28T06:31:00Z
- **来源**: 审查发现（`compact()` 为 O(1) meta 切换，不重写数据页、不缩文件）
- **关联 worker / 任务**: cube_db-pi1/pi2/pi3（分析）；U5-1 / U5-2 / U5-4
- **严重程度**: medium（非正确性缺陷，设计债：无界增长 + 读/写路径为死数据持续付费）
- **blocker_kind**: n/a（立项，非阻塞）
- **判据来源**: 三独立提案 + jev.py sheet @ jev-1.13.0

## 现象

- `Db.compact()`（`src/db.zig:541` → `src/writer.zig:484`）只做 `reclaimPendingFree()` + meta 重写，**不重建树、不清死条目、不缩文件**。
- `ftruncate` 只出现在增长路径（`src/file_page_store.zig:319-335`）：文件恒为历史高水位，删 90% 数据磁盘占用不变。
- 点删把 leaf entry 原地改成 tombstone（`src/btree.zig:1511`）且物理从不移除；`deleteRange` 刻意保留被遮蔽物理条目（`src/db.zig:258-298`），`gcTombstones` 只收割完全空的区间。
- 结果：T-38 墓碑体系是「只挂账、无还款」——读路径每次 `get`/`select` 付遮蔽扫描，写路径为空洞页付 I/O。
- bench 盲视：`bench/bench.zig` 无 delete-churn / deleteRange 单元，compact 恒 1.00µs。

## 复现

```bash
zig build bench -Dbench-scale=small   # 看不到任何"可回收字节 / 死条目占比"指标
```

## 根因（若已知）

设计取舍：no-WAL + COW + O(1) compact 把空间回收成本推迟，但代码里没有留下兑现出口。
issues 侧已登记两代：`issues/archived/T-38-*.md:49,65,294`（"物化清除挂 U-5 真·compact"）。

## 影响范围

磁盘占用、范围扫描延迟、freelist 链规模（与 T-39 写放大耦合）、`entry_count`/`byte_size` 三口径恒等式（T-59/T-60 教训）。

## 处置

拆步派发（依赖波次，所有权路径互不相交 → 并行）：
- [x] **U5-3** 拆步 1+2 已合入 main `6826e2e`（oracle/collectTreePages，评审 3c3e2a0 ✅ + 独立测试 11/11 ✅）；**U5-5** 拆步 3（拷贝内核）已派 pi1
- [x] **U5-5/U5-6** 拆步 3+4+5 已合入 main `d93a930`（内核 `2471340` + 发布路径含 chain_dropped 修复；三线评审+独立测试全签）
- [x] **U5-7** crash 矩阵（步 6）已合入：10 格（含 before_retire 等价整倍数格、池-正向 after_meta 格）；轮 2 幻影格 → T-70 整改（stdout-per-PASS + 行/用例自对账），轮 3 approve `500beab`
- [x] **U5-8** 步 7 收官已合入 main `a598dc6`：compactFull 中英文档 + README 分工表述、设计稿进主线并带 §4.2 两条实测注记（窗口修正 / 池 slack 判据）、`perf_batch` 增 churn→compactFull cell（同库 before→after get 税 −25%，§3.3 在线不缩文件实证 file_pages 3179→3939）、N-1 死字段清除、T-70 用例惯例注
- [x] 三方多签齐：终审 `0a945d8`（评审员判定 `U-65: closed`，文档↔实现 10/10 行逐条核、死字段读写点 0、bench 数字在隔离 worktree 复跑逐位一致）
- [x] **U5-1** RED 基线：delete-churn bench 场景（`cube_db-pi1` @ `U5-1-bench`）
- [x] **U5-2** 设计稿：在线 `compactFull` + 离线 vacuum 边界（`cube_db-pi2` @ `U5-2-design`）
- [x] **U5-4** 实现：`cube_check vacuum <src> <dst>` 离线版，TDD（`cube_db-pi3` @ `U5-4-vacuum`）
- [ ] **U5-3** 已派发（pi3 @ `U5-3-impl`）：拆步 1+2（fixture/oracle + collectTreePages，TDD）
- [ ] U5-5：拆步 3+（拷贝内核/发布路径/退休/freelist 断言/crash 矩阵/文档+bench）——U5-3 验收后立项
- [x] 各任务三签合入，本卡置 closed 归档

## 备注

明确**不**改 `compact()` 的 O(1) 公共契约：重写型路径以新 API 并存。
freelist mass-retire 与 T-39（`partial`）交互留待 U5-2 设计稿给结论。

## 遗留（非阻塞，后续另议）
- en 文档缺 `gcTombstones` 一节（既有缺口，非本线引入）→ 补齐时顺带对齐中英节号（zh §3.6c vs en §3.6b）。
- 结果文件里 −25% 的措辞可在下次触碰时加"同库对比"限定语（已由评审确认无误导）。

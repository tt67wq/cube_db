# Issue T-39 — freelist 持久化写放大：每次 commit 整链重写 + O(pool) 去重扫描

- **状态**: 部分交付（去重/观测痛点已闭合并验收；写放大痛点不可在现有崩溃模型下安全闭合，
  拆分至 `issues/T-39-C-followup-append-only-freelist.md` 后续立项）
- **交付注记**: 本次 TDD 完成"去重收敛 + 静默吞错可观测化 + FreelistStats 观测 API"
  （T-39-B），并独立评审通过（review.md verdict=approve）+ T-27 崩溃注入矩阵稳定全绿
  （T-39-D，test-report.md）。增量/append-only 链持久化（写放大痛点）经论证在不改
  T-33 崩溃安全模型（两代退休 + 统一 gen 戳 + INV-F1/INV-F2）硬约束下**不可安全落地**
  （页复用下无 freshness proof 时无法区分陈旧合法内页与当前页，torn-sync 窗口会导致
  双重分配损坏），故降级记录为 follow-up issue 交回 conductor 立项。
- **优先级**: **medium-high**（持久化/性能梯队；3/4 worker 独立提出，代码自身注释已承认升级路径）
- **梯队**: 持久化/性能（尚未成为暴露瓶颈，但随空闲页数必然放大）
- **来源**: 演进点征集（roadmap-evo）wf-pi-1-E3、wf-pi-2-E3、wf-pi-3-E2
- **基线**: HEAD `4d7b1c8`（行号均基于此）
- **对应旧清单**: U-2（freelist 持久化改增量/append-only）+ U-3（池去重扫描 + 不再静默吞错）

---

## 摘要

`FilePageStore.vtWriteMeta` **每次** meta 提交都调用 `persistChainLocked` 把**整个空闲页池**
从零重新序列化成一条全新 FREE 链（整链 COW 重写），成本 O(free_pages/1016) 页
memcpy+CRC；且 `pushPoolLocked` 每次 free 都对池做 `std.mem.indexOfScalar` 线性去重扫描
（N 次 free = O(N²)）。**两者成本都随空闲页数线性/平方增长**——空闲池一大，每次 commit
（哪怕只 put 一个 key）都在重写"一堆跟本批次无关的页"。

高删除工作负载下（COW 使每次改写产生旧页）空闲池持续变大，之后每次 commit 的整链重写
+ 每次 free 的 O(pool) 扫描都直接进 profile。这是写路径上**随空闲页数增长的固定开销**。

## 现状 / 机制佐证

- `src/file_page_store.zig:316-320` `persistChainLocked`：`n = freelist.len` 全量序列化，
  `k = ceil(n/(cap+1))` 页链，每次 commit 重建
- `src/file_page_store.zig:591-635` `vtWriteMeta`：retire 旧链 + 全量重建在同一个
  freelist_mu 临界区，是 commit 路径的固定组成
- `src/file_page_store.zig:267-268` `pushPoolLocked` 的 `indexOfScalar` 线性去重
- `src/file_page_store.zig:268` `append(...) catch {}` **静默吞错**（OOM 时静默丢页，
  安全但泄漏空间、零观测）
- **代码自身承认升级路径**：`src/file_page_store.zig:316` ponytail 注释
  "whole-chain rewrite per commit costs O(free_pages/1016) page memcpy+CRC (~400KB at
  100k free pages)"；`:264-268` "O(pool) scan per free; upgrade to a HashSet-backed pool"
- 链结构常量 `src/format.zig:26` `MAX_FREE_ENTRIES_PER_PAGE=1016`/页
- 现成量测工具：`bench/fps_bench.zig`、`profile_commit`

## 建议演进方向

- **增量/append-only 链持久化**（LMDB freelist 风格：追加 dirty 记录，头部周期性 compact），
  使每次 commit 成本从 O(空闲页总数) 降到 O(本次新增空闲页)；或
  **dirty-flag 跳过未变池**；
- 去重结构化（按位图/有序结构二分，或利用"池保持升序"的不变量）；
- `append catch {}` 静默吞错改为计数器/日志观测。
- 注意崩溃语义：append-only 需要把「链页复用 + gen 戳」升级为「追加 + 头部合并」，
  T-27 崩溃注入矩阵必须语义等价通过。

## 可测验收判据（RED→GREEN）

- (a) 构造 10 万空闲页的库，commit 一个小批次的元数据写字节数相比整链重写下降 ≥ 一个
  数量级（用 write 计数 hook 或页分配数差衡量）；
- (b) T-27 崩溃注入矩阵（before/mid/after chain）在 append-only 版本下全部语义等价通过；
- (c) 重启后空闲页池与链一致（复用 T-33 既有用例）；
- (d) `pushPoolLocked` 重复 free 同页时仍幂等（既有 INV-F1 断言不破）。

## 关联

- 与 T-37/T-38 交互：E-1/E-2 落地前，delete/deleteRange 的墓碑路径持续把页送进空闲池，
  池只增不减——正是写放大曲线变陡的场景。三个演进点实为同一条退化曲线的三面。
- 即使 T-37/T-38 先落地，长期运行的库（高 churn 负载）仍会积累大池，值得独立收敛。

## 状态跟踪

- [x] 现状核验（3 worker 独立确认 U-2/U-3 在当前 HEAD 成立）
- [x] 确定性 RED 测试（`tests/core_format/freelist_amp_red_test.zig`，T-39-A，HEAD 上 4 fail 确定性验证有效）
- [x] 去重收敛修复（T-39-B：`pushPoolLocked` O(pool)→O(1) HashSet 镜像；静默吞错可观测化
  `dropped_pages_oom`；`FreelistStats` 观测 API）—— 已合并 main，RED #2/#3/命名契约全绿
- [x] 回归测试（T-39-D 独立评审 approve + T-27 崩溃矩阵 T5 全注入点/T6 夹具/T5-b/r 稳定全绿，
  零 flake；10 套件确定性套件 exit 0）
- [ ] 写放大（增量/append-only 链持久化）—— **未闭合**：现有崩溃模型下不可安全落地，
  拆分至 `issues/T-39-C-followup-append-only-freelist.md`，RED #1 仍红（20/20 链页）为其遗留断言
- [ ] 验收门（RED #1 绿 + 新格式全矩阵语义等价）稳定后关闭（见 follow-up issue）

# Issue T-39-C-followup — append-only freelist 增量持久化在现有崩溃模型下不可闭合（impossibility 记录）

- **状态**: proposed（T-39-C 降级交付记录，待 conductor 立项处理）
- **优先级**: medium（性能梯队；正确性不受影响，现有整链重写是安全的）
- **归属**: T-39-C（增量/append-only FREE 链持久化）未闭合部分
- **基线**: T-39-impl 分支 `a384334`（T-39-B 已落地：O(1) 去重 + 静默吞错可观测化；
  RED #2/#3/命名契约已绿）
- **结论**: 在**不改动 T-33 崩溃安全模型**（两代退休 + 统一 gen 戳 + INV-F1/INV-F2）
  的硬约束下，append-only 增量链持久化**无法安全落地**——需要新的磁盘格式不变量
  （freshness proof）。本文记录不可能性论证、反例、已评估方案与前进方向。

---

## 摘要

T-39-C 的目标是让 RED #1（写放大断言：small commit 不再整链重写）转绿，方向是把
`persistChainLocked` 的每次 commit 整链 COW 重写降为增量/append-only。设计阶段证明：
**在"链页从空闲池复用 + 统一 gen 戳"的现有模型下，任何放松 `gen == meta.sequence`
校验以允许"追加页带各自 commit 的 seq"或"跳过未变池复用旧页"的方案，都会在
torn-sync 崩溃窗口下把"陈旧但字节合法"的内页误当当前内容接受，还原出仍 live 的
页 → 双重分配 → 数据损坏**。这比现状（严格 gen==seq，陈旧链整链丢弃 = 泄漏方向，
安全）更糟。因此正确性上不可接受，T-39-C 按 conductor 决定降级为本文记录。

T-39-C 已闭合的部分（T-39-B，commit `a384334`）不受影响：去重 O(1)、静默吞错
可观测、`FreelistStats` 观测 API、`chain_pages_written` 语义（本次 commit 实际写出的
链页数，含整链重写的 k 页——RED #1 在整链重写策略下恒写满链，正是该断言红着的
真实原因）。

## 不可能性论证（核心）

**模型事实**（T-33，全部是既有代码语义）：

1. 链页本身从空闲池分配（`popPoolLocked`/`bumpPageLocked`），用完退休后**回到池里
   被复用**——同一个页号在不同 commit 里可能承载不同代数的链内容。
2. 唯一的代数标识是 `hdr.gen = meta.sequence`（H1）；`restoreFreeList` 要求每个链页
   `gen == meta.sequence`，否则整链丢弃（INV-F2，泄漏方向安全）。
3. 崩溃窗口：链页先于 meta 落盘（write-order 保证），meta 切到新链头后单次 fsync；
   torn-sync（power loss）下磁盘可能留下"新 meta + 部分旧链页字节"的组合。
4. 两代退休保证：一个链页只有在指向它的 meta 死亡后才会被回收复用——**活 meta 的
   链不会可达"已被复用的陈旧页"**，但这只覆盖"页被活链引用又被复用"的场面，
   **不覆盖"磁盘上残留陈旧字节 + 新 meta 恰好指向它"的 torn-sync 场景**（见反例）。

**论证**：append-only 的本质是"链上不同页承载不同 commit 的增量"，即同一时刻活 meta
的链必然包含 `gen ∈ {多个历史 seq}` 的页。于是 restore 的 gen 校验必须放松为
`gen ≤ meta.sequence`（conductor steer 中的 rule (a)）。但页复用意味着磁盘上任何
`gen ≤ seq` 且 CRC/type/range/count 全部合法的 FREE 页字节**都可能是上一轮生命的
陈旧残留**——没有任何字段能区分"这个合法页是本 meta 链的当前成员"与"这是它上一代
被复用前的尸体"。严格 `gen == seq` 之所以安全，正因为它把"任何不一致"都归入 INV-F2
丢弃（泄漏）；一旦放宽到 `≤`，就把"校验全过但陈旧"的尸体也放进来了。

## 反例（torn-sync 窗口 → 双重分配 → 损坏）

设 commit 序列 S0 → S1，池复用页 P3：

1. S0 时 P3 作为 S0 链的内页落盘，内容 `entries_A`，`gen = S0`（含页 X）。
2. S0 的 meta 退休、P3 回池；S1 commit 时 P3 被复用为**数据页**（比如新 leaf），
   分配给了 btree——此刻 X 在 S1 的树里是 live 页。
3. power loss 落在 S1 的 torn-sync 窗口：S1 的新 meta 已 durable，但 P3 的新字节
   （leaf 内容）**没有**落盘，磁盘上 P3 仍是 `gen = S0` 的完整合法 FREE 页
   （CRC/type/page_no/count 全过）。
4. reopen：S1 链（append-only）需要 P3 作为内页；rule (a) 下 `gen = S0 ≤ S1` **通过**，
   `entries_A` 被还原进池——**X 被当作空闲页交出去 → 双重分配 → 已提交数据损坏**。

现状（严格 `gen == seq`）在同一场面下：P3 的 `gen = S0 ≠ S1` → 整链丢弃 → X 永不
入池 → 只是泄漏。**泄漏 vs 损坏，这就是不可放宽的边界。**（T6 v6 夹具钉死的正是
"陈旧代字节必须被拒"这一语义。）

## 已评估方案与不成立原因

| 方案 | 思路 | 为何不成立（在现有模型内） |
|---|---|---|
| dirty-flag skip-unchanged（朴素版） | 池未变时 meta 直接复用上次的 free_head/free_count，不写链页 | meta.sequence 前进了但链页 gen 仍是旧 seq → reopen 时 `gen != seq` → **每次未变池 commit 之后必然整链丢弃**（从"省写"变成"必丢"）。要么接受丢（性能目标落空且泄漏增长），要么放宽 gen 校验 → 回到反例 |
| head-restamp skip-unchanged | 同上，但把链头页用新 seq 重打 gen 戳（只写 1 页），保持 `head.gen == seq` | 只救了头页：内页 gen 仍是旧 seq，restore 仍需放宽为 `≤` 才能走完整链 → 反例复活。且头页重写自身还引入"头页新戳 + 内页旧字节"的新陈旧组合 |
| gen ≤ seq 游走 + 首个 gen > seq 停止 | conductor steer rule (a)：快照页带写入时 seq、追加页带各自 seq，walk 时接受 `≤` 并在 `>` 处截断 | 截断解决"过新"，不解决"过旧"：反例里 P3 的 `gen = S0 ≤ S1` 且校验全过，在截断点**之前**就被接受。如上论证，页复用 + 无 freshness proof 时无法区分陈旧合法页与当前页 |
| per-commit nonce / freshness proof | 链上记录随 meta 单调前进的 per-commit 值，restore 校验"页属于本 meta 的链历史" | **方向正确但超出 T-39-C 范围**：需要新的磁盘格式不变量（nonce 存储、链-序关系、与两代退休的交互）、T-27 崩溃矩阵语义重新定义与全量复验（T-39-D 的硬门槛）、旧格式兼容读取。契约明令"不改 FREE 页字节布局"，此路是独立演进点，不是本任务的有界收尾 |
| 不复用链页（链页专用页空间，永不回池） | 消灭"陈旧合法页"的来源 | 改变页空间管理模型（page_no 语义、T7 分区、复用率），整链容量无界增长，同样是大格式变更；且与"compact 后链页回收"冲突 |

## 可行的前进方向（供立项参考）

要求磁盘链格式**新增不可伪造的 freshness 载体**，候选：

1. **per-commit 单调 nonce 序列随链存储**：meta 记录当前 nonce N；每个链页写
   `gen = N`（不复用 meta.sequence 双重语义）；restore 严格 `gen == N`。等价于把
   "两代退休"从"seq 比较"升级为"链世代号"，torn-sync 下陈旧页 nonce 不匹配 → 丢弃
   （回到泄漏方向）。需要：meta 格式字段、T6 夹具同步、T-27 矩阵重新定义等价语义。
2. **分段 gen + 段内校验和**：链按快照段组织，每段携带段号 + 段内容 digest，
   meta 记 (段数, digest)，restore 校验 digest 而非逐页 gen。崩溃窗口由 digest 覆盖。
3. 两者都需要：格式版本化 + 旧格式兼容读取（INV-F2 语义不变）+ T5/T6 全矩阵复验 +
   T-39-D 语义等价复核。

## 建议的验收（未来立项时）

- RED #1（freelist_amp_red_test 写放大断言）转绿：small commit `chain_pages_written
  ≤ max(4, full/8)`；
- T5 崩溃矩阵（4 注入点 + baseline + reopen 幂等）在新格式下语义等价全绿；
- T6 夹具（v0–v10）最小侵入同步，INV-F2 判定语义不变；
- 旧格式文件可直接打开（兼容读取），或提供一次性升级路径；
- churn 基准（bench/fps_bench.zig）写放大曲线对比。

## 关联

- 父 issue：`issues/T-39-freelist-persist-write-amplification.md`（本 issue 是其
  "增量/append-only"方向的未闭合部分）
- 已闭合部分：T-39-B（commit `a384334`：O(1) 去重 + 静默吞错可观测 + FreelistStats
  观测 API；RED #2/#3/命名契约绿）
- RED gate：`tests/core_format/freelist_amp_red_test.zig` RED #1 仍红
  （small commit 写满 20/20 链页——整链重写策略的真实计量），归本 issue 后续处理
- T-39-D：崩溃注入矩阵复核方；任何新格式方案落地前需与其等价语义对齐

## 状态跟踪

- [x] 不可能性论证 + 反例（本文）
- [x] 已评估方案清单与不成立原因（本文）
- [ ] freshness 载体格式设计（nonce / 分段 digest，二选一或合并）
- [ ] T-27/T5 崩溃矩阵语义重定义 + T-39-D 对齐
- [ ] T6 夹具最小侵入同步方案
- [ ] 实现至 RED #1 绿 + 全矩阵绿

# T-39-D review — T-39-B 去重 O(1) + 静默吞错可观测化（崩溃安全复验）

- **Reviewer**: cube_db-pi-1（T-39-A 测试作者；T-39-B/C 实现者为 cube_db-pi-2 — 独立性成立）
- **Reviewed SHA**: `a384334`（T-39-B），评审分支 **T-39-integration** head `7c428c2`
  （= a384334 + 55e58f6 RED gate 合入 + 7c428c2 T-39-C 降级 issue；`ad82cb2..HEAD` 的 src 改动仅 a384334）
- **范围调整（conductor）**: T-39-C append-only 已论证不可安全闭合、降级为
  `issues/T-39-C-followup-append-only-freelist.md`。本次评审**无磁盘格式改动**，
  硬门槛 = T-39-B 不破坏 T-33/T-27 崩溃安全模型 + T-39-A 去重/观测断言绿 + 矩阵稳定。
- **Verdict**: **approve**

---

## 1. 变更范围确认（崩溃模型未触碰）

`src/file_page_store.zig` 唯一 src diff 是 a384334（+168/−7）。逐项核对：

- **磁盘格式零改动**：FREE 页字节布局、`MAX_FREE_ENTRIES_PER_PAGE`、`persistChainLocked`
  的整链重写算法、链页写入循环、gen 戳（`gen = seq`）、meta 字段覆盖、两代轮转
  （chain_prev→chain_cur）全部原样。
- **崩溃注入点零改动**：5 个 `fireCrashHook`（before_chain `:708`、mid_chain `:447`/`:724`、
  after_chain_before_meta `:749`、after_meta `:758`）位置逐一比对未动；
  `git diff ad82cb2..HEAD` 中唯一相关新增是 `freelist_stats.chain_pages_written += k` 统计行
  （persistChainLocked 尾部，不参与任何写序）。
- **restoreFreeList 判定链零改动**：XOR gate / bound1 / bound2 / revisit guard / CRC / type /
  page_no / gen 戳 / total 匹配 / 排序后 range+dup+self-ref 检查 —— 全部原样，v0..v10 的
  接受/丢弃语义由测试原断言锁定（复验全绿，见 test-report.md）。

## 2. pool_set 镜像同步审计（核心风险面）

T-39-B 的正确性关键是"池唯一真值 + set 镜像 1:1"，危险方向是 **set 漏收**（池有 set 无 →
re-free 双列 → 双分配）。逐个写点审计：

- `pushPoolLocked`（`:321-339`）：getOrPut OOM → 丢页计数，池/集双未动 ✓；
  found_existing → no-op（INV-F1 幂等保持）✓；池 append OOM → 先回滚 set 插入再丢页计数
  （保持 set ⊆ pool，注释明确指出反向是 unsafe 方向）✓。
- `popPoolLocked`（`:296-301`）：池 pop + set remove 同步，remove 无失败路径 ✓。
- **全部 `self.freelist` 写点核对**：grep 确认除 restoreFreeList 的整体赋值（`:594`）外，
  池的所有增删都走 *Locked 原语 — 无旁路写点。
- `restoreFreeList`（`:575-594`）：set 重建在**全部校验之后、采纳池之前**；OOM → 整链丢弃
  （free_list_discarded，INV-F2 泄漏方向），池保持空 ✓。entries 在 T6 v3 已验证无重复，
  put 无碰撞前提成立 ✓。init 单线程段，无并发窗口 ✓。
- 失败方向一致性：所有 OOM 路径都是**泄漏方向**（丢页/丢链），无一处引入误回收方向 ✓。

## 3. 语义保持

- **allocPage 取出顺序**：池仍是 LIFO 尾弹，freePagesSnapshot 输出序不变（实现者否决
  二分/有序插入方案的理由成立——池只在 restore 后升序，运行期无序，且改序会破坏契约
  四函数语义；hash 镜像是零语义改动的选择）✓。
- **INV-F1（幂等 free）**：单次 getOrPut 探测，found_existing 短路，与旧 indexOfScalar
  判重语义等价 ✓（T-39-B 自测 + T-39-A RED #2 双向锁定）。
- **pushPoolLocked 的 P0-A 依赖**（restore 接受含 tree 页的链 → reclaim 合法 re-free）：
  镜像方案下 re-free 同样被去重，语义保持 ✓。
- **并发**：stats 增减全在 freelist_mu 临界区内；resetFreelistStats/freelistStats 取同锁
  （freelistStats 用 freePageCount 同款 constCast 模式）✓。reset 与进行中 commit 的竞争
  由锁串行化 ✓。

## 4. 可观测 API（T-39-A 契约比对）

- 命名与 T-39-A 固定契约完全一致：`FreelistStats{chain_pages_written, dedup_scans,
  dedup_membership_probe, dropped_pages_oom}` + `resetFreelistStats`/`freelistStats`，
  且 `FilePageStore.FreelistStats` 与 `file_page_store.FreelistStats` 双路径可达。
- **非空转验证**：dedup_scans/dedup_membership_probe 每次 free 恰 +1（T-39-A RED #2
  实测 64 次 re-free = 64 探测，与池大小无关）；dropped_pages_oom 在 FailingAllocator
  强制 OOM 下真实 +1（实现者自测），健康路径 0。
- **chain_pages_written 口径**：`+= k`（每次 persistChainLocked 实际写的链页数，含整链
  重写的 k 页）。在整链重写策略下 small commit 恒写满链 — 这正是 RED #1 红着的真实
  度量，不是空转计数。真实消减归 T-39-C-followup。

## 5. 发现（非阻塞）

1. **Minor（口径备注）**：`chain_pages_written += k` 在 persistChainLocked 的 fallback
   早退路径（链页写一半 OOM 回滚）不计数 — 已写的部分链页不计。骨架口径下无碍，
   follow-up 落地增量语义时建议同步明确 torn 路径的计数口径。
2. **Minor（内存放大备注）**：pool_set 为每空闲页 ~1.5-2 slot 的哈希镜像（20k 池
   ≈ 200KB 量级）— 可接受，follow-up 若引入 dirty-flag/skip 路径可顺带评估合并。
3. **观察（既有）**：`zig build test` 下个别 run 步骤打印 freelist/T7 诊断 stderr 并在
   步骤树里渲染为 `w`，但 Build Summary 均为 success（zig 0.16 server 模式的 stderr
   回放渲染，T-37-C 已分析过）— 与 T-39-B 无关，不构成发现。

## 6. 结论

T-39-B 是一次**纯内存层**改动：磁盘格式、写序、注入点、恢复判定零触碰；镜像同步在
每个写点上朝安全方向闭合；观测 API 命名与 T-39-A 契约逐字一致且度量真实。崩溃矩阵
（T5 全注入点 + T5-b/r + T6 v0..v10 + 全 crash 聚合 70 测试）多轮复验全绿零 flake
（详见 test-report.md）。

**Verdict: approve**

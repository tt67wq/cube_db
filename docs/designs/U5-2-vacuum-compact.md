# U5-2 设计稿 — 在线 `compactFull`（真·compact）+ 离线 vacuum 的边界

- 任务: U5-2（设计，不含实现代码）· 分支 `U5-2-design` · 基线 `8f578cd`
- 前案: `evolution-proposals-cube_db-pi2.md` ①节 / `evolution-proposals-cube_db-pi3.md` §1（E-1 三 worker 独立收敛到同一演进点）
- 所有 `path:line` 引用均在 blob `8f578cd` 核对（本分支 src/ 与基线零差异）。

---

## 0. 摘要与结论

| 决策点 | 结论 |
|---|---|
| API | 新增 `Db.compactFull(opts: CompactFullOptions) !CompactFullStats`；O(1) `compact()` 原样保留 |
| 提交模型 | 「一次巨型提交」：全程持有 `write_mutex`，流式拷贝不发布，**单次** packed 换根（对读者等价于一次普通 commit） |
| 墓碑链 | 拷贝后**整链丢弃**（新树只含可见条目，发布 `tomb_head=0`）；旧读者靠自身 snapshot 的 `(root, tomb_head)` 对继续正确读 |
| 旧树退休 | publish 时一次性 `queuePendingFree`（全树+链页，release_seq = 新 sequence）；复用现有水位回收，不新增机制 |
| freelist 持久化 | **一次大链**：compact 后首个无读者 commit 的 `vtWriteMeta` 自然把整个池写成一条链（摊销恰是期望行为），拒绝人为分批 |
| 文件收缩 | 在线**不收缩文件**（页号即身份，truncate 破坏 freelist 页恒等）；收缩是离线 vacuum（换文件+rename）的专属出口 |
| 崩溃矩阵 | 拷贝期磁盘零新状态 → 仅 +1 个过程性 tag `compact_mid_copy`；最终提交复用现有 7 个 tag 重跑 |
| 计数器 | 绝对值直设（非 delta）：`entry_count=V`、`byte_size=B`（流式实测），构造性保证三口径一致，顺带修复历史漂移 |

---

## 1. API 形态与公共契约

### 1.1 命名与签名

```zig
pub const CompactFullOptions = struct {
    /// 每 batch 调用一次；返回 false = 中止（error.CompactAborted，无发布、无副作用）。
    /// copied = 已拷贝可见条目数。Hint 阶段不做总量预估（见 1.3）。
    progress: ?*const fn (copied: u64, batches: u64) bool = null,
};

pub const CompactFullStats = struct {
    entries_copied: u64,   // V：新树可见条目数
    live_bytes: u64,       // B：Σ(key.len + value.len + 10)
    old_pages_retired: u64,// 退休的全树+旧链页数
    batches: u64,
    chain_dropped: bool,   // 旧链非空且已随本次丢弃
};

pub fn compactFull(self: *Db, opts: CompactFullOptions) !CompactFullStats;
```

理由：`compactFull` 与 `compact()` 对称、语义自明（full = 全量重写）；`vacuum` 留给离线工具
（U5-4 `cube_check vacuum`），两条路径名字不同正好承载能力不同（见 §6）。

### 1.2 与 O(1) `compact()` 的并存关系

`Db.compact()`（src/db.zig:541 → src/writer.zig:484-502）契约**一个字不动**：O(1) meta 切换 +
`reclaimPendingFree`，仍是对外默认出口。`compactFull` 是显式 O(n) 的重写型出口，文档明示三件事：

1. **阻塞写者**：全程持有 `write_mutex`（src/db.zig:36 单写者锁），持续 ≈ 重写耗时；
2. **读者不阻塞**：MVCC 读不感知（新读者全程读旧根直到 publish，旧读者靠 pin 存活——§2.4）；
3. **不收缩文件**：效果是「空间回收为可复用 + 死条目物理清除 + 墓碑链归零」，OS 级文件缩小走
   `cube_check vacuum`（§6）。

### 1.3 公共契约文档改动

- `docs/usage.en.md`：§3 compact 段（:335「O(1)」、:338、:342、:356、:488 快速参考）旁新增
  `compactFull` 小节：何时用（delete-heavy 之后 / gcTombstones 收不动的链 / 发布前瘦身）、代价
  （O(n)、阻塞写、约 ×2 瞬时空间——新页写完才退休旧页）、不收缩文件。
- `docs/usage.md` 镜像同步。
- `README.md` 特性表保留「**O(1) compact**」一行（默认契约未变），其下加一行
  「`compactFull`: explicit O(n) full rewrite — dead-entry removal + tomb-chain convergence」。
- 进度回调**保留**（v1 就有）：5 行实现换来 O(n) 操作的最基本可观测性；不提供总量预估
  （预估算 O(n)，比拷贝本身还贵），CLI/调用方要百分比就先 `entryCount()` 自己算分母。
- 不加任何 `Options` 配置位（chunk 大小、回调频率等都是常量——没有第二个取值就不该是配置）。

---

## 2. 重写算法

### 2.1 总体：一次巨型提交

对提交协议而言，`compactFull` **就是**一个 `applyBatchSwap` 形状的提交（src/writer.zig:619），
只是 batch 换成「流式逐批 insertBatch 到未发布的新根」：

```
① try self.flush()                      // staging 必须先可见（deleteRange 先例 src/db.zig:281）
② write_mutex.lock()                    // 全程持有：根冻结、无交错 commit
③ (root, tomb_head) = captureRootTomb() // src/writer.zig:269，冻结快照
④ fast path: root==0 && tomb_head==0 → 零副作用返回（镜像 gcTombstones src/db.zig:513）
⑤ it = self.select(null, null)          // 可见条目流（见 2.2）；写锁内调用有先例 src/db.zig:332
⑥ 循环：arena 内 dupe → 按 count+payload 预算切块 → btree.insertBatch(new_root, chunk)
        → 累计 V/B/new_pages；每批后 progress 回调（false → 清退 abort，§2.5）
⑦ old_pages = collectTreePages(root) ++ loadTombChainInto(...).old_pages
⑧ queuePendingFree(old_pages, seq+1)    // src/writer.zig:367
   // 注：old_pages 可能与 pending_free 已有条目重叠（上次普通 commit 的 COW victim
   // 尚未放行）——双重入队是**允许的**：pool_set 层幂等去重（src/file_page_store.zig:366-378
   // `if (gop.found_existing) return;`，P0-A 同一语义），双条目只多占 16B 与一次 hash probe。
   // 实现禁止「优化」成 assert(!contains(p))——合法状态，不是不变量违反（§3.1）。
⑨ writeCommitMeta(new_root, 0, sticky_version, seq+1, V, B)   // src/writer.zig:279
⑩ publishSnapshot(new_root, 0) + sequence/entry_count/byte_size store（镜像 step 7 src/writer.zig:869-874）
⑪ reader_count==0 → reclaimPendingFree()（applyBatch step 9 模式 src/writer.zig:877-879）
```

为什么不分多次 commit 渐进发布：发布后的新根立刻成为读者可见状态，若拷贝中途发布半棵新树，
后续批次必须基于「新根 + 期间读者」增量推进，等于把单写者协议重写一遍——纯风险零收益。
一次发布下，崩溃面（§4）和计数器面（§5）都是已有机制的直接重放。

### 2.2 流式 select：可见集 = 迭代器天然输出

`Db.select(null, null)`（src/db.zig:458）恰好就是「可见条目流」：
- 树内 tombstone 条目被迭代器跳过（src/btree.zig:2304 `if (ev.tombstone) continue`）→ 点删死 key
  物理死亡（compact 的核心目的）；
- 区间墓碑遮蔽由 `loadShadowCtx` + `shadowSkip` 过滤（src/db.zig:475-476）→ 被 C1 遮蔽的物理条目
  不进新树（T-38 设计承诺的「物化清除」出口，issues/archived/T-38-…md:49/65）；
- 溢出值由迭代器 `ov_buf` 组装（src/btree.zig:2223）→ 拷贝侧拿到完整 value。

切片生命周期：`next()` 返回的 value 指向 `ov_buf`（**下一次 next() 即失效**，src/btree.zig:2221-2223），
key 指向 pin 住的稳定页。因此每批把 key/value dupe 进 batch arena（materializeSegment 同款模式，
src/db.zig:1051、:1144-1161），`insertBatch` 落页后再 arena reset。批量内存上界 = chunk 预算（2.3）。

### 2.3 批量切块：count + payload 双预算

单批 chunk 规则（直接复用既有两个教训）：
- **count 上界 256**：`deleteRangeMaterialized` 的 `CHUNK = 256`（src/db.zig:360-361）；
- **payload 上界 ~256KB**：T-40 教训——batch 必须按字节而不只按条数切
  （tests/crash_insertbatch_pb/insertbatch_capaware_test.zig、src/btree.zig:1636/1713 的
  byte budget 注释）。流里一条 value 可达任意大小（溢出链），故按
  `Σ(key.len + value.len)` 累计超 256KB 即切批；单条超限者独占一批（value 本体走溢出链，
  叶内只占 4B 指针，src/btree.zig:154-176）。
- `insertBatch` 的 per-entry `MAX_KEY_SIZE` 门自动继承（src/btree.zig:1579-1581）——
  能被读出来的 key 一定早已通过同一门，无需特判。

`insertBatch` 对非空根走 `insertBatchIntoBranch`（src/btree.zig:1997）逐页分裂，新根可能长高，
splice 重建层级的路径（src/btree.zig:1596-1620）原样可用。批间 dirty 页累积到
`all_new_pages`（abort 清退与 §4 泄漏核算共用这一张表）。

### 2.4 墓碑链收敛：整链丢弃，旧读者自洽

拷贝完成后发布 `(new_root, tomb_head=0)`——链整条丢弃。正确性论证：

1. **未来读者**：新树只含可见条目，无链可遮，`get/select` 的 `tomb_head==0` 短路
  （src/db.zig:406-408、:473-474）直达树，行为与「从未 deleteRange 过」的库逐字节一致。
2. **旧读者**：`beginRead` 注册时捕获的 snapshot 就是 `(root, tomb_head)` 打包对
  （src/writer.zig:190-197、:269-273；ReadTxn 用 `snapshot_tomb_head` 过滤，src/db.zig:727）。
  旧读者继续读旧根 + 旧链，publish 不影响他们的捕获值；旧链页按 `queuePendingFree(old_pages,
  new_sequence)` 退休（commitTombSwap 完全相同的纪律，src/writer.zig:1006-1013 注释），
  水位放行前页不被复用——旧读者到 `endRead` 为止读到的都是原字节。
3. **发布态合法性**：`tomb_head=0` 是 v3 库的合法发布态——gcTombstones 收空链时即发布 head 0，
  且「v3 永不降级」由 sticky 版本保证（src/writer.zig:1025-1027 注释；compactFull 透传
  `self.meta_version.load(.acquire)`，不写死 2）。
4. **可见性不变量 INV-RT1**（遮蔽 key 读不到）：新树里根本没有这些 key，不变量构造性成立。

与 `gcTombstones` 的关系：compactFull 后 `tomb_head=0`，gc 变成永久 no-op——**compactFull 蕴含
gcTombstones**。文档写明推荐顺序：日常用 gc（O(chain)），维护窗口用 compactFull（O(n) 一次清干净）。

### 2.5 中止（progress 返回 false）

未发布 → 无任何持久化后果。清退：对 `all_new_pages` 逐页 `store.freePage()` 归还池
（这些页或来自池、或来自 bump，均无读者可见引用；归还池后由后续 commit 持久化或按
n<=1 规则滞留池内，src/file_page_store.zig:439-441），返回 `error.CompactAborted`。
计数器、根、链全部原样。

### 2.6 溢出链

无特殊路径：读侧由迭代器 `ov_buf` 组装（§2.2），写侧由 `insert → writeOverflowPages`
（src/btree.zig:181-216）重建新链。旧溢出链页不进新树，作为旧树页的一部分被 §3 收集退休。
唯一注意点：`collectTreePages` 遍历叶条目时要沿 `LEAF_FLAG_OVERFLOW`（src/btree.zig:179）的
4B 头页号 + `free_next` 链接收尾全部溢出页（MVP 无 nkeys 更新，链靠 free_next，src/btree.zig:182），
并带 visited-set 防环——T-52 的教训（准 hang）在收集器里花 10 行买断。

---

## 3. 旧树退休与 freelist 持久化策略

### 3.1 一次性 retire（分批 retire 不可行，直接排除）

分批 retire = 拷贝途中把已读过的旧页 `freePage` 入池 → **不可能安全**：旧根在被发布替换前始终是
读者可达状态，任何旧页都可能被某个 snapshot 引用；入池页会被后续分配复用，旧读者即读脏。
唯一正确形状就是现行 COW 纪律：**publish 时全量 `queuePendingFree`（release_seq = 新 sequence），
由 `reclaimPendingFree` 的水位（src/writer.zig:533-547）放行**。本设计不发明新机制。

内存代价：`PendingPage` 16B/条（src/writer.zig:28-33），1M 退休页 ≈ 16MB 常驻直到读者放行。
**最坏 32B/页**：同一旧页可能已在 pending_free 里有一条旧记录（上次普通 commit 的 COW victim，
release_seq ≤ N，被长读者 pin 住未放行），compactFull 的 ⑧ 再追加一条 release_seq = N+1 的
新记录——两条共存是合法状态（§2.1 ⑧ 注），池侧由 pool_set 幂等去重兜底，只多占一条 16B。
实现**不得**入队前去重（额外 O(pending) 扫描买不来任何东西，评审 Blocking B 方案 (b) 已弃）。
- 量化上限：全库页数 = 文件页数，1TB 理论上界 268M 页 ≈ 4.3GB（最坏双条目 8.6GB）——**不设防的诚实上限**，
  以 ponytail 注释记录（upgrade path：publish 后延迟收集，需 freshness 判据，即 T-39-C 同族问题）。
- 实际工作面：vacuum 目标库是 delete-heavy 后的库，页数远低于上界；且 ⑪ 的即时回收在
  `reader_count==0`（维护窗口常态）时**当步清零**，列表只是过路状态。
- 入队调用分片（每 64K 页一次 `queuePendingFree`）只为限制单次锁持有时间，语义不变。

### 3.2 mass-retire 对链持久化的冲击：一次大链，拒绝人为分批

时序关键点：retire 发生在 publish 步（内存列表），旧页进入**池**要等下一次
`reclaimPendingFree`（无读者时 applyBatch step 0 / compact 即刻做，src/writer.zig:630-634、:487）。
因此冲击落在 **compactFull 之后的第一个无读者 commit**：`vtWriteMeta` 的
`persistChainLocked` 把整个池（≈ 旧树页数 n）一次性串成 k=⌈n/1016⌉ 页 FREE 链
（src/file_page_store.zig:434-449，`MAX_FREE_ENTRIES_PER_PAGE=1016`，src/format.zig:34-36）。

- 成本：1M 空闲页 ≈ 986 链页 ≈ 4MB mmap memcpy+CRC，**一次性**，无 syscall
  （ponytail 注释自认的同型数字，src/file_page_store.zig:430-432）；
- 安全性：这正是 T-39 写放大痛点的**期望 amortization**——与其每 commit 重写整链，不如让
  compact 后的池在单次 commit 里成链。fallback `{head=0,count=0}`（OOM 时跳过持久化，
  泄漏方向，src/file_page_store.zig:452-456、:787-802）原样兜底；
- H1 gen 校验无交互：链页由 `persistChainLocked` 以当前 sequence 重盖章
  （src/file_page_store.zig:483），restore 只认 `hdr.gen == meta.sequence`
  （src/file_page_store.zig:565-566）——旧树页的旧内容被整页覆盖，与页的来历无关；
- **为什么不分批**：人为给池增长设闸（每 commit 只回收 X 页）只会把同一场 4MB 写拆成 N 次、
  拉长「未持久化池」的暴露窗口（掉电即泄漏），纯负收益。若未来实测该尖峰进 profile，
  那是 T-39-C freshness-proof 的立项论据，不是本设计要预支的复杂度
  （观测就位：`FreelistStats.chain_pages_written`，src/file_page_store.zig:81-100）。

验收口径（进 §7 步骤 4）：构造 10 万空闲页库 → compactFull → 下一 commit 断言
`chain_pages_written` 单次跳变 ≈ ⌈n/1016⌉，且 T-27 崩溃矩阵全绿。

### 3.3 文件收缩边界（明确不做）

在线收缩文件 = 截断 `next_free` 之上——但池中页号是全距散布的（`bumpPageLocked` 只推高水位，
src/file_page_store.zig:387-393；`ensureFileGrowth` 只向上 ftruncate，src/file_page_store.zig:319-335），
任何截断都可能切掉池内页。页号即身份的格式不变量（vtable 契约，src/page_store.zig:17-53）下，
**在线路径不存在安全收缩**；收缩属于离线 vacuum（拷进新文件 + rename，页号整体重排）。
这条边界写进两个文档，杜绝「compactFull 怎么不缩文件」的必然 issue。

---

## 4. 崩溃矩阵

### 4.1 关键性质：拷贝期磁盘零新状态

拷贝期间只发生两件事：新页 `writePage`（mmap 脏页）、内存列表增长。**meta 双槽未被触碰**，
崩溃后重开 = 现行恢复路径原样接管：
- 新树页若来自池：仍在持久化链里，restore 认领（内容是垃圾但池页不验内容）；
- 新树页若来自 bump：`last_page` 覆盖它们但无任何 meta 引用 → 孤儿页（泄漏方向，安全，
  与 tomb-chain 写一半崩溃同型，src/writer.zig:839-841 注释先例）；
- 旧根、旧链、计数器：全部原样。

因此**不需要为拷贝期发明任何恢复逻辑**——期望恢复行为就是「旧根完整、孤儿泄漏、cube_check scrub 全过
（孤儿页 CRC 本就有效，src/cube_check.zig:61）」。

### 4.2 tag 清单

| tag | 切点 | 期望恢复 |
|---|---|---|
| `compact_mid_copy(k)`（**新增**） | 第 k 批落页后 abort() | 旧根/旧计数/旧链完整；孤儿页数 = 已写新页数（泄漏方向）；重开后读写一致 |
| `before_retire`（**新增**） | ⑦ 收集完、⑧ 入队前 | 同上（磁盘态与 mid_copy 不可区分，入队纯内存） |
| 现有 7 tag @N+1（compactFull 自身提交） | 最终提交窗口复用 `writeCommitMeta` 双槽协议 | `before_chain`/`mid_chain`/`after_chain_before_meta`/`after_meta` 等语义逐项不变（src/file_page_store.zig:137-145、:782-859）——新根 or 旧根二者取一，**两棵树都完整**（新树先于提交全量落页；旧树未被触碰），meta 双槽协议保证不 torn（src/file_page_store.zig:823-857） |
| `after_chain_before_meta@N+2`（**新增行**：首个含 mass-pool 的普通 commit） | compact 后第一个 commit 的 vtWriteMeta 内：整池大链（≈⌈n/1016⌉ 页）已写、meta N+2 未落 | 恢复根 = **meta N+1 的 `(new_root, 0)`**（compact 后的干净态）。旧树页两条互斥归宿 + 判据：① compact 收尾时 `reader_count==0`（writer.zig:634 即时回收）→ 旧树页已在池、随大链持久化 → 重开后 `freePageCount ≈ 池大小`、且 ∈ `[FIRST_DATA_PAGE, meta.last_page]` 无重复（restore 自检 fps:586/597/601 再证一遍）；② 收尾时有读者 → 回收被水位拦下 → 旧树页**既不在池也不被任何 meta 引用** = 孤儿（泄漏方向）→ `freePageCount` 显著小于树页数、scrub 全绿（孤儿 CRC 有效）、重开读写一致。两情形共用可断言不变量：**恢复根重开后逐 key 与 compact 后可见集一致** |

> **行① 注记 a（实测修正，U5-7）**：上表 acbm 行的「① 无读者 → 旧树页 ∈ 大链」其可观测窗口是 **`after_meta`，不是 `after_chain_before_meta`**——⑪ 的回收发生在 N+1 meta 落地之后（纯内存），从未持久化；acbm 窗口的恢复态用的是 N+1 的持久化链（池为 0），旧树页为孤儿。两个互斥情形的判据不变（收尾时 reader_count），但「池 vs 孤儿」的区分断言请打到 `after_meta` 窗口（U5-7 矩阵 #4/#6/#7 已按真实窗口重排）。
>
> **行① 注记 b（实测惯例，U5-7）**：池-正向判据请写成 **`pool + small_slack >= old_tree`**（带命名余量的区间下界），不要写 `pool == old_tree`：`after_meta` 中止点在 N+2 数据页持久化之后，N+2 自身的 put 分配会从 ⑪ 刚回收的池 pop 页（1-entry put 净 pop ∈ [0,4]，实测 33→32）。1 页余量不影响「孤儿方向 vs 池正向」判定（读者格实测 pool=0，无重叠）。
| `after_meta@N+2`（**新增行**） | meta N+2 已落双槽、compact 后第一个普通提交生效 | 恢复根 = N+2 提交的根（普通小写），大链合法持有整个池：`freePageCount == meta.free_count`、链页 `gen == meta.sequence`（H1，fps:565-566）、池条目无重复（fps:601-608）、scrub 全绿、重开读写一致 |

> **表注（旧读者推演）**：N+2 崩溃窗口内「有读者的旧树页」情形只存在于**崩溃前**；崩溃后旧读者
> **不存在**——fork 注入的子进程已 abort（`test_crash_hook` 协议，fps:926-932），单进程引擎里
> 读者句柄随进程消亡，无任何快照能幸存到重开。因此恢复判定无需为旧读者保留旧树页：判据「收尾时
> reader_count 是否为 0」只决定旧树页走 ① 池还是 ② 孤儿，两条路都是泄漏方向安全的，恢复根恒为
> N+1 的 `(new_root, 0)`。派发步骤 6 的期望值表按此两行机械填写，不再依赖运行时读者状态。

新增 tag 走现有 `test_crash_hook` 静态协议（src/file_page_store.zig:150、fireCrashHook :926-932），
fire 点放在 compactFull 内部（`fireCrashHookPub` 透传模式，src/file_page_store.zig:942），
生产路径为一个可预测冷分支。

### 4.3 power_fail 模式

提交前 `writeCommitMeta` 内的 `syncDataPages` 已覆盖 `[FIRST_DATA_PAGE, next_free)` 全距
（src/writer.zig:296-300；fsync 语义论证 src/file_page_store.zig:905-917）——compact 拷贝的新页
天然落在该距内，「数据页不晚于 meta 落盘」的 T-27 排序**无需任何改动**即成立。

---

## 5. 计数器不变量（T-59/T-60 教训的内化）

三口径：`entryCount()`（原子计数器）/ `select` 可见数 / 物理活条目数。T-59/T-60 的根因是
**delta 补偿路径与物理/可见态错位**（逐 req 重复补偿、遮蔽 key 的物理覆盖多减 1，
issues/archived/T-59-…md:11-15、T-60-…md:10）。

compactFull 的对策是**结构性绕开 delta**：

1. 拷贝期间**丢弃** `insertBatch` 返回的 `live_delta/count_delta`（src/btree.zig:27-31）——
   它们描述的是「旧树物理态→新树物理态」的差，而 compact 的语义是**重定义**物理态，差值无意义；
2. publish 时**绝对值直设**：`entry_count = V`、`byte_size = B`（⑨ 的流式累计），不碰任何
   `@max(0)` 钳制的 delta 加减（commitTombSwap 的 delta 路径，src/writer.zig:1018-1019，此处不用）；
3. B 的公式 `key.len + value.len + 10` 与库内两处既有口径逐字一致：
   deleteRange count pass（src/db.zig:325-334）与 btree live_delta
   （src/btree.zig:1063/1072）；
4. **构造性三口径合一**：新树无链、无树内 tombstone → 物理活条目数 ≡ entryCount ≡ select 可见数。
   compactFull 由此兼任**漂移复位出口**：T-59 类历史漂移（修复合入前累积的 -1 钳制吸收量）
   被一次绝对值重置抹平——这也是验收断言（§7 步骤 3）：compact 前人为制造口径漂移，
   compact 后三口径严格相等。

---

## 6. 离线 vacuum（U5-4）与在线 compactFull 的复用边界

| | 在线 `compactFull` | 离线 `cube_check vacuum <src> <dst>` |
|---|---|---|
| 存储 | 同一 store 内建新树 + 原子换根 | 全新 store 建树 + 校验后 rename |
| MVCC | 读者 pin / 水位退休全程参与 | 无（flock 独占，src/file_page_store.zig:166） |
| 退休 | pending_free 全量入队 | 无（旧文件整体废弃） |
| 崩溃面 | 双槽 meta 提交窗口 | 旧文件不动直到 rename，天然原子 |
| 文件收缩 | **不能**（§3.3） | **能**（页号整体重排） |

**共用（抽 `src/compact.zig` 内核，两路共调）**：
- 可见集流式拷贝内核：`copyVisibleEntries(store, root, tomb_head, opts, sink)` —— ②③⑤⑥ 的
  循环体（chunk 预算、arena dupe、progress 中止语义）；
- `collectTreePages`（btree.zig 新 pub fn，含溢出链 + visited-set）——在线用于退休清单，
  离线用于「src 树页数 vs dst 树页数」的对账报告；
- 计数 oracle：V/B 公式（§5.3）的唯一实现点。

**测试共用**（`tests/compact_common.zig` helper，build.zig 的 scan 会把它当无测试 helper 跳过，
build.zig:84-101）：churn fixture 构造器（put/deleteRange/点删混合）、可见集模型 oracle、
B 公式 oracle、「链丢弃后 gc 为 no-op」不变量。

**各自独有**：在线——崩溃矩阵（§4）、MVCC 交错、retire/reclaim 断言；离线——rename 前后
`cube_check scrub` 全绿（src/cube_check.zig:61）、跨文件页数对账、flock 冲突行为。

---

## 7. 拆步实现计划（每步带验收，供 TDD 派发）

| 步 | 内容 | 验收（RED → GREEN） |
|---|---|---|
| 1 | fixture + oracle（`tests/compact_common.zig`：churn 库构造、可见集/B 公式 oracle） | 基线数字实测入库（issues/README.md §4.1 约定）；oracle 自测绿 |
| 2 | `btree.collectTreePages`（含溢出链 + visited-set）+ 单测 | 深树/溢出链/环注入三用例：页数 == 理论值；坏链报 `error.Truncated` 而非挂死 |
| 3 | `src/compact.zig` 拷贝内核（不发布） | churn 库上：新树 select 输出 ≡ 旧库 select 输出（逐 key/value）；新树无 tombstone 条目；abort 清退后 `freePageCount` 归位 |
| 4 | `Db.compactFull` 发布路径（⑦-⑩）+ 三口径断言 | 人为漂移库 → compact → entryCount == select 可见数 == 物理活数；旧 ReadTxn 跨 compact 读旧快照逐字节不变；staged put 先 flush 后拷贝；**双重入队单测（Blocking B）**：开长读者 pin 旧快照 → 先做一次普通 putBatch（造 COW victim 条目）→ 再 compactFull（同页二次入队）→ `endRead` 后断言 `pendingFreeCount == 0` 且 `freePagesSnapshot` 无重复（fps:684 现成 API） |
| 5 | 退休 + 回收 + freelist 持久化断言（§3.2 验收口径） | 10 万空闲页 → `chain_pages_written` 单次跳变 ≈ ⌈n/1016⌉；读者 pin 期间 pending 保持在位、endRead 后放行 |
| 6 | 崩溃矩阵（fork harness + 2 新 tag + 7 旧 tag 重跑） | §4.2 表逐行期望行为全绿；泄漏数可核算 |
| 7 | 文档 + bench（`bench/perf_batch.zig` 加 delete-churn→compactFull cell；usage.en/usage.md/README） | bench 数字入库 `bench/results/`；契约文案与实现一致（O(1) 行未动） |

步骤 3/4 之间是唯一设计风险点（发布路径的原子性），步骤 4 的 MVCC 交错用例
（`staging_concurrent_test.zig` 的既有 harness 形态）必须在 GREEN 前先 RED。

---

## 8. 边界情况与已知上限

- **空库**（root=0, tomb=0）：④ 零副作用返回，无 commit。
- **全删库**（链非空、树全被遮蔽）：V=0 → 发布 `(NULL_ROOT, 0)`，`treeDepth=0`（合法态，
  State.init 同款发布 src/writer.zig:237）。
- **链损坏**：`select` 入口即报错（src/db.zig:403-405「库损坏不吞」），compactFull 失败无副作用。
- **近 MAX_KEY_SIZE key**：继承 insertBatch 逐条门（src/btree.zig:1579-1581），无特判。
- **微批 staging**：① 强制 flush，staged 数据必须参与拷贝（deleteRange 先例 src/db.zig:281）。
- **长读者**：整个旧树 pin 在 pending_free（16B/条，同页双重入队最坏 32B/页，§3.1）直到水位放行——文档建议维护窗口跑，
  不做强制（读不阻塞是契约，§1.2）。
- **已记录上限**：retire 列表 O(全库页数) 内存（§3.1，ponytail 注释）；compact 后首 commit 的
  大链尖峰（§3.2，实测入 bench）。二者都有明确 upgrade path，不预支复杂度。

## 9. 引用核验表（blob `8f578cd`）

| 引用 | 内容 |
|---|---|
| src/db.zig:271/281/325-334/360-361/406-408/458/475-476/499-513/538/541/727/812/938/1144-1161 | deleteRange/flush/计数公式/物化 fallback/isShadowed 短路/select/阴影过滤/gcTombstones 短路/commitTombSwap 调用/compact/ReadTxn 链头/链遍历/链装入/物化段与 revive 补偿 |
| src/writer.zig:28-33/145-156/190-197/257/269-273/279/296-300/311/367/400/484-502/533-547/573/600/619/630-634/839-841/869-879/929/996-1033 | PendingPage/Durability/packed 根/发布/捕获/提交 meta/power_fail 排序/链写/退休入队/读者注册/O(1) compact/水位回收/读者水位/TombSwap/applyBatchSwap/无读者即时回收/链窗崩溃注释/publish step/规范化/commitTombSwap |
| src/file_page_store.zig:137-145/150/166/319-335/341/366/387-393/434-456/483/505/565-566/651/684/692/733/775/782-859/905-917/926-942 | CrashTag/hook/flock/ensureFileGrowth/池弹出入池/水位 bump/整链持久化与 fallback/H1 盖章/restore/gen 校验/池计数/快照/vtAlloc/vtReadMeta/vtWriteMeta 全程/数据页 fsync/crash hook |
| src/btree.zig:27-31/148-152/173-216/1063/1072/1497/1569-1581/1596-1630/1997/2203-2304 | WriteResult/inline 预算/MAX_KEY_SIZE 与溢出链/live_delta 公式/insert/insertBatch 与门/splice 重建/branch 批插/迭代器与 tombstone 跳过 |
| src/page_store.zig:10-53 · src/format.zig:21-36/340-345 · src/cube_check.zig:18-20/61 · build.zig:84-101 | vtable 与 FIRST_DATA_PAGE/meta 常量/池页容量/墓碑 envelope/exit codes/scrub/helper 扫描 |
| issues/archived/T-38-…md:49/65/294 · issues/README.md:52 · issues/archived/T-59/T-60 · issues/T-39-…md | U-5 遗留出处/T-38 主线行/计数漂移两案/T-39 写放大论证 |
| docs/usage.en.md:335/338/342/356/488 · bench/results/20260908_bench.md | O(1) 契约现行文案/compact 1.00µs 基线 |

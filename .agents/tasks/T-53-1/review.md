# T-53-1 Review — 独立评审双槽 meta 协议 + torn 拒绝门

- **被评审 SHA**: `e74aeb1`（`t53-1-torn-meta` = `652c319..e74aeb1`，RED `35c2023` → GREEN `bf44685` → report）
- **评审者 worktree**: `worktree/silver-stone-cef7`（未 checkout impl 分支；RED/GREEN 独立复跑在临时 detached worktree，已清理）
- **Verdict: `approve`**（协议级论证经独立推演成立；RED/GREEN 本人复证；3 条 NB，无 Blocking）

## 独立复证（评审者本人实跑，非采信 report）

| 检查 | 结果 |
|---|---|
| t535 @ `35c2023`（RED 基线） | t1+t2 **实红**，失败信息正是 `fresh-opened (T-53-1)`——冻结的 adv4b 破坏面属实 |
| t535 @ `e74aeb1` | rc=0（4/4 过） |
| filelock / crash_meta_midwrite / crash_harness / freelist_persist @ `e74aeb1` | 全 rc=0（无假拒） |
| src/ diff 面 | 仅 db.zig（注释）+ file_page_store.zig（协议+门），白名单内；t535 216 行新测试；check.sh gate3/5 filter 修正理由核实成立（目录级 filter 避开 T-39 RED-by-design 假红，注释已写明） |

## 检查单逐条（评审者独立推演，非抄 report）

### 1. 双槽写序崩溃窗口 —— 逐条对上代码，且补一个 report 未明说的关键点

`vtWriteMeta` 写序：hook(after_chain_before_meta) → slot1（meta_index 槽，**提交点**）→ slot2（冗余）→ 翻转 meta_index。

- crash 前 slot1 → 双槽 = 上一提交 → 回滚 ✓
- slot1 撕（含「落半页」形态）：半页 = 新旧字节混合（第二半是上一提交残留，非零）→ CRC 必不匹配 → unreadable；slot2 = 上一提交完整副本 → 回滚 ✓。特例：slot1 撕成**全零**（power-fail 无一块落盘）→ 落入零性分类，slot2 有效照常恢复，方向安全 ✓
- slot1 落地、slot2 未写/撕 → slot1 = 新 meta 有效 → 恢复新态 ✓
- **评审者补充推演**：双槽协议下两槽在任意已完成提交后持有**同一份** meta（不是旧协议的交替新旧），因此即使 power-fail 下两槽落盘乱序，恢复取高 sequence 也正确——结论不依赖槽序假设。这比 report 的窗口表更强，成立。
- **chain 退役纪律**核查：chain(N) 页在 commit N+1 step1 入队（release_seq=N+1），物理回收要等后续 commit 开头的 reclaimPendingFree（彼时双槽均已 ≥N+1，meta N 不可恢复）；crash 时 pending_free 在内存丢失 → chain N 完整保住 → slot2 兜底恢复 meta N 安全。report「meta N keeps chain(N) until commit N+2」论证成立，且与 T-38-5 已验证的既有纪律同构，零改动属实。

### 2. 「双槽均非零且皆 unreadable」不可由单次崩溃产生 —— 独立论证成立

崩溃时刻每槽状态只能三选一：(a) 全零（仅首次提交前）；(b) 上一提交的**完整**副本（上一提交的 slot2 写完整才算完成）；(c) 本提交 slot1 的撕裂态。两槽页号不同，单次崩溃只污染正在写的那个槽。⟹ 双撕需要两次独立损坏事件（或外源/蓄意）。我特意核查了「上一提交的 slot2 自己就是撕的」链式场景：那发生在上一提交 crash，reopen 恢复后撕裂槽会被下一次提交重写；若下一次提交又撕 slot1，那是**两次**独立 crash——仍不是单次。判据的不可由崩溃产生性成立，拒绝即正确方向。

### 3. 存量旧协议库兼容面 —— 与 report 声称一致，且多提交存量其实被兜住

| 存量形态 | 新判据行为 | 评估 |
|---|---|---|
| 旧协议多提交库（两槽都已写）双撕 | **拒绝** ✓ | report 未明说，实际这类存量也被新门兜住了 |
| 旧协议多提交库撕一槽 | 另槽有效 → 正常恢复 ✓ | |
| 旧协议**单提交**库撕唯一已写槽 | fresh 放行 | **已知残余**，与首提交中途 crash 指纹不可分（impossibility 论证成立：页级无区分特征，收紧必误伤 crash 家族「旧态回退」路径）✓ |
| 首提交中途 crash（meta0 撕 + meta1 全零） | fresh 放行 ✓ | 无已提交数据，fresh 即正确恢复 |

残余如实限定在旧单提交库，收敛路径（任意一次新提交后进双槽协议）成立。

### 4. 新错误用户可见性 —— NB-1

`error.TornMetaNoFreshEvidence` 经 `Db.open` 的 `try store.readMeta()` 传播（db.zig 注释块更新属实，open 逻辑零改动正确）。但 `docs/usage.md` 未更新：§3.1 打开示例与错误表都没有列这个新错误（连同 T-53 的 `InvalidMeta` 也没列）——用户撞上拒绝时在文档里找不到语义。错误名达意（torn + 无 fresh 证据 → 拒绝），「NoFreshEvidence」稍术语化，可接受。**建议补 docs 一行**（错误表加 `TornMetaNoFreshEvidence` + §3.1 一句话），非阻断。

### 5. R3 结论 —— 同意推迟，值得立 issue

`readMetaPageSingle` 校验 page_type 不校验 `hdr.page_no ∈ {META_PAGE_0, META_PAGE_1}` 与槽位对应。report 的一行收紧（`hdr.page_no == expected`）可信：forge 类测试全部用正确 index 写入（t535 corruptSlotByte 只翻转字节不改 page_no），不会误伤；且撕裂判据 CRC 短路优先，不依赖该校验。风险（蓄意字节级搬运）与收益（信任链收紧）都小——**另立低优先级 issue 合适**，本任务不动正确。

### 6. t3/t4 防误杀守卫 —— 覆盖了 2/3 个放行分支，缺「单撕 + 单零」形态 —— NB-2

断言读毕：t3 = 两提交库撕一槽、另槽**有效** → 恢复（entryCount==2 + 值正确，锁的是恢复路径）；t4 = 双槽全零 → fresh 可写。**新门的第三条放行分支「恰一槽非零 torn + 另一槽全零 → fresh」（即 mid-first-commit 形态，也是判据表第二行）没有任何测试直接构造**——t535 五个用例都不产这个形态，crash 家族也不触及（crash 测试先建空库=已提交态，无「首提交 meta 写入中途 crash 后 reopen」用例）。该分支的失效模式是 crash 恢复被误拒（过度拒绝），目前无回归网。建议补 t6：建库单提交 → 撕 META_PAGE_0 一字节 → 把 META_PAGE_1 整页清零 → 断言 fresh 打开可写。非阻断（分支逻辑简单且表有论证），但这是本评审最实质的一条。

另：测试头注声称 t5（拒绝路径不改文件字节），实际该断言内联在 t1 里（before/after 全文件比对），功能覆盖无缺，仅编号与结构不符——记录在案不值一条 NB。

## 结论

approve。双槽协议 + 零性判据是对 adv4b 数据破坏面的正确闭合：RED/GREEN 本人复证、
不可由崩溃产生性独立推演成立、存量兼容面如实限定、crash 家族无假拒（本人复跑 4 家族 +
conductor 容器门）。NB-1 补文档、NB-2 补 t6 形态测试、R3 另立 issue——三条都是后续小任务，
不阻断合入。

— reviewer: silver-stone-cef7（≠ impl pi1）

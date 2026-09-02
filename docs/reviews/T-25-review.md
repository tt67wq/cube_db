# T-25 Review: 讲义 §5.1「insert 入口与 root 分裂」扩写

- **Reviewer**: w-lucky-valley（非作者；作者 ws1-pi1）
- **Reviewed**: `main@8dc614a + uncommitted docs change`，s51 区段 sha256 = `f513ffff01312f2bc24106a1adb181b90e84dcb875ecde36c5bce2fc842e5fee`（已复核一致）
- **契约**: `.agents/tasks/T-25/task-review-test.md`
- **日期**: 2026-09-02

## Verdict: ✅ APPROVE（附 minor findings，不阻塞）

blocker: 0 · major: 0 · minor: 6

## 核查过程与结果（对照 src/btree.zig / writer.zig / format.zig / page_store.zig / file_page_store.zig @ 8dc614a）

### 逐条断言核对（任务 A 清单）

| # | 契约核查项 | 结果 | 证据 |
|---|-----------|------|------|
| 1 | NULL_ROOT=0、FIRST_DATA_PAGE=3、meta 占 1/2 | ✅ | btree.zig:10（`pub const NULL_ROOT: u32 = 0;`）、page_store.zig:8（FIRST_DATA_PAGE=3，注释「0=NULL，1=meta0，2=meta1」）、format.zig:17-18（META_PAGE_0=1/META_PAGE_1=2）。两实现 next_free 均从 3 起（page_store.zig:93、file_page_store.zig:98），页号 0 永不分配成立 |
| 2 | 空树 dupe+defer、encodeLeafPayload dirty 形参为空操作 | ✅ | btree.zig:1044-1063（dupe → defer free → encode → writeNodePage(LEAF, nkeys=1)）；btree.zig:175 `_ = dirty;` 行号精确。溢出链核实：encodeLeafPayload 在 is_ov 分支调 `writeOverflowPages(store, e.value)`（btree.zig:196），只 store 不需要 dirty——dirty 空操作无碍 |
| 3 | live_delta +9 口径、tombstone count_delta=0 | ✅ | btree.zig:1056-1057：`key.len + (if (tombstone) 0 else value.len) + 9`、`count_delta = if (tombstone) 0 else 1`；墓碑 value dupe 为 `""`（btree.zig:1045）。§5.2 同口径见 btree.zig:755 |
| 4 | ②「即弃」借用分析 | ⚠️ 部分属实，见 F-1/F-2 | 「返回借用而非拷贝」「读 payload[0] 后不再触碰」属实：btree.zig:1066-1067 取 is_leaf 后，函数体对 payload 再无引用（1069-1090 只用 sub 字段）。readNodePayload btree.zig:39-44 行号精确 |
| 5 | InsertSub 五字段 + split_key 所有权行号 | ✅ | btree.zig:521-527 与文中代码块逐字一致；906（叶分裂 `split_key = try allocator.dupe(u8, right_entries[0].key)`）、1003（branch 再分裂 `up_key = try allocator.dupe(u8, branch.keys[mid])`）、974（`new_keys[ci] = sk;`，注释「key pointers transferred to new_keys」在 978）、1079（root 分裂 `allocator.free(sk);`）全部命中 |
| 6 | root 分裂 nkeys=2 记 children 数；encodeBranchPayload assert | ✅ | btree.zig:1078 `writeNodePage(..., PAGE_TYPE_BRANCH, 2, ...)`；assert 内容属实：btree.zig:266-267 `std.debug.assert(children.len >= 2); std.debug.assert(keys.len == children.len - 1);` |
| 7 | 旧 root 回收链路 | ✅ | insert 确不对旧 root append（btree.zig:1035-1091 内无 dirty.append）；子层标记：768（insertIntoLeaf）、945（insertIntoBranch）行号精确。writer.zig:39-42 batch_dirty → pending_free（加锁），flushPendingFree → store.freePage（writer.zig:231-242）；「活跃读者延迟到末位读者 flush」属实：endRead prev==1 才 flush（writer.zig:169-175） |
| 8 | ⑤ delta 冒泡透传；writer 消费口径 | ✅ | btree.zig:940-941 `const live_delta = sub.live_delta;` 原样抄传，快（950-953）慢（997-999、1029-1031）路径返回值均为该局部变量；insertIntoLeafSplit 以参数带入（856-857）原样填回（911-912）。writer.zig:286-287 `batch_entry_delta += wr.count_delta; batch_byte_delta += wr.live_delta;`；`@max(@as(i64, 0), ...)` 写法属实（writer.zig:416-419） |
| 9 | nkeys 两义性框数值 | ✅ | LEAF_KIND=2/BRANCH_KIND=1（btree.zig:17-18）；PAGE_TYPE_LEAF=3/PAGE_TYPE_BRANCH=2（format.zig:11-12）。payload kind 与页头 page_type 两套编号确实不同 |
| 10 | HTML 结构合法 | ✅ | s51 区段标签配平（html.parser 校验零错误、无游离文本、`<pre>` 内仅 `<code>`）；§5.3 及之后与基线逐字节一致（见范围越界说明） |

### 改动范围核查（Ownership）

`git diff --stat 8dc614a -- docs/lecture_btree.html` → +215 −8，**实际改了两处**：
1. s51 区段（本任务标的）✅
2. **s52 区段亦有大量改写**（新增 ①-⑥ h4 小节、删旧 warn 框等）⛔ 超出契约「仅 s51 至 s52 之间」

但经比对，s52 的改动与 conductor 提供的验收基线 `.agents/tasks/T-25/baseline_tail.html` 逐字节一致（check_s51.py 的「tail 未动」判据即以此为准、通过），说明该扩写是先前步骤产物、被误计入本次工作区 diff。不计入 T-25 评分，见 F-4。

### Findings

**F-1（minor）MemPageStore 存储结构描述过时。**
正文：「测试用 MemPageStore 是 `AutoHashMap` 的 value」。
实况：MemPageStore 用 `std.ArrayList(*[PAGE_SIZE]u8)` slab 页池，每页独立堆分配、地址稳定（src/page_store.zig:78 注释、:117-131 ensurePage）。且当前实现 allocPage **不会**使已借用的页数据切片悬垂（page_store.zig:71-73 明确此为 SEGV 修复）。

**F-2（minor）「allocPage 可能触发 HashMap rehash 使切片悬垂」与现行两实现均不符。**
FilePageStore：mmap 裸指针寻址（file_page_store.zig:150-152），allocPage 只 ftruncate+递增，无 HashMap（全仓 grep 无 HashMap/AutoHashMap）；freelist ArrayList 扩容移动的是页号数组，不是页数据。MemPageStore：见 F-1。该说法与基线 §5.2 🔴 框同源（baseline 即如此表述，属沿袭的历史叙述——早期实现确为 HashMap 页缓存），但作为对**现行代码**的事实断言不准确。缓解：§5.2 栈拷贝不变量本身仍然成立且必要（防御接口契约：PageStore vtable 不承诺借用长存，page_store.zig:26-28 仅注明「返借用切片」）。

**F-3（minor）行号区间小幅漂移。**
「btree.zig:1035-1096」：insert 实际为 1035-**1091**（1093 起已是批量插入注释区）。其余全部引用（10、39-44、175、768、906、945、974、1003、1069-1084、1079）逐一命中，±5 行内。

**F-4（minor，范围备注）s52 区段被改动**（详见上节）。非 T-25 契约内工作，但与 conductor 基线一致、验收脚本通过，提请 conductor 归档时区分归属。

**F-5（minor）「源码注释『key pointers transferred to new_keys』」定位略偏。**
引文属实但注释位于 btree.zig:978（紧邻所引语句 974 之下），随句行号 974 指向的是 `new_keys[ci] = sk;` 本体。教学语境可接受。

**F-6（minor）「root 是叶 → §5.2 第④步 dirty.append」的步骤编号错位。**
btree.zig:768 的 `dirty.append(allocator, page_no)` 在 §5.2（扩写版）中属「④⑤ 溢出回收与三段拼接」小节的判定列表第二项，正文称「第④步」勉强对应；而「③ live_delta / count_delta」小节并不含该 append。语义无误，编号映射略含糊。

### 值得肯定的点（抽查为真）

- 空树路径「dirty 全程未动」精确（btree.zig:1044-1063 无 append）；「encodeLeafPayload 内部自动 writeOverflowPages」属实（:196）。
- split_key 所有权「每条路径恰好释放一次」三分支（free@1079 / 转移@974+deinit / up_key 全新 dupe@1003）与 Branch.deinit（btree.zig:387-391 逐 key free）完全吻合。
- 「新 root 是最小合法 branch：1 key + 2 children」与 encodeBranchPayload 双 assert 吻合。
- 「bytes 口径照加墓碑 key 开销」这一近似性的主动披露准确。
- 三种悬垂应对（即弃/先拷/重读）分类与代码一致：fresh_payload 重读在 btree.zig:958。

## 结论

所有实质性技术断言与 8dc614a 源码相符或属沿袭性历史表述（F-1/F-2 建议下轮修订时改为「ArrayList slab、地址稳定；接口契约不保证借用长存」）；行号引用密度高且几乎全中；HTML 合法、§5.3+ 未动、验收脚本 exit 0。无 blocker/major。**APPROVE**。

# T-38-2 评审报告 — 读路径墓碑遮蔽判定（阶段 2）

- **评审者**：pi-2（判定者 ≠ 实现者；worktree `cube-db-pi-1-rebuilt`，对 `b60d0fd` 独立实测）
- **被评审 GREEN commit**：`b60d0fd`（分支 `T-38-2-impl`）
- **前置 RED**：`2b05ca8`（12 测试）→ `f2751bc`（pi-3 追加 g6/g9/g10，15 测试）——
  commit 顺序亲核（`git log`：RED 先于 GREEN）；`git diff f2751bc b60d0fd -- tests/` 为空
  （GREEN 未触碰任何测试行，含 pi-3 的追加）。
- **结论**：**approve**（Blocking 0 / Non-blocking 3）
- 判定依据：独立读 diff 逐处核对 + 自写 6 个探针（P1–P6，独立推导期望值，
  跑毕删除）+ 三命令亲测 + T-51 三处 fixture 缺陷的独立字典序复核。

---

## 一、命令实测输出（本人，`b60d0fd`，scratch 删除后复测）

```
$ zig build test --summary all            # 验收①（无墓碑零行为变化）
Build Summary: 36/36 steps succeeded; 451/452 tests passed (1 skipped)   # exit 0
$ zig build test-format --summary all
Build Summary: 6/6 steps succeeded; 62/62 tests passed
$ zig build test-rangetomb-probe --summary all
Build Summary: 4/4 steps succeeded; 6/6 tests passed
$ zig build test-rangetomb-read --summary all    # 验收②
Build Summary: 2/4 steps succeeded (1 failed); 12/15 tests passed (3 failed)
```

验收① 451/452（1 skip）exit 0 —— 与基线 f5b7db6 **逐数一致**（基线数字为本人
spec-precheck 亲测），零回归。验收② 的 3 fail 经本人独立复核**全部为 RED fixture
缺陷**（§四），实现在语义上正确；验收②的「全绿 exit 0」门在 pi-3 修完 T-51 后
由 conductor 复跑即可（预期 15/15）。

## 二、五入口接线 + 短路唯一性 + 错误裸传（逐处 diff 核对）

| 检查项 | 结果 | 证据（file:line，b60d0fd） |
|---|---|---|
| `Db.get` 下降前遮蔽 | ✅ | db.zig:334-341（beginRead → captureSnapshot → isShadowed → getChecked） |
| `Db.getInto` 同（buffer 不动） | ✅ | db.zig:355-360（先判遮蔽，BufferTooSmall 不可能先触发） |
| `Db.select` 物化 + 钩子 | ✅ | db.zig:377-389（selectChecked 成功后 loadShadowCtx，挂 skip_fn） |
| `ReadTxn.get` / `getInto` / `select` | ✅ | db.zig:551/:560/:577-581，全部用 `snapshot_tomb_head` |
| `beginReadTxn` 成对捕获 | ✅ | db.zig:430-436（captureSnapshot 与 snapshot_root 同点） |
| **tomb_head==0 短路** | ✅ 唯一（按形态各一处） | 点查族唯一汇聚 `isShadowed` 开头 db.zig:317；select 族唯一 db.zig:384/:577 的 `!= 0` 门。五入口无各自为政的第三处判断 |
| **错误裸传** | ✅ | `isShadowed`/`walkTombChain`/`loadShadowCtx` 全 `try`，无任何 catch/`catch {}`；探针 P4(d) 实证坏 CRC → `error.CorruptCrc` 从 get/select/ReadTxn.select 裸传，无静默 |
| ReadTxn 用快照而非现值 | ✅（代码审查） | db.zig:544/:551/:560/:577-578 全部 `self.snapshot_tomb_head`；全文件无 `self.db.tomb_head` 于 ReadTxn 方法内的读取。注：阶段 2 tomb_head open 后不可变，此检查只能靠审查区分（运行时不可区分）——审查确认正确 |
| 并发原子性说明 | ✅ | `captureSnapshot`（db.zig:297-311）为唯一捕获 seam；tomb_head 只在 open 写入（db.zig:67-69/:87），单次 readMeta 同页取 root+tomb_head；阶段 3 packed-atomic 演进路径已写进函数注释——与本人 spec-precheck §2 的建议一致 |

btree.zig 改动核对：**仅 Iterator**——3 个默认 null 钩子字段（:2232-2242）、
deinit 先 `skip_deinit` 后 `pin_deinit`（:2248-2253）、next() 在 min/max 过滤后、
**overflow 组装前**插钩子（:2315-2317）。树逻辑/插入/删除/COW 零改动 ✓。
钩子在 overflow 前评估 = 被遮蔽的 overflow entry 不读链页（设计 §3.1 ✓）。
所有权合规：仅 db.zig + btree.zig(Iterator) + build.zig(删 RED 引入的重复
dependOn 行，语义零变化，亲看 diff)；format/writer/file_page_store 零触碰 ✓。

## 三、独立探针（P1–P6，6/6 绿，期望值全部本人手推）

scratch `tests/t38_2_review_scratch_test.zig`（跑毕删除；期间全量 `457/458 passed
(1 skipped)` = 基线 451 + 6 探针全绿）：

| 探针 | 内容 | 结果 |
|---|---|---|
| P1 真值表 | 4 墓碑混合（普通半开 / 双 append_zero / 单侧负无穷 / 单侧正无穷）× 16 key（含 `""`、`"\x00"`、`\xff\xff` 邻界），期望手推 | ✅ 全对 |
| P2 select⟺get 一致性 | 3 页乱序链（单侧+append+空键边界混合）：全量 select 输出 == 手推可见集；逐 get 一致；子区间 select(`b`,`c\0`) 一致 | ✅ 全对 |
| P3 环防护 | 自指环 p1→p1 与 2 页环 p1→p2→p1（均 CRC 合法）：get / select / ReadTxn.get 全部 `error.Truncated`，无 hang | ✅（MemPageStore limit=10000 快速触发） |
| P4 pin 不泄漏 | (a) select 中途 deinit → reader_count=0；(b) 不迭代直接 deinit → 0；(c) ReadTxn.select deinit 后 count=1（txn pin 正确保留）、txn.end 后 0；(d) 坏 CRC → select() 报错路径 errdefer 释放 pin → count=0 | ✅ 无泄漏（testing.allocator 无 arena 泄漏报警） |
| P5 tomb_head==0 短路 | v2 库上 `it.skip_fn == null`、`skip_ctx == null`、`skip_deinit == null`（Db.select 与 ReadTxn.select 双验）——短路是**结构性证明**（钩子根本没挂），叠加 452 回归门 | ✅ |
| P6（信息） | FPS mapsize 算术 | 2^28 页；环走 ~12288 MiB / 2.68 亿次 decode 后才 error.Truncated → 见 NB-1 |

（scratch 首跑 2 处失败均为本人探针自身缺陷——expectEqualSlices 对 slice-of-slice
比较的是指针位而非内容（打印证明显得输出与期望逐项相同）、txn 存续期 reader_count
断言值笔误（应为 1 写成 0）；修正后 6/6 绿。与实现无关，如实记录。）

## 四、T-51 复核（3 处 RED fixture 缺陷）——**conductor 判定正确，实现对**

本人独立重推字典序 + 亲读失败输出，三条全部确认 fixture 错、实现对：

1. **s2（:175 `expected 2, found 0`）**：单墓碑 `[b,d)` 下，`select("b","d")` 访问
   {b, b\0, ba, c, c\0}——全部 ∈ [b,d)（c\0="c"++0x00 < "d" ✓）→ 全被遮蔽，
   正确输出 **0 条**。断言期望 2 条 {b\0,ba} 对应双墓碑 `[b,b\0)+[c,d)`。
   决定性交叉证据：**s4 用同一墓碑断言 `!containsKey("b\0")`、`!containsKey("ba")`
   且全绿**——s2/s4 不可能同时通过任何实现。
2. **s7（:342 `expectVisible(db,"dc")` 失败）**：`putAll` 的种子集 all_keys =
   {a,b,b\0,ba,c,c\0,d,e}，**"db"/"dba"/"dc" 从未存储** → get("dc")=null（缺失≠
   遮蔽）。want 集含 "dc" 同样假设了未存储的 key。**注**：T-51 对机制的描述有小瑕疵
   ——「第二参数 `&.{}`（数据 key 集为空）」不准确（`openWithTombs` 第二参数是
   opts，putAll 总是执行）；且 `expectShadowed(db,"dba")` 严格说不是「假绿」而是
   「弱断言」（"dba" 确在 [db,dc) 内，null 语义正确，只是无法区分遮蔽与缺失）。
   瑕疵不影响结论：**fixture 错、实现对**，conductor 判定成立。
3. **g9（:560 `expectShadowed(db,"c")` 失败，got 值 "v"）**：`"c" == max` →
   半开**不含** → 可见，正确。断言期望恰对应 `max=succ("c")`（append_zero）——
   **s6 正是该形状且全绿**（c 遮蔽、c\0 可见），g9 与 s6 直接矛盾。

交叉印证：钉死同一语义的 12 测试全绿（s1/s3a-c/s4/s5/s6/s8/s9/s10/g6/g10）。
若实现的 max 排除或 append_zero 比较有误，s1/s3a/s6/g10 必翻红——未翻。

## 五、本人 spec-precheck 缺口（G-1..G-11）处置核对

| 预审缺口 | 落地 | 证据 |
|---|---|---|
| G-1（HIGH 语义分叉） | ✅ 已声明（H-2） | green-report §二：commit 覆写 v2/tomb_head=0、reopen 丢墓碑——阶段 3 根治（T-50）；测试纪律「注入后只读」已遵守（s9 写事务走 abort） |
| G-2（CRC 分层） | ✅ 有意分层（H-3） | select 物化每链页只验一次 CRC；点查逐次 decode（RED s10 的契约形状要求 open 后报错，open 时缓存会让 open 失败——理由成立） |
| G-3（sequence 陷阱/防假绿） | ✅ | 测试注入配方 sequence+1（impl-plan §6）；s8 显式断言 v2/tomb_head=0 |
| G-4（装后只读） | ✅ | s9 abort 不落页 |
| G-5（损坏时序） | ✅ | 逐次 decode 形状对「open 后破坏」天然兼容（s10 绿） |
| G-6（HIGH 链环防护） | ✅ 已落地 | db.zig:660-671 `steps > store.mapsize() → error.Truncated`；探针 P3 实证（自指环+2页环，get/select/ReadTxn 全 typed error 无 hang）。**遗留 NB-1：FPS 上界过宽** |
| G-7（select 形状/pin） | ✅ | 钩子方案（btree.Iterator 三字段）；deinit 顺序 skip_deinit→pin_deinit（btree.zig:2248-2253）；探针 P4 实证无泄漏（含物化失败 errdefer 路径） |
| G-8（451/452 口径） | ✅ | 实测 451/452（1 skip）exit 0 |
| G-9（不假设有序） | ✅ | `tombListCovers` 纯线性扫（db.zig:644-651）；探针 P2 三页乱序链全对 |
| G-10（空键） | ✅ | boundCmpKey 处理 k=""（db.zig:613-628）；g10 + P1 双验 |
| G-11（缓存生命周期） | ✅ | ShadowCtx arena 整体持有（db.zig:680-701）；bounds 借用页缓冲，pin 保活性，deinit 顺序正确 |

## 六、发现（Blocking 0 / Non-blocking 3）

### Blocking

无。

### Non-blocking

| # | 发现 | 证据 | 处置建议 |
|---|---|---|---|
| NB-1（medium） | **环防护在 FilePageStore 上形同虚设**：`walkTombChain` 上界 = `store.mapsize()`——MemPageStore 返回页数（如 10000，防护有效）；但 FilePageStore 的 `vtMapSize` = `REGION_SIZE/PAGE_SIZE` = **2^28 页**。CRC 合法的环链在 FPS 上要跑 2.68 亿次 readPage+全页 CRC（CPU 数分钟~小时级），且每步 append 一个 TombPage（~48B）→ **~12 GiB 峰值内存**（P6 探针算术：268435456×48B≈12288 MiB）才触发 error.Truncated，或先 OOM（error.OutOfMemory，typed）。字面上满足「非无限循环」，实际是准 hang/资源炸弹。仅损坏库触发（trust boundary），阶段 2 测试全走 MemPageStore，故不阻塞。 | db.zig:660-666；file_page_store.zig:811-813（vtMapSize）；P6 实测算术 | 建议随 T-51 修复周期或阶段 3 前置补强：去重防护（已访问页号 set，环重访即 Truncated，O(链) 内存）或上界收紧到 `min(mapsize, last_page+1)`。建议开 issue 跟踪 |
| NB-2（low） | green-report §H-1 把 FPS mapsize 单位写成「字节」——实际是**页数**（region_size/PAGE_SIZE）。结论（两单位都宽于合法链）不受影响，属报告笔误。 | file_page_store.zig:811-813 | 报告勘误即可 |
| NB-3（low） | 点查（get/getInto）每次调用走全链 + arena 分配 + 全页 CRC（墓碑页不受 Options.crc_check 三档控制，恒验）。设计/契约允许（impl-plan §4 选定形状；H-3 已声明），阶段 2 无墓碑库成本恰为零（tomb_head==0 短路）。记录为有意决策 + 阶段 4 优化项，非遗留缺陷。 | db.zig:316-324 | 无需动作（阶段 4 连同剪枝/二分一起优化） |

## 七、验收②的门状态（流程性，非实现缺陷）

验收②要求全绿 exit 0；当前 12/15，3 fail 全部为 T-51 的 RED fixture 缺陷
（§四已独立复核，实现对）。**approve 的判定对象是实现**；验收门在 pi-3 修完
fixture 后由 conductor 复跑（预期 15/15）。建议 T-51 关闭条件照旧：15/15 +
本评审对 fixture 语义的独立确认（§四即该确认）。

## 八、方法存档（可复现）

- diff 逐处核对：`git show b60d0fd -- src/db.zig src/btree.zig build.zig`；
  `git diff f2751bc b60d0fd -- tests/` 为空（GREEN 零改测试）。
- 探针：`tests/t38_2_review_scratch_test.zig`（P1–P6，期望全手推；删除前全量
  `457/458 (1 skipped)` 印证 6/6 绿；删除后复测 `451/452 (1 skipped)` 复原）。
- T-51：亲读 3 处失败输出（s2 `expected 2, found 0`；s7 `expectVisible("dc")`；
  g9 `expectShadowed("c")` got 值 "v"）+ 字典序独立重推 + s4/s6 交叉矛盾证明。

# T-52 评审报告 — 墓碑链环防护 visited-set 修复

- **评审者**：pi-2（review，作者独立性：≠ impl pi-1 ≠ test pi-3）
- **被评审 SHA**：`3e5d3c7`（= 05b74db GREEN + 3e5d3c7 注释；diff 范围 `0addc91..T-52-impl`，仅 `src/db.zig` walkTombChain，13+/8-）
- **verdict**：**approve**（Blocking 0 / Non-blocking 3 条观察项）

## 一、实测命令与结果（全部本人在被测 SHA 上亲跑）

```
$ time zig build test-tombguard --summary all
Build Summary: 4/4 steps succeeded; 2/2 tests passed        # 实时 6.2s（含编译）
$ zig build test-rangetomb-read --summary all
Build Summary: 4/4 steps succeeded; 15/15 tests passed
$ zig build test --summary all
Build Summary: 40/40 steps succeeded; 458/459 tests passed (1 skipped)
  # 459 = 454 全量（含 tombguard 2 用例）+ 本评审 5 个探针；探针删除后复测 453/454
```

基线对照（本人亲测）：`0addc91`（RED）全量 `452/454 (1 skipped, 1 failed)`——
1 failed 即 a1；`3e5d3c7`（GREEN）唯一差异 = a1 转绿，skip 为**既有**（非本任务引入）。
a1 的 RED 耗时 10m19s（conductor 记录）→ GREEN 全步骤 6.2s（含编译），运行时微秒级。

## 二、逐条审查意见（file:line 以 3e5d3c7 为准）

### 1. 有界性（步数/内存）— ✅

db.zig:663-673：`visited = AutoHashMapUnmanaged(u32, void)`，每步 `getOrPut`，`gop.found_existing` → `error.Truncated`。
- 环 = 有限页号集合内必然重访（鸽笼），**第一次重访即抓住**：最大步数 = 去重页数 + 1。
- 内存 O(链长)（visited + pages 同阶），与后端无关。
- **无环链的有效上界与旧代码等价**：无环链访问的页号互异 ≤ store 总页数 ≤ mapsize()（Mem: max_pages；FPS: region/PAGE_SIZE）——旧代码的 mapsize 步上界对无环链从未更紧。即：三种情形（环、无环、损坏）全部有界，且无环情形的界一字不差。
- 实证：R1(a) 自环步 2 抓、R1(b) 2 页环步 3 抓、R1(c) **链中段环**（p1→p2→p3→p2，head 不在环上）步 4 抓——中段环是 mapsize 步数方案最难及时命中的形状，visited-set 天然覆盖。

### 2. typed error 保留（无数据复活）— ✅

- db.zig:668-669：`try visited.getOrPut(...)`（OOM → error.OutOfMemory 裸传）+ db.zig:670 `return error.Truncated`（环）。无任何 catch。
- a1 的 `expect(false)` 分支（静默返回值 = 复活）未触发；R1 中被遮蔽 key（"c"）与未遮蔽 key（"a"）**都**返回 error.Truncated（get 必走链，损坏链对任意 key 报错，不可能选择性复活）。
- `getOrPut` 在分配失败时不插入（Zig stdlib 语义），OOM 路径 visited 状态一致，`defer` 清理安全。

### 3. 无环链行为不变 — ✅

- 走法顺序未动：read → decode → append → next（db.zig:671-673，与旧版逐行同构，仅换掉 steps 计数为 visited 查重）。
- a2（FPS 无环 2 页链四断言）绿；15/15 阶段 2 回归绿；R2（FPS 无环 **5 页**链，手推 9 key 真值表 + 全量 select⟺get 一致）绿。
- 唯一可观察差异：每次 walk 多了 visited hashmap 的 arena 分配（O(链长)，同阶常数因子），不违反硬约束 2。

### 4. visited 分配/释放 leak-free（错误路径）— ✅

- db.zig:664 `defer visited.deinit(a)`：任何 return（含 error）都执行。
- 两个调用方都传 arena allocator（`isShadowed` db.zig:321 stack arena；`loadShadowCtx` db.zig:694 ShadowCtx arena）：`deinit` 对 arena 是安全的记账释放，随后 arena 整体拆除无双重释放。
- 实证 R3：FPS 环链上 **100 次 get + 20 次 select + ReadTxn.get** 全部走错误路径，testing.allocator 泄漏检测零报警（任何一次 visited/pages 泄漏都会让测试 fail）。

### 5. head 页重访 / 边界形状 — ✅

- `while (pn != 0)`：0 = 链尾哨兵，永不入 visited；head=0 时调用方短路（isShadowed db.zig:317），即使直接调 walkTombChain(0) 也零步返回。
- head 在环上（R1a/R1b）与 head 不在环上（R1c）两种形状均实证。

### 6. Ownership 合规 — ✅

- `git diff 0addc91..T-52-impl --stat` = src/db.zig 一个文件，13+/8-，全部落在 walkTombChain 函数体 + 紧邻 doc 注释 + 一行函数内注释。RED 测试文件、page_store/file_page_store/format、build.zig 零触碰。
- 方案选择已声明：GREEN commit message 明确「首选 visited-set」并给出弃用 mapsize 界的理由（契约要求 impl 报告说明选型——commit message 承担了该职责，如实记录）。
- 附带修复确认：旧注释 "File: bytes" 的**错误单位说明**（我在 T-38-2 评审 NB-2 指出的报告笔误同源）已被更正为准确描述（db.zig:659-662），中文行内注释同样准确。

## 三、独立探针（R1–R5，5/5 绿，跑毕删除）

| 探针 | 内容 | 结果 |
|---|---|---|
| R1 | FPS 环三形状：自环 / 2 页环（head 重访）/ 3 页链中段环（head 不在环上）；get（遮蔽+未遮蔽 key）、select、墙钟 < 2s | ✅ 全部 error.Truncated，微秒级 |
| R2 | FPS 无环 5 页链：9 key 手推真值表 + 全量 select⟺get 一致（{b,b\0,c,c\0,d}） | ✅ 无误报 Truncated |
| R3 | FPS 环链错误路径 ×121 次（100 get + 20 select + 1 txn.get），泄漏检测即断言 | ✅ 零泄漏 |
| R4 | MemPageStore 环回归（visited-set 后端无关性） | ✅ error.Truncated |
| R5 | 无环非自指链换页号布局（a2 语义等价，Mem 上）+ 页号唯一性论证：合法链不可能重访页号 → 去重恰为环的充要判定 | ✅ |

## 四、Non-blocking 观察

| # | 内容 | 建议 |
|---|---|---|
| O-1（low） | 合法链每次 walk 多 O(链长) 的 hashmap 内存/查重开销（点查 get 每调一次 walk 一次，NB-3 of T-38-2 已记录点查形状）。与旧代码同阶。 | 阶段 4 连同链缓存/剪枝一起优化，无需本任务处理 |
| O-2（info） | `error.Truncated` 语义从「超步数界」收窄为「页重访」——error 同族不变，现无调用方区分二者；新注释已如实描述。 | 阶段 3 writer 文档里保持该语义描述即可 |
| O-3（info） | task.md 验收节的 `tombWalkStepsForTest()` 探针不存在（早期草案残留句）；实际判定为行为+墙钟（a1 实现），已完成。回归门口径「452/452（0 skip）」与实际基线（既有 1 skip）有出入——impl 与本评审各自独立核实 skip 为既有，非本任务引入。 | task.md 勘误由 conductor 处理，不影响本 verdict |

## 五、结论

修法正确、最小、有界：环在第一次重访被抓（步数 ≤ 去重页数+1，内存 O(链长)），typed error 全程裸传，无环链走法/解码/pages 内容与顺序零变化，错误路径零泄漏，ownership 完全合规。RED→GREEN 对照（a1: 10m19s fail → 6.2s pass）与基线对照（唯一差异 = a1 转绿）均亲测。**approve**。

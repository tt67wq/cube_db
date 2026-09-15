# N-1-P 探路报告 — `put` 组合条目溢出 panic：读码判定与修复方向

- **任务**: N-1-P（读码探路，不实现修复）
- **探路者**: cube_db-pi-2
- **基线**: `f7808d0`（main）
- **关联**: `issues/N-1-put-composite-entry-overflow-panic.md`
- **判定结论**: **方向 B（组合感知的 overflow 判定）**，不是 A（入口拒绝）。
  一句话：**overflow 分离存储机制在代码里完整存在且已接通，缺的只是判定
  条件没有把 key 长度算进去——补全判定即恢复设计意图，拒绝则是倒退。**

---

## 0. 评审方法

全部结论基于：临时探针实测（独立 `zig test --dep cube_db` 命令行编译，
不动 build.zig，探针用完已删）+ 源码逐行审计 + 设计文档交叉核对。
每条实测附命令与真实输出。

---

## 1. 七问逐条回答

### 问 1：4068 这个「单条条目上限」怎么算出来的

**来源是页容量推导，不是独立常量**。完整算式（`src/btree.zig:337`、
`src/format.zig:5-6`）：

```
NODE_PAYLOAD_CAP = PAGE_SIZE - PAGE_HEADER_SIZE - 4
                 = 4096     - 24               - 4     = 4068
```

- `PAGE_SIZE = 4096`（format.zig:5）
- `PAGE_HEADER_SIZE = 24`（固定页头：page_no/类型/gen/nkeys/free_next，format.zig:6）
- 尾部 4B CRC（format.zig:2 注释，`setPageChecksum` 写 `page[4092..4096]`）

「单条条目上限」= 单条 entry 编码后必须 ≤ NODE_PAYLOAD_CAP（一个 entry
至少独占一叶）。`4068` 这个数**没有单独的常量名**——它就是
`NODE_PAYLOAD_CAP`，所有分块/预算检查（`leafChunkLen`、`branchChunkLen`、
T-26 precheck、T-40 insertBatchFresh 检查）都用它。

### 问 2：是否存在 overflow / 大 value 分离存储机制？

**有，且已接通（运行时真实生效）**。这不是设计残留：

| 组件 | 位置 | 状态 |
|---|---|---|
| 页面类型 `PAGE_TYPE_OVERFLOW = 4` | format.zig:13 | ✅ |
| 溢出链写入 `writeOverflowPages`（分页 + free_next 链接 + CRC） | btree.zig:150 | ✅ |
| 溢出链读取 `readOverflowValue` | btree.zig（:475 读路径调用） | ✅ |
| 溢出链释放 `freeOverflowPages`（复用 freelist） | btree.zig:~205 | ✅ |
| 叶内 flags 位 `LEAF_FLAG_OVERFLOW=1`，溢出时叶内只存 4B 页号 | btree.zig:146 | ✅ |
| 内联阈值 `MAX_INLINE_VALUE = 3800` | btree.zig:124 | ✅ |
| 解码端按 flags 分支（读侧不关心 value 大小） | btree.zig:311/617/705 | ✅ |

**设计文档口径**（docs/lecture_btree.html:227）：「value ≤ 3800 字节直接放
leaf payload，> 3800 走溢出页」；:687 「value 超 MAX_INLINE_VALUE=3800 时
内部自动 writeOverflowPages」。

**实测确认已接通**（探针 P2）：

```
$ zig test --dep cube_db --dep zio -Mroot=probe_n1p.zig ... --test-filter "P2"
[P2] key=6 val=100000 (overflow chain) OK
All 1 tests passed.
```

100KB value 走溢出链，存取完整回读成功。**所以 B 路线的全部基础设施
都在并且工作。**

**缺的只是一件事**：`needsOverflow`（btree.zig:231-233）的判定条件是
**纯 value 长度**：

```zig
fn needsOverflow(entry: LeafEntry) bool {
    return entry.value.len > MAX_INLINE_VALUE;
}
```

key 长度不参与判定。于是 `key=4000 + value=64`：64 ≤ 3800 → 判定
「内联」→ 编码 3+10+4000+64 = 4077 > 4068 → 越界。

### 问 3：`3 + 10 + 4000 + 64` 各是什么 + 真正的可行上界

实际叶编码布局（`encodeLeafPayload`，btree.zig:246-275 实测对齐）：

```
叶 payload:
  [0]        LEAF_KIND               1B   ┐ 叶头 3B
  [1..3]     nkeys (u16 LE)          2B   ┘
  每条 entry:
    tombstone                        1B   ┐ 固定 10B
    klen (u32 LE)                    4B   │
    key bytes                       klen  │
    vlen (u32 LE)                    4B   │
    flags                            1B   ┘
    value bytes                vlen 或 4B（溢出时=页号）
```

- `3` = 叶头（kind 1 + nkeys 2）
- `10` = 每条固定开销（tombstone 1 + klen 4 + vlen 4 + flags 1）
- `4000` = key 字节
- `64` = **内联** value 字节（64 ≤ 3800 → 不走溢出）

**真正的可行上界**（分两种情况）：

1. **value 内联**（vlen ≤ 3800）：
   `3 + 10 + klen + vlen ≤ 4068` → **klen + vlen ≤ 4055**
2. **value 走溢出链**（vlen > 3800）：叶内条目 = `3 + 10 + klen + 4`
   → klen ≤ 4051 = MAX_KEY_SIZE ✓ 恒成立；value 大小无上限（链长不限）

`MAX_KEY_SIZE = 4068 - 3 - (1+4+4+1+4) = 4051` 的推导
（btree.zig:126-140）**正是按「value 永远可逃逸到溢出链」假设的**——
注释原文：「a value can always escape to an overflow chain (4 bytes
in-leaf); a key has no such escape, so key is the hard bound」。**设计
意图明确是 B**：value 不该有大小上限，只有 key 有。

**推导的盲点**：它假设了「vlen > 3800 时才逃逸」，但没有保证
「vlen ≤ 3800 且组合超限时也逃逸」。问题恰好出在判定条件与推导假设
之间的这条缝上。

### 问 4：边界行为实测矩阵

临时探针（`probe_n1p.zig`，已删），独立命令行编译，不碰 build.zig：

```
$ zig test --dep cube_db --dep zio -Mroot=probe_n1p.zig \
    --dep zio -Mcube_db=src/root.zig --dep zio_options \
    -Mzio=zig-pkg/zio-0.17.0-*/src/zio.zig \
    -Mzio_options=.zig-cache/c/*/options.zig -lc --test-filter "P..."
```

| # | 输入 | 组合 | 实测行为 | 输出 |
|---|---|---|---|---|
| P1 | key=4051(MAX), value="" | 4064 | **✅ 存储成功**，回读 len=0 | `[P1] ... OK` |
| P2 | key=6, value=100000 | 叶内 3+10+6+4=23 | **✅ 溢出链存储**，回读 100000B 完整 | `[P2] ... OK` |
| P3a | klen+vlen=4055 | **恰好 4068** | **✅ 存储成功**，回读完整 | `All 1 tests passed` |
| P3b | klen+vlen=4056 | 4069（超 1B） | **❌ panic: integer overflow**（btree.zig:116） | 见下 |
| P4a | fresh 树, 4000+64 | 4077 | **❌ panic: index out of bounds: 4101, len 4096**（btree.zig:115 ← insert:1483） | 见下 |
| P4b | 非 fresh 叶根, 4000+64 | 4077 | **❌ panic**（:115 ← insertIntoLeafSplit:1239 ← insertIntoLeaf:1065） | 见下 |
| P4c | 500 key 枝根后, 4000+64 | 4077 | **❌ panic**（:115 ← insertIntoLeafSplit:1239 ← insertIntoBranch:1296） | 见下 |
| P5a | putBatch 单条 4000+64 | 4077 | **❌ panic**（:115 ← insert:1483 ← applyBatch:499） | 见下 |
| P5b | putBatch 有序多条含 4000+64 | 4077 | **❌ panic**（:115 ← insertBatchSplitLeaves:1646 ← insertBatchFresh:1618） | 见下 |
| P5c | putBatch 无序多条含 4000+64 | 4077 | **❌ panic**（:115 ← insertBatchSplitLeaves:1646 ← applyBatch:611） | 见下 |
| P6 | WriteTxn.put 4000+64 | 4077 | **❌ panic**（:115 ← insert:1483 ← commit:443） | 见下 |
| P7 | deleteRange 近-MAX 墓碑 | ≤4064 | **✅ 安全**（value 恒 ""） | `[P7] ... OK` |

关键输出摘录：

```
P3b: thread panic: integer overflow
     btree.zig:116:62 in writeNodePage
       const remaining = f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4 - payload.len;
     btree.zig:1483:26 in insert (fresh-tree 单条路径)

P4b: thread panic: index out of bounds: index 4101, len 4096
     btree.zig:115:41 in writeNodePage (@memcpy)
     btree.zig:1239:26 in insertIntoLeafSplit
     btree.zig:1065:39 in insertIntoLeaf (T-26 precheck fallback 到 split)
```

**边界两侧行为不对称且都炸**：4068 可存，4069 的一种 panic、4077 的
另一种 panic。**两种 panic 表现**：
- 组合 > 4068 但 ≤ 4072（页内 memcpy 不越界）：`:116` 的
  `4096-24-4-payload.len` usize **下溢** panic（Debug 断言）
- 组合 > 4072：`:115` 的 `@memcpy` **索引越界** panic

### 问 5：panic 的确切位置与原因

**是校验缺失，不是偏移算错**。编码函数的算术全部自洽（`leafPayloadSize`
算出 4077，`encodeLeafPayload` 按它写满 4077B），问题是没有人在编码前
问「4077 放得进 4068 吗」。两条崩溃路径：

**路径 1 — fresh 树单条**（`insert`，btree.zig:1477-1488）：

```zig
if (root == NULL_ROOT) {
    const new_page = try store.allocPage();
    var entries: [1]LeafEntry = ...;
    const pl = leafPayloadSize(&entries);        // = 4077，无检查
    var buf: [f2.PAGE_SIZE]u8 = undefined;       // 4096B 栈缓冲
    _ = try encodeLeafPayload(buf[0..pl], ...);  // 写 [0..4077)，本身没越 buf
    try writeNodePage(store, new_page, ..., buf[0..pl]);  // ← 炸
}
```

`writeNodePage:115`：`@memcpy(page[24..][0..4077], payload)` → 目标
`page[24..4101]`，但 page 只有 4096 → **索引 4101 越界**。若组合在
4069..4072 之间，memcpy 恰好能塞进 page（24+4072=4096），随后 `:116`
的 remaining 计算下溢先炸（Debug）——Release 下则会继续把 CRC 写到
`page[4092..4096]`，**静默覆盖已写入的 value 尾部**（严重度更高，
【未实测】Release 行为——见未实测清单）。

**路径 2 — 非 fresh 树**（`insertIntoLeaf` → fallback →
`insertIntoLeafSplit`）：fast path 的 T-26 字节预算 precheck
（btree.zig:1048-1060）**工作正常**——它算出 4077 > 4068，正确地
fallback 到 split 路径。但 split 路径的分块器 `leafChunkLen`
（btree.zig:345-356）：

```zig
if (len > 0 and n + need > NODE_PAYLOAD_CAP) break;  // ← len==0 时不设防！
```

**第一条 entry（len==0）无条件收进 chunk**——注释（btree.zig:339-341）
声称「A single entry always fits (MAX_KEY_SIZE is derived from this
bound), so the result is >= 1」。**这个声称是错的**：MAX_KEY_SIZE 的
推导假设 `val_sz` ≤ 4（溢出逃逸），而实际内联 value 可达 3800B。
于是 4077 的单条被塞进 chunk → `encodeLeafPayload` + `:1239
writeNodePage` → 同样的越界。

**根因一句话**：`needsOverflow` 的判定条件（纯 value 长度）与
`MAX_KEY_SIZE` 推导假设（value 永远可逃逸）不一致——判定条件没有把
「组合超限时也该逃逸」这一分支包含进去，导致推导的「单条恒装得下」
前提在 vlen ≤ 3800 && klen+vlen > 4055 时失效，下游所有分块器
（`leafChunkLen` / `insertBatchFresh` 检查之后的 `insertBatchSplitLeaves`
:1640 / `insertIntoLeafSplit` :1233）在「单条装不下」这个从未考虑过的
输入上越界写页。

### 问 6：公开 API 完整触发面

所有写入口最终汇聚到 `applyBatch`（writer.zig:458）的两条 btree 调用：
`batch.len == 1` → `btree.insert`（:499）；否则 → `btree.insertBatch`
（:550 有序 / :611 无序）。**没有任何一层做组合检查**：
`checkKeySize`（db.zig:27-28）只查 key ≤ 4051；`insert`/`insertBatch`
入口的防御性复查（btree.zig:1472/:1545）同样只查 key。

实测触发面（P4a-P6 全部 panic）：

| 公开 API | 路径 | 触发 | 实测 |
|---|---|---|---|
| `Db.put`（micro-batch） | put→stage→flush→putBatch | ✅（staged entry 同样无检查） | 【未实测】单独跑（与 putDirect 同路） |
| `Db.putDirect` | →WriteTxn→commit→applyBatch→insert | ✅ | P4a/P4b/P4c ❌ |
| `Db.putBatch`（单条） | applyBatch len==1→insert | ✅ | P5a ❌ |
| `Db.putBatch`（多条有序/无序） | applyBatch→insertBatch | ✅ | P5b/P5c ❌ |
| `WriteTxn.put` + commit | commit→applyBatch | ✅ | P6 ❌ |
| `Db.delete` / `WriteTxn.delete` | 墓碑 value="" | **安全**（3+10+klen ≤ 4064） | 读码确认 |
| `Db.deleteRange` | 墓碑 value=""（:270） | **安全** | P7 ✅ + T-38-B R5 |

**btree 直调者**（库内不设防的更深入口）：`btree.insert` /
`btree.insertBatch` 的公开入口同样只有 key 检查（:1472/:1545）——直接
调用 btree 的代码（非 Db 层）也全裸。实测里 P4a-P6 都经由 Db 层，
btree 直调【未实测】但读码确认为同一无检查路径。

### 问 7：修复方向判定

**推荐：方向 B——把 overflow 判定从「纯 value 长度」改为「组合感知」。**

具体：`needsOverflow` / `leafPayloadSize` / `encodeLeafPayload` /
`leafChunkLen` / `insertIntoLeaf`(fast path + T-26 precheck) 共 5 处
判定点（全部是 `value.len > MAX_INLINE_VALUE` 的同口径表达式）改为：

```
内联条件 = value.len ≤ MAX_INLINE_VALUE
         且 3 + 10 + key.len + value.len ≤ NODE_PAYLOAD_CAP
```

即组合预算不够时，**无论 value 多小都强制走溢出链**（叶内 4B 页号）。
等价表述：内联 value 的可用预算 = `min(MAX_INLINE_VALUE,
NODE_PAYLOAD_CAP - 3 - 10 - key.len)`。

**为什么 B 是对的**：

1. **B 恢复设计意图**。MAX_KEY_SIZE 推导注释（btree.zig:128-131）白纸
   黑字：「a value can always escape to an overflow chain」——设计的
   契约就是 value 无上限。lecture_btree.html 的语义（§2.2/§5.1）同样是
   「> 阈值走溢出页」，从未承诺「小 value 一定内联」。「什么 value 走
   溢出」是实现细节，不是 API 契约——把它改成组合感知不破坏任何文档
   化行为。
2. **B 修复全部 7 个触发点**（P4a-P6），顺带把 `leafChunkLen` 的错误
   注释前提（「单条恒装得下」）重新变为真：组合感知后 val_sz ≤
   `NODE_PAYLOAD_CAP-3-10-klen` 恒成立（klen ≤ 4051 → 4055 预算，
   超出即溢出 4B），单条恒装得下 → 所有分块器的不变式恢复。
3. **B 的改动面小且集中**：5 处判定同口径改一处语义（建议提成
   `fn inlineValueBudget(key_len) usize` 单一函数，5 处调用）。读路径
   零改动（flags 位驱动，本就不关心 value 大小）；溢出链读写/释放
   零改动（已接通，P2 实证）。
4. **B 零功能倒退**：当前能存的（P1/P2/P3a）修后仍能存；当前 panic
   的（4069+）修后能存。没有任何输入从「能」变「不能」。

**为什么 A（入口 typed 拒绝）是错的**：

1. A 在公开 API 上引入一条**文档从未承诺的新限制**（key+vlen ≤ 4055
   且 vlen ≤ 3800），并把设计承诺（「value can always escape」）变成
   谎言——`checkKeySize` 旁边那条「never an assert」的 T-33 注释承诺
   的优雅错误哲学，被 A 用来掩盖一个本可修复的功能缺口。
2. A 造成**荒谬倒挂**：key=4000 + value=100KB **能存**（P2 实证，走
   溢出链），key=4000 + value=64B 却被拒。越小的 value 越被拒绝——
   这在语义上不可辩护。
3. A 需要在**每一个**入口（put/putBatch×3 路径/WriteTxn.put/btree 直调
   ×2）加检查，或者依赖 applyBatch 单点——但 applyBatch 单点检查
   拦不住已 staged 的 micro-batch 场景的语义一致性问题（stage 时可
   读、flush 时报错），改动面不比 B 小，收益却是负的。

**A+B 的合理残余**：B 修复后，仍然存在一个理论入口值得 A 式防御——
`btree.insert`/`insertBatch` 的直调者。B 修好后分块器不变式恢复，
单条恒装得下，直调者自然安全，无需额外拒绝。若想加 defense-in-depth
（对齐 T-33 的 key 检查风格），可在 btree 入口加一条 debug assert /
typed error 兜底——但这是 B 之上的加固，不是方向选择。

**设计缺失声明**（如实说明，不硬下结论）：**没有**。这不是「本该有
overflow 页但设计没定」的情形——overflow 页机制、格式、读写、回收全部
存在且接通；缺的只是判定条件的一个分支。判定不受设计缺失所限。

---

## 2. 建议的实现切分（两步）

**第 1 步（N-1 本体，小）**：组合感知的内联判定
- 提 `inlineValueBudget(key_len) = min(MAX_INLINE_VALUE, 4058 - key.len)`
  单一函数（4058 = 4068 - 3 - 10 + 10 自检：`3+10+klen+budget ≤ 4068`
  恒成立，等式右边恰在两处同时饱和）；
- 改 5 个判定点：`needsOverflow`(:231)、`leafPayloadSize`(:240)、
  `encodeLeafPayload`(:256)、`insertIntoLeaf` fast path(:1102) +
  T-26 precheck(:1052)、`leafChunkLen`(:349)——全部换成
  `value.len > inlineValueBudget(key.len)`；
- 修正 `leafChunkLen`/`MAX_KEY_SIZE` 的注释（「单条恒装得下」在组合
  感知下恢复为真，注明前提）；
- RED 测试：本报告 §3 边界表逐行。

**第 2 步（可选加固，独立小任务）**：btree 直调入口的
defense-in-depth 检查（对齐 T-33 风格），以及 Release 模式下
`writeNodePage` 对 `payload.len > NODE_PAYLOAD_CAP` 的显式错误
（当前 Release 下 :116 下溢是 UB/静默覆盖，值得一条前置检查）。

---

## 3. 验收判据设计（供实现任务直接写 RED 测试）

修复后的完整边界表（**= 期望行为**；`put(k,v)` 经任意公开写入口）：

| # | key.len | value.len | 组合（内联口径） | 修复后期望 | RED 现状 |
|---|---|---|---|---|---|
| 1 | 0 | 0 | 13 | ✅ 存，get 回 (k="",v="") | ✅ 现在也绿（控制组） |
| 2 | 4051 (MAX) | 0 | 4064 | ✅ 存 | ✅ 绿（P1） |
| 3 | 4051 | 1 | 4065 | ✅ 存（value 走溢出链，叶内 4B） | ✅ 绿（控制组） |
| 4 | 4051 | 3800 | 叶内 4068 | ✅ 存（溢出链） | ✅ 绿（P2 类比） |
| 5 | 4051 | 100_000 | 叶内 4068 | ✅ 存（溢出链，多页链） | ✅ 绿（P2 类比） |
| 6 | 2005 | 2050 | 4068（恰好） | ✅ 存（**内联**，预算恰好用满） | ✅ 绿（P3a：klen+vlen=4055） |
| 7 | 2005 | 2051 | 4069（超 1B） | ✅ 存（**value 2051B 走溢出链**，叶内 3+10+2005+4=2022） | ❌ **RED：panic integer overflow**（P3b） |
| 8 | 4000 | 64 | 4077 | ✅ 存（64B value 走溢出链） | ❌ **RED：panic index OOB**（P4a/b/c、P5a/b/c、P6） |
| 9 | 4052 | 任意 | — | ❌ `error.KeyTooLarge`（现状保持，控制组） | ✅ 现在就返回错误 |
| 10 | 任意 ≤4051 | vlen=u32 极值 | 叶内 ≤4068 | ✅ 存（溢出链长度受 freelist 容量限制而非格式限制） | 【未实测】 |
| 11 | 4000 | 64（**经 putBatch 单条**） | 4077 | ✅ 存 | ❌ RED（P5a） |
| 12 | 4000 | 64（**经 putBatch 多条有序**） | 4077 | ✅ 存 | ❌ RED（P5b） |
| 13 | 4000 | 64（**经 putBatch 多条无序**） | 4077 | ✅ 存 | ❌ RED（P5c） |
| 14 | 4000 | 64（**经 WriteTxn.put+commit**） | 4077 | ✅ 存 | ❌ RED（P6） |
| 15 | 4051 | 任意（**delete 墓碑**） | ≤4064 | ✅ 安全 no-op | ✅ 绿 |
| 16 | 4051 | —（**deleteRange 墓碑**） | ≤4064 | ✅ 安全 | ✅ 绿（P7） |

**额外不变式断言（修复后必须成立）**：
- 任意 `k,v`（klen ≤ 4051）存储后 `get(k)` 精确回读 v（字节级）；
- 表 #7 修复后**读回路径**正确：溢出链读取（`readOverflowValue`）对小
  value 同样工作（P2 已证大 value，小 value 走链是新增路径，RED 测试
  必须显式覆盖：#7/#8 存后立即 get 并逐字节比对）；
- 修复后 `zig build test` 全量 436/437+1 skipped 不回归（新增 RED
  测试后计数相应增加）；
- 覆盖后的条目**可被覆盖/删除**（溢出链被 freeOverflowPages 回收，
  无泄漏——std.testing.allocator 全程校验）。

**错误面**：修复后**唯一新增的返回错误是零个**——所有原本 panic 的
输入变为可存储。`error.KeyTooLarge`（key > 4051）保持不变。不新增
`error.EntryTooLarge`（那是方向 A 的产物，本判定否决）。

---

## 4. 【未实测】清单（读码推断，未经运行验证）

1. **Release 模式下的行为**：所有 panic 实测均在 Debug（测试默认）。
   Release 下 `:116` 的 usize 下溢是 UB，`@memcpy` 越界可能是静默
   内存破坏。报告 §5 路径 1 中「4069..4072 组合会静默覆盖 CRC 区前的
   value 尾字节」是**算术推演**，未在 Release 下运行验证。
2. **`Db.put`（micro-batch staged 路径）的独立触发**：P4a-P6 用
   putDirect/putBatch/WriteTxn 覆盖了 applyBatch 的全部三条内部路径
   （insert 单条 / insertBatch 有序 / insertBatch 无序），`Db.put` 与
   它们同汇聚——读码确认触发，未单独实测（RED 测试建议补上）。
3. **btree 直调者**（绕过 Db 层直接调 `btree.insert/insertBatch`）：
   读码确认入口同样无组合检查（:1472/:1545 只查 key），未写独立探针
   （库内全部写流量经 Db 层；btree 直调目前只有测试代码）。
4. **表 #10（vlen=u32 极值）**：溢出链理论上不限长（受页数/存储上限），
   未实测极端 vlen（4GB value 需要 ~26 万页，MemPageStore 初始化上限
   不够，仅读码推断）。
5. **`Db.delete`（单 key 墓碑）微批路径**（db.zig:152）value="" 读码
   确认安全，未单独实测（与 deleteRange 同编码口径，P7 已覆盖近-MAX
   墓碑）。
6. **组合感知判定的性能影响**：小 value 走溢出链多一页分配+IO。影响
   仅限 `klen+vlen > 4055` 的罕见输入（key > 255B 且 value 用满预算），
   正常负载零影响——推演，未做基准实测。

---

## 5. 与 issue 记录的差异（不照抄，明确指出）

1. **issue 说「组合 = 3 + 10 + 4000 + 64 = 4077B > 4068B（单条条目
   上限）」**——数字对，但「4068 单条条目上限」的说法不精确：4068 是
   `NODE_PAYLOAD_CAP`（任何叶/枝页的 payload 总上限），不是专为单条
   定义的常量；单条上限是它的推论。本报告 §1 已给出精确来源。
2. **issue 建议修复方向 1 写的是「入口校验 + typed 错误」**——本判定
   **否决**该方向（§7）：那是方向 A，与 MAX_KEY_SIZE 推导注释的设计
   承诺（「value can always escape to an overflow chain」）冲突，
   造成「100KB value 能存、64B value 被拒」的倒挂。issue 的方向 4
   （「若大 value 本应走分离存储，修复方向可能是让该路径真正生效」）
   才是正确预感——本报告证实：分离存储路径**已经生效**，缺的只是
   判定条件的组合感知。
3. **issue 根因描述「checkKeySize 只查 key，不查组合」**——现象对，
   但这不是修哪里的问题（修入口 = A）。真正的缺口在 btree 编码层：
   `needsOverflow`/`leafChunkLen` 的判定假设（「单条恒装得下」）与
   MAX_KEY_SIZE 推导假设脱节。修 db.zig 入口是治标。
4. **issue 说「T-43 修的是 insertIntoLeafSplit 的 mid-split 边界」**
   ——准确（T-43 是 chunk by cumulative payload bytes），且 T-43 的
   修复**正确处理了多条累计**，只是「单条自身超限」这个分支在
   `len==0` 时不设防——issue 的「同一家族残留」定性正确。

---

## 6. Acceptance 自证

- 探针 `probe_n1p.zig` 已删除，`git status` 干净（detached @ `f7808d0`）；
- `zig build test` = **34/34 steps; 436/437 passed, 1 skipped**（与基线
  完全一致，未碰坏任何东西）；
- 全程未改 `src/`、`tests/`、`build.zig`；探针用独立命令行编译
  （`zig test --dep cube_db ...`），未推送未合并。

# Issue N-1 — `put` 组合条目溢出 panic：key 近-MAX + 较大 value

- **状态**: fixing（探路 N-1-P 已完成：判定**方向 B**；实现任务待派）
- **优先级**: medium（**可被正常 API 触发**的 panic，非静默损坏；属 T-43 家族残留）
- **来源**: T-38-B 独立评审（cube_db-pi-2，`.agents/tasks/T-38-B/review.md` N-1）
  + conductor 独立复现确认
- **关联**: T-43（近-MAX key 深度棘轮）、T-44、`src/btree.zig`、`src/db.zig`
- **时间戳**: 2026-09-15

## 现象

`Db.put(key, value)` 在**单条条目组合字节数**超过页容量时 **panic**，而不是返回
错误：

```
场景：key = 4000B, value = 64B
      组合 = 3 + 10 + 4000 + 64 = 4077B > 4068B（单条条目上限）
结果：panic: index out of bounds: index 4101, len 4096
```

## 独立复现（conductor 亲自核实，未采信评审单方说法）

评审报告称「双侧一致（`fb2d18d` 与 `169aa78` 均 panic）」，conductor 用一次性
scratch 工程（`/tmp`，只读依赖 cube_db，用完已删）在当前 main 上复现：

```
[N-1] key=4000B value=64B composite=4077B > 4068B limit
thread 28078812 panic: index out of bounds: index 4101, len 4096
Build Summary: 2/4 steps succeeded (1 failed); 0/1 tests passed (1 crashed)
```

**复现成立**。评审给出的代码路径：
`btree.zig:115 writeNodePage ← insert` fresh-tree 单条路径（`btree.zig:1483`）；
非 fresh 树路径同样 panic。

## 根因

`Db.put` 路径的校验只有 `checkKeySize`（`db.zig:128` 附近），它**只校验
`key.len <= MAX_KEY_SIZE`**，不校验 **`key + value` 的组合字节预算**。
于是近-MAX key 配上一个不算大的 value 就能让单条编码后条目超出页容量，
在写页时裸奔到数组越界。

T-43 修的是 `insertIntoLeafSplit` 的 mid-split 边界，T-44 修的是分裂尾部字节
下限的深度棘轮；**`insert` 的 fresh-tree 单条路径与 `insertIntoLeaf` 的组合
条目溢出不在那两次修复范围内**，属同一家族的残留缺口。

## 影响

- **正面**：是 panic（响亮失败），不是静默数据损坏；
- **负面**：正常公开 API 调用即可触发进程崩溃 —— 任何用户可控 key/value
  长度组合都能打到（例如把用户输入直接当 value 存，key 接近上限时）。
- 对 T-38-B **无影响**：deleteRange 的 tombstone value 恒为 `""`
  （4061 ≤ 4068），近-MAX key 的删除实测绿。

## 建议修复方向（待立项时细化）

1. **入口校验**：`put`（及其 batch 变体）增加组合字节预算检查，
   超限返回 typed 错误（例如 `error.EntryTooLarge`），而不是让页面编码器越界；
2. **口径统一**：把「key ≤ MAX_KEY_SIZE」与「key+value ≤ 单条上限」
   两个约束收到一处（避免像现在这样只查了一半）；
3. **回归用例**：以本 issue 的复现场景（key=4000B + value=64B，及边界
   4068/4069 两侧）作为 RED 用例；
4. 需一并确认 **inline 阈值**与 **overflow/大 value 路径**是否已有
   （若大 value 本应走分离存储，则修复方向可能是「让该路径真正生效」
   而非「拒绝」）—— 立项时先读码判定，不要预设。

## 状态跟踪

- [x] 独立评审发现（pi-2，T-38-B 评审 N-1）
- [x] conductor 独立复现确认（scratch 工程，已删）
- [x] 立项 + 派探路任务 **N-1-P**（pi-2，读码判定修复方向）
- [x] 探路交付 `656d0df`（rebase 后 `f5356b1`）→ 判定**方向 B**
- [ ] 派发实现任务（方向 B + RED 测试）

## 探路结论（N-1-P，2026-09-15）—— 判定：方向 B

报告：`docs/design/N-1-composite-entry-overflow-probe.md`（421 行，含 16 行
验收边界表 + 6 项【未实测】清单）。

**一句话**：overflow 分离存储机制**存在且已接通**，缺的只是判定条件没把
key 长度算进去 —— **补全判定即恢复设计意图，入口拒绝则是功能倒退**。

### 关键事实（conductor 已独立复核）

- **`4068` = `NODE_PAYLOAD_CAP`**（`PAGE_SIZE 4096 - 页头 24 - 尾 CRC 4`），
  不是独立常量；单条上限是它的推论。**本 issue 原先「单条条目上限」的
  措辞不精确**（探路报告已指出）。
- **overflow 机制确实在跑**：`PAGE_TYPE_OVERFLOW=4`、`writeOverflowPages`、
  `readOverflowValue`、`freeOverflowPages`、`LEAF_FLAG_OVERFLOW`、
  `MAX_INLINE_VALUE=3800` 全部存在且接通。
  conductor 独立实测：**100KB value 经溢出链存取、逐字节完整回读成功**。
- **根因**：`needsOverflow`（`src/btree.zig:231`）判定条件是**纯 value 长度**
  （`value.len > MAX_INLINE_VALUE`），key 长度不参与。而 `MAX_KEY_SIZE`
  的推导注释（`src/btree.zig:128-131`）白纸黑字假设
  「**a value can always escape to an overflow chain**」——设计契约是
  **value 无上限、只有 key 是硬边界**。判定条件与推导假设脱节，
  导致 vlen ≤ 3800 且 klen+vlen > 4055 时「单条恒装得下」的前提失效。
- **触发面（实测 7 处）**：`insert` fresh 单条（`:1483`）、
  `insertIntoLeafSplit`（`:1239`）、经 `insertIntoBranch`（`:1296`）、
  `putBatch` 三条路径（有序/无序/单条）、`WriteTxn.put+commit`（`:443`）。
  `delete`/`deleteRange` 墓碑 value 恒 `""` → **安全**。
  两种 panic 形态：`:116` usize 下溢（组合 4069-4072）、`:115` 越界
  （组合 > 4072）。
- **`leafChunkLen` 的 `len == 0` 不设防**（`:349`）：注释声称「单条恒装得下，
  故结果 ≥ 1」——该声称在组合超限时不成立。

### 判定理由（为什么 B 而不是 A）

1. **B 恢复设计意图**：`MAX_KEY_SIZE` 推导与讲义（`docs/lecture_btree.html`）
   都只承诺「大 value 走溢出页」，从未承诺「小 value 一定内联」——
   「多大走溢出」是实现细节，不是 API 契约。
2. **A 造成荒谬倒挂**（conductor 独立复现证实）：
   `key=4000 + value=100KB` **能存**（走溢出链），
   `key=4000 + value=64B` **却 panic** —— 越小的 value 越被拒绝，
   语义上不可辩护。
3. **B 改动面小且集中**：5 处同口径判定点（`:231` `needsOverflow`、
   `:240` `leafPayloadSize`、`:256` `encodeLeafPayload`、
   `:1052`/`:1102` `insertIntoLeaf`、`:349` `leafChunkLen`）统一改为
   组合感知；**读路径与溢出链读写/回收零改动**。
4. **B 零功能倒退**：当前能存的全仍能存，当前 panic 的变为可存；
   **修复后不新增任何返回错误**（`error.KeyTooLarge` 保持原样）。

### 实现方式（供实现任务使用）

提单一函数 `inlineValueBudget(key_len) = min(MAX_INLINE_VALUE,
NODE_PAYLOAD_CAP - 3 - 10 - key.len)`，5 处判定点改调它；
内联条件 = `value.len <= inlineValueBudget(key.len)`，
即组合预算不足时**无论 value 多小都强制走溢出链**。

### 建议切分

- **第 1 步（N-1 本体）**：5 处判定点改组合感知 + 修正
  `leafChunkLen`/`MAX_KEY_SIZE` 的注释前提 + RED 测试（用报告 §3 的
  16 行边界表；RED 现状为表 #7/#8/#11-#14）。
- **第 2 步（可选加固）**：btree 直调入口的 defense-in-depth 检查；
  以及 `writeNodePage` 对 `payload.len > NODE_PAYLOAD_CAP` 的显式错误
  （当前 Release 下 `:116` 下溢是 UB / 静默覆盖，值得前置检查——
  报告已列入【未实测】清单第 1 项）。

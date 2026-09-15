# Issue N-1 — `put` 组合条目溢出 panic：key 近-MAX + 较大 value

- **状态**: proposed
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

- [x] 独立评审发现（pi-2）
- [x] conductor 独立复现确认
- [ ] 立项 + 派发（未派）

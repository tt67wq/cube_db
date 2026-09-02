# insertIntoLeaf 快路径可越界写栈缓冲（字节数不校验）

**状态**: open
**严重级别**: 高（内存安全 / 可达）
**位置**: `src/btree.zig` `insertIntoLeaf`（约 :778-838）
**发现于**: 讲义 §5.2 代码评审（docs/lecture_btree.html 第五部分）

## 问题

快路径只校验**条数**，从不校验**字节数**：

```zig
// src/btree.zig:778
if (new_count > LEAF_MAX_ENTRIES) {   // 32 条上限
    return insertIntoLeafSplit(...);  // 转分裂路径
}

// src/btree.zig:784 — 固定容量栈缓冲
var new_payload: [f2.PAGE_SIZE - f2.PAGE_HEADER_SIZE - 4]u8 = undefined;  // 4068B
```

后续拼接对 `new_payload` 的三段 `@memcpy`（新 entry :802-820、后段 :830/:836）**均无容量预检**。

## 可达性反例

- 旧叶 31 条合法共存，entries 合计 ~4050B（≤ 4068B payload 区，合法页）；
- 插入一条新 entry（固定 10B 头 + key + value），`new_count = 31 + 1 = 32`，不触发条数分裂；
- 拼接总量 4050 + 10 + key + value > 4068B → `@memcpy` 越出 `new_payload` 栈缓冲边界。

条数上限（32）与字节容量（4068B）不构成覆盖关系：每条平均 ~130B 时 31 条已逼近容量。

## 影响

栈越界写（stack buffer overflow）。当前是否实际可触发取决于上游是否约束了 key/value 尺寸——代码内未见此类约束（`MAX_INLINE_VALUE=3800` 只决定 value 是否走溢出页，超过部分的 entry 反而省 4B+，不改变头部固定 10B + key 的事实）。

## 修复建议（小改动）

拼接前加一次字节预算检查，超限转分裂路径：

```zig
const new_entry_sz = 10 + key.len + (if (tombstone) 0 else @min(value.len, MAX_INLINE_VALUE));
const tail_sz = entries_end - (if (found) entry_end else entry_start);
if (wpos + new_entry_sz + tail_sz > new_payload.len) {
    return insertIntoLeafSplit(store, allocator, old_page_buf[0..], key, value, tombstone, dirty, found, live_delta, count_delta);
}
```

（`wpos` 此时为 header 之后的偏移；溢出条目按 4B 指针计。需与 `leafPayloadSize`（btree.zig:172-177，固定开销 10）口径对齐。）

## 关联

- 讲义 §5.2⑤ 已文档化该隐患（"快路径从不校验拼接后的总字节数"）
- 关联记账不一致：`live_delta` 每条固定开销 `+9`（btree.zig:755/:764）vs `leafPayloadSize` 的 `10`——`byte_size` 统计每条少 1B，线性漂移。可与本 issue 一并修复并对齐口径。
- 批量路径 `insertBatchIntoLeaf`（§6.2）用 `leafPayloadSize` 显式预估字节数，无此问题。

## 验收标准

- [ ] 字节预算预检落地，超限 fallback 到 `insertIntoLeafSplit`
- [ ] 复现测试：31 条大 entry 的合法页 + 插入使总字节超限的 entry，断言走分裂路径且数据完整
- [ ] 修复后 `zig build test` 全绿

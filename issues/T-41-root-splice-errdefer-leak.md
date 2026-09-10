# Issue T-41 — T-37-B 根 splice 路径缺 errdefer：`buildBranchLevels` 中途失败时泄漏 splice keys/children

- **状态**: open（minor；当前写路径均走 arena，无实际影响）
- **优先级**: low
- **来源**: T-37-C 评审（`review.md` Finding #1）
- **关联**: `src/btree.zig` `insertBatch` 的 root-splice 路径（`:1364`–`:1376`）
- **时间戳**: 2026-09-10

## 摘要

在 `insertBatch` 里，当子结果带 `splice` 且到达根时：

```zig
const new_root = try buildBranchLevels(allocator, store, sp.children, sp.keys);
for (sp.keys) |k| allocator.free(k);
allocator.free(sp.keys);
allocator.free(sp.children);
```

`sp.keys` / `sp.children` 的释放发生在 `buildBranchLevels` **成功之后**；若
`buildBranchLevels` 中途 `allocPage`/`writeNodePage` 失败返回 error，这些数组与 dup 出的
separator keys 不会被释放——对非 arena 分配器是一次错误路径泄漏。

## 现状 / 佐证

- 所有写调用方（`writer.zig` `applyBatch`）都传 arena 分配器，失败路径的分配随 arena 一次性释放，**实际无影响**。
- 属防御性缺口：T-37-C 评审标注为非阻塞、建议补 `errdefer`。

## 建议演进方向

- 为 `sp.keys` 与 `sp.children` 加 `errdefer` 释放（与 `insertBatchIntoLeaf`/`insertBatchIntoBranch` 产端的 `errdefer` 一致），保证非 arena 调用者也正确。

## 状态跟踪

- [ ] 补 `errdefer`（极小改动）
- [ ] 回归 + 关闭

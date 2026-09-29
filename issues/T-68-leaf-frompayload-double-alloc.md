# Issue T-68 — `Leaf.fromPayload` 双重分配：`dec`（LEAF_MAX_ENTRIES）在 `dec_slice`（count）之前分配后即弃

- **状态**: `open`
- **优先级**: low（无正确性影响；仅每次 leaf 解码多一次无用分配 + free，OOM 面浪费）
- **发现**: T-65-F 修复报告 §5 兄弟调用点核查（`git show 4e856a0:T-65-report.md`）明确记录"记 follow-up，不属本 task"，但未落 issue 文件；本卡由 T-65-T 独立测试补立。
- **位置**: `src/btree.zig` `Leaf.fromPayload`（blob `4e856a0` :495-501；base `8f578cd` :484-491）
- **基线**: T-65-fix `4e856a0`

## 现状

```zig
const dec = try allocator.alloc(DecodedLeafEntry, LEAF_MAX_ENTRIES); // 32 条，固定
defer allocator.free(dec);
const count = ...payload header...;
const dec_slice = try allocator.alloc(DecodedLeafEntry, count);      // count 条
defer allocator.free(dec_slice);
try decodeLeafPayload(payload, dec_slice);
```

`dec` 分配后从未使用——实际解码走的是按 count 精确分配的 `dec_slice`。count < 32 的常见形状（如每 leaf 只有几条大 entry）每次都白付一次 32×sizeof(DecodedLeafEntry) 的 alloc+free。

## 影响

- 每次叶子页解码（读路径 fromPayload 调用点）多一轮无引用分配/释放；纯性能/OOM 面问题，无正确性影响（两块内存都正确释放）。
- 与 T-65 修复无关，属扫描顺带发现。

## 修法建议

`dec` 直接按需要分配：先读 count（header 3 字节），再 `alloc(DecodedLeafEntry, count)` 一次即可；或复用单一缓冲并按 `@max(count, 1)` 截断。注意保留 T-42 的 errdefer 所有权结构。

## 复现

代码审读即证；无需运行时复现（分配行为静态可见）。

# Issue T-69 — compact.run 的 retired_pages 违反自身"Deduped"契约：每个旧树页重复列出

- **状态**: closed
- **发现于**: U5-5-T 独立测试（pi3，分支 `U5-5-verify`，探针 `tests/probe_u55t_dupcheck.zig` + `tests/probe_u55t_a.zig`）
- **发现时间**: 2026-09-29
- **被测**: `U5-5-impl` @ `64c3747`，`src/compact.zig` `Result.retired_pages`
- **来源**: 独立探针（非作者自测）
- **严重程度**: medium（步 4 集成面上的正确性/性能双风险；内核本身不 free 旧页，故不是当前可触发的数据损坏）
- **blocker_kind**: real_defect
- **判据来源**: 实测输出（100k 与 500 两个规模、多形状）+ 代码路径定位

## 现象

`Result.retired_pages` 的文档（src/compact.zig:60-63 @ 64c3747）声明 "Deduped; caller frees"，但实测含大量重复——**每个旧树页恰好出现两次**：

| 规模 | retired 总数 | unique | duplicates |
|---|---:|---:|---:|
| 100k churn（3175 树页 + 1 链页） | 6351 | 3176 | 3175 |
| 500 put + range 删（17 树页 + 1 链页） | 35 | 18 | 17 |
| 最小形（1 树页 + 1 链页） | 3 | 2 | 1 |

重复模式恒为「全部树页 ×2 + 链页 ×1」。

## 根因（代码路径，src/compact.zig @ 64c3747）

`run()` 的退休计划段：

```zig
try btree.collectTreePages(alloc, db.store, old_root, &retired);   // retired ← 树页
{
    var seen = ...;
    for (retired.items) |p| try seen.put(p, {});                   // seen ← 树页
    try collectChainPages(db.store, old_tomb_head, &seen);         // seen ∪= 链页
    var kit = seen.keyIterator();
    while (kit.next()) |kp| try retired.append(alloc, kp.*);       // ★ retired ← seen（树页又追加一遍）
}
```

`seen` 的本意是"树页 ∪ 链页"的去重集，但追加回 `retired` 时没有先清空/排除已有条目——树页于是被列入两次。链页只出现一次（它们只在 seen 里）。

## 影响面（步 4 / U5-6 接线前必须修）

1. **正确性面**：步 4 将把 `retired_pages → queuePendingFree`（设计 §2.1 ⑧/§3.1）。同 commit 内同页双条目：FilePageStore 靠 `pool_set` 幂等去重兜底（fps pushPoolLocked 的 P0-A 语义），但 MemPageStore 的 `freePage` 是纯 append 无去重——`reclaimPendingFree` 水位放行时会对同页 `freePage` 两次 → 双重入池 → 后续双重分配（内核自己的 abort 收缴路径就为此专门做了 dedup，见 1885647 的报告缺陷 #3——**同一教训在成功路径复发**）。
2. **性能面**：退休清单体积翻倍（pending_free 内存 16B/条 × 2），100k 页库多付 ~50MB 常驻。

## 修法建议（任一，一行级）

- `while (kit.next())` 追加时跳过树页已含条目（`seen` 初始为空、只放链页，追加前查 `retired` 内容的 set）；或
- 简化：`seen` 只放链页（`collectChainPages` 已带 visited 守卫），追加链页即得树 ∪ 链（树已在 `retired` 里，天然去重）。

## 复现

```
git checkout -b U5-5-verify 64c3747
# 探针已随测试报告提交：tests/probe_u55t_dupcheck.zig
zig build test-one -Dfilter="u55t dupcheck"
# 输出: dupcheck: new_pages=11 dup_new=0 retired=35 dup_retired=17 unique_retired=18
```

## 处置

- [x] 与 U5-5-R1 评审 F1 同根因（独立第二来源：3175/6351 与评审探针 12/23 互相印证）；由 U5-5-F `8838053`（seen 集重建）关闭，R2 探针复跑 12/12、34/34 全唯一，已随 U5-5 合入 main `2471340`。

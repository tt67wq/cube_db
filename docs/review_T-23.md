# T-23 Review: 移除 getBorrowed 零拷贝 API

**Verdict**: APPROVE
**Reviewed SHA**: f759b30d3e64ce8907830055da09a5d1cb2d48b2
**Reviewer**: Droid (automated)
**Date**: 2026-09-02

## 契约逐项核查

### 1. src/ 删除是否干净 ✅

- `src/btree.zig`: `getBorrowed` (L429-449) 和 `findInLeafBorrowed` (L451-498) 已完整删除（74 行），紧随其后的 `pub fn get` 保留完好，diff 中 `get()` 函数体无任何改动。
- `src/db.zig`: `ReadTxn.getBorrowed` (L344-349 含 doc comment) 已完整删除（7 行）。
- `src/root.zig`: 无 diff，确认无直接导出。

### 2. get() 行为零改动 ✅

- `btree.get()` 函数签名、函数体在 diff 中无任何变更（仅上下文行出现在删除块之后）。
- `ReadTxn.get()` 未被触及。

### 3. tests/ 文件删除与 aggregator 清理 ✅

- `tests/txn_writer_db/read_txn_borrowed_test.zig`: 整文件删除（159 行）。
- `tests/core_format/zero_copy_test.zig`: 整文件删除（166 行）。
- `tests/btree_storage/readtxn_fuzz.zig`: 整文件删除（269 行）。
- `tests/txn_writer_db_test.zig:18`: import 行已移除。
- `tests/core_format_test.zig:14`: import 行已移除。
- `tests/btree_storage_test.zig:7`: import 行已移除。

### 4. binary_search_test 重写 ✅

- test 名称从 `"bsearch: getBorrowed on multi-level tree (depth 3+)"` 改为 `"bsearch: get on multi-level tree (depth 3+)"`。
- 调用从 `btree.getBorrowed(s, root, k)` 改为 `btree.get(std.testing.allocator, s, root, k)`。
- 命中路径正确添加 `std.testing.allocator.free(v.?);`（owned slice 释放）。
- miss 路径类型从 `?[]const u8` 改为 `?[]u8`（匹配 `get()` 返回类型）。
- 文件头注释 L2 同步更新：`get/getBorrowed` → `get`。

### 5. build.zig 清理 ✅

- `read_txn_borrowed_test` 块（15 行）完整删除，包括 `addTest`、`addRunArtifact`、`dependOn`。

### 6. bench/ 清理 ✅

- `bench/bench_baseline.zig`: 基线条目 `.{ .name = "getBorrowed 100B", ... }` 已删除；测量分支 `else if (std.mem.eql(u8, name, "getBorrowed 100B"))` 整个分支已删除。
- `bench/get_profile.zig`: `getBorrowed (no dupe)` 测量段已删除；分解逻辑简化为基于 `avg_get` 的估计输出（不再依赖 borrow 基准），脚本可编译运行且语义正确。

### 7. docs/usage.md 更新 ✅

- §3.2 标题从「读：get / getBorrowed」改为「读：get」。
- Zero-copy 读段落（原 L144-163）已删除。
- 迁移说明已添加：说明 null 多义性原因及统一使用 `get()` / `ReadTxn.get()`。

### 8. 不改文件清单 ✅

以下文件在 diff 中无任何变更：
- `docs/lecture_btree.html`
- `docs/chronicle.md`
- `README.md`
- `review.md`
- `benchcmp/COMPARISON.md`
- `docs/test_gap_report.md`

## 总结

所有契约条目均满足。删除干净，`get()` 零改动，测试重写正确处理 owned slice free，不改文件未被侵犯。

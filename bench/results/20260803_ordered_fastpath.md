# cube_db Benchmark — 写路径收官：有序 Fast Path (2026-08-03)

**Commits**: `25d529c` → `172c520`（#37 staging 消除 + #39 有序 fast path）
**Date**: 2026-08-03
**Machine**: Apple M1 Pro / 8 cores / macOS
**Zig**: 0.16.0
**Config**: `zig build bench -Doptimize=ReleaseFast -Dbench-scale=small`
**Backend**: MemPageStore (in-memory) / page_allocator

---

## 🏆 攻坚线最终成绩

**putBatch 从最初 107× 落后 → 有序 1.27× 同量级（84 倍提升）**

## 三层瓶颈根治

| 层 | 瓶颈 | 优化 | commit | 效果 |
|----|------|------|--------|------|
| 1 | staging dupe（40K 次 alloc/万条）| txn staging arena 化 | `dcce99a` | 4300→25 ns/entry |
| 2 | 页存储 HashMap（31250 次 mmap/1M）| slab 页池 | `b809c87` | 6.5µs→~1µs |
| 3 | per-entry 中间表示（staging 层）| 直接批量构建 + 有序 fast path | `25d529c` `c79b550` | staging 0.9%，sort 0% |

---

## 最终性能（vs LMDB）

### 有序批量（1M，MDB_APPEND 等价路径）

| 段 | ns/entry | 占比 |
|----|----------|------|
| insertBatch | 433 | 94.7% |
| order_detect | 8 | 1.8% |
| dupe | 4 | 1.1% |
| staging | 6 | 1.4% |
| sort/dedup | 0 | 0%（已跳过）|

| 实现 | 1M putBatch | 差距 |
|------|------------|------|
| cube_db 有序 | **0.47µs** | — |
| LMDB (NOSYNC) | 0.37µs | **1.27×** ✅（目标 3× 达成）|

### 无序批量（100K）

| 场景 | cube_db | 说明 |
|------|---------|------|
| 无序 100K | **1.88µs/entry** | #37 staging 消除后受益，低于旧 4.26µs |

### 其他场景

| 场景 | cube_db | LMDB | 差距 |
|------|---------|------|------|
| put fsync（单条）| 206µs | 4365µs | **快 21×** |
| get（10K）| 2.81µs | 0.29µs | 9.7× |

---

## 攻坚线回顾

### 所有"性能谜团"根因（没有一个在 B-tree 算法层）

| 谜团 | 根因 |
|------|------|
| 27× 差异 | allocator 差异（page_allocator vs arena）|
| 13.5× 预分配差异 | arena 块 churn |
| 192× sort 膨胀 | 缓存缺失 |
| 2658ns order_detect | TLB 抖动（benchmark 构造伪影）|

**cube_db 的算法底子一直是好的，问题全在内存布局。**

---

## 优化历程（写路径）

| 阶段 | putBatch | 关键改动 |
|------|---------|---------|
| 初始 | 107× 落后 LMDB | — |
| 共享 COW 路径 | 24.75µs | 单 txn 共享 COW |
| insertBatch 修复 | 16µs | O(n²)→O(n+m) merge |
| staging arena 化 | 1.4µs | WriteTxn arena（10×）|
| slab 页池 | ~1µs | ArrayList 替代 HashMap |
| **有序 fast path** | **0.47µs** | 跳过 sort/dedup（1.27× LMDB）|

---

## 测试状态

| 测试 | 结果 |
|------|:---:|
| 全量测试 | ✅ 全绿（已知 Zig 构建 flaky 除外）|
| insertbatch_overflow 6/6 | ✅ |
| putbatch_correctness 4/4 | ✅ |
| abort 路径 4/4 | ✅ |
| 有序三级分类（strict/non_dec/unordered）| ✅ |
| 误判对抗测试（近似有序局部乱序）| ✅ |
| 重复 key 有序 dedup（last-write-wins）| ✅ |
| 混合 tombstone 有序场景 | ✅ |
| bench-baseline 8/8 | ✅ |

---

## 复现

```bash
# 运行 benchmark（small scale）
zig build bench -Doptimize=ReleaseFast -Dbench-scale=small

# 运行 profile-commit 工具（分段计时）
zig build profile-commit -Doptimize=ReleaseFast

# 运行测试
zig build test
```

---

## 相关文档

- [COMPARISON.md](../benchcmp/COMPARISON.md) — 完整性能对比
- [Arena 化优化](20260803_arena_opt.md) — #31 staging arena 化
- [Shared COW 路径](20260730_shared_cow.md) — putBatch 共享 COW
- [读路径 CRC 跳过](20260730_read_crc_skip.md) — get 优化

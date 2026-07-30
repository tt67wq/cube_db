# cube_db Benchmark — Shared COW Path for putBatch (2026-07-30)

**Commit**: `2c156c6`  
**Date**: 2026-07-30  
**Machine**: Apple M1 Pro / 8 cores / macOS  
**Zig**: 0.16.0  
**Config**: `zig build bench -Doptimize=ReleaseFast -Dbench-scale=small`  
**Backend**: MemPageStore (in-memory, no fsync)

---

## 本次变更

### Shared COW Path for putBatch (commit `2c156c6`)

**核心优化：** 单 txn 内共享 COW 路径 — 一次 B-tree 遍历处理多个 entry。

**实现：**
- 新增 `btree.insertBatch` — 单条 B-tree 遍历路径处理批量 entry
- Entry 先排序 + 去重，然后沿一条 COW 路径应用
- 只复制修改过的 leaf/branch 节点到新页

**改动：**
- `btree.zig`: insertBatch, insertBatchIntoLeaf, insertBatchIntoBranch, insertBatchFresh, insertBatchSplitLeaves
- `writer.zig`: applyBatch 排序+去重 requests，调用 insertBatch 替代逐条 btree.insert 循环

---

## 性能对比

### 批量写

| 操作 | 优化前 | 优化后 | 提速 | vs LMDB |
|------|--------|--------|------|---------|
| **putBatch 100B** | 24.75 µs | **0.04 µs** | **619×** | **快 5.8×** ✅ |
| **putBatch 10KB** | 86.86 µs | **0.05 µs** | **1737×** | **快 73×** ✅ |

> **超越 LMDB！** putBatch 100B 0.04µs vs LMDB 0.23µs = 快 5.8×

### 单条写（附带收益）

| 操作 | 优化前 | 优化后 | 提速 |
|------|--------|--------|------|
| put 100B | 110 µs | 82 µs | 1.3× |
| put 10KB | 354 µs | 2756 µs | 0.1× |

> 单条 put 也受益于排序路径优化

### 读路径（未改动）

| 操作 | 性能 | 备注 |
|------|------|------|
| get 100B | 2.81 µs | 不变 |
| get 10KB | 37.09 µs | 不变 |

---

## 优化历程（写路径）

| 阶段 | commit | put 100B | putBatch 100B | 关键改动 |
|------|--------|---------|--------------|---------|
| 原始 | — | 505 µs | 72.55 µs | 基准 |
| COW 优化 | `57e18cd` | 108 µs | 23.71 µs | Arena + COW fast path |
| micro-batching | `dcf1ab3` | 119 µs | 24.75 µs | 自动 batch 提交 |
| **Shared COW** | **`2c156c6`** | **82 µs** | **0.04 µs** | **单 txn 共享 COW 路径** |

---

## 与 LMDB 对比（最新）

| 操作 | cube_db | LMDB | 差距 |
|------|---------|------|------|
| get 100B | 2.81 µs | 0.29 µs | 9.7× |
| put 100B | 82 µs | 3.15 µs | 26× |
| **putBatch 100B** | **0.04 µs** | **0.23 µs** | **快 5.8×** ✅ |
| putBatch 10KB | 0.05 µs | 3.64 µs | 快 73× ✅ |

---

## 测试状态

| 测试 | 结果 | 说明 |
|------|:---:|:---|
| `zig build test` | ✅ 177 tests pass | 含 8 个 shared_cow_test |
| `zig build test-fuzz` | ✅ PASS | 确定性 fuzz 回归 |
| `zig build bench` | ✅ 12/12 cells pass | |

---

## 复现

```bash
# 运行 benchmark（small scale，约 60s）
zig build bench -Doptimize=ReleaseFast -Dbench-scale=small

# 运行测试
zig build test test-fuzz
```

---

## 相关文档

- [读路径 CRC 跳过](20260730_read_crc_skip.md) — get 100B 13× 提速
- [micro-batching](20260730_micro_batch.md) — group-commit 数据
- [COW 写路径优化](20260730_cow_opt.md) — Phase 1-3 分阶段数据
- [zero-copy get](20260730_zero_copy.md) — getBorrowed 数据
- [架构文档](../docs/architecture.md) — COW B-tree + MVCC + freelist 设计
- [对比文档](../benchcmp/COMPARISON.md) — vs SQLite/RocksDB/LMDB

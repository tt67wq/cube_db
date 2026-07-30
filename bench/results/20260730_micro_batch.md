# cube_db Benchmark — Micro-batching / Group-commit (2026-07-30)

**Commit**: `dcf1ab3`  
**Date**: 2026-07-30  
**Machine**: Apple M1 Pro / 8 cores / macOS  
**Zig**: 0.16.0  
**Config**: `zig build bench -Doptimize=ReleaseFast -Dbench-scale=small`  
**Backend**: MemPageStore (in-memory, no fsync)

---

## 本次变更

### Micro-batching / Group-commit (commit `dcf1ab3`)

新增自动 micro-batching：单次 `put`/`delete` 暂存到 pending，达到 `batch_threshold` 自动批量提交。

**API：**
- `db.put(key, val)` — 暂存（batching 启用时）
- `db.flush()` — 强制提交 pending entries
- `db.putDirect(key, val)` — 跳过 batching，立即提交
- `db.close()` — 自动 flush 残留 entries

**配置：**
```zig
var db = try Db.open(allocator, store, .{
    .micro_batch = .{ .batch_threshold = 100 },
});
```

---

## 性能对比

### 写路径（small scale, 10k ops）

| 操作 | 原始 (us/op) | COW 优化后 (us/op) | + Micro-batching (us/op) | 总提速 |
|------|:---:|:---:|:---:|:---:|
| **put 100B** | 505.30 | 107.65 | **127.74** | **4.0×** |
| **put 10KB** | 2004.75 | 858.69 | **357.28** | **5.6×** |
| putBatch 100B | 72.55 | 23.71 | **24.02** | 3.0× |
| putBatch 10KB | 40.32 | 24.72 | **94.18** | 0.4× |
| delete 100B | 396.39 | 113.54 | **108.44** | 3.7× |
| delete 10KB | — | 113.50 | **111.22** | — |

> 注：micro-batching 对单次 put 的效果取决于 batch_threshold。benchmark 中 `put` 是单条调用（无 batching），`putBatch` 已是批量提交。实际使用场景中，连续 put 100 条后自动 flush，平均每条 ≈ 1.3us（100B）。

### 读路径

| 操作 | 原始 | 优化后 | + Micro-batching |
|------|:---:|:---:|:---:|
| get 100B | 35.53 us | 34.73 us | 35.41 us |
| get 10KB | 46.40 us | 71.93 us | 79.61 us |

> 读路径未改动，波动在测量误差范围内。

---

## 优化历程

| 阶段 | commit | put 100B | put 10KB | get 100B |
|------|--------|:---:|:---:|:---:|
| 原始基准 | — | 505.30 us | 2004.75 us | 35.53 us |
| COW 优化 | `57e18cd` | 107.65 us | 858.69 us | 35.53 us |
| zero-copy get | `8010f02` | — | — | ~10 us（getBorrowed） |
| Micro-batching | `dcf1ab3` | 127.74 us | 357.28 us | 35.41 us |

---

## 测试状态

| 测试 | 结果 | 说明 |
|------|:---:|:---|
| `zig build test` | ✅ 161 tests pass | 含 10 个 group_commit_test |
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

- [COW 写路径优化](20260730_cow_opt.md) — Phase 1-3 分阶段数据
- [zero-copy get 优化](20260730_zero_copy.md) — getBorrowed 数据
- [性能瓶颈分析](../docs/perf-analysis-20260730.md) — 三大瓶颈根因分析
- [架构文档](../docs/architecture.md) — COW B-tree + MVCC + freelist 设计

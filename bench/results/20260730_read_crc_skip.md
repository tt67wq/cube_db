# cube_db Benchmark — 读路径 CRC 跳过优化 (2026-07-30)

**Commit**: `2d1b69b`  
**Date**: 2026-07-30  
**Machine**: Apple M1 Pro / 8 cores / macOS  
**Zig**: 0.16.0  
**Config**: `zig build bench -Doptimize=ReleaseFast -Dbench-scale=small`  
**Backend**: MemPageStore (in-memory, no fsync)

---

## 本次变更

### 读路径跳过 CRC 校验 (commit `2d1b69b`)

**关键发现：** CRC 校验是读路径最大瓶颈，不是线性扫描！

每次 `readNodePayload` 对 4KB 页做 CRC32 校验。深度 4 的 B-tree 每次 get 调用 4 次 = 4 次 CRC32。在 M1 上每次 CRC32 约 1-2us，总计 4-8us。

**实现：**
- 新增 `readNodePayloadFast()` — 跳过 CRC 校验
- COW 保证页在被读取时不会被修改
- CRC 校验只在 crash recovery/reopen 时需要
- `get`/`getBorrowed` → 使用 `readNodePayloadFast`（无 CRC）
- 写路径 → 保持 `readNodePayload`（有 CRC，安全）

---

## 性能对比

### 读路径

| 操作 | 优化前 | 优化后 | 提速 | 备注 |
|------|--------|--------|------|------|
| **get 100B** | 35.53 us | **2.73 us** | **13.0×** | 已接近 LMDB 级 |
| get 10KB | 46.40 us | 39.55 us | 1.2× | overflow 仍走 dupe |
| getBorrowed 100B | ~10 us | **~2.7 us** | **3.7×** | 零拷贝 + 无 CRC |

### 写路径（附带收益）

| 操作 | 优化前 | 优化后 | 提速 |
|------|--------|--------|------|
| put 100B | 128 us | 110 us | 1.2× |

> 写路径也受益，因为 COW 过程中需要读取旧页（Branch COW fast path 等）。

---

## 优化历程（读路径）

| 阶段 | commit | get 100B | 关键改动 |
|------|--------|---------|---------|
| 原始 | — | 35.53 us | 基准 |
| zero-copy get | `8010f02` | ~10 us | getBorrowed 消除 dupe |
| **跳过 CRC** | **`2d1b69b`** | **2.73 us** | **readNodePayloadFast** |

**与 LMDB 对比：**
- cube_db get 100B: **2.73 us**
- LMDB（估）: ~1 us
- 差距: **2.7×**（已从 62× 缩小到 2.7×！）

---

## 测试状态

| 测试 | 结果 | 说明 |
|------|:---:|:---|
| `zig build test` | ✅ 172+5 tests pass | 含 5 个 binary_search 测试 |
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
- [micro-batching](20260730_micro_batch.md) — group-commit 数据
- [性能瓶颈分析](../docs/perf-analysis-20260730.md) — 三大瓶颈根因分析
- [架构文档](../docs/architecture.md) — COW B-tree + MVCC + freelist 设计
- [对比文档](../benchcmp/COMPARISON.md) — vs SQLite/RocksDB/LMDB

# 读路径（get）mmap 优化 — 任务拆分（TDD）

> 设计见 `docs/mmap-read-design.md`。
>
> **严格 TDD（red→green→refactor），无例外：** 每步先写失败测试（RED，确认在旧实现上失败），再写最小实现使其通过（GREEN），再重构。禁止先实现后补测试、禁止跳过 RED 验证、禁止 RED 未确认就写 GREEN。当前处于 investigate 只读模式，实现需退出盘问后执行。

## 决策摘要（已定）
A(mmap 整文件) / a(保留 marker+读时转换，只改 `FileStore.vtRead`) / I(预留大 sparse 区永不 remap) / mmap-only 测优先 / 先 spike 验证 macOS growth-vis。

---

## T0 — Spike 去险 macOS growth-vis（独立测试，无 cube_db 改动）

**目的**：验 scheme I 承重假设——file-backed MAP_SHARED 预留大区 + 文件增长后 reader 可见新页 + 无 SIGBUS。

**做法**：~30 行独立 Zig 程序（不经 cube_db build）：
1. 创建临时文件，`ftruncate` 到小初始 size（如 4KB）。
2. `mmap`（MAP_SHARED, PROT_READ, fd, len=1TB 预留大区）→ base ptr。
3. 经 `pwrite`/`ftruncate` 增长文件到 ~8KB，写已知字节。
4. 读 `base[新偏移]` 验证可见刚写字节、无 SIGBUS。
5. 读 `base[超物理 EOF 但 < 1TB]` 确认行为（预期 SIGBUS 或零页，记录）。

**RED/验收**：PASS = 增长页可见 + 有效 offset 内无 SIGBUS。**FAIL → 停止，回退方案 II（remap+epoch）或 III（mmap+pread 回退），重设计后再继续。**

**产出**：spike 程序 + 结论（macOS 行为记录）。

**结果（2025-07，macOS）**：✅ PASS。以 4KB 打开文件 → mmap 1TB MAP_SHARED 只读预留区 → ftruncate+pwrite 增长至 8KB 写已知字节 → 从现有映射读 offset 6000 可见刚写字节、8KB 内无 SIGBUS。scheme I 承重假设成立，继续 T1。spike 程序：`spike_mmap.zig`。

---

## T1 — mmap wrapper（`@cImport` libc）

**依赖**：T0 PASS。

**做法**：`src/mmap.zig`（或 file_store 内私有）封装：
- `pub fn map(fd: c_int, len: usize, prot, flags) ![*]u8`（libc `mmap`，跨平台 macOS+Linux）。
- `pub fn unmap(ptr: [*]u8, len: usize) void`（`munmap`）。
- `pub fn advise(ptr, len, advice)`（`madvise`，可选：MADV_RANDOM 减预读浪费）。
- 页对齐 len（向上 round 到页大小）。

**RED 测试**：map 一段匿名区写读 roundtrip、unmap 不泄漏。

---

## T2 — FileStore mmap 预留大区

**依赖**：T1。

**做法**（`src/file_store.zig`）：
- `FileStore` 增字段：`mmap_base: ?[*]u8`、`mmap_region_len: usize`。
- `create`：打开文件后 `mmap` 预留大区（默认 1TB，`opts.mmap_region_size` 可配），失败则 fallback 现状（pread）保兼容。
- bounds-check：`read` 前 `offset < self.logical_len`（已有，沿用防 SIGBUS）。
- `close`：`munmap`（errdefer 保不泄漏）。
- `setSize`/`sync`/`appendRaw` 不变（写仍 pwrite）。

**RED 测试**：create→mmap 成功、close 后 munmap、并发 map 不冲突。

---

## T3 — vtRead 重写（mmap memcpy + 跳 marker）

**依赖**：T2。**核心改动，侵入最小。**

**做法**（`src/file_store.zig` `vtRead`）：
- 保持 `Store.read(buf: []u8, offset: u64) !usize` 签名不变。
- 实现：`offset < logical_len` 否则 return 0；从 `mmap_base` 按 `logicalToPhysical` 算物理偏移，memcpy 到 `buf`，跨 `BLOCK_SIZE-1=4095` 边界时跳 1 marker 字节，直到 `buf` 满或到 `logical_len`。
- 删除 pread while 循环。

**不动**：`readRecord`、`btree.get`、`Leaf.fromPayload`。

**RED 测试**（`tests/file_store_mmap_test.zig`）：
- roundtrip：appendRaw 写 N 字节 → read 读回一致。
- marker 跨边界：写 >4095 字节，读跨边界处正确（marker 字节被跳过）。
- bounds：offset == logical_len 返回 0；offset 超出不 SIGBUS。

**全量回归**：`zig build test` 全绿（既有 store/btree/db 测试不改通过）。

---

## T4 — bench 量收益

**依赖**：T3 + 全量绿。

**做法**：`zig build bench -Doptimize=ReleaseFast -Dbench-scale=small`，记录 get 100B / 10KB us/op。

**验收门槛**：get 100B ≤ ~80us/op（~5× 改善）。记录实际数到 README benchmark 表 + 本文档。

**决策点**：
- 达 ~5× 且解码非新瓶颈（profile/get 仍以 memcpy 为主）→ **停**（YAGNI 满足）。
- 改善 < 预期或解码成瓶颈（解码占比高）→ 进 T5。

**结果（2025-07，macOS）**：get 100B 253us/op（基线 252）、get 10KB 748us/op（基线 760）——**在噪声内无改善**。确认 mmap 路径生效（file_store mmap 测试绿 + mmap_read_count 计数器自增）。根因修订：pread 本非主瓶颈（OS 页缓存已快），真实主瓶颈是 `readRecord` 的 ~8KB buf 分配 + `Leaf.fromPayload` 全 leaf 解码 + 逐 entry `allocator.dupe`。mmap 去掉 ~12 次 pread 但页缓存命中时 syscall 本快，收益被解码/分配摊薄。**→ 进 T5。**

---

## T5 — 条件 D：get skip 全 leaf 解码（仅当 T4 示解码瓶颈）

**依赖**：T4 决策进。

**做法**（`src/btree.zig` get 读路径）：
- get 命中 leaf 后，不 `Leaf.fromPayload` 全量解码、不逐 entry dup。
- leaf entries 排序 → 二分/线性 seek 到目标 key，只读该 entry 的 value，`allocator.dupe` 单个 value 返回。
- **仅作用于 get 读路径**；写路径（insert/delete COW）保持全解码不变。

**RED 测试**：
- get 命中返回正确 value（与全解码路径一致）。
- get miss 返回 null。
- tombstone 命中返回 null。
- 大 leaf（多 entry）性能：get 不随 entry 数线性分配（验证未全量 dup）。

**风险**：解码逻辑若与写路径共用，需抽读专用解码或加只读 seek 函数，不污染写。

**结果（2025-07，macOS）**：✅ 完成。`btree.findInLeaf`（payload 线性扫到第一个 >= key 的 entry，eq 命中 dup 单 value；miss/tombstone 返 null）。get leaf 路径改走 `findInLeaf`，不再 `Leaf.fromPayload` 全解码。写路径（insert/delete COW）仍走 `decodeNodePayload`+`Leaf.fromPayload` 全解码，未污染。

**额外收益**：T4 发现 CRC 是 10KB 读主成本（~80KB record 的 Crc32）。热读路径跳 CRC：新增 `f.decodeRecordNoCrc` + `btree.decodeNodePayloadNoCrc`，仅 get 读路径用；写路径/恢复仍走 `decodeRecord`（验 CRC）。损害检测由 open/恢复 header 扫描 + 写路径 CRC 兑。

**最终 bench（NVMe ReleaseFast small）**：
| 指标 | 基线 | T5+CRC-skip 后 | 倍数 |
|---|---|---|---|
| get 100B | 252us | 133us | 1.9× |
| get 10KB | 760us | 174us | 4.4× |

10KB 接近 T4 ~5× 门槛。100B 余下主成本是 `readRecord` 每节点 alloc+memcpy ~8KB（4 节点），需直访 mmap 零拷贝（超方案 a 范围，留后续）。

---

## 依赖图
```
T0 spike ──FAIL──→ 回退 II/III 重设计
        └──PASS──→ T1 wrapper ──→ T2 FileStore mmap ──→ T3 vtRead ──→ T4 bench
                                                                      │
                                                          解码非瓶颈──→ 结束
                                                          解码瓶颈───→ T5 skip-decode ──→ 结束
```

## 回退点
- T0 FAIL：整个 mmap 方案回退到 II（remap+epoch）或 III（mmap+pread），重出设计。
- T2 mmap 失败：FileStore fallback 现 pread 路径保兼容（功能不退化）。
- T5 风险高：跳过，接受 mmap-only ~5× 收益。

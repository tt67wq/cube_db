# cube_db 读路径（get）优化设计：mmap

> 对应写路径优化见 `group-commit-design.md`。本文聚焦单一最大短板：单线程随机读 `get`。
>
> **开发方式：严格 TDD（red→green→refactor）。** 每个任务先写失败测试（RED），再写最小实现使其通过（GREEN），再重构。不允许先实现后补测试，不允许跳过 RED 验证。实现退出盘问后按 `docs/mmap-read-tasks.md` 执行。

## 0. TL;DR

`get` 单线程 100B 252us/op（3,968 ops/s），落后 LMDB mmap 读（~1–5us/op，~100K–800K ops/s）**~25–125×**。根因不是"逐字节读 8000 次"（旧文档措辞过时），而是**每 get ~12 次小 pread × `waitForIo`（futex）开销 + 无读缓存复用 + 全 leaf 解码逐 entry `allocator.dupe`**。

方案五决策：
1. **A. mmap 整文件**（读路径零拷贝、去 pread+waitForIo，收益上限最高）。
2. **a. 保留 marker + 读时转换**（不改格式/offset 语义，只重写 `FileStore.vtRead`）。
3. **I. 预留大 sparse 区永不 remap**（依赖 append-only 天然 MVCC，无 race、无 SIGSEGV）。
4. **mmap-only 测优先**（一次只改一层，量收益，解码非瓶颈则停；YAGNI）。
5. **先 spike 验证 macOS growth-vis**（承重假设去险，FAIL 回退 II/III）。

预期：syscall ~12→0，252us → 估 ~50–80us（~5×）。若解码成新瓶颈再上 D（skip-decode）追 LMDB 量级。

---

## 1. 目标与非目标

### 目标
- `get` 100B 从 252us/op 降到 ~50–80us/op（~5×），去掉 pread+waitForIo 开销。
- 不改磁盘格式、不改 btree offset 语义、不改 `Store.read` 签名（侵入最小、可回退）。
- 保持 durable 与并发语义：get 无锁、可与写并发，读到最近一次已提交 root 的快照。

### 非目标
- 不追 LMDB ~125× 到位（mmap-only 先拿 ~5×，解码瓶颈确认后再决定是否上 D）。
- 不改写路径（写仍 pwrite；mmap 仅读路径用，pwrite+mmap 共识已设计可行）。
- 不改 compact（仍单线程全量重写）。
- 不做读缓存（B 方案，留作 mmap 后若 decode 瓶颈的叠加选项）。
- 不改 header 发现机制（marker 保留，`getLatestHeader` 不动）。

---

## 2. 背景与根因

### 2.1 benchmark（NVMe，ReleaseFast，单线程，small）

| 指标 | 数值 |
|---|---|
| get 100B | 252 us/op（3,968 ops/s） |
| get 10KB | 760 us/op（1,316 ops/s） |

业界对照：

| 引擎 | 随机读 ops/s | us/op |
|---|---|---|
| LMDB mmap | ~100K–800K | 1–5 |
| RocksDB point get | ~100K–800K | 1–5 |
| RocksDB（cache miss） | ~50K–200K | 5–20 |
| LevelDB | ~50K–150K | 7–20 |
| **cube_db get** | **~4K** | **252** |

差距 ~25–125×。**单一最大短板**。

### 2.2 根因（代码已读，精确版）

读路径：`db.get` → `btree.get` 遍历深度~4，每层节点 `readRecord` → `Store.read`（`FileStore.vtRead`）→ `zio.File.read`（1 pread/调用）。

**`FileStore.vtRead` 现**（`src/file_store.zig`）：while 循环按 `BLOCK_SIZE-1 = 4095` 逻辑字节切块，每块一次 `self.file.read`（= 1 pread）。跨块边界再切。

**`readRecord`**（`src/btree.zig:50`）：先读 4 字节 len（1 pread），再 while `s.read` 填满 total（每 4095 字节 1 pread）。

**单 get 成本拆解**：
1. **~12 次 small pread/读**：4 节点 × (1 len + ceil(payload/4095) ≈ 2) ≈ 12。每次经 `waitForIo`（futex 唤醒 ~10–20us）。12× ≈ 150–250us → **对上 252us**。
2. **无读缓存复用**：每次 get 都重新 `readRecord` 全量读+解码，无 LRU/页缓存。热 leaf 反复重读。
3. **全 leaf 解码 + 逐 entry dup**：`Leaf.fromPayload` 解码整 leaf 并 `allocator.dupe` 每个 key/value（get 只需 1 key 却解码全 leaf + 分配）。

> 注：旧设计文档 §2.3/§10.4 措辞"~8KB leaf = ~8000 次读"**过时**——`vtRead` 实际按 4095 切块，非逐字节。真实 syscall 数 ~12/读，瓶颈在 syscall+waitForIo 开销与解码，非 syscall 数量级。

### 2.3 关键事实（核代码确认）
- `appendRaw` 返回**逻辑 offset**，btree 节点存**逻辑 offset**。
- `BLOCK_SIZE=4096`，每块首字节 = marker（`MARKER_DATA=0`/`MARKER_HEADER=1`），逻辑内容 = 物理剔 marker。
- `logicalToPhysical`：每 4095 逻辑字节跳 1 marker 字节。→ **mmap 物理文件后，逻辑字节流非连续**（每 4095 字节有 1 marker 间隙）。
- marker 用途：`getLatestHeader` 扫描时区分 data/header 记录。
- Zig std 仅 `os.linux.mmap`（无 macOS）；zio 无 mmap → wrapper 需 `@cImport` libc mmap 或手写 syscall。

---

## 3. 方案对比与取舍

### 3.1 主攻方向：A. mmap 整文件

读路径零拷贝、去 pread+waitForIo，收益上限最高（追平 LMDB）。代价：侵入 store 层、需 mmap wrapper、处理 append 增长可见性。

**未选**：B 读缓存（命中率决定收益，冷读退化）、C+D 批量整 leaf 读+skip-decode（小改低风险但仅 ~2–3×，不追上限）。

### 3.2 marker 处理：a. 保留 marker + 读时转换

mmap 物理文件后逻辑字节流非连续（marker 间隙挡零拷贝）。三子方案：

| 方案 | 做法 | 代价 |
|---|---|---|
| **a（选）** | 保留 marker，读路径做 logical→physical 指针算，跨边界跳 1 字节 | 不改格式/offset 语义，只重写 vtRead；零 syscall 非纯零拷贝（解码从 caller buf 读连续字节，buf 由 memcpy+跳 marker 填充） |
| b | 改格式去 marker | 纯零拷贝；但格式迁移+写路径重写+header 发现重做，侵入最大 |
| c | btree 改存物理 offset | 中等：改 offset 语义+append 算物理偏移+向后兼容 |

选 a：侵入最小、可回退。保持 `Store.read(buf, offset)` 签名 → 只重写 `FileStore.vtRead`（pread 循环 → mmap memcpy+跳 marker），`readRecord`/`get` 全不改。caller buf 连续，解码无需容忍间隙。

### 3.3 增长 + 并发一致性：I. 预留大 sparse 区永不 remap

append-only COW：writer pwrite 追加 → 文件增长。mmap 必须反映增长后字节，否则 get 越界。即便单线程 bench（先 put 再 get）也须解决；DB 还支持 get 无锁与写并发。

**POSIX 事实**：MAP_SHARED mmap 与同 fd 的 pwrite 对**已 backing 重叠页**一致可见；映射区**超出物理 EOF 的页**访问 → SIGBUS。btree 只沿 root 指针走，有效 offset ≤ root 写入时 logical_len ≤ backing → 若预留区够大，理论上永不越界。

| 方案 | 做法 | 代价 |
|---|---|---|
| **I（选）** | open 时 mmap 一大预留虚拟区（如 1TB，sparse 几乎不占资源），writer pwrite、reader mmap 对已 backing 页一致，永不 remap | 无 race、无 SIGSEGV；成本=虚拟地址预留（64-bit 廉价）；依赖 append-only 天然 MVCC（旧页不变，reader 沿 root 看一致快照） |
| II | map 现大小，写后超窗口 munmap+mmap（macOS 无 mremap）+ epoch/RCU | 复杂、remap 有开销、reader 中途 munmap 需保护 |
| III | mmap 现大小 + 超映射 offset 回退 pread | 两路径不纯、I "永不 remap" 收益打折 |

选 I：最简最安全，无 remap race。

### 3.4 范围：mmap-only 测优先

A 落地后 syscall ~12→0，但 `readRecord` 仍 copy ~8KB + `Leaf.fromPayload` 全解码 + 每 entry dup。估 252us → ~50–80us（~5×），未到 LMDB ~125×。要逼近需同时做 D（get skip 全 leaf 解码）。

选 mmap-only：一次只改一层、可回退、量收益后定。lazy 正解（YAGNI）。解码非新瓶颈则停；是再上 D。

### 3.5 去险：先 spike 验证 macOS growth-vis

Scheme I 承重假设 = macOS 大区 mmap 文件增长可见性。macOS man page 有 caveat（文件 mmap 后再 extend，新页可能不反映/SIGBUS）。若不成立 → I 塌，回退 II/III。

选先 spike：动 cube_db 前写 ~30 行独立 mmap 测试，5 分钟去险。FAIL 直接回退，不浪费 FileStore 改动。

---

## 4. 实现路径

### 4.1 T0 Spike（去险，独立测试）
~30 行独立 mmap 测试：file-backed MAP_SHARED 预留大区 → ftruncate/pwrite 增长 → 读验证新页可见 + 无 SIGBUS。**FAIL → 回退 II/III 设计，停止后续。**

### 4.2 T1 mmap wrapper
`@cImport` libc（`c.mmap`/`c.munmap`/`c.madvise`），跨平台 macOS+Linux。封装到 `src/mmap.zig`（或 file_store 内）：`map(fd, len, flags) -> [*]u8`、`unmap(ptr, len)`。

### 4.3 T2 FileStore mmap
- `create`：mmap 预留大区（默认 1TB 可配，`opts.mmap_region_size`），存 `mmap_base: [*]u8` + 已有 `logical_len`/`physical_len`。
- `read`/vtRead 前置 bounds-check：`offset < logical_len` 防 SIGBUS（已有逻辑沿用）。
- `close`：munmap。`setSize`/`sync` 不变（写仍 pwrite，mmap 不参与写）。

### 4.4 T3 vtRead 重写
```
fn vtRead(ptr, buf, offset):
    if offset >= logical_len: return 0
    # logical→physical 指针算 + 跨 marker 边界跳 1 字节，memcpy 到 buf
    # 保持 Store.read(buf,offset) 签名；readRecord/get 不改
```
跨 `BLOCK_SIZE-1=4095` 边界时跳 marker 字节，buf 连续。RED 测试：roundtrip（append→read 一致）+ marker 跨边界正确。

### 4.5 T4 measure
bench get，对比 252us。预期 ~50–80us（~5×）。记录实际，决定是否上 T5。

### 4.6 T5 条件 D（skip-decode）
若解码成新瓶颈 → get 路径不解码全 leaf：leaf 排序，只 seek 到目标 key 读其 value，不 `Leaf.fromPayload` 全量、不 dup 全 entry。**注意不污染写路径**（写仍需全解码做 COW 插入，D 仅作用于 get 读路径）。RED 测试先行。

---

## 5. 风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| **macOS growth-vis caveat** | 文件 mmap 后 extend，新页可能不反映/SIGBUS | T0 spike 先验；FAIL 回退 II/III |
| 跨平台 wrapper 差异 | macOS/Linux mmap flags、页对齐 len | @cImport libc 统一；wrapper 封页对齐 |
| SIGBUS 越界 | reader 算 offset 超 backing | bounds-check offset < logical_len（已有）；btree 只沿 root 有效 offset |
| skip-decode 污染写路径 | D 改解码逻辑可能影响 COW 写 | D 仅作用于 get 读路径，写路径保持全解码 |
| mmap 生命周期 | close 需 munmap；crash 由 OS 回收 | close munmap；errdefer |
| 大区上限 | 1TB 是否够/系统限制 | 可配；64-bit 廉价；build 阶段实测系统上限 |

---

## 6. 与写路径 / group commit 的关系

- 写路径不动：put/putBatch/delete/compact 仍 pwrite + fsync。mmap 仅读路径。
- pwrite + MAP_SHARED mmap 对已 backing 页一致（POSIX）→ 写后立即可见，get 读最新 root 快照。
- append-only CoW 天然 MVCC：旧页不变，reader 沿 root 看一致快照，无需额外版本机制。
- group commit（lever 3）合并发写不影响读：reader 无锁读 root，与 leader/follower 写互不干扰。

---

## 7. 验收

- T0 spike PASS（macOS growth-vis 可行）。
- 全量 `zig build test` 绿（现有 + 新 RED 测试）。
- bench get 100B ≤ ~80us/op（~5× 改善门槛）；记录实际数。
- 并发 get + 写 仍正确（既有 `concurrent puts all visible` + get 验证不回归）。

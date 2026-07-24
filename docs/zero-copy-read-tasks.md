# 读路径（get）真零拷贝 — 任务拆分（TDD）

> 设计见 `docs/zero-copy-read-design.md`。
>
> **严格 TDD（red→green→refactor），无例外：** 每步先写失败测试（RED，确认在旧实现上失败），再写最小实现使其通过（GREEN），再重构。禁止先实现后补测试、禁止跳过 RED 验证、禁止 RED 未确认就写 GREEN。当前处于 investigate 只读模式，实现需退出盘问后执行。

## 决策摘要（已定）
1. **去 marker 改磁盘格式**（mmap 物理天然连续 → readRecord 返借用 mmap 切片，真零拷贝追 LMDB）。
2. **新项目、不需旧文件兼容**（去迁移代价）。
3. **Store 借用 API：读+写路径全改**（readRecord 返 `[]const u8` 借用、~8 调用点去 `free`）。
4. **header 发现：正向扫全文件记最后有效 header**（crash 半写跳过、不比现慢、代码更简单）。

---

## T1 — 去 marker（appendRaw 写连续逻辑字节）

**依赖**：无（基础）。

**做法**（`src/format.zig` + `src/store.zig` + `src/file_store.zig`）：
- `appendRaw`（FileStore + MemStore）不再插 `MARKER_DATA`，写连续逻辑字节（逻辑==物理）。
- `BLOCK_SIZE`/`MARKER_*` 常量可保留（header 发现 T5 不依赖 marker）但数据路径不写 marker。

**RED 测试**（`tests/zero_copy_marker_test.zig`）：
- 写 >4095 逻辑字节（跨原 marker 边界），读回全等（marker 字节不再插入，逻辑字节天然连续）。
- 物理长度 == 逻辑长度（无 marker 字节）。

---

## T2 — logicalToPhysical identity（逻辑==物理）

**依赖**：T1。

**做法**（`src/store.zig`）：
- `logicalToPhysical(offset) = offset`（identity）。
- `physicalToLogical(offset) = offset`。
- 保留函数（调用点不炸），但实现 identity。

**RED 测试**：
- 转换往返：`logicalToPhysical(x) == x`、`physicalToLogical(x) == x`。
- 既有 store/btree 测试全绿（不依赖 marker 的转换）。

---

## T3 — Store.readBorrow vtable（借用切片）

**依赖**：T2。

**做法**（`src/store.zig` vtable + `FileStore` + `MemStore` + `FaultStore`）：
- `Store.VTable` 加 `readBorrow: *const fn(ptr, offset, max) anyerror![]const u8`。
- `Store.readBorrow(offset, max) -> []const u8`：返指向 mmap/ArrayList 的借用切片（不 alloc 不 memcpy）。
- `FileStore.readBorrow`：bounds-check `offset < logical_len`，返 `mmap_base[offset..min(offset+max, logical_len)]`（mmap 指针直访；无 mmap 则回退 pread 到内部小缓存？ponytail：MVP 无 mmap 时返错误或回退 readBorrowCopy，但 cube_db 默认 FileStore 有 mmap）。
- `MemStore.readBorrow`：返 `data.items[offset..min]`（ArrayList 切片）。
- `FaultStore.readBorrow`：代理 inner。

**RED 测试**（`tests/zero_copy_borrow_test.zig`）：
- FileStore：append 写 → readBorrow 读回等（mmap 切片）。
- MemStore：同。
- bounds：offset==logical_len 返空切片；超界返错误或空（不 SIGBUS）。

---

## T4 — readRecord 返借用 []const u8 + ~8 调用点改

**依赖**：T3。**核心改动，零拷贝落地。**

**做法**（`src/btree.zig`）：
- `readRecord(allocator, s, offset) -> ![]const u8`：用 `s.readBorrow(offset, max_node_size)` 返借用切片（指向 mmap/MemStore），不 alloc 不 memcpy。
- 调用点去 `defer allocator.free(rec)`、改用借用切片（生命周期：Store 存活期间有效；get 读路径无写、借用安全；写路径读旧记录也只读、借用安全）。
- ~8 调用点：`btree.get`、`btree.insertIntoLeaf`/`insertIntoBranch`/split 系列、`btree_batch`（~2 处）、其他 btree 遍历点。

**不动**：`findInLeaf`（已 skip 全解码，改读 mmap 指针）、写路径的 COW 追加逻辑。

**RED 测试**：
- 既有 btree 全量测试（`btree_test.zig`、`db_test.zig`、`btree_batch_test.zig` 等）全绿——验证 ~8 调用点改全、不漏（编译器抓返回类型变：`defer free` 对 `[]const u8` 借用切片会编译错）。
- 新增：get 读路径零 alloc 验证（可选：计数器或 allocator 注入确认 readRecord 不 alloc）。

**全量回归**：`zig build test` 全绿。

---

## T5 — getLatestHeader 正扫全文件记最后有效 header

**依赖**：T1（去 marker）。

**做法**（`src/store.zig` `getLatestHeader`）：
- 改正扫：从 offset 0 按 record 长度一条条走（mmap 指针/`readBorrow`）。
- 每条：读 4 字节 len → 读 payload（靠 `readBorrow` 借用）→ 判别是 header（payload 有 magic+version，`f.decodeHeaderPayload` + `h.magic == MAGIC && h.version == VERSION`）vs node（kind leaf/branch）。
- 记最后一个有效 header 的 offset + 内容。
- 文件尾写一半（crash，crc 不对或 len 超 EOF）→ 跳过，用上一个有效 header。

**RED 测试**（`tests/zero_copy_header_scan_test.zig`）：
- 正常：append N 次 commit（header 在尾）→ getLatestHeader 返最后一个。
- crash 半写：手工构造文件尾半截 header（crc 不对）→ getLatestHeader 跳过返上一个有效。
- 空文件 → null。
- 全 node 记录（无 header）→ null。

---

## T6 — bench 量收益

**依赖**：T4 + T5 + 全量绿。

**做法**：`zig build bench -Doptimize=ReleaseFast -Dbench-scale=small`，记 get 100B / 10KB us/op。

**验收门槛**：get 100B ≤ ~10us/op（~13× 改善，追 LMDB 量级）。记录实际数到 README benchmark 表 + 本文档。

**决策点**：
- 达 ~2–5us（追 LMDB）→ **停**（目标达成）。
- 改善 < 预期 → profile 定位新瓶颈（可能：branch 全解码 `Branch.fromPayload`、或 btree 深度、或 findInLeaf 线性扫可改二分）。

**结果（2025-07，macOS）**：✅ **追平 LMDB**。get 100B **~3 us/op**（3.0–3.8 多次）、get 10KB **~5–13 us/op**（4.7–13 随 mmap 缺页波动）——LMDB mmap 读 ~2–5us 量级（10KB 随机 10000 次有缺页波动）。

进程：T4 后 get 仍 ~128us（真零拷贝 readRecord 借用未提速——发现 readRecord alloc/memcpy 非主成本，主成本是 branch 全解码 `Branch.fromPayload`）。按决策点加 **T6 续**：`findInBranchPayload`（get 跳 branch 全解码，线性扫 keys 找目标 child offset，不 dup 全 entry）。落地后 get 100B 128→~3us、10KB 174→~5–13us。

全量改进（两阶段累计）：get 100B 252→**~3us**（~85×）、get 10KB 760→**~5–13us**（~60–136×）。

**结论**：目标达成，停。写路径 put（140us）仍 fsync 主导；get 已非短板。

---

## 依赖图
```
T1 去 marker ──→ T2 logicalToPhysical identity ──→ T3 Store.readBorrow ──→ T4 readRecord 返借用 + ~8 调用点 ──→ T6 bench
                                                                                                                    │
                                                                                                          达标──→ 结束
                                                                                                          未达──→ profile → 局部优化
T1 去 marker ──→ T5 getLatestHeader 正扫 ──────────────────────────────────────────────────────────────────┘
```

## 回退点
- T1 去 marker 若波及过广：先只在 FileStore 去 marker（MemStore 保留 marker 作对照测试），渐进。
- T3 readBorrow 若 mmap 不可用（某平台）：FileStore 回退 readBorrowCopy（alloc+memcpy，与现 read 一致），功能不退化但非零拷贝。
- T5 正扫若大文件开机慢：换 C 链表（header 加 prev_offset）或 sidecar 文件，基于实测。
- T4 若借用生命周期有竞态：写路径退回 alloc（仅读路径借用），方案 2 降级。

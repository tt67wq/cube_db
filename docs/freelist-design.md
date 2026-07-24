# freelist 页面复用设计（format v2）

> 状态：设计稿（未实现）。评审通过后按分阶段计划动码。
> 前置决策：clean break（不向后兼容 v1 .db）、固定 mapsize 上限（LMDB 式）。

## 1. 目标

当前 compact 带宽 2.9 MB/s，写放大 ~33×，恢复 O(file_size)。根因：
append-only + COW 每次提交把旧路径节点变 dirt，无页面复用；compact 只能全量重写 live 数据。

freelist 让旧页原地复用，三个短板一次解决：

| 指标 | v1 现状 | v2 目标 | LMDB 参考 |
|---|---|---|---|
| compact 带宽 | 2.9 MB/s 全量重写 | ~O(1)（只写 meta page） | O(1) |
| 写放大 | ~33× | ~1×（页复用） | ~1× |
| 恢复 | O(file_size) 正扫 | O(1) 读 meta page | O(1) |

## 2. v1 现状（精确事实）

### 文件格式（`src/format.zig`）
- append-only，逻辑偏移 == 物理偏移（去 marker 后）。
- 记录：`len:u32 | payload | crc:u32`（CRC 覆盖 len+payload）。
- Header（38B payload）：`magic | version | btree_root | entry_count | byte_size | dirt`。
- Header append 到文件末尾，每批一个。恢复：`getLatestHeader` 正扫全文件找最后一个 magic+version 对的 header。
- 节点：leaf（`kind:u8 | count:u16 | [tombstone:u8 | klen:u32 | key | vlen:u32 | value]...`）、branch（`kind | count | [klen|key]... | [child:u64]...`）。
- 节点大小不固定（变长 payload，受 `LEAF_MAX_ENTRIES=32` / `BRANCH_MAX_CHILDREN=32` 条目数控制，非字节）。

### COW 写路径（`src/btree.zig` + `src/writer.zig`）
- `insert` 递归 COW：读旧节点 → 改 → append 新版本到文件末尾 → 返回新 offset。
- `WriteResult.dirt_delta` = 旧路径节点记录总字节数（被替换的旧 root 全路径）。
- `applyBatch` 累加 `dirt`，写 header，fsync，原子更新 root/dirt/count/byte_size。
- **旧节点永远不被回收**，只在 compact 时全量跳过。

### compact（`src/compactor.zig` + `src/db.zig doCompact`）
- select 全遍历 live B-tree → 逐条 insert 到 `.compact` 临时文件 → appendHeader → `sync()` 一次性刷全量 → rename 切换。
- 2.9 MB/s 拆解：遍历读 ~5% / 逐条 COW insert ~60% / 最后一次性 fsync 全量 ~30%。

### Store 抽象（`src/store.zig`）
- `Store` vtable：`read / append / sync / setSize / size / readPhysical / physicalSize / readBorrow / close`。
- `readBorrow` 返 mmap 借用切片（零拷贝读）。
- `appendRaw` 写连续逻辑字节，返回起始逻辑偏移。

## 3. v2 文件格式

### 3.1 总体布局

固定大小 mmap 区（用户指定 `mapsize` 上限，sparse 预留）。页面是基本单位。

```
┌─────────────────────────────────────────────────┐ offset 0
│  Meta Page 0   (主 meta，最新提交)              │
├─────────────────────────────────────────────────┤ PAGE_SIZE
│  Meta Page 1   (备 meta，交替写)                │
├─────────────────────────────────────────────────┤ 2*PAGE_SIZE
│  Freelist Page(s)   (空闲页表，链式)            │
├─────────────────────────────────────────────────┤
│  B-tree 数据页 (leaf/branch)                   │
│  ...                                            │
│  （旧页回收 → 进 freelist，原地复用）           │
├─────────────────────────────────────────────────┤
│  未分配区（mapsize 剩余）                       │
└─────────────────────────────────────────────────┘ mapsize
```

### 3.2 页大小

`PAGE_SIZE = 4096`（匹配 OS 页，mmap 对齐）。
leaf/branch 节点 payload ≤ `PAGE_SIZE - 页头开销`。超长 value（> 单页）走溢出页（overflow page，见 §3.6）。

### 3.3 页头（Page Header，每页前 N 字节）

```
page_no:    u32   // 本页页号（自校验）
page_type:  u8    // 0=free 1=meta 2=branch 3=leaf 4=overflow
gen:        u64   // 页写入世代（MVCC 用，见 §5）
nkeys:      u16   // leaf/branch: 条目数；overflow: 占用页数
free_next:  u32   // free page: 链下一空闲页；其他: 0
padding:    u6    // 预留对齐
checksum:   u32   // 页尾 CRC（覆盖页头+payload）
```

固定页头大小 `PAGE_HEADER_SIZE`（约 32B），payload 区 = `PAGE_SIZE - PAGE_HEADER_SIZE - 4(CRC)`。

### 3.4 Meta Page

交替写的两个 meta page（page 0 / page 1），用 sequence number 区分新旧。

```
magic:        u32   = 0x43554232  ("CUB2"，v2 区分 v1)
version:      u16   = 2
mapsize:      u64   // 用户指定上限
sequence:     u64   // 提交序号，每次提交 +1，meta0/meta1 取大者为新
root_page:    u32   // B-tree 根页号（0 = 空树）
entry_count:  u64
byte_size:    u64   // live bytes
free_head:    u32   // freelist 链头页号（0 = 无空闲页）
free_count:   u64   // 空闲页总数
last_page:    u32   // 已分配的最高页号（高位水位线）
checksum:     u32
```

恢复：读 meta0 + meta1，比 `sequence`，取大者校验 CRC。O(2 页)。

### 3.5 Freelist

空闲页链表。每页的 `page_type=0`（free），`free_next` 指下一空闲页。

分配：从 `free_head` 取头页，`free_head = 该页.free_next`，`free_count--`。
- freelist 空 → 从未分配区 bump 分配 `last_page+1`（若 < mapsize/PAGE_SIZE）。

回收：COW 提交时，旧路径页号列表 append 到 freelist 尾部。
- 为避免每次提交写 freelist 页，freelist 页本身也走 COW（改 free_head 指向新 freelist 页）。

freelist 页满（一页存不下更多页号）→ 链式分配新 freelist 页，`free_next` 串起。

### 3.6 溢出页（overflow）

value > payload 区容量（~4KB）时，value 存溢出页链，leaf entry 只存 `overflow_page:u32 + value_len:u32`。
溢出页 `page_type=4`，`nkeys` = 占用页数，链式串接。
回收时整条溢出链进 freelist。

> ponytail: v1 现在靠变长 payload + 条目数控制，没有溢出页。v2 固定页必须处理超长 value。MVP 可先限 value ≤ 4KB，超长报错，溢出页列后续阶段。

## 4. 页寻址

- 所有 B-tree 节点引用从「逻辑字节偏移 u64」改为「页号 u32」。
- branch 的 `children: []u64` → `children: []u32`（页号）。省 50% 指针空间。
- `readBorrow(offset, max)` → `readPage(page_no)`：mmap 基址 + `page_no * PAGE_SIZE`，直接返页内切片（零拷贝不变）。

## 5. MVCC（读旧版本）

v1 靠 append-only 天然 MVCC：旧 root offset 不被覆盖，reader 沿旧 root 读旧版本。
v2 页复用会覆盖旧页，必须显式版本管理。

### 5.1 page generation + reader txnid

每页 `gen:u64`（页写入世代 = 提交时的 `sequence`）。每个 reader 持有读事务开始时的 `reader_seq`（= meta.sequence）。

读规则：reader 沿 `root_page`（来自 meta）走树。COW 写新版本页时，**旧页不立即回收**，等所有 reader 的 `reader_seq >= 旧页.gen` 才回收。

### 5.2 回收安全（LMDB 式）

维护 `oldest_reader_seq`（所有活跃 reader 的最小 `reader_seq`，无 reader 则 = 当前 sequence）。
- freelist 回收页时，页的 `gen` 必须 `< oldest_reader_seq` 才能进 freelist（否则该 reader 可能正读它）。
- 即「安全回收窗口」= sequence - oldest_reader_seq 之前的页。

> ponytail: MVP 可先做「无并发 reader 时立即回收」（single-reader 快路径），reader txn 跟踪列后续。无 reader = oldest_reader_seq = sequence，旧页全可回收。这退化到单读快照语义（v1 也只支持读最近提交 root 快照）。

## 6. 提交路径（v2 applyBatch）

```
1. 快照 cur_meta = 当前 meta（root_page, free_head, sequence）
2. COW 构建新 B-tree 路径：
   - 需要新页 → 从 freelist 取（free_head）或 bump 分配
   - 旧路径页号收集到 pending_free 列表
3. 更新 freelist：pending_free 追加，freelist 页自身也 COW
4. 构造新 meta（sequence+1, new_root_page, new_free_head, ...）
5. 交替写 meta0/meta1（选 sequence 较旧的那个覆盖），sync
6. 原子提交完成：root_page 等原子切换
```

写放大：每条 op 的 COW 路径页数 × 页大小。无全量重写。freelist 在提交内增量更新。

## 7. compact（v2）

**不再需要全量重写**。compact 退化为：
- 回收所有 `gen < oldest_reader_seq` 的 pending free 页 → 进 freelist。
- 可选：若 freelist 过大、文件有碎片，做一次「重排」——但这仍是增量、可选、低频。

若用户想缩小物理文件（mapsize 内回收高位页）：
- 显式 `compactShrink()`：把高位 live 页迁移到低位 freelist 页，`ftruncate` 文件。低频用户操作。

## 8. 恢复

```
1. mmap 文件
2. 读 meta page 0 + page 1
3. 比 sequence，取大者，校验 CRC
4. root_page / free_head / entry_count 等全部就位
5. 未完成提交（meta CRC 错）→ 回退到前一个 meta（另一 meta page）
```

O(2 页读 + CRC)。不再正扫全文件。

crash 在 meta 写一半：另一 meta page 仍是上一有效提交，无损。
crash 在数据页写一半：meta 未切换，旧 root 完整，新半写页被 freelist 回收（下次提交覆盖）。

## 9. 迁移（clean break）

- 旧 v1 `.db` 文件不可读。
- `Db.open` 检测 magic：v1 (`0x43554244`) vs v2 (`0x43554232`)。v1 直接报错 `error.LegacyV1Format`，提示用 v1 二进制 `compact` 后手动迁移，或提供一次性 `migrate_v1_to_v2` 工具（全量读 v1 → 写 v2）。
- 新库只认 v2。

## 10. 接口变更

### Options
```zig
pub const Options = struct {
    fsync: bool = true,
    mapsize: u64 = 1 << 30,  // 新增：mmap 区上限（默认 1GB）
    page_size: u32 = 4096,   // 新增：页大小（默认 4KB）
    // auto_compact 语义改变：v2 compact 是 O(1)，阈值检查保留但几乎不触发全量重写
    auto_compact_dirt_ratio: ?f32 = 0.50,
    auto_compact_min_bytes: u64 = 0,  // v2 默认 0（compact 很便宜）
    // 旧 compact_* 字段保留但语义变化
};
```

### Store vtable
- 新增 `allocPage() -> u32`（从 freelist 取或 bump）
- 新增 `freePage(page_no)`（回收，进 pending free）
- `append` / `readBorrow` 语义改为页寻址
- 保留 `sync` / `setSize`（setSize 变 `ftruncate` 缩文件）

## 11. 分阶段实现计划

| 阶段 | 内容 | 验证 | 风险 |
|---|---|---|---|
| **P1** 页格式 + Store | 新 `format2.zig`（页头、meta、freelist 编解码）、`page_store.zig`（页分配/回收/mmap）。单测：页 roundtrip、freelist alloc/free、meta 交替写恢复。 | format2 + page_store 单测 | 低 |
| **P2** B-tree v2 | 新 `btree2.zig`：页号寻址、固定页 leaf/branch、COW insert/insert、get、select。先不做溢出页（限 value ≤ 3.8KB）。单测：随机 ops vs StringHashMap（搬 btree.zig 现有模型测试）。 | btree2 模型测试 | 中（COW 逻辑搬移） |
| **P3** Writer v2 | 新 `writer2.zig`：applyBatch（freelist 分配/回收、meta 交替写、原子提交）。dirt 统计变为 freelist 页数。group commit leader/follower 搬移。单测：batch + dirt 归零。 | writer2 单测 | 中 |
| **P4** MVCC + reader | 读事务 txnid 跟踪、`oldest_reader_seq`、安全回收窗口。先做 single-reader 快路径（无 reader 立即回收）。 | 并发 reader + writer 测试 | 中 |
| **P5** Db v2 + open/close | 新 `db2.zig`：open（meta 恢复 O(1)）、close、put/putBatch/get/delete/select/compact。集成测试搬移。 | db2 集成测试 | 低 |
| **P6** compact v2 | O(1) meta 切换；可选 `compactShrink`。对比 benchmark：compact 带宽 2.9MB/s → ~O(1)。 | benchmark 对比 | 低 |
| **P7** 溢出页 | overflow page 链（value > 单页）。去掉 value ≤ 3.8KB 限制。 | 大 value 测试 | 中 |
| **P8** 切换 + 清理 | root.zig 导出 v2、删 v1 模块（或保留 v1 作 `legacy`）、README 更新、benchmark 全量重跑。 | 全量测试 + benchmark | 低 |

每阶段都可独立编译测试，v1 与 v2 可共存于不同模块直到 P8 切换。

## 12. 风险与开放问题

1. **freelist 页自身 COW 开销**：每次提交若 freelist 变化，需写新 freelist 页。高频小提交下 freelist 页写放大可能抵消收益。LMDB 把 freelist 编码进 meta page（meta 够大就内联），减少额外页写。→ P3 需验证。
2. **页对齐浪费**：固定 4KB 页，小 value（如 100B）填不满一页，空间利用率低于 v1 变长。LMDB 同样如此，可接受。可配 `page_size` 调整。
3. **mapsize 不足**：用户指定 mapsize，写满报错 `error.MapFull`。需文档说明 + 运行时检测。动态扩展（remap）列后续，不在 v2 范围。
4. **溢出页 MVP 限制**：P2-P6 阶段 value ≤ ~3.8KB。大 value 用户（如存 10KB）要等 P7。影响 benchmark 10KB 格子。
5. **CRC 粒度**：v1 per-record CRC，v2 per-page CRC。页级 CRC 检测粒度变粗（单页内多 entry 的损坏定位变难），但恢复路径只验 meta + 按需验数据页。可接受。
6. **get 零拷贝路径**：v1 `readBorrow` 返 mmap 切片。v2 `readPage` 同样返 mmap 切片（页内偏移），零拷贝语义不变。`findInLeaf` / `findInBranchPayload` 逻辑可复用，只是 payload 边界从变长变固定页。
7. **group commit 合并**：leader/follower 机制与页格式无关，搬移即可。但 freelist 分配/回收在 leader 持锁段完成，followers 不碰。

## 13. 对比 LMDB 的取舍

| 维度 | LMDB | cube_db v2 | 取舍理由 |
|---|---|---|---|
| 页大小 | 4KB 固定 | 4KB 可配 | 灵活性，benchmark 调参 |
| meta | 双 meta 交替 | 双 meta 交替 | 同 |
| freelist | 编码在 meta 内联/溢出页 | 独立 freelist 页链 | 实现简单，meta 小 |
| MVCC | txnid + reader 注册表 | page gen + oldest_reader_seq | 同语义，不同实现 |
| 溢出页 | 有 | P7 补 | MVP 先限 value |
| 动态 mapsize | 不支持（固定上限） | 不支持 | 同 LMDB，文档说明 |
| 压缩 | 无 | 无 | 同 |
| 并发写 | 单写者 | 单写者（group commit 合并） | 同 |

cube_db v2 本质是 LMDB 架构在 Zig 的重新实现，加 group commit 合并优化。目标：compact O(1)、写放大 ~1×、恢复 O(1)，追平 LMDB。

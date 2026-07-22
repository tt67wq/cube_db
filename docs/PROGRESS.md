# cube_db 实现进度

跟踪 `docs/DESIGN.md` 的落地进度。模块按 §12 TDD 顺序推进，每模块完成后更新本表。

## 模块状态

| 模块 | 文件 | 测试用例 | 状态 | 备注 |
|------|------|----------|------|------|
| M0 zio 接入 spike | build.zig/.zig.zon | T0.1–T0.4 | ✅ | zio 0.16.0 path 依赖接入，`spawn+join` 验证通过 |
| M1 format.zig | src/format.zig | T1.1–T1.8 | ✅ | header/branch/leaf 编解码、CRC、truncation、边界 |
| M2 store.zig | src/store.zig | T2.1–T2.7 | ✅ | MemStore + 块标记 + 反向 header 扫描 + CRC 回退 |
| M3 btree.zig | src/btree.zig | T3.1–T3.15 | ✅ | 不可变 B-tree、COW 插入/删除、范围迭代、模型测试 |
| M4 writer.zig + db.zig | src/writer.zig, db.zig, file_store.zig | T4.1–T4.7 | ✅ | open/put/delete/select/close + 重开；MVP 同步写（mutex）替代 writer 协程；10×100 并发验证 |
| M5 compactor.zig | db.zig (doCompact) | T5.1–T5.2 | ✅ | 手动 compact + 重开；MVP 全量重建、写停顿、父目录 fsync 跳过（注明） |
| M6 崩溃安全矩阵 | src/fault_store.zig | T6.1–T6.5 | ✅ | §9 五场景（MemStore + fault 注入）；header CRC 回退、垃圾尾部、truncate 恢复 |

图例：✅ 完成 / 🚧 进行中 / ⏳ 未开始 / ❌ 阻塞

## 验收标准（每模块）

- [x] M1: `zig build test` 全绿
- [x] M2: `zig build test` 全绿
- [x] M0: ReleaseSafe 构建无警告 `zig build -Doptimize=ReleaseSafe`
- [x] M3: `zig build test` 全绿；模型测试（seed 7, 2000 ops）对比 StringHashMap
- [x] M4: `zig build test` 全绿（10 协程×100 put 并发验证 1000 key）；ReleaseSafe 绿
- [x] M5: `zig build test` 全绿（手动 compact + 重开）；ReleaseSafe 绿
- [x] M6: `zig build test` 全绿（§9 五场景 fault 注入）；ReleaseSafe 绿

## 关键实现决策（偏离 DESIGN 的地方）

### 1. Store vtable 增加 `readPhysical` / `physicalSize`（M2）

DESIGN §5.1 的 vtable 只有 `read/append/sync/setSize/size/close`。实现时发现 header 反向扫描（§4.5）需要读**物理**块首 marker 字节，而 marker 不属于逻辑内容流（逻辑 `read` 跳过 marker）。

权衡：
- 选项 A：让 marker 可通过逻辑 `read` 访问 → 破坏「逻辑偏移 = 内容偏移」不变量，btree 节点偏移语义混乱
- 选项 B（采用）：vtable 加 `readPhysical(phys_offset)` 与 `physicalSize()`，仅供恢复路径扫描 marker 使用；btree/writer/db 全部面向逻辑 `read`

`readPhysical` 是内部细节，不进公开 `Db` API。真文件 FileStore 同样实现这两个方法（pread 物理偏移）。

### 2. MemStore 块标记自同步（M2）

`appendRaw` 用「物理长度 % BLOCK_SIZE == 0」判定是否需要插 marker，而非「逻辑长度 % (BLOCK_SIZE-1) == 0」。原因：header 块 marker（MARKER_HEADER）由 `appendHeaderRecord` 直接写物理、不计入逻辑长度；逻辑判定法会让随后的内容字节误判为已在块首而漏插 marker。物理自同步保证无论 marker 如何写入都对齐。

### 3. btree root 空哨兵用 maxInt(u64) 而非 0（M3）

设计未指定空树哨兵。0 是合法逻辑偏移（首条 `append` 返回 0），若用 0 作空树哨兵则首节点偏移与空树混淆，第二条插入误判为空树。改用 `btree.NULL_ROOT = std.math.maxInt(u64)`。db 层持久化 header 时 `NULL_ROOT ↔ 0` 转换（header.btree_root=0 表示空树）。

### 4. branch 分隔 key 语义：左闭右开，findChild 走上界（M3）

branch.keys[i] 分隔 children[i]（全 < sep）与 children[i+1]（全 >= sep）。`findChild` 找第一个 keys[i] > key 的位置（上界），相等 key 走右子。这与 leaf.findPos（下界，相等覆盖）相反，需各自正确。

### 5. COW 分裂所有权转移（M3）

分裂 leaf/branch 时，entries/keys 指针（`[]u8` 切片）从原节点 `appendSlice` 到 left/right 后，必须 `shrinkRetainingCapacity(0)` 清空原节点但不 free 元素内部指针，避免 double free（原节点 defer deinit 循环 free 与 left/right deinit free 冲突）。被抛弃的 mid key（branch split）单独 `allocator.free`。

### 6. DB 层 root 哨兵用 off+1 编码，0=空（M4）

btree 有效 root off 可能是 0（首节点逻辑偏移）。DB 层与 header 需区分「空树」与「off 0」。方案：DB 层 `state.root` 与 `header.btree_root` 用 `0=空树，n>0=btree off + 1`。`applyBatch`/`get` 转换：`bt_root = (db_root==0) ? NULL_ROOT : db_root-1`；`db_root = (bt_root==NULL_ROOT) ? 0 : bt_root+1`。这样 off 0 → db_root 1，空树 → 0，无冲突。

### 7. MVP 同步写替代 writer 协程（M4，偏离 D4）

设计 D4 要求 put/delete 经 mailbox 发给 writer 协程，writer 串行 batch+group commit。实现时发现 zio 在协程内嵌套 `spawn(writer)+join` 触发 `task_count` 断言失败（单 executor 下 nested join 的已知限制）。

MVP 折中：`sendRequest` 用 `zio.Mutex` 串行化 `applyBatch`（直接在调用协程同步应用），保留 mailbox 结构与 `applyBatch` 逻辑供后续切回 writer 协程。正确性等价（串行写），仅失去 group commit 的批量 fsync 优化。`putNoFsync` 与 `put` 行为一致（fsync 默认开）。

### 8. FileStore 物理游标自维护（M4）

FileStore 维护 `physical_len`（含块标记）与 `logical_len`（不含），`appendRaw` 用 `physical_len % BLOCK_SIZE == 0` 判定插 MARKER_DATA（与 MemStore 同款自同步）。`appendHeaderRecord` 直接 `file.write(MARKER_HEADER, physical_len)` + 手动 `+=1`，不经 appendRaw（marker 不占逻辑字节）。`create` 从 `file.size()` 反推初始 logical_len。

## 测试运行

```sh
zig build test                          # 全部测试
zig build -Doptimize=ReleaseSafe         # ReleaseSafe 无警告
```

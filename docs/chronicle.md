# cube_db 代码编年史

> **时间跨度**：2026-07-22 → 2026-08-04（14 天）
> **提交数**：114 次（线性历史，无 merge）
> **主作者**：wanqiang（112 次）/ admin（2 次）
> **代码规模**：约 3700 行 Zig + 36 个测试文件 + 10 份基准报告

这是一部按时间线展开的项目演进史。想搞清楚"这个项目是怎么一步步长成现在这样的"，跟着纪元往下读就行。不熟 Zig、不熟 KV 引擎？没关系，下面每个概念都会顺手讲清楚。

---

## 阅读指南：先认识几个核心概念

正式开读前，先认 7 个反复登场的主角。后面每个纪元都在打磨它们，先混个脸熟，故事就顺了。

| 概念 | 一句话解释 | 在 cube_db 中的角色 |
|------|-----------|-------------------|
| **B+tree（B 树）** | 磁盘友好的平衡多路树，数据只在叶子，分支节点只存导航键 | 存所有 key-value 的骨架 |
| **COW（Copy-On-Write，写时复制）** | 永不原地改页面，要改就复制一份新的，旧页面留给读者 | 崩溃安全的根基；读不阻塞写 |
| **mmap（内存映射文件）** | 把文件映射进进程地址空间，读文件 = 读内存指针 | 读路径零拷贝；1TB 预留区 |
| **MVCC（多版本并发控制）** | 读事务看到开始那一刻的"快照"，后面写入影响不到它 | 读不阻塞写、写不阻塞读 |
| **freelist（空闲页表）** | 记录哪些页面被释放、还能复用 | 页面回收再分配 |
| **meta page（元页面）** | 存"数据库根指针在哪、第几次提交"的小页面，是"提交点" | commit = 切换 meta 指针 |
| **WAL（预写日志）** | 写入前先记一条日志，崩溃后重放恢复 | **最终版无 WAL**（曾短暂实验后删除，见第四纪），靠 COW + meta 切换实现崩溃安全 |

还有个全程刷存在感的关键词：

- **fsync**：强制操作系统把内存里的脏页刷到物理磁盘。不 fsync，数据可能只是内存里的幻觉，断电就没了。它是"耐久性（durability）"的边界，也是性能的大敌——后面好多故事都绕着它转。

7+1 个词记牢，下面的故事就好看懂了。

---

## 纪年总览

| 纪元 | 日期 | 提交 | 主题 | 核心产物 |
|------|------|------|------|---------|
| 第一纪 起源 | 07-22 | 4 | v1 原型落地 | `store.zig` 接口式存储、初版 B 树 |
| 第二纪 批量与读加速 | 07-23 | 16 | putBatch、group commit、零拷贝读 | `BTreeBatch`、mmap 读路径 |
| 第三纪 v2 大重写 | 07-24 | 16 | COW B-tree 确立，删 v1 | 页地址 COW、freelist、MVCC、overflow、FilePageStore |
| 第四纪 LSM 岔路 | 07-27 | 7 | memtable/WAL/compactor 实验 + fuzz | LSM 层（后被删除）、fuzz 框架 |
| 第五纪 正本清源 | 07-30 | 31 | 删 LSM、1TB mmap、显式事务、崩溃恢复、COW 写优化 | LMDB 正统架构定型 |
| 第六纪 基准与正确性 | 07-31 | 22 | 大规模 bench、kill-9 测试、putBatch 溢出 bug | 回归基线系统、容量感知 split |
| 第七纪 写路径收官 | 08-03 | 16 | arena 化、slab 页池、有序 fast path | 写路径性能追平 LMDB 算法层 |
| 第八纪 硬件加速 | 08-04 | 2 | ARM64 硬件 CRC32 | `crc32_hw.zig` |

---

## 第一纪 · 起源（2026-07-22，4 次提交）

### 这天在干嘛

作者要用 Zig 0.16.0 搓一个**嵌入式 KV 引擎**——你可以理解成"只管 key-value 的 SQLite"，或者"自己手搓的 LMDB"。"嵌入式"是说它是个库（链接进你的程序），不是独立服务。参照对象是 LMDB（OpenLDAP 用的那个，以极简和高性能著称）。第一天不追求架构完美，能跑起来就算赢。

### 提交脉络

**`54d3d42 first version`** —— 第一铲土。一口气落地的初版（v1）：

```
src/
  store.zig        # 存储接口（Store trait）
  file_store.zig   # 文件存储实现
  fault_store.zig  # 注入故障的存储（测试用）
  btree.zig        # B 树（913 行，当天最大头）
  db.zig           # 数据库句柄 + API（214 行）
  format.zig       # 页面格式（351 行）
  writer.zig       # 写入器（158 行）
  root.zig         # 公共导出
  main.zig         # 入口
```

这版 B 树还不是 COW——就地改 + 全量重写式压缩。存储层走接口抽象老路：`Store` 定读写页面的规矩，`FileStore` / `FaultStore` 照着实现。典型的面向对象思路。能跑，但方向没定——第二纪还在它身上加了一整天的活，07-24 就被连根拔起重写了。

> **Zig 小知识**：Zig 没有类和继承，做"接口"靠 **vtable**——一个 `*anyopaque`（类型擦除指针）+ 一个函数指针表（`*const VTable`），调用时用 `@ptrCast(@alignCast(self))` 把擦除的指针还原回来。这就是 cube_db 后来 `PageStore` 的写法。

**`ff4a773 hide zio runtime behind sync Db API`** —— 把异步运行时（`zio`）藏到同步 API 后面。用户调 `db.put()` 是同步的，内部可能走协程，但用户无感。

**`97b877a close D4 coroutine bet, remove dead mailbox/writerLoop code`** —— 关掉"D4 协程"的赌注，顺手清掉用不到的 mailbox/writerLoop 死代码（-33 行 writer、-18 行 db）。**第一次做减法**，后面会越减越狠。

### 小结

v1 是个"能跑但方向没定"的原型：接口式存储、就地修改 B 树、协程运行时。它撑了两天就退场——第二纪拿它跑了一整天批量优化，第三纪直接推翻重写。

---

## 第二纪 · 批量写入与读路径加速（2026-07-23，16 次提交）

### 为什么单条 put 慢

每条 `put` 都要：分配页面 → B 树插入 → 写 meta → fsync。**fsync 是毫秒级**的昂贵操作。要一次提交 1000 条 key，逐条 put = 1000 次 fsync，灾难。解法就俩字：**batch**——攒一批，一次提交、一次 fsync，把那笔昂贵的 syscall 摊薄。

### 提交脉络

**`5d13612 add benchmark`** + **`b83e1e4 drop runtime`** —— 先加基准测试（没有度量就没有优化，这是项目第一条铁律），然后彻底砍掉运行时，回归纯同步。**作者很快想明白：KV 引擎不需要异步运行时，同步最简单也最快。** 这个判断后面再没动摇过。

**`5fb4724 ~ eb59146 BTreeBatch 系列`**（4 次提交）—— 用 TDD（测试驱动）一步步搭 `BTreeBatch`：
1. `5fb4724` 骨架：apply + commit 去重，测试 1 跑绿
2. `23b8871` 节点缓存 + arena 管理的 flush（+297 行 btree）
3. `eb59146` 拆成独立文件 `btree_batch.zig`（btree -354 行，抽离）
4. `cb80fbb` 2000 条混合操作模型测试，去重 + select 计数对得上

> **arena allocator（竞技场分配器）**：一种"批发式"内存分配器——一次性申请一大块，内部指针单调递增地分，**释放时整块一起还**。批量插入用它最爽：所有临时 COW 页面分配飞快（无碎片管理），事务结束一把丢弃。这招后面贯穿全项目。

**`6097762 db: add putBatch([]Entry)`** —— 公共 API 落地：`putBatch([]Entry)` 一次提交多条。4 个测试跑绿。

**`ed9d54f bench: putbatch ~1000x`** —— 结果惊人：单线程 putBatch **~1000 倍**于逐条 put（0.15us/op vs 178us）。fsync 摊薄到整批上，收益直接起飞。

**`b592414 group commit: leader/follower`** —— group commit（组提交）：多个线程同时 put，**leader 负责真正提交，follower 挂在自己的 future 上等**。16 个线程 × 50 条 put 合并，~6.8 倍提升。

> **group commit 的本质**：把"多次 fsync"合并成"一次 fsync"。LMDB/PostgreSQL/MySQL 都用这招。代价是 follower 要等，增加延迟——拿延迟换吞吐的经典交换。

**`b72502e get read path: mmap + skip-decode + read-no-CRC`** —— 读路径三连击：
1. **mmap**：读页面直接用内存指针，不 `read()` 系统调用
2. **skip-decode**：热路径跳过反序列化，直接在原始字节上二分查找
3. **read-no-CRC**：读时不校验 CRC（COW 保证页面不会被原地改，信任度高）

这是把读路径往"LMDB 级别"推的关键一步。

**`9619b31 read path: zero-copy`**（07-24 开头，但属同一波）—— 进一步零拷贝：去掉 marker 字节、`readBorrow` 直接返回 mmap 指针、跳过分支节点解码。读到 LMDB 水平（100B ~3us，10KB ~5-13us）。

### 小结

这纪的主题是**两条性能曲线同时拉升**：
- **写**：putBatch + group commit，把 fsync 摊薄 1000 倍
- **读**：mmap + 零拷贝 + 跳 CRC，把单次 get 压到微秒级

风光归风光，底层 B 树还是 v1 的就地修改式。这成了下一纪要推翻的靶子。

---

## 第三纪 · v2 大重写（2026-07-24，16 次提交）

### 为什么 v1 的 B 树必须推翻

v1 的 B 树**就地修改页面**。两个致命伤：
1. **崩溃不安全**：写到一半断电，页面半新半旧，数据损坏
2. **读阻塞写**：写入时要锁页面，读者得等

LMDB 的答案是 **COW（写时复制）**：要改一个页面？复制一份新的，改新的，旧页面原封不动留给正在读的人。所有修改最终汇聚到一个新的 **meta page**，commit = 原子地切换 meta 指针。旧 meta 还在，崩溃了读旧 meta 即可——**天然崩溃安全，无需 WAL**。

作者拍板：推翻 v1 的 B 树，重写成页地址式 COW B 树。这就是 "v2"。

### 提交脉络：v2 七连击

一天之内，v2 的全部核心组件落地：

| 提交 | 产物 | 意义 |
|------|------|------|
| `60a7c6f` freelist v2 | `page_store.zig` +181 行 | 空闲页回收机制，COW 的旧页有地方去 |
| `d779c84` btree2 | `btree2.zig` 756 行 | **页地址式 COW B 树**——不持有指针，只持页号 |
| `581b3cb` writer2 | v2 批量提交 | btree2 + PageStore + **meta 双页交替** |
| `e50eeae` MVCC | `pending_free` + reader_count | 读者安全：旧页延迟到读者退出才回收 |
| `5d83f75` db2 | v2 数据库句柄 | open/close/put/get/delete/select/putBatch |
| `2cf9d73` compact v2 | **O(1) meta 切换** | 压缩不再是全量重写，只切指针 |
| `9424b12` overflow pages | 大值溢出页链 | value > 3800B 走溢出页链 |

**`5da8aa3 FilePageStore + v1 vs v2 对比基准`** —— `file_page_store.zig` +143 行首次登场：真正的文件存储（之前是内存 `MemPageStore`）。顺手跑 v1 vs v2 基准，证明 v2 方向对。

> **页地址式 B 树 vs 指针式**：v1 节点持有内存指针；v2 节点只持 **页号（u32）**，要用时才从 page store 取。看似多一层间接，但它让 B 树**与具体存储解耦**——能放内存、能放文件、能放 mmap。这是 COW 能成立的前提。

> **meta 双页交替**：磁盘上有两个 meta 页（page 1、page 2）。这次写 meta1，下次写 meta2，轮流来，每次写完整 meta（含 CRC）。崩溃恢复读两个，**校验 CRC + 取 sequence 更大的那个**。这就是 cube_db 的"原子 meta 切换"——不是单条原子指令，而是"旧页不动 + CRC 防撕裂 + 序号选新"三件套。

**`717c2f9 refactor: remove CubDB v1, rename v2 files`** —— **决定性的一刀**：57 个文件，+2024 / **−9579** 行。删掉 v1 全部代码（`store.zig`/`file_store.zig`/`fault_store.zig`），把 v2 文件名的 '2' 后缀抹掉（`btree2.zig` → `btree.zig`）。**v1 正式退场，v2 成为唯一真相。**

文件结构从这一刻起基本定型（和今天对比，只差 `crc32_hw.zig`）：

```
src/
  btree.zig           # COW B 树
  db.zig              # 公共 API
  writer.zig          # 提交逻辑 + State
  format.zig          # 页面格式 + meta + CRC + 恢复
  page_store.zig      # PageStore 接口 + MemPageStore
  file_page_store.zig # FilePageStore（mmap）
  root.zig            # 导出
  main.zig            # 入口
```

### 小结

项目的**奠基日**。一天确立了 LMDB 式核心架构：COW B 树 + freelist + MVCC + overflow + 双 meta 交替 + O(1) 压缩。v1 连根拔起。后面所有优化都在这套骨架上做。

---

## 第四纪 · LSM 岔路（2026-07-27，7 次提交）

### LSM 是什么，为什么要试又为什么放弃

**LSM（Log-Structured Merge-tree）** 是另一类 KV 引擎架构（RocksDB/LevelDB 用它）。思路：写入先进内存表（memtable），攒够了落盘成有序文件（SSTable），后台定期合并（compaction）。为崩溃安全，写 memtable 前先记 WAL。

LMDB（COW B 树）和 LSM 是两条路线。这个周末作者**手痒试了一下 LSM**：加 memtable + WAL + compactor。结果发现：cube_db 的 COW B 树已经够好，LSM 是画蛇添足。**3 天后整个删除，干净利落。**

### 提交脉络

**`6649a3b 5-chapter tutorial`** —— 给初学者写 5 章教程（页面格式 → 溢出页），+1248 行。作者很重视教学，这点贯穿全程。

**`3beede5 LSM layer`** —— 加 memtable、WAL、compactor。db.zig +122 行接入 LSM 数据流。

**`f1496bd merge WAL 4×pwrite → single pwrite`** —— LSM 唯一的性能优化：把 WAL 的 4 次 `pwrite` 合并成 1 次，3.3 倍快。
**`3ba8933` bench: WAL single-pwrite 基准数据** —— 配 f1496bd 的基准记录。

> **pwrite vs fsync**：`pwrite` 是"在指定偏移写"，不移动文件指针；`fsync` 是"确保写到磁盘"。WAL 追加日志用 pwrite 高效，但耐久性最终还得靠 fsync 收尾。

**`320ec0a fuzz framework`**（+2342/−1479，28 文件）—— **重要遗产**：TDD 式模糊测试框架，3 个 fuzz 目标（API fuzz、格式 fuzz、WAL parse）+ 框架自检探针。模糊测试拿随机字节流当输入，对比 `std.StringHashMap` 参考模型，专找边界 bug。这框架活过了 LSM 删除，一直留到今天。

**`9082b5b wrapup tutorial`** —— 带 LSM 数据流图的收尾教程。
**`85d174f Add benccmp`** —— 加 `benchcmp/` 对比工具（LMDB 对标二进制 + COMPARISON.md）。这工具存活至今，是后面所有 LMDB 对标数据的承载体——编年史反复提到的 COMPARISON.md 就在 `benchcmp/` 里。

### 小结

一次**有代价的探索**：LSM 层加了又删，但**模糊测试框架**和**教程体系**留了下来，成了后续正确性的护城河。作者的选择很果断：试错 3 天，发现不对下一纪就一刀砍掉。

---

## 第五纪 · 正本清源（2026-07-30，31 次提交）

### 这天发生了什么

07-30 是项目的**超级日**——31 次提交，从早到晚。主题：删掉 LSM 岔路，把架构彻底锚定在 LMDB 正统路线上，然后一口气补齐崩溃恢复、显式事务、COW 写优化、零拷贝读、CRC 跳过。这一天产出了今天代码库 70% 的灵魂。看提交密度就知道，作者这天进入了心流。

### 提交脉络（按主题分组）

#### 5.1 清算 LSM（2 次）

- **`2cca3aa remove LSM layer`**：10 文件 **−1437 行**。wal/memtable/compactor 全部代码和测试连根删除。注释写得明明白白："consolidate on pure COW B-tree (LMDB-style)"。**LSM 岔路正式终结。**
- **`9dc184a long-run fuzz`**：带时间预算的长跑模糊（50ms 探针截止 + 2 分钟长跑）。

#### 5.2 文件存储升级（2 次）

- **`f6017ee 1TB reserved mmap`**：`file_page_store.zig` 197/−119（整提交 +309/−119，另含 mmap_region_test 112 行）。LMDB 式做法：开库时 `mmap` 一个 **1TB 的 MAP_SHARED 保留区**，文件靠 `ftruncate` 按需增长（稀疏文件，不占实空间）。读者永远不用重新 mmap。
- **`0a5200c fix meta_index recovery + last_page`**：修 FilePageStore 重开时的 meta 索引恢复和 last_page 追踪 bug。

> **为什么 1TB mmap 不爆内存**：mmap 只是保留**虚拟地址空间**，不分配物理内存。只有真正写到的页才落磁盘（稀疏文件）。Linux/macOS 都支持。这是 LMDB "零拷贝 + 无限增长"的秘诀。

#### 5.3 显式事务（3 次）

- **`3830286 explicit LMDB-style transactions`**：db.zig 124/−34（整提交 +304/−34，三文件）。引入 `WriteTxn`（单写者互斥）和 `ReadTxn`（MVCC 快照）。之前只有隐式事务，现在用户能显式控制：`beginWriteTxn` / `commit` / `abort` / `deinit`。
- **`7406987 durability/crash-recovery tests`**：+218。异步/同步模式（`Options{fsync}`）+ group commit 验证。
- **`5d0382b crash harness (fork+kill)`**：+281。**关键测试设施**：`fork` 子进程写数据，中途 `kill -9` 模拟崩溃，父进程重开库验证数据完整。还有 meta 损坏 fuzz + 1k key 压力测试。

> **fork+kill 崩溃测试**：验证"崩溃安全"最硬核的办法。光单元测试不够——你得真把进程杀掉，看重启后数据对不对。LMDB、SQLite 都有这类测试。

#### 5.4 COW 写路径优化（1 次，但 +691/−121）

- **`57e18cd COW write path optimization`**：btree.zig **+414/−118**。put 100B **4.2 倍**，put 10KB **2.0 倍**。写路径第一次大规模优化，把 COW 插入的热路径整个重写。

#### 5.5 零拷贝读 + 修复（4 次）

- **`8010f02 zero-copy getBorrowed`**：btree +74。`ReadTxn.getBorrowed` 直接返回 mmap 指针，零拷贝。
- **`3a47cd4 ReadTxn 生命周期 fuzz`**：+269。专门 fuzz 读事务的生命周期（开始/结束时序）。
- **`684be09 crash recovery 测试框架`**：+398。系统化的崩溃恢复测试框架。
- **`559a214 fix future error 静默丢弃`**：**重要 bug 修复**——`WriteTxn.commit` 里 future 的 error 被吞掉了，修复就 db.zig 一行 `try`；同提交删了临时的 repro_delete_test.zig（-42 行）。

#### 5.6 微批处理 + 读 CRC 跳过 + 共享 COW（3 次，性能三连击）

- **`dcf1ab3 micro-batching / group-commit for db.put/delete`**：db.zig 67 行变动。给便捷 API `db.put`/`db.delete` 加微批处理：攒到阈值自动 flush。
- **`2d1b69b skip CRC on read path`**：get 100B **35us → 2.8us（12.7 倍）**。读路径不校验 CRC——COW 保证页面不被原地改，信任度高。
- **`2c156c6 shared COW path for putBatch`**：btree **+410**。putBatch **24.75us → 0.04us（619 倍！）**。批量插入时多个 key 共享同一条 COW 路径，避免重复分配。

> **619 倍是什么概念**：算法层面的胜利——把"每条 key 独立走一遍 COW 插入"换成"整批一次走完 COW 路径"。后面第七纪会继续在这个方向榨取。

#### 5.7 文档收尾（多次）

`ca06a49`（同步 README，删 LSM/WAL/v1 残留）、`1605086`（写 `docs/architecture.md`，339 行设计文档）、`e5d281d`（基准数据文档）。

### 小结

31 次提交，项目灵魂定型。删 LSM、上 1TB mmap、上显式事务、上崩溃恢复测试、COW 写优化、零拷贝读、CRC 跳过、共享 COW。**今天的架构在这一天基本长成。**

---

## 第六纪 · 基准与正确性危机（2026-07-31，22 次提交）

### 性能跑出来后，正确性是下一个战场

第五纪把性能拉到 LMDB 级别后，新问题冒头：**putBatch 在大规模下有正确性 bug**。这纪一半在补基准（和 LMDB 对标），一半在修 putBatch 的溢出/分裂 bug。性能追平的代价是正确性反噬——经典剧情。

### 提交脉络

#### 6.1 大规模基准 + LMDB 对标（~8 次）

- **`7876dfb FilePageStore fps_bench`**：`bench/fps_bench.zig` 首次加入（+260）。fsync 开/关 × 批次大小（10→10K）的 2×2 矩阵基准。（注：`04a542a` 同日只改了 build.zig +23 接线，真正的 bench 文件来自本提交。）
- **`32ff2a0 FilePageStore kill -9 crash recovery`**：+261。putBatch 中途 kill -9 的崩溃恢复测试。
- **`09f6ec1 large scale FilePageStore + fsync + key copy fix`**：大规模基准 + 修 key 拷贝 bug。
- **`2d2037e / 7008f93 / 24d0a45 / 20ee71d / c8b6dc8`**：一连串 LMDB 默认（fsync）基准数据 + COMPARISON.md 更新。LMDB warm 10K putBatch 1.30us/op。
- **`a8585ff benchmark 回归基线系统`**：+156。`bench_baseline.zig`——**防止性能倒退**的回归基线。

#### 6.2 putBatch 正确性危机（5 次，核心）

- **`65d82cd putBatch 正确性测试 + insertBatch leaf 溢出回归`**：+258/−46。**发现 bug**：`insertBatchIntoLeaf` 在叶子页溢出时分裂逻辑有缺陷。新增 `insertbatch_overflow_test.zig`（188 行）；`putbatch_correctness_test.zig` 实为 `18fd2be` 引入，本提交复用它。

> **叶子页溢出问题**：一个叶子页最多 32 条 entry（`LEAF_MAX_ENTRIES`）。批量插 100 条进一个叶子，必须"分裂"成多个叶子。v2 初版的分裂是"先全塞进去再分裂"（O(n²)），且容量判断有错——会溢出。

- **`69db8ed fix insertBatchIntoLeaf capacity-aware split + putBatch key copy`**：btree **+138/−21**。**容量感知分裂**：插入前先算会不会超容量，超了就提前分裂。顺手修 key 拷贝的生命周期 bug。
- **`b1179fe fix single-entry fast path in applyBatch`**：修单条插入的快路径。
- **`157e22d wip: leaf-capacity-aware multi-split (partial)`**：多级分裂的半成品（WIP）。
- **`bb91eca fix insertBatchIntoBranch partition bug + futures arena`**：修分支节点分裂的分区 bug + future 改用 arena 分配。
- **`28d49e1 insertBatchIntoLeaf O(n+m) merge`**：btree +101/−57。**算法升级**：把 O(n²) 的"先长再切"换成 O(n+m) 的归并式插入。

> **O(n²) → O(n+m)**：旧法把新条目全 append 进叶子，再排序，再切分——n 条数据 O(n²) 操作。新法用归并：叶子已有的 n 条 + 新插入的 m 条，两个有序序列一次归并 O(n+m)。这是数据库引擎里经典的"bulk load"思路。

#### 6.3 基线校准（2 次）

- **`f7fdb37 recalibrate benchmark baseline`**：修完 bug 后性能数字变了，重新校准基线。
- **`bc41ce6 fix bench_baseline putBatch shared buffer`**：基准自己也有 bug——共享 buffer 导致 key 被覆盖，改成 per-entry 分配。

### 小结

性能追平 LMDB 后，**正确性反噬**：putBatch 的大规模溢出分裂有 bug。这纪用容量感知分裂 + O(n+m) 归并修好了，同时建起和 LMDB 对标的基准矩阵 + 回归基线系统。**教训：性能优化的尽头是正确性测试。**

---

## 第七纪 · 写路径收官（2026-08-03，16 次提交）

### 把 putBatch 的延迟榨干

第六纪把 putBatch 修对之后，这纪的目标是**把 putBatch 的单条延迟从微秒级压到纳秒级**，对标 LMDB 的算法层性能。手段是一连串"消除每条 key 的额外开销"的微优化，一条链往下榨。

### 提交脉络（一条优化链）

```
arena 化 staging      →  消除每条 key 的 syscall
   ↓
slab 页池              →  消除每页 mmap
   ↓
profiling 埋点         →  找到下一个瓶颈
   ↓
跳过 staging 层        →  直接批量构建
   ↓
预分配连续 key buffer   →  消除 per-entry arena dupe
   ↓
有序 fast path         →  有序时跳过 sort/dedup
```

逐条看：

- **`7a9cc93 WriteTxn abort 路径正确性测试`**：+123。先补 abort 路径测试（优化前先有测试护栏，这是规矩）。
- **`dcce99a WriteTxn staging arena 化`**：+335/−48。把 staging（暂存）层改成 arena 分配——putBatch 的 dupe/staging **零 syscall**。
- **`b809c87 MemPageStore slab 页池`**：+259/−9。`MemPageStore` 从 HashMap 改成 **ArrayList slab**——消除每页一次 mmap。同时新增 `slab_page_store_test` / `slab_memory_test`。

> **slab（页池）**：预分配一大块连续内存当页面池，按索引取页。比 HashMap（每页一次 mmap）快几个数量级。这是测试用 `MemPageStore` 的优化，不影响 `FilePageStore`。

- **`6cfe7df commit 路径 profiling 埋点`**：writer +100。给 commit 路径加规模敏感的计时埋点 + `profile-commit` 工具。**先测量再优化**，又一条铁律。
- **`25d529c putBatch 直接批量构建，跳过 staging 层`**：staging **4300 → 25 ns/entry**。跳过 WriteTxn staging 直连 applyBatch。但提交消息明言**总耗时 5.1µs/entry 与优化前持平**——瓶颈转移到 applyBatch 内部 arena dupe（4481 ns/entry），等于把靶点暴露给下一步。
- **`3850771 applyBatch 预分配连续 key 缓冲区`**：消除 per-entry 的 arena dupe（重复拷贝）开销。
- **`c79b550 putBatch 有序 fast path`**：writer +99/−52。**O(n) 单调性检测**：输入 key 已有序就跳过 sort + dedup。
- **`172c520 order_detect 独立计时`**：把单调性检测单独计时，验证它本身够快。
- **`7156efd FPS 写路径计数器 + 判别式实验`**：+480。给 FilePageStore 写路径加性能计数器，做判别式实验（A/B 测）找出真正的瓶颈。

#### 文档收官（5 次）

- **`f327da0` 写路径收官文档**、`60ddac2` 补证据链、`1b38a4a` 补 FilePageStore 实测数据、`ec55c89` + `4ae1d65` **终局 COMPARISON.md**：双层结论叙事——**算法层 parity 1.27x（追平 LMDB）/ 持久化层 1.9–2.6×**。

> **"算法层 vs 持久化层"**：作者把性能分两层。算法层（B 树插入、内存操作）追平 LMDB（1.27 倍）。持久化层（FilePageStore 真实堆分配）1.9–2.6× LMDB。**注意：早期一度报告的 49× 差距是 `page_allocator`（每 key 一次 mmap = 1M 独立页 = 最坏 TLB 分散）的人工伪影**，`4ae1d65` 自己就把它修正成 2× 矩阵；剩余 2.6× 差距在 `insertBatch` 的 B-tree 操作，不是 fsync 物理限制。这个分层认知很清醒。

### 小结

写路径的"榨干"之纪。arena → slab → 跳 staging → 预分配 → 有序 fast path，一条链把 putBatch 单条延迟压到纳秒级，配套建起 profiling 工具和回归基线。**算法层追平 LMDB（1.27x），剩下的差距在 insertBatch 树操作 vs LMDB 优化，不是 fsync 物理限制。**

---

## 第八纪 · 硬件加速（2026-08-04，2 次提交）

### CRC32 的软件实现是瓶颈

每个页面尾部有 4 字节 CRC32 校验。软件 CRC32（查表法）在写大量页面时成了热点。ARM64 处理器有**硬件 CRC32 指令**（`crc32x/crc32w/crc32h/crc32b`），一条指令算 8 字节，实测比软件快 23 倍。该上硬件了。

### 提交脉络

- **`42f1a05 ARM64 硬件 CRC32`**：+318。新增 `src/crc32_hw.zig`（129 行）——用 **内联汇编** `asm volatile ("crc32x w0, w1, x2")` 直发 ARMv8 CRC32 指令，硬件加速 page checksum。`format.zig` +12 接入。配 `crc32_hw_test`（160 行测试）+ `crc32_bench`。
- **`22c4e22 CRC32 硬件加速 Phase 2+3`**：+525/−1。完善硬件 CRC 路径 + 软件回退（`std.hash.crc.Crc32`）。

> **Zig 内联汇编**：cube_db 没有用 `@cImport` 拉 C 头文件，而是直接写内联汇编 `asm volatile ("crc32x w0, w1, x2")` 调 ARMv8 的 CRC32 指令。`crc32x/crc32w/crc32h/crc32b` 分别处理 64/32/16/8 字节，每 64B 一轮（8×crc32x）降循环开销。非 ARM64 平台回退到 `std.hash.crc.Crc32` 软件实现。

### 小结

收尾之纪。用硬件指令给 CRC32 提速，"最后一公里"的优化。项目到这里告一段落（至少 git 历史到此）。

---

## 文件演进史

### src/ 模块的诞生顺序

| 文件 | 首次出现 | 备注 |
|------|---------|------|
| `btree.zig` | 07-22 (v1) | 913 行起步；07-24 被 btree2 整体替换（页地址 COW） |
| `db.zig` | 07-22 (v1) | 214 行起步；07-30 显式事务大改 (+304) |
| `format.zig` | 07-22 (v1) | 351 行；07-23 加 mmap 读、08-04 接入硬件 CRC |
| `writer.zig` | 07-22 (v1) | 158 行；承载 commit 路径，08-03 profiling 大改 (+100) |
| `root.zig` | 07-22 (v1) | 导出层，随模块增删演进 |
| `main.zig` | 07-22 (v1) | 入口，18 行基本不变 |
| `page_store.zig` | 07-24 (v2) | +181 行，freelist v2 时诞生 |
| `file_page_store.zig` | 07-24 (v2) | +143 行；07-30 1TB mmap 大重写 (+309/-119) |
| `crc32_hw.zig` | 08-04 | 129 行，最后诞生的模块 |

### 已删除的模块（历史遗迹）

| 文件 | 生卒 | 死因 |
|------|------|------|
| `store.zig` | 07-22 → 07-24 | v1 接口式存储，v2 用 PageStore vtable 取代 |
| `file_store.zig` | 07-22 → 07-24 | v1 文件存储，被 `file_page_store.zig` 取代 |
| `fault_store.zig` | 07-22 → 07-24 | v1 故障注入存储，v2 用 crash harness 取代 |
| `btree_batch.zig` | 07-23 → 07-24 | putBatch 逻辑，07-24 并回 btree.zig |
| `btree2.zig` | 07-24 → 07-24 | v2 B 树，当天改名 btree.zig（删 v1 后） |
| LSM 层（wal/memtable/compactor） | 07-27 → 07-30 | 试错 3 天，发现 COW 够用，整体删除 (-1437) |

### 测试文件的扩张

```
07-22: 2 个测试（compact_test, db_test）
07-24: 8 个（+btree, format, mvcc, overflow, page_store, writer）
07-27: +fuzz 框架（5 个 fuzz 文件：common 工具 + api/format/probe/wal_fuzz 4 个测试）
07-30: +crash recovery（4 个）+ zero_copy + readtxn_fuzz + stress + binary_search
07-31: +putbatch_correctness + insertbatch_overflow + insertbatch_capaware + crash_putbatch
08-03: +txn_arena + txn_abort_arena + slab_* + cow_fast
08-04: +crc32_hw + crc_regression
HEAD: 36 个测试文件
```

测试和功能几乎 1:1 同步长，而且**总是先写测试再优化**（TDD 风格贯穿全程）。

---

## 关键设计决策回顾（按时间）

| 决策 | 时间 | 选择 | 替代方案（被否） | 为什么 |
|------|------|------|----------------|--------|
| 异步 vs 同步 API | 07-22 | 纯同步 | zio 协程运行时 | KV 引擎不需要异步运行时，同步最简最快 |
| 就地改 vs COW | 07-24 | COW B 树 | v1 就地修改 | 崩溃安全 + 读不阻塞写 |
| WAL vs 无 WAL | 07-30 | 无 WAL（COW + meta 切换） | LSM + WAL | COW 天然崩溃安全，WAL 是冗余 |
| 接口式 vs vtable | 07-24 | PageStore vtable | v1 Store trait | Zig 惯用法，零开销 |
| 读校验 CRC | 07-30 | 读跳过 CRC | 每次读校验 | COW 保证页面不变，信任度高，12.7 倍快 |
| memtable vs B 树 | 07-30 | 纯 B 树 | LSM memtable | B 树 + COW 已足够，LSM 画蛇添足 |
| mmap 大小 | 07-30 | 1TB 预留 | 按需 mmap | 读者永不重新 mmap，零拷贝 |
| 分裂算法 | 07-31 | O(n+m) 归并 | O(n²) 先长再切 | 大批量插入性能 |
| CRC 实现 | 08-04 | ARM64 硬件 | 软件查表 | 内联汇编 crc32x，实测 23 倍快 |

---

## 给学习者的阅读路线图

想系统性读懂这份代码，建议按"演进顺序"读，别按"当前文件"读。这样能理解每个设计**为什么**是这样。

### 路线 A：跟编年史走（推荐）

1. **先读 v1 提交 `54d3d42`**：看最原始的 B 树和 store 接口，理解"起点"
   ```
   git show 54d3d42:src/btree.zig | head -100
   ```
2. **跳到 `717c2f9`**：看 v2 重写后的 btree.zig，对比理解 COW 的本质
3. **读 `docs/architecture.md`**（07-30 写的）：作者的官方设计文档
4. **读 `docs/tutorial/`**（8 章）：按 00-overview → 08-wrapup 顺序，初学者友好
5. **读 `format.zig`**：页面格式 + meta 双页 + CRC + 恢复，是格式的核心
6. **读 `writer.zig` 的 `applyBatch`**：commit 路径，理解"meta 切换 + fsync + 延迟回收"
7. **读 `file_page_store.zig`**：1TB mmap + ftruncate 增长 + meta 恢复
8. **读 `btree.zig` 的 `insertBatch`**：看 O(n+m) 归并和容量感知分裂

### 路线 B：按模块读（快速定位）

| 想理解 | 读这个文件 | 关键函数 |
|--------|-----------|---------|
| 公共 API | `db.zig` | `Db.open` / `put` / `get` / `beginWriteTxn` |
| 提交逻辑 | `writer.zig` | `State.applyBatch` |
| B 树 | `btree.zig` | `insert` / `insertBatch` / `getBorrowed` |
| 页面格式 | `format.zig` | `MetaPage` / `readMetaPage` / `PageHeader` |
| 文件存储 | `file_page_store.zig` | `init`（mmap）/ `vtWriteMeta` |
| 页面抽象 | `page_store.zig` | `PageStore` vtable / `MemPageStore` |
| 崩溃恢复 | `format.zig` | `readMetaPage`（双 meta + CRC + 序号） |
| 硬件 CRC | `crc32_hw.zig` | `crc32_hw` / 软件回退 |

### 路线 C：看测试学行为

测试是最好的活文档。按这个顺序看：

1. `tests/db_test.zig` —— 最基本的 put/get/delete/select
2. `tests/txn_test.zig` —— 显式事务的 commit/abort
3. `tests/mvcc_test.zig` —— 读不阻塞写、写不阻塞读
4. `tests/crash_recovery_test.zig` —— 崩溃后数据完整
5. `tests/putbatch_correctness_test.zig` —— 批量插入的正确性
6. `tests/fuzz/api_fuzz_test.zig` —— 随机操作对比 HashMap 参考模型

---

## 附：完整提交时间线（精简版）

```
07-22  第一纪 起源 (4)
        54d3d42 first version
        ff4a773 hide zio behind sync API
        97b877a remove dead coroutine code

07-23  第二纪 批量与读加速 (16)
        5d13612 + b83e1e4  benchmark + drop runtime
        5fb4724~eb59146    BTreeBatch (TDD)
        6097762            putBatch API (~1000x)
        b592414            group commit (~6.8x)
        b72502e            mmap 读 + skip-decode + no-CRC

07-24  第三纪 v2 大重写 (16)
        9619b31            zero-copy 读
        60a7c6f~9424b12    v2 七连击 (COW/freelist/MVCC/overflow/compact)
        5da8aa3            FilePageStore
        717c2f9            删 v1, rename v2 (+2024/-9579)

07-27  第四纪 LSM 岔路 (7)
        3beede5            LSM 层 (memtable/WAL/compactor)
        f1496bd            WAL pwrite 优化 (3.3x)
        3ba8933           WAL pwrite 基准数据
        320ec0a            fuzz 框架 (+2342/-1479)
        85d174f           Add benccmp (LMDB 对标工具)

07-30  第五纪 正本清源 (31)
        2cca3aa            删 LSM (-1437)
        f6017ee            1TB reserved mmap
        3830286            显式 WriteTxn/ReadTxn
        5d0382b            crash harness (fork+kill)
        57e18cd            COW 写优化 (4.2x)
        8010f02            zero-copy getBorrowed
        559a214            fix future error 静默丢弃
        2d1b69b            skip CRC 读 (12.7x)
        2c156c6            shared COW putBatch (619x!)

07-31  第六纪 基准与正确性 (22)
        32ff2a0            kill -9 crash recovery
        a8585ff            回归基线系统
        65d82cd            putBatch 溢出 bug 发现
        69db8ed            容量感知 split 修复
        28d49e1            O(n+m) 归并替代 O(n²)

08-03  第七纪 写路径收官 (16)
        dcce99a            staging arena 化
        b809c87            MemPageStore slab 页池
        25d529c            跳过 staging (4300→25 ns)
        c79b550            有序 fast path
        4ae1d65            终局 COMPARISON.md (算法层 parity)

08-04  第八纪 硬件加速 (2)
        42f1a05            ARM64 硬件 CRC32
        22c4e22            CRC32 Phase 2+3
```

---

## 结语：这个项目教会我们什么

回看 14 天 114 次提交，几条主线清清楚楚：

1. **先跑通再优化，先正确再性能**。v1 能跑就重写 v2；v2 正确了才追性能；性能追上了 putBatch 溢出 bug 反噬，回头补正确性。
2. **试错要快，砍要果断**。LSM 试了 3 天，发现不对立刻 −1437 行全删，不留死代码。
3. **度量驱动**。几乎每次性能优化都配基准 + 回归基线 + profiling 工具。没有度量的优化是盲飞。
4. **测试是护城河**。从 2 个测试长到 36 个，先写测试再优化（TDD），崩溃安全靠 fork+kill 真杀进程。
5. **分层认知要清醒**。算法层追平 LMDB（1.27x）后，作者把一度报告的 49× 差距自己修正成 2× 矩阵——49× 是 `page_allocator` 伪影，真实差距 1.9–2.6× 在 `insertBatch` 树操作，非 fsync 物理限制。

cube_db 的 14 天，是一部"如何从零写一个嵌入式 KV 引擎"的浓缩教材。读它的 git 历史，比读任何教科书都直观。

---

*本文档由 git 历史分析生成，数据截至 2026-08-04（HEAD: 22c4e22）。*

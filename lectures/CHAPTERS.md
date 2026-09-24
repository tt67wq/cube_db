# cube_db 详解讲义 — 章节目录（草案）

> 读者设定同纲要：会编程、不懂 KV 存储；每章配类比 + HTML/SVG 图解。
> 产出形式：`lectures/ch01-…html` … `ch08-…html` + `lectures/index.html`（目录页）。
> 每章预计 1~2 屏一节，读完一章 = 懂透一个机制。行号以当前 HEAD 为准，供定位用。

---

## 第 1 章 · 页与文件格式 —— 一切的宪法
**对应代码：`src/format.zig`（653 行，纯函数无 IO）**

- 1.1 为什么存储引擎从「页」开始：4KB 固定页、页号寻址，OS 块设备特性决定了这个粒度
- 1.2 一页的解剖图：24B PageHeader（类型/nkeys/序号）+ payload + 4B 尾部 CRC（L40, L74）
- 1.3 六种页类型逐个图解：FREE / META / BRANCH / LEAF / OVERFLOW / RANGE_TOMBSTONE（L9-17）
- 1.4 meta 页：数据库的总目录 —— MetaPage 字段逐个讲（根页号、freelist 头、sequence…），v2→v3 加 tomb_head 的兼容处理（L49, L28）
- 1.5 meta 的合法性判定：magic "CUB2"、双份互验、坏一份怎么办（isValidMeta / readMetaPage，L220-296）
- 1.6 校验和：CRC32 是什么、为什么放在页尾、整页自覆盖校验的巧妙处（computePageChecksum，L118）
- 1.7 freelist 页与 range-tombstone 页的编码格式：16B 定长 entry 头 + 变长 bound（L299-475）

## 第 2 章 · PageStore 抽象 —— 把「磁盘」变成可替换的插头
**对应代码：`src/page_store.zig`（261 行）+ 少量 Zig 语言补课**

- 2.1 Zig 没有 interface：手工 vtable 多态长什么样（ptr + VTable 函数表，L17-93）—— 本章兼作 Zig 语法补课
- 2.2 接口只切四刀：allocPage / freePage / readPage / writePage（+writeMeta），为什么这么多就够
- 2.3 MemPageStore：纯内存实现，给谁用、怎么用（测试与 fuzz 的地基，L95）
- 2.4 页号从 3 开始：NULL / meta0 / meta1 三个特殊席位（FIRST_DATA_PAGE）
- 2.5 分层收益复盘：同一个 btree 代码，一会儿跑内存一会儿跑文件 —— 动手小实验（读 tests 里一个用 MemPageStore 的测试）

## 第 3 章 · B-tree 读路径 —— 从根走到一片叶子
**对应代码：`src/btree.zig` 读侧（get/select/Iterator/编解码，约 L33-696, L2203-2500）**

- 3.1 树形与容量账：叶子 32 条 / 分支 64 叉（L12-15），百万 key 只要 3 层的算术
- 3.2 cmpKey：字节序比较，为什么 KV 引擎的 key 是「排序的字节串」而不是字符串
- 3.3 get 的一次旅程：meta→root→branch→leaf，配逐步图解（getChecked，L613）
- 3.4 叶子页 payload 编码：tombstone 位 + 变长 key/value 怎么塞进 4KB、怎么解码（encodeLeafPayload / decodeLeafPayload，L279-360）
- 3.5 大 value 的去处：MAX_INLINE_VALUE=3800，超了就挂 overflow 页链（L134；图解链结构）
- 3.6 select 范围扫描与 Iterator：定位起点后横向走叶子页；getInto 零拷贝变体为什么存在（L691, L2203-2488）
- 3.7 读时的 CRC 分档：off / sample(每64抽1) / full，性能与安全怎么权衡（L64-102）

## 第 4 章 · COW 写路径 —— 树怎么「改」而不「涂」
**对应代码：`src/btree.zig` 写侧（insert/insertBatch/apply，约 L104-2100）**

- 4.1 复习 COW + 本页目标：一次插入如何产生一串「新副本页」，旧页一页不碰
- 4.2 单条 insert 的路径复制：下行找叶子→复制→插入→父指针更新，dirty 页列表怎么收集（L1497）
- 4.3 页满了怎么办：split 分裂（LEAF_MIN/MIN_CHILDREN 半满规则），图解一次分裂
- 4.4 大 key / 大 value 的特殊账：MAX_KEY_SIZE 的推导、inlineValueBudget、超长时进 overflow 再分裂（L134-267）
- 4.5 insertBatch 批量应用：一万条 put 为什么比一万次 insert 便宜得多（L1569）
- 4.6 删除的真面目：单删写 tombstone 标记；deleteRange 写 range-tombstone 链页，扫描时才生效（为什么不物理删除）
- 4.7 写放大账本：一次提交碰几页？与 LSM-tree / 原地更新 B-tree 的一段对比（为什么本项目 ~1×）

## 第 5 章 · 事务与提交 —— 六步仪式逐步走
**对应代码：`src/db.zig`（门面+WriteTxn/ReadTxn）+ `src/writer.zig` 提交编排**

- 5.1 API 形状：beginWriteTxn→put/delete→commit/abort；单写者 Mutex 在哪、锁的是什么（db.zig L31-597）
- 5.2 staging：改动先进内存暂存区，key/value 立刻 dup 进 arena —— 为什么不直接动树（L598 注释）
- 5.3 put 走批（micro-batch）：MicroBatchConfig 怎么把多次 commit 合并摊薄 COW+fsync 开销（writer.zig L164）
- 5.4 commit 全程走查：publishSnapshot → 树应用 → freelist 持久化 → 交替写 meta + fsync（逐步图解，对纲要第 5 节的六步）
- 5.5 「原子」到底原子在哪：单页写 + 双 meta 乒乓；sequence 号怎么判新旧
- 5.6 持久性旋钮：Durability = process_crash / power_fail，Options{fsync}、Db.sync()、putDirect/deleteDirect 旁路（writer.zig L145；db.zig L179-201）
- 5.7 abort 与错误路径：提交前失败时那些 dirty 页去哪了

## 第 6 章 · MVCC 与页回收 —— 旧页什么时候才能死
**对应代码：`src/writer.zig` 的 Reader/PendingPage/水位线（L28-476）+ tests/get_mvcc_pin_test.zig 等**

- 6.1 问题引入：freelist 复用一个还有读者在看的页 = 读到新数据 = 数据错乱；构造一个具体时序
- 6.2 Reader 句柄 API：beginRead/endRead 返回显式 *Reader；T-30→T-32 的演化史（曾经用 thread-local 栈+64 槽猜身份）—— 好 API 的形状
- 6.3 snapshot/sequence 与最老活跃读者水位线：pending_free 的 release_seq 比较规则，为什么边界要保守（L28 注释逐句拆）
- 6.4 dirty page 持有与归还：commit 后旧页进 pending 队列、reader 退出后批量回 freelist 的完整生命周期图
- 6.5 读事务如何「钉住」快照：ReadTxn 里 pin 的注入点（select 惰性迭代时的 pages 保留）
- 6.6 多读者、慢读者与内存/空间放大：水位线被拖住时会发生什么（README: dirty pages held until readers drain）

## 第 7 章 · 落地到操作系统 —— mmap、freelist 链与文件锁
**对应代码：`src/file_page_store.zig`（1041 行）**

- 7.1 mmap 补课：内存映射是什么、MAP_SHARED、为什么读路径零拷贝（先给 OS 背景，零基础友好）
- 7.2 1TB 预留戏法：REGION_SIZE=1<<40 只占虚拟地址不占磁盘；文件 ftruncate 增长后旧指针直接可见、不用 remmap（L25；对读 spike_mmap.zig）
- 7.3 写路径：writePage 拷进 mmap、msync/fsync 时机与 durability 的联动
- 7.4 freelist 的工程实现：内存 pushPool/popPool + 落盘链页 persistChain/restoreFreeList，一内存一磁盘两视图图解（L434, L505）
- 7.5 单进程独占：flock 排他锁，两个进程同开一个 DB 会怎样（T-34 的 EWOULDBLOCK 处理）
- 7.6 崩溃注入钩子：CrashTag 枚举 + test_crash_hook 全局变量，测试怎么在指定步骤「模拟断电」（L137-150）—— 连接第 8 章

## 第 8 章 · 可靠性工程 —— 让「任何时刻断电都不坏」可被证明
**对应代码：`src/cube_check.zig` + `src/crc32_hw.zig` + `tests/` + docs/fuzz-testing.md**

- 8.1 校验和的性能账：ARM64 CRC32 硬件指令 vs 软件查表；为什么 x86 反而退回软件（SSE4.2 是不同多项式）（crc32_hw.zig）
- 8.2 读路径的抽查策略如何与写路径的 full 校验配合：谁在什么时候验哪页
- 8.3 cube_check scrub 工具：逐页验 CRC、ScrubReport、退出码契约 0/1/2（cube_check.zig 全文件，159 行可通读）
- 8.4 模型检验式 fuzz：随机操作序列跑 DB、和「内存里的 HashMap 参照物」对账 —— properties 测试思想入门
- 8.5 崩溃测试闭环：crash hook × fuzz，每个提交点断电都要通过恢复对账（举 1-2 个现成测试为例）
- 8.6 收尾自测：纲要第 9 节的三道题，现在能展开讲多少 —— 全书知识串联图

---

## 生产顺序建议

1→2→3→4→5→6→7 严格按依赖走（后面章节会引用前面的概念）；8 最后。
每章产出即挂到 index.html；若某章写到中途发现「该拆」（如 4.6 范围墓碑篇幅过大），当场拆成小节但不另开一章。

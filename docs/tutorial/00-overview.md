# 00 全景：cube_db 与两条路径

> 先看全貌，再钻数据流

---

## cube_db 是什么

cube_db 是一个用 Zig 0.16.0 编写的**嵌入式键值存储引擎**。它像 SQLite 那样嵌入到你的进程里，但只做 KV（键值）一件事：

- `put(key, value)` — 写入
- `get(key)` → value — 读取
- `delete(key)` — 删除
- `select(min, max)` → 范围遍历

数据存在**固定大小的页面**（默认 4KB）里。内部用 B-tree 组织这些页面。

**~2855 行 Zig 代码，82 个单元测试，零外部依赖**（除了本地 `zio` 协程库）。

---

## 两条数据路径

cube_db 有两条完全不同的数据写入路径：

### 1. Legacy COW B-tree（写时复制 B-tree）

每次 `put` 都：

1. 找到要改的页面
2. **复制它**（Copy-On-Write）
3. 改副本
4. 向上更新父节点指针

```
put("hello", "world")
  → 找到 hello 所在叶页
  → 复制叶页，写新值
  → 复制父页，更新指针
  → 复制祖父页，更新指针
  → ... 一直到根页
  → 写新 meta 页指向新根
```

**每写一条数据，要复制一整条页链**（O(log N) 页写放大）。

优点：实现简单，逻辑清晰。缺点：慢，449 µs/op。

### 2. LSM（Log-Structured Merge-tree）

每次 `put` 只做两件事：

1. **追加日志**：把操作写到磁盘 WAL（Write-Ahead Log），一条 `pwrite`
2. **写内存**：写到内存里的 `Memtable`（一个 HashMap）

```
put("hello", "world")
  → wal.append(.put, "hello", "world")   // 磁盘：单 pwrite ≈ 6.4 µs
  → mt.put("hello", "world")               // 内存：HashMap dupe ≈ 3.2 µs
                                           // 总共 ≈ 9.7 µs
```

**等 Memtable 满了，后台线程把它一次性灌进 B-tree**（Compaction）。

---

## 性能对比

数据来自项目 README（Apple M1 Pro，1000 次 ops，warmup 100）：

| 指标 | COW B-tree | LSM | Δ |
|------|:----------:|:---:|:-:|
| 单条 put 100B | 449.85 µs | **9.7 µs** | **46× 快** |
| 随机 get 100B | 34.91 µs | **2.5 µs** | **14× 快** |

LSM 把随机写变成了顺序追加（WAL）加内存写入，写放大从 O(log N) 降到 O(1)。

---

## 为什么本教程追 LSM 路径

三个理由：

1. **快**——46× 的写性能提升在 LSM 设计里，理解它才理解现代 KV 引擎
2. **概念丰富**——LSM 路径涵盖 WAL、memtable、compaction、并发控制、崩溃恢复。每个都是 KV 引擎的核心概念
3. **代码边界清晰**——LSM 模块（`db.zig` / `wal.zig` / `memtable.zig` / `compactor.zig`）独立于共享基础设施（`btree.zig` / `format.zig` / `page_store.zig`），适合按需下钻

---

## 路线图

```
01 基础概念（黑盒）   02 Open           03 Put
    page / B-tree     Db.open           wal.append + mt.put
    page_store / meta  灌 state + attach   + flush 信号
    
04 Get               05 Delete         06 Compaction
mt.get → btree.get    tombstone         后台线程灌 B-tree

07 Recovery          08 串联 + 动手改
wal.replay           完整数据流 + 4 个练习
```

每条路径从 `docs/tutorial/README.md` 的架构总图和数据流总图开始。

---

## 关键核真事实（读完本章应该记住）

- LSM 字段（`mt` / `wal` / `rwlock` / `compactor`）在 `Db.open` 里**不创建**——调用方 `open` 后手动 attach（`db.mt = &mt; db.wal = &wal;`）
- 两条路径在 `Db.put` / `Db.get` / `Db.delete` 里用 `if (self.mt)` 分流
- Compaction **复用 COW B-tree 的 `applyBatch`** 路径——LSM 和 COW 不是完全独立的

---

下一步：[01 基础概念黑盒](01-foundations.md)

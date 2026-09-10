# Issue T-38 — deleteRange 高效化：全量物化 + 每 key tombstone 的 O(range) 内存与写放大

- **状态**: proposed（演进点提案，待立项 TDD）
- **优先级**: **high**（可用性缺口 + 内存安全边界；4/4 worker 全部独立提出，共识度最高）
- **梯队**: 可用性/性能（兼正确性观感——文档承诺与实际行为差距）
- **来源**: 演进点征集（roadmap-evo）wf-pi-1-E1、wf-pi-2-E2、wf-pi-3-E3、wf-pi-4-E2
- **基线**: HEAD `4d7b1c8`（行号均基于此）
- **对应旧清单**: U-1（Range tombstone / 高效 deleteRange）——当前 HEAD 复核仍完全成立

---

## 摘要

`Db.deleteRange` 现实现 = flush → `select` 全量迭代 → **把范围内每个 key dupe 进堆上
ArrayList** → 构造等长 tombstone Entry 数组 → 整批 `putBatch`。删除一个 N key 的
范围 = 提交前 RAM 同时持有 N 个 key 拷贝 + 写入 N 条 tombstone（每条独立占叶空间，
直到被后续写入压实）。

- **内存峰值 O(range)**：删 5000 万 key 范围 = 5000 万 key 副本 + 5000 万 Entry 同时
  在内存，事实上会 OOM。
- **写放大 O(range) + O(N²)**：逐 key tombstone 把删除成本放大为写入成本；对同一范围
  反复 deleteRange 时 O(范围) 读 + O(在场 key) 写每次全款重付。
- **墓碑永不清理**（见 E-3 关联）：每个被删 key 永久占 ~key.len+10 字节，占满即叶裂变，
  又反哺 T-37 的深度增长。

**可用性缺口**：文档把 deleteRange 描述为常规 API（`docs/usage.md:233` 明示"内部基于
select 迭代器 + tombstone 批量提交实现"），但**没有披露 O(range) 内存峰值**——大范围
删除会 OOM，这属于"文档无法自圆其说"的行为差距。

## 现状 / 机制佐证

- `src/db.zig:222-250`：`deleteRange` = flush + select 全扫 + `allocator.dupe` keys
  （`:242`）+ 逐 key tombstone 数组 + 整批 putBatch（`:248`）
- `src/db.zig:231-243`：keys ArrayList 无界 dupe + entries 同长分配，两份 O(range) 内存
- `src/db.zig:245-249`：整批 tombstone 走 putBatch → COW 重写受影响叶页链，范围越大写的页越多
- `src/btree.zig:257` `encodeLeafPayload` 写 tombstone 标志，无任何丢弃分支
- `src/btree.zig:817-1008` `insertIntoLeaf` 合并重写时 tombstone 原样保留
- `src/btree.zig` 叶/分支编码目前只有 entry 一种叶子形态，没有区间墓碑节点类型
- `docs/usage.md:233`（deleteRange 语义）/ `:316`（compact 只切 meta，不重写数据）

## 建议演进方向

- **Range tombstone（区间墓碑）**：删除时在树上挂 `[min,max)` 墓碑节点，读取/迭代时做
  遮蔽判断，压缩/合并时再物化清除，把大范围删除从 O(range) 降到 O(log n + 墓碑数)；
- 格式扩展可走 `f2.MetaPage.version` 位平滑升级（wf-pi-3 指出）；
- 墓碑 GC 需配合真·compact（见 T-38 关联的 U-5）才有完整收敛出口。

## 可测验收判据（RED→GREEN）

- (a) 1000 万 key 库上 `deleteRange(null,null)` 在有界内存（如 ≤64MB）内完成且耗时不随
  range 线性增长（用分配计数断言峰值内存 ≤ O(batch)）；
- (b) 删除后 `select` 迭代不返回已删 key、`entryCount` 精确；范围删除后
  `entryCount`/select 结果/点读三口径一致；
- (c) 墓碑与并发 staging/flush 交错（复用 `tests/staging_concurrent_test.zig` 场景）
  语义不变；重启后墓碑遮蔽语义保持；
- (d) 同范围反复 deleteRange K 次后，页数/tombstone 行数不随 K 线性增长。

## 关联

- 与 T-37 交互：deleteRange 的 tombstone 批次是推动树高增长的小批量提交源之一；
  墓碑积压放大 merged 集合尺寸，间接加速加深。
- 墓碑 GC 依赖真·compact（U-5，wf-pi-4-E3）才完整；可并立项或在 T-38 内给出收敛出口。

## 状态跟踪

- [x] 现状核验（4 worker 独立确认 U-1 在当前 HEAD 成立）
- [ ] 确定性 RED 测试（大范围删除内存/性能断言）
- [ ] 根因定位与修复（GREEN：range tombstone + 墓碑 GC）
- [ ] 回归测试 + 评审
- [ ] 验收门稳定后关闭

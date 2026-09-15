# T-38-P probe report — 区间墓碑（Range Tombstone）方案可行性

- **任务**: T-38-P（探路/设计，方法 C）
- **作者**: cube_db-pi-1（worktree cube-db-pi-1-rebuilt，基线 main `4e69f8a`）
- **设计文档**: `docs/design/T-38-range-tombstone-probe.md`（契约「须回答」全条目）
- **探针**: `spike/rangetomb_probe.zig`（自包含，**未改任何 src/ 生产代码**）
- **日期**: 2026-09-16

## 1. 探针运行命令与真实输出

```
$ zig build test-rangetomb-probe --summary all
Build Summary: 4/4 steps succeeded; 5/5 tests passed
test-rangetomb-probe success
+- run test 5 pass (5 total) 54ms MaxRSS:3M
   +- compile test Debug native cached 137ms MaxRSS:31M
      +- options cached
$ echo $?
0
```

确定性：无 RNG、无时间依赖、无并发；断言全部固定输入。重复运行结果一致
（`zig build` 缓存命中与冷跑均验证）。

探针覆盖（5 个测试 ↔ 设计文档 §9【实测】行）：

| # | 测试 | 验证内容（设计章节） |
|---|---|---|
| 1 | 墓碑页 round-trip + CRC 损坏检测 | §1.2/§1.4 字节布局（头/gen/nkeys/链）、变长键区、§5.1 CRC 翻转必报 `CorruptCrc` |
| 2 | 遮蔽判定边界 | §3.3：min 含 / max 不含 / 空区间 / 倒置 / 全区间 (null,null) / 单侧 / bytewise 前缀键序 |
| 3 | 共存优先级 + put 打洞 | §3.2 INV-RT1、§4.3 字典序后继 k+0x00 分裂、MAX_KEY_SIZE 后继超长边界（右段放弃） |
| 4 | v2↔v3 meta 升级/降级 demo | §2：v3 round-trip、新代码读 v2→tomb_head=0、旧 isValidMeta 干净拒绝 v3、双槽 sequence 取高无混合态、torn 反向（v2 高 seq）降级读安全 |
| 5 | 多页链 + 容量核对 | §1.2/§1.4：三页链 round-trip（free_next 链、跨界条目、seq）、每页容量 ≥155 条（1B 键）/ ≥101 条（8B 键）实测核对 |

附带回归确认：`zig build test --summary all` →
`Build Summary: 34/34 steps succeeded; 436/437 tests passed (1 skipped)`
（基线即此数——src/ 零改动，无回归）。

## 2. 结论：方案 A（区间墓碑）**有条件可行**

条件（全部为工程量而非可行性障碍）：

1. **meta version 2→3 单向升级**：v3 库对旧二进制干净拒绝（探针 4c 实测）。
   要求部署纪律：升级后不得回滚二进制。备份/迁移工具需同步升 version 判定。
2. **写路径纪律 INV-RT1**：put 打洞（探针 3 实测的 k+0x00 字典序后继分裂）
   必须在写路径强制维护，读路径才能用纯空间判定（无逐 entry 时间戳）。
   这是改动面最大的部分：`applyBatch`/`WriteTxn.put` 需在提交前扫墓碑链
   （O(T)，T=墓碑数）打洞。
3. **entryCount 精确性**：deleteRange 仍需 O(range) 一次**流式**读来修正
   entry_count/byte_size（内存 O(1)，CPU O(range)）——issue 验收 (a) 的
   内存目标达成，但「耗时不随 range 线性增长」的**时间**目标只部分达成
   （见设计 §4.1 步骤 3）。若验收要求时间也 O(log n)，需接受
   entryCount 变为近似值（上界），另议。
4. **GC 至少做水位收割**（设计 §6）：无 compact 的完整物化清除时，
   「删除后再写回」的区间墓碑会积累；交叠合并 + 空区间收割可保 T 有界。

## 3. 与方案 B（流式分块）对比

方案 B = 现有物化路径分块化：select 流式迭代，按块（如 10k key）构造
tombstone 批并 putBatch，循环到尾。**不改格式**，改动只在 db.zig。

| 维度 | A 区间墓碑 | B 流式分块 |
|---|---|---|
| 内存峰值 | **O(墓碑数)**（≈0） | **O(chunk)**（10k key 级，可配） |
| 写放大 | **O(墓碑页)**（每次 deleteRange 重写 T 页 + meta） | O(range)（每 key 一条墓碑，不变） |
| 同范围反复删（验收 d） | ✅ K 次不增长（等价墓碑幂等） | ❌ 每次全款重付 |
| 叶空间/树高（T-37/T-44） | ✅ deleteRange 零叶写入 | ❌ 墓碑占叶空间推动裂变 |
| 格式风险 | ⚠️ version 3 + 新页 kind + 崩溃模型论证 | ✅ 零格式改动 |
| 实现量 | 大（format/writer/db/迭代器 + GC + 版本迁移） | 小（db.zig 一个函数） |
| 语义风险 | INV-RT1 写路径纪律（漏打洞=数据复活类 bug） | 低（同现有语义） |

**判断**：B 是低风险的**立即止血**（OOM 消除），但不解决写放大/墓碑积压/
树高三连；A 是根治但工程量大且引入格式版本。**推荐 A+B 组合分阶段**（下节）。

## 4. 推荐落地路径（分阶段）

- **阶段 0（独立小任务，可先行）**：方案 B 流式分块（db.zig deleteRange 重写，
  分块 putBatch；~50 行 + 回归测试）。立即消除 OOM。T-38 验收 (a) 内存项达成。
- **阶段 1（T-38 主体 A）**：格式层——`PAGE_TYPE_RANGE_TOMBSTONE=5` 页
  codec + `MetaPage.tomb_head` + version 3 判定（探针代码可直接迁移为
  src/format.zig 实现 + 单测）。
- **阶段 2**：读路径——get/select 遮蔽判定（点查二分 + 迭代器整叶剪枝）；
  entryCount 流式修正。
- **阶段 3**：写路径——deleteRange 写墓碑链 + put 打洞（INV-RT1）+
  交叠合并 + 旧链 pending_free 回收；micro-batch flush 语义保持。
- **阶段 4**：GC——水位收割（空区间丢弃）+ crash 测试矩阵扩展
  （T6/T7 家族加墓碑 commit 场景）；物化清除挂 U-5 真·compact。
- 每阶段独立 TDD + 独立评审；阶段 2 起需要并发的 staging 交错测试（验收 c）。

## 5. 未验证 / 存疑（如实）

| 项 | 状态与理由 |
|---|---|
| Db 级端到端（deleteRange→重启→遮蔽保持） | 【未实测】需改 db.zig/writer.zig——探路阶段禁改 src/；模型论证见设计 §4/§5 |
| 并发 staging/flush 交错（验收 c） | 【未实测】同上；write_mutex 串行化论证见设计 §4.2 |
| FilePageStore meta 扩字段 torn 行为 | 【未实测】需改 format/file_page_store；模型论证见设计 §5.1/§2（探针 4f 模拟了 v2/v3 双槽取高） |
| 墓碑链实际增长曲线 | 【未实测】理论上界 T ≤ 不同区间数（设计 §6）；建议阶段 3 带基准测试 |
| get 遮蔽判定的性能开销（每次 get O(log T) 链扫描） | 【未实测】T 小（合并后有界）时可忽略；缓存策略（内存热墓碑集）留待阶段 2 |
| punchHole 的 succ(k) 语义在「k 是另一 key 前缀」时的正确性 | 【实测】（探针 3：k="b" 打洞后 "b\0" 仍被右段遮蔽）——正确 |
| issue 验收 (a) 的「耗时不随 range 线性增长」 | 【部分达成】时间仍 O(range)（entryCount 修正），内存 O(1)；见 §2 条件 3 |

## 6. 附：与 T-46 的串行隔离确认

本任务零改动 `src/**`（`git diff --stat` 仅 build.zig / spike/ / docs/ /
.agents/tasks/T-38-P/）。T-46 可并行进行，无路径冲突。

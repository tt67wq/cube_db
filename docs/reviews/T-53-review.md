# T-53 评审报告 — 开库路径区分「invalid meta」与「fresh DB」（关闭 T-49 + T-50）

- **评审者**：pi-2（review，作者独立性：≠ impl pi-1 ≠ test pi-3）
- **测试者**：pi-3（test，独立对抗性验证；作者独立性同上）
- **被评审 SHA**：`1c6ce1d`（GREEN）= `fb492ea`（RED，conductor 编写）+ `1c6ce1d`（实现，pi-1）
- **基线**：`b8a4250`
- **verdict**：**approve**（review Blocking 0 / Non-blocking 3）；**PASS**（test，11 条对抗用例全绿，无可判定缺陷）
- **三方多签**：impl pi-1（自测绿灯）+ review pi-2（approve）+ test pi-3（PASS）+ conductor 终签

---

## 一、任务与根因

T-49 与 T-50 是**同一根因的对偶**，故合并为一个任务（T-53）：

- **T-49**（high，数据破坏面）：**旧**代码读 v3 库 → `readMetaPageSingle` 判 `isValidMetaAny`
  失败返回 `null` → `Db.open` / `FilePageStore.init` 把 `null` 当「未曾初始化」
  → 打开成功、`entryCount=0` → 后续写入从 `FIRST_DATA_PAGE` 起分配，**覆盖既有 v3 数据页**。
- **T-50**（medium，v4 出现时升 high）：**新**代码读未来版本（v4 / 坏 magic）→ 同一个
  `null` → 同样静默当空库。

**共同根因**：`null` 在 format 层同时承载「认不出」（错误）与「没有」（空库）两种语义；
下游一律解释为后者。

---

## 二、实现（`1c6ce1d`，4 个允许文件）

```
 src/format.zig                                | 31 +++++++++++++++++++++++++++----
 src/db.zig                                    | 13 ++++++++++++-
 src/file_page_store.zig                       | 14 ++++++++++++++
 docs/design/T-38-range-tombstone-probe.md     |  4 ++--
```

1. **`format.zig`** — 新增 `isInvalidMetaPage(page)`：槽页**CRC 合法** + `page_type==META`
   + `!isValidMetaAny`（magic 非 MAGIC_V2 或 version ∉ {2,3}）→ 判为 invalid。
   `readMetaPage` 签名由 `?MetaPage` 改为 `!?MetaPage`，首行
   `if (isInvalidMetaPage(page0) or isInvalidMetaPage(page1)) return error.InvalidMeta;`。
   判据与既有 `readMetaPageSingle` **互补无第四组合**（后者需 CRC→type→magic/version 三关全过）。
2. **`db.zig`** — `Db.open` 的 `if (try store.readMeta()) |meta|` 裸传 typed error；
   新增 `errdefer allocator.destroy(state)` 覆盖两条错误路径（`State.init` 零堆分配）。
3. **`file_page_store.zig`** — 新增 `invalid_meta` 诊断标志（init 记录、后续只读），
   与既有 `free_list_discarded` 同款模式；init 本身**不致命**（硬门在 `Db.open`）。
4. **文档** — `docs/design/T-38-range-tombstone-probe.md` §2 行 2 更正为
   「静默按空库打开并覆盖数据」，并写明「**回滚不是『用不了』，而是『静默毁数据』**」。

---

## 三、实测（两位独立验证者亲跑，均在 `1c6ce1d`）

```
$ zig build test-openmeta --summary all      # 主验收
Build Summary: 4/4 steps succeeded; 9/9 tests passed

$ zig build test-rangetomb-read --summary all
Build Summary: 4/4 steps succeeded; 15/15 tests passed

$ zig build test-tombguard --summary all
Build Summary: 4/4 steps succeeded; 2/2 tests passed

$ zig build test --summary all               # 全量
Build Summary: 40/40 steps succeeded; 462/463 tests passed (1 skipped)   # exit 0（worktree）
Build Summary: 40/40 steps succeeded; 463/463 tests passed              # exit 0（main 检出目录）
```

- **RED 独立复跑**（pi-2 checkout `fb492ea`）：`4/9 passed, 5 failed` ——
  a1/a2/a3/a4/a6 失败（invalid meta 被当空库接受），a5/a7/a8/a9 通过。
  与 conductor 记录的 RED 状态**逐用例一致**。
- **1 skip 为既有环境跳过**（`cube_check_test.zig` 需 `zig-out/bin/cube_check`，
  worktree 未构建该二进制），非回归；main 检出目录跑则无 skip。见 `issues/README.md` §4.2。

---

## 四、review 必查项逐条结论（pi-2，10 条全 ✅）

| # | 必查项 | 结论 |
|---|---|---|
| 1 | 三态（fresh/valid/invalid）真的分清 | ✅ 判据互补无第四组合；typed error 全链裸传 |
| 2 | T-49 数据页不可能被覆盖 | ✅ 拒绝点 `db.zig:79` 在一切写路径之前；a4/a5 + 探针 PE 零破坏实证 |
| 3 | T-50 通用性（不只拦 v3） | ✅ `!isValidMetaAny` 结构性拦截，与版本号无关（v4/v1/坏 magic/未来版本） |
| 4 | fresh 误杀 | ✅ 三关严格串联，非宽松判定；双槽全 torn → fresh（旧行为零变化） |
| 5 | `isInvalidMetaPage` 判据稳健性 | ✅ 随机损坏先坏 CRC → torn 路径；正常 torn 不被误判 invalid |
| 6 | `readMetaPage` 签名变更副作用 | ✅ vtable 本就 `anyerror!?MetaPage`，零签名改动天然穿透 |
| 7 | 零磁盘格式改动 | ✅ 编码原语/版本号零触碰；老库照常读写 |
| 8 | FPS `invalid_meta` 绕过路径 | ✅ 可接受：仓库无「不经 Db.open 的写入方」；`invalid_meta` 提供检测面 |
| 9 | 资源清理 | ✅ `errdefer destroy(state)` 与 `State.init` 零堆分配相符；无漏 free/double free |
| 10 | 文档更正与代码一致 | ✅ 措辞准确，如实记录残余回滚风险 |

---

## 五、独立对抗性探针（review PA–PG 7/7 + test adv1–adv8 11/11，全绿）

**pi-2 探针（PA–PG，跑毕删除）**

| 探针 | 内容 | 结果 |
|---|---|---|
| PA | 单槽 invalid 三形状（两种排列 + 另一槽全零）→ 全部整体拒绝 | ✅ |
| PB | torn 容错：单 torn+单 valid 照开；双 torn → fresh | ✅ |
| PC | 随机损坏 → CRC 先失败 → torn 路径不误拒 | ✅ |
| PD | CRC 合法非 META 页（LEAF）→ null 路径非 invalid | ✅ |
| PE | FPS `invalid_meta` 三态 + 拒绝后 meta 恢复即库可用（零破坏可恢复） | ✅ |
| PF | FPS v2 真实 writer 落盘往返 | ✅ |
| PG | typed error 值 = `error.InvalidMeta`（Mem/FPS/format 三点） | ✅ |

**pi-3 对抗用例（adv1–adv8，11 个 test）**

- **adv1** T-49 核心圆桌：v2 库真实数据页 + 双槽落盘改 v4/v5/v65535/v0/v1 + 4 个坏 magic
  → **全部拒绝**（均 `error.InvalidMeta`）、**拒绝前后逐字节相同**、改回原 meta 后**数据完好**。
- **adv2** v3 源库圆桌：v3 合法版本不被误拒，墓碑语义完好，拒绝路径不伤墓碑页。
- **adv3** T-50 泛化全扫：`version × magic` **30 组合全部拒绝**。
- **adv4** fresh/torn 边界：双槽全零照开；双槽 torn 照开（fresh 语义）；单槽 torn + 单槽 valid 兜底。
- **adv5** 混合槽（合法 + 非法，两种排列）→ **整体拒绝**（比契约最低要求更严，语义有据）。
- **adv6** 误判面：CRC 合法随机内容 → 安全方向拒绝（撞中概率 ~2⁻³²）；非 META 页 → null 路径。
- **adv7** 绕过路径：`FilePageStore.init` 不失败但 `invalid_meta=true`；
  `store().readMeta()` **在 store 层即报 `error.InvalidMeta`**（门不止在 Db）。
- **adv8** page_no 不匹配不被校验（既有行为，T-53 未改变，非回归）。

---

## 六、Non-blocking 观察（不阻塞，登记备查）

| # | 来源 | 内容 | 处置 |
|---|---|---|---|
| N-1 | review | a5 在 RED 期即通过（RED 期 v4 被当 fresh 打开后 open/close 不写盘，字节不变）；其真实守卫价值在 GREEN 期与未来回归 | 无需动作（测试设计事实记录） |
| N-2 | review | `cube_check.zig` 对 invalid 文件现报 `error.InvalidMeta` 而非 `NoMeta`——更准确，impl 已声明 | 后续可让 cube_check 错误信息区分三态 |
| N-3 | review | 「任一 invalid 槽即整体拒绝」对「升级中途双写者」形状是保守选择（沿旧槽继续 = 静默回退旧状态） | 阶段 3 若引入在线升级需重审 |
| **R1** | test | **torn 方向仍通**：双槽 torn（或单提交库唯一持有槽 torn）→ 当 fresh 打开 → 写入从 `FIRST_DATA_PAGE` 起可覆盖旧数据页 | **已立 T-53 issue（open）**，见下 |
| R2 | test | 硬门在 `Db.open`；绕过 Db 直接用 FPS 原始写接口仍可覆盖 v4 库 | 设计取舍，impl 注释已声明，接受 |
| R3 | test | meta 槽 `page_no` 与槽号不匹配不被校验（既有行为，低危） | 已并入 T-53 issue 的关联说明 |

**R1 说明**：T-49 的破坏面在「invalid meta」上已关死，但「torn」方向仍通。
理由：torn 无法与「未初始化」区分，且交替槽保证单次 crash 至多坏一槽
（双 torn 需双重蓄意损坏）。契约明确 torn 走 null 路径。建议阶段 3 或独立任务
考虑「文件 > `FIRST_DATA_PAGE` 且双槽皆 null」时告警/拒绝（heuristic，有误伤空文件边缘）。

---

## 七、Ownership 核对

- `1c6ce1d` 恰好触碰 4 个允许路径；**禁改文件零触碰**（逐文件验证）：
  `cube_check.zig`、`btree.zig`、`writer.zig`、`page_store.zig`、`tests/` 全部 = 0 行。
- `tests/` 变更全部归属 conductor 的 RED commit `fb492ea`
  （RED 测试新增 + 2 处既有测试调用点的 `try` 适配 + 2 处 fixture 修正）。
- `713999d`（impl worktree GREEN）与 `1c6ce1d` 的 **src + docs 字节一致**（diff 0 行）。

---

## 八、结论

三态区分判据严谨且与既有 `readMetaPageSingle` 互补；typed error 全链裸传
（vtable 零改动天然穿透）；**拒绝先于一切写入且零破坏可恢复**；torn / 随机损坏 /
非 META 页三类边界零误杀零误拒；fresh 与 v2/v3 行为零变化；资源清理完备；
ownership 完全合规；文档更正准确并如实记录残余回滚风险。

**RED 4/9 → GREEN 9/9 独立复跑确认。approve + PASS，三方多签齐备。**

**残余风险（转 T-53 issue）**：torn 方向仍可被当 fresh 打开 → 潜在覆盖（R1）。

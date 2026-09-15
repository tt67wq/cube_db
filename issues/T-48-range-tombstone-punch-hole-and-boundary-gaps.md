# Issue T-48 — 区间墓碑方案的两个设计缺口：打洞右段复活（F1）、近-MAX 边界不可表示（F2）

- **状态**: closed（2026-09-15，返工 + 独立评审通过并合入 main；N-R1 转阶段 1 跟进）
- **优先级**: high（属 T-38「区间墓碑」方案 A 的**可行性前提**；照当前设计实现会引入静默数据复活）
- **来源**: T-38-P 独立评审（cube_db-pi-2，`.agents/tasks/T-38-P/review.md`）
  + conductor 独立复算确认
- **关联**: `spike/rangetomb_probe.zig`、`docs/design/T-38-range-tombstone-probe.md`、
  母 issue `issues/T-38-deleteRange-efficient-range-tombstone.md`
- **时间戳**: 2026-09-15

## 背景

T-38-P（commit `5764fbb`）交付了区间墓碑方案（方法 C）的设计文档 + 可运行探针
（5/5 绿、零 `src/` 改动）。评审结论为 **REQUEST_CHANGES**：**不否定方案 A 可行性**，
但交付物里有两处设计缺口被探针「实测到了却论证错了」。

conductor 未采信评审单方说法，用一次性 scratch 探针（只读依赖 cube_db，用完已删）
独立复算，两个缺口**均成立**：

```
[F2] PAGE_SIZE=4096 HDR=24 PAYLOAD=4068 TOMB_HDR=24 MAX_KEY_SIZE=4051
[F2] 单条墓碑变长预算 = 4042B（含 min+max）
[F2] 墓碑 [m×4050, "z") 需要 4077B > 4068B → overflow = true
[F2] succ(k) 长度 4052B 需要 4078B → overflow = true
[F1] punchHole(k='q'×4051) 后右段存在 = false；活 entry "r" 仍被遮蔽 = false
```

## F1 — `punchHole` 右段「放弃」= 数据复活，且被探针断言固化为预期

**位置**：`spike/rangetomb_probe.zig` `punchHole`（约 :170-190 注释）、探针 3 第三段
（约 :373-385）；设计 §4.3。

`punchHole` 只在 `k.len + 1 <= MAX_KEY_SIZE` 时建立右段 `[succ(k), t.max)`，否则
走「右段放弃」分支，注释声称「由后续 deleteRange 重新建碑覆盖」。

**论证是错的**：右段覆盖的是**墓碑建立前就存在、并被那次 deleteRange 删掉的活
entry**。放弃右段 = 这批 key 复活。只有 `k` 是最大可表示键（全 0xFF 尾）时右段
才真空、放弃才安全；一般情形（如 k='q'×4051，(k,"z") 内仍有大量可表示键）不成立。

**更严重的次生问题**：探针 3 第三段恰好命中该分支，却把「右段被丢弃」断言为
**预期行为**（`punched3.items.len == 1`）——等于把 bug 写成契约。阶段 3 若照此实现
= 近-MAX key 场景静默数据复活，且「探针已验证安全」会成为未来实现的错误背书。

**复活反例（评审者临时实验实测，可复现）**：
```
put "r"(seq1) → deleteRange ["a","z")(seq2) → put big='q'×4051(seq3) → punchHole
断言 shadowed(punched, "r")  →  失败（"r" 被复活）
```

## F2 — 墓碑页装不下近 `MAX_KEY_SIZE` 的边界（格式可表示性缺口）

**位置**：`spike/rangetomb_probe.zig:73-74`（`TombPageOverflow` 判定）；设计 §1.2。

变长区预算 = `TOMB_PAYLOAD`(4068) − 2 − `TOMB_HDR`(24) = **4042B < `MAX_KEY_SIZE`(4051)**。
单条墓碑一个 4050B 边界就装不下；而 `deleteRange` 接受最长 4051B 的用户 key，
`punchHole` 的 `succ(k)` 需要 4052B（实测 `TombPageOverflow`）。

设计 §1.2/§1.4 与报告条件清单**均未提及**——属**设计层可行性缺口**，
阶段 1 若照探针 codec 迁移进 `src/` 即埋雷。

## FR-1 — conductor 追加发现：探针释放计数错误

`spike/rangetomb_probe.zig` 探针 3 第三段走「右段放弃」分支时**零 `succ` 分配**，
但释放调用 `freePunchedMins(punched3.items, 1)` 传计数 **1**。当前实现恰好不炸
（传 1 只释放匹配项），F1 修好后会变成误释放/漏释放。需修正计数语义或消除该
易错参数。

## 影响

- **不影响当前生产代码**：探针与设计文档均未进 `src/`，零 `src/` 改动。
- **影响方案 A 的可行性结论边界**：方案 A 仍然可行，但「近-MAX key 的
  deleteRange」这一真实用户场景必须先在格式层（F2）与写路径语义层（F1）闭环，
  否则不能进入实现阶段。

## 修复方向

- 已派 **T-38-P-R** 给 cube_db-pi-2（原始评审者，省一次交叉理解成本），
  返工范围：设计 §1.2/§4.3 + 探针注释/断言修正（F1）、边界可表示性分析与修复
  方向（F2）、释放计数（FR-1）、条件清单与 §5 未验证表补两项。
- 返工后**无需重跑探路**（可行性结论方向不变），文档级复审即可。
- 方案 B（流式分块）不受本 issue 阻塞，已另立 **T-38-B** 先行落地止血。

## 状态跟踪

- [x] 独立评审发现（pi-2）
- [x] conductor 独立复算确认
- [x] 立项 + 派发返工（T-38-P-R → pi-2）
- [x] 返工交付（`c4af657`，rebase 后 `21d6c8b`）+ 复审通过
- [x] 条件清单闭环 — 方案 A 可进入实现阶段（阶段 1 起）

## 验收记录（2026-09-15）

- **返工实现**：cube_db-pi-2，commit `c4af657`
  （`docs(T-38-P-R): 修正打洞右段复活论证 + 边界可表示性（附 RED 用例）`）。
  返工后 rebase 到 main 得 `21d6c8b`（内容经 `git diff` 校验与评审对象
  **字节一致**，且 `spike/`、`docs/design/` 零 `src/` 改动）。
- **F1 修复方式**：墓碑边界改为 `Bound{bytes, append_zero}`，`succ(k)=k++0x00`
  用 bit31 标志紧凑表示（存原键长）→ **右段恒可建**；原「近-MAX 时丢弃右段」
  的错误论证与错误断言（`punched3.items.len == 1` 把 bug 当预期）彻底移除，
  改为**复活反例 RED 用例**（`shadowed(punched, "r")` 必须为真）。
- **F2 修复方式**：条头 24B→16B（seq 从页 gen 继承），单边界上界
  4068−16 = **4052 ≥ MAX_KEY_SIZE(4051)** 自洽；双长边界以 typed
  `error.TombBoundTooLarge` 显式拒绝而非静默溢出。
- **FR-1**：`freePunchedMins` 计数释放接口**连根删除**（punchHole 改为零堆分配），
  不是换成另一个易错形态。
- **独立评审**（cube_db-pi-1，评审者 ≠ 返工者；且 pi-1 是 T-38-P 原实现者，
  须自行确认原论证确实错了）：结论 **APPROVE**
  （`.agents/tasks/T-38-P-R/review.md`）。评审自构造**更难的嵌套打洞反例**
  （REV-X1：对 append_zero 边界为 min 的墓碑再次打洞）验证不复活；对新比较器
  做 **6000 组固定种子交叉验证**（`boundCmpKey`/`boundCmpBound` 与物化
  `cmpKey` 全序一致，零 MISMATCH）。
- **整合**：conductor rebase 到 main → ff-merge，全量 `zig build test` =
  **34/34 steps，437/437 passed**。

### 评审新发现（非阻塞，转阶段 1 跟进）：N-R1 空 plain 边界编码折叠

`Bound{bytes="", append_zero=false}`（非 null、空、无标志）编码为 len=0 无标志，
解码时**折叠成 null（unbounded）**。危害：空区间墓碑 `[m, "")` 若进编码器，
max 折叠为 null → 解码后变**全区间墓碑**（遮蔽一切，数据丢失方向）。

- 基线 `5764fbb` 即存在，非返工引入；返工设计 §1.2 已明示该折叠语义；
- 唯一能产出该形状的路径是空区间 `deleteRange`，写路径本应在建碑前过滤；
- **处理决定**：记入本 issue 作为**阶段 1 落地前必须补**的两项 ——
  ① 设计文档增补写路径不变量「空区间/空 plain 边界墓碑不得进入编码器」；
  ② 编码器对 empty-plain `max` 做 typed 拒绝（同 `TombBoundTooLarge` 风格），
  把静默折叠变成显式错误。当前 spike 层面不阻塞。

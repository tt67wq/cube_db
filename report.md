# T-58 Report — key 尺寸入口校验与 btree 实际容量对齐（复验 + 边界锁死）

- **分支**: `t58-keysize`（基于 main `d490c1c`）
- **结论**: **GREEN** —— check.sh 6/6 PASS（gate rc=0，双平台）；**核心复验结论：issue 的
  不一致在当前 main 上已不存在**（N-1 已闭合），无 src/ 改动；交付 = 复验证据 +
  ±1 边界回归锁死 + mutation 验证 + usage.md 真值
- **src/ 改动**: **0**（白名单内零 diff；理由见「两案择一」）
- **改动面**: `tests/txn_writer_db/t58_keysize_test.zig`（新，4 用例）+ `docs/usage.md` §3.3 + `.agents/tasks/T-58/check.sh` 入库（git add -f，gate4 验收项）

## 1. 复验（立项数字必须实测——issue 数字过期）

实测扫描（MemPageStore，k∈[4020,4070] 逐长度独立建库 putDirect / staged，四 value 剖面）：

| value 剖面 | last_ok | 首个错误 | 错误点 |
|---|---|---|---|
| empty（0B） | **4051** | KeyTooLarge @4052 | 入口 |
| "v"（1B） | **4051** | KeyTooLarge @4052 | 入口 |
| "x"×100 | **4051** | KeyTooLarge @4052 | 入口 |
| "x"×5000（溢出链） | **4051** | KeyTooLarge @4052 | 入口 |
| staged "v"（put+flush） | **4051** | KeyTooLarge @4052 | 入口 |

**当前真实上界 = 4051 可写 / 4052 入口 `KeyTooLarge`**——与 `MAX_KEY_SIZE` 的推导
精确一致，入口校验就是首个报错点，**不存在 issue 声称的「4044 可写 / 4045
commit 期 PayloadTooLarge」**（四剖面 + staged 路径均不复现）。

## 2. 「7 字节」构成拆解（逐项对 src/btree.zig，非猜）

`MAX_KEY_SIZE`（btree.zig:173）= `NODE_PAYLOAD_CAP(4068 = PAGE_SIZE 4096 −
页头 24 − 尾 CRC 4)` − 叶头 **3**（encodeLeafPayload：kind 1 + nkeys 2）− 单
entry 最小编码 **14**（tombstone 1 + klen 4 + vlen 4 + flags 1 + 溢出页号 4，
btree.zig:268-277 leafPayloadSize）= **4051**。假设链的最后一环「value 恒可逃
逸到溢出链（叶内仅占 4B 页号）」由 N-1 的组合感知 `inlineValueBudget` 保证
（btree.zig:147-159：key+value 组合超页预算时无论 value 多小都走溢出链）。

**issue 的 7 字节差 = vlen(11) − 溢出指针(4)**，是 **N-1（6d1d318，9-15）之前**
的旧行为：旧判定 value ≤ 3800 一律内联，vlen=11 的 value 在 k=4045 时叶
payload = 3+10+4045+11 = 4069 > 4068 → commit 期 `PayloadTooLarge`；k=4044
时恰 4068 = cap → 可写。**4044/4045 与 issue 数字精确吻合**——tester 的实测
跑在 pre-N-1 基线上（T-57 分支基线早于 9-15），issue 立项（9-20）引用了过期
数字。N-1 的 RED 测试文件（tests/n1_composite_overflow_test.zig 头注与 #8 系列
用例）独立佐证了这一机制与时间线。

## 3. 两案择一 → **两案都不需要**（理由）

- 案 1（收紧 checkKeySize 到实际可写上限）：实际可写上限**就是** 4051 =
  `MAX_KEY_SIZE`，checkKeySize 无需收紧；
- 案 2（入口校验计入 btree 固定开销）：同理已计入（推导即此构成）。

强行改 src 只会是保守多杀（违反硬约束「别拿保守值交差，±1 精确」）。故 src/
零改动，错误语义保持入口层（本就正确）。

## 4. RED→GREEN 的实现方式（mutation 验证，注入物未提交）

复验发现当前态已对齐，契约预设的「当前态红在上限不一致」无从做起（如实记录，
不造假红）。改用 **mutation 验证**证明边界测试确实锁死该不一致类：临时把
`MAX_KEY_SIZE` 虚放宽 4B（→4055，即 issue 的「checkKeySize 放行但实际不可写」
形态）→ **t1/t3/t4 即红**（4052..4055 在 commit 期 PayloadTooLarge，入口却放行）
→ 还原后全绿。RED 证据成立（注入物已还原，工作区 src/ 干净）。

## 5. 交付物

- **tests/txn_writer_db/t58_keysize_test.zig**（新文件，不改既有测试）：
  - t1：MAX_KEY_SIZE(4051) 三 value 剖面（empty / 内联恰满 4B / 5000B 溢出链）
    put+commit 成功、读回逐字节一致
  - t2：MAX+1(4052) 全入口恰报 `error.KeyTooLarge`（put/putDirect/delete/
    putBatch/WriteTxn.put），staged 未被写入（入口拒绝先于 staging）
  - t3：FilePageStore 真落盘 staged put(4051) + flush + reopen 持久；4052 仍入口拒
  - t4：墓碑面自查——MAX key 的 delete（墓碑 entry 3+10+4051=4064 ≤ 4068）
    走通且幂等；deleteRange 近-MAX 端点不受 checkKeySize 影响
    （**item 5**：墓碑端点 4052B 紧凑编码是 `TOMB_PAYLOAD_SIZE` 独立约束面，
    与入口 key 界正交；t38 家族全绿 = 不误伤实证，含 gate6 容器内 range_tombstone）
- **docs/usage.md §3.3**：补 key 上限真值 **4051B** + 入口错误语义 +
  构成说明 + 墓碑端点独立约束说明（原文档无任何 key 上限记载，非「改假值」而是「补真值」）。
- **check.sh git add -f 入库**（gate4：`git ls-files --error-unmatch` 实证）。

## 6. 门退出码（bash check.sh <worktree>）

| 门 | 结果 |
|---|---|
| gate1 t58 ×3 无 flake | PASS |
| gate2 src/ 白名单（db/btree，零 diff 亦过） | PASS |
| gate3 usage.md updated | PASS |
| gate4 check.sh tracked on branch（NB3 纪律） | PASS |
| gate5 macOS 全量 rc=0 fc=0 | PASS |
| gate6 Linux 容器（t62-debian-arm64 原生 fs）：t58 + range_tombstone | PASS |

RESULT: PASS (6/6)，exit 0。

（process note：一次 gate6 FAIL 为时序自摆乌龙——gate 在 fix commit 前 archive 了
HEAD；commit 后复跑即过。评审可无视。）

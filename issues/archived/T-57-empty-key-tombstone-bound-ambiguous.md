# Issue T-57 — `put("")`（空 key）在区间墓碑库上使**全部**已存在 key 不可见（entryCount 与 select/get 不一致）

- **状态**: `closed`（已合入 main `6348171`，三方多签；见文末「交付与验收记录」）
- **发现于**: T-56 的 `ModelMismatch` 失败模式深挖（conductor 侦察，main `77a7b32`）
- **关联任务**: T-56（fuzz seed flaky，其根因之一即本 issue）、T-38-3（区间墓碑写路径 / 打洞）
- **时间**: 2026-09-20

## 现象（最小复现，5 步）

在 `MemPageStore` 上：

| 步骤 | `entryCount()` | `select(null,null)` 可见 | 说明 |
|---|---|---|---|
| `put("aaa","1")`, `put("bbb","2")` | 2 | `aaa bbb` | 正常 |
| `deleteRange(null, null)` | 0 | （空） | 全区间墓碑 |
| `put("ccc","3")` | 1 | `ccc` | 打洞成功，可见 ✅ |
| `put("ddd","4")` | 2 | `ccc ddd` | 打洞成功，可见 ✅ |
| **`put("", "")`** | **3** | **（空！）** | 💥 物理 3 条，**可见 0 条** |

并且 `get("ccc")` 返回 **`null`**（不是 error）—— 已存在的 key 全部被遮蔽。
`put("", "")` 本身**返回成功**（不报错），所以空 key 属于 DB 接受的输入范围。

复现（conductor 侦察用探针，`zig build test-one -Dfilter=t56_probe`）：
`put aaa,bbb` → `deleteRange(null,null)` → `put ccc` → `put ddd` → `put("","")` → dump。

## 根因（已定位到格式定义层）

`src/format.zig:354`：

```zig
pub const TombBound = struct {
    bytes: []const u8,
    append_zero: bool = false,
};

pub const RangeTombstone = struct {
    min: ?TombBound, // null = negative infinity (stored len 0, no flag)
    max: ?TombBound, // null = positive infinity
};
```

注释自己写明了编码规则：**`null` = 「存 len 0、无 flag」**。
而「空 key 端点」`{bytes: "", append_zero: false}` 恰好也是 **len 0、无 flag** ——
**两者编码完全相同**，解码后必然都变成 `null`（无界）。

于是给空 key `""` 打洞时（`""` 是最小 key，落在这条链的第一段 [min, "ccc") 内），
需要把该段拆成 `[min, "")` ∪ `[succ(""), "ccc")`：

- 左段的 **max 界 = `{bytes:"", append_zero:false}`（空 key）** → 编码后 = `null`（正无穷）
- 解码后左段变成 **`[min, null)` = 从 min 到无穷** → **覆盖全库** → 所有 key 被遮蔽

（同理，`min` 为空 key 时 `{bytes:"", append_zero:false}` 也表示「k ≥ ""」＝全部 key，
与 `null`（负无穷）语义恰好相同，所以只有 **max 方向**会出错。）

**注**：`deleteRange(min, "")` 这种「空区间」调用本来也会踩同一个坑（max = 空 key），
但被 T-38-4 的 C1（`count == 0` 零副作用短路）挡住了 —— 打洞路径没有这层短路，所以暴露出来。

## 影响

- **数据可见性丧失**：只要一个库上存在区间墓碑（`deleteRange` 之后必然有），
  再 `put("")` 就会让**整个库**对 `select`/`get` 不可见 —— 而 `entryCount()` 仍报真实条数，
  **两个口径不一致**，上层无从察觉。
- **触发面**：任何接受外部输入当 key 的调用方（key 来自用户/网络时，空串是很自然的输入）。
- **不触发面**：没有区间墓碑的库（纯 put/delete 点删）不受影响；`deleteRange` 的空区间被 C1 挡住。
- 这正是 T-56 中 `ModelMismatch`（约 10% seed）的根因：fuzz 脚手架的 putBatch 空 key 占位分支
  会 `put("","")`，随后 `get_all` 发现模型里的 key 在 DB 里取不到 → 但**这不是测试的锅，是 DB 的真缺陷**。

## 建议修法（lazy：不改磁盘格式）

`[x, "")` **恒为空区间**（不存在小于空 key 的 key），所以**在产出端规范化**即可，无需改格式：

1. 产出墓碑段时，**丢弃 max 界为 `{bytes:"", append_zero:false}` 的段**（空区间，语义上不存在）；
2. 或等价地：把 `{bytes:"", append_zero:false}` 这一 bound 在**写入前**归一化
   （作为 max → 该段丢弃；作为 min → 归一为 `null`，语义等价）。

**硬约束**：`src/format.zig` 的**格式版本号不得变更**（这是产出端规范化，不是格式变更）。
若勘察发现必须动格式版本，**停下来上报**（conductor 重新界定范围）。

## 验收

- RED（conductor 预写）：`tests/txn_writer_db/empty_key_tombstone_test.zig`
  —— 断言「`put("")` 后已存在 key 仍可见」「`entryCount == 可见条数`」「close+reopen 后仍可见」
  「无墓碑时 `put("")` 无害（守卫）」；
- 全量门 exit 0 且无失败；T-38-3/T-38-4 既有区间墓碑测试全部保持绿；
- T-56 的 `ModelMismatch` seed（`0xd184e5f9`、`0x12345678`）转绿（作为本 issue 的**额外证据**，
  若仍红 → 说明还有别的缺陷，需上报）。


---

## 交付与验收记录（2026-09-20，已 closed）

- **分支** `t57-empty-key`：RED `9119cc7`（conductor 预写）→ GREEN `9ce1859`（impl ws1-pi1）
  → 评审 nitfix `687498d`（纯文档）→ **合并 `6348171`**（`--no-ff`）
- **修法**（产出端规范化，**磁盘格式零变更**）：
  1. `src/db.zig` `planTombPunch`：左段 `[tmin, k)` 在 `k` 为空键时**丢弃**
     （`[x, "")` 恒为空区间；其 max 端点编码与 `null` 相同，会变成 `[tmin, +inf)` 遮蔽全库）；
     旧判据只查 `tmin == k`，漏了 `tmin == null` 的情形。
  2. `src/writer.zig` `canonicalTombs`：发布前**兜底归一化**（max 为空键的段丢弃；
     min 为空键归一为 `null`，语义等价），两条发布路径都流经这里。
  3. `src/format.zig` **零改动**；`meta.version` 仍 3（C3 满足）。
- **三方多签（作者独立性）**：
  - **review**（ws1-pi3，纯静态）**approve**，Blocking 0 / Non-blocking 3。
    独立重扫确认「歧义 bound 的生产侧**唯一**产出点 = 打洞左段」，并逐行读 `format.zig` 编解码
    证明右段 `succ("") = {bytes:"", append_zero:true}` **天然安全**（bit31 flag 与 len 无关，
    解码端不可能产出歧义 bound）；`norm` 重写逐行核过；`sorted` 早返回**不是泄漏**（两调用点皆 arena）。
  - **test**（ws1-pi2，独立）**PASS**：门 6/6；独立 scratch 探针 P1–P9；
    **回归对比**：非空 key 的打洞/deleteRange 链形状在基线 `9119cc7` 与 `9ce1859` 上
    **逐字节一致**（恒等变换）；9 类反证尝试（极值 key、`\x00`、`\xff\xff`、重复 put、
    窄墓碑、`gcTombstones` 交互、`putBatch` 形态、WriteTxn 混合、4030B 大 key 打洞）
    **均无法再构造全库遮蔽**。
  - **conductor** 复跑门 @ `687498d`：**6/6 PASS**；main 集成验证见下。
- **闭环证据**：T-56 的两个 `ModelMismatch` seed（`0xd184e5f9` / `0x12345678`）
  在修复后**转绿**；main 集成态 `zig build test --seed 0xd184e5f9` **EXIT=0**（修复前必红）。
- **非阻塞（已处置）**：
  - NB-1 报告里「门 4 FAIL / blocked」已**过期** —— 门 4 是 **conductor 写的假阳性**
    （正则命中 `format.zig:225/263` 的既有注释文字，main/RED 上同样命中 ⇒ 该门从来不可能通过）。
    已修门脚本（排除注释行）并在 `687498d` 上复跑 6/6。
    **实现者按纪律 blocked 上报、而非改注释骗过门 —— 正确行为。**
  - NB-2 旧库风险已落盘：见 `docs/usage.md` 新增小节（修复前写入的歧义段与真全区间墓碑
    磁盘编码逐字节相同，无法区分 → 这类旧库需重建/人工修复）。
  - NB-3 空 key 语义已补进 `docs/usage.md`。
- **遗留（明确不修）**：修复**只保证新产出干净**；修复前已写入的歧义段无法在不改磁盘格式下辨识
  （信息论意义上的不可区分），属数据修复范畴。

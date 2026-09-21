# Issue T-56 — `api_batch_fuzz_test.zig` 依赖随机 seed，使默认门（及 CI）非确定性 flaky

- **状态**: `closed`（脚手架部分已合入 main `c7b7642`；数据面部分由 T-57 承接，T-57 亦已 closed）
- **发现于**: T-38-4 实现（`ws1-pi1`）报告「环境/既有问题 1」；conductor **独立复现并定责**
- **发现时间**: 2026-09-20
- **来源**: T-38-4 的验收门 `zig build test` 反复出现「同一 commit 时绿时红」
- **严重程度**: **medium**（CI 假红 / 掩盖真回归；且失败模式之一是 **SIGSEGV use-after-free**，
  不排除背后有真缺陷）
- **关联**: `tests/fuzz/api_batch_fuzz_test.zig`、`build.zig`（seed 传递）、
  `.woodpecker/ci.yml`、`.github/workflows/ci.yml`；关联 main `50af0d1`

## 现象

`zig build test` 的 seed 每次随机。约 **10%** 的 seed 会让 `api_batch_fuzz_test.zig` 失败
（本任务树上 20 个 seed 中 2 个失败）。已观察到**两种**失败模式：

| seed | 现象 |
|---|---|
| `0x37c6c92f` | smoke 测试 **SIGSEGV**：`execOneOp`（:146 附近）释放 `del_keys[i]` 时指针已是 `0xaa` 填充（free 后的 undefined 填充）→ **use-after-free / double-free** |
| `0xd184e5f9` | `error.ModelMismatch`（:113 附近，`get_all`：model 里的 key 在 db 里取不到） |

## 复现（conductor 实测）

```
zig build test --seed 0xd184e5f9      # exit 1, error.ModelMismatch
zig build test --seed 0x8c40347c      # exit 0（全绿）
```

`--seed` 会被转发到 test runner（失败日志的 `failed command:` 行里带 `--seed=0x…`，可原样复跑）。

## 定责（已完成，与本任务无关）

- 在**干净基线** `8cf3e29`（T-38-4 的 RED 提交）上，用同一 seed 同样失败 → **先于 T-38-4 存在**。
- `api_batch_fuzz_test.zig` 只用 `putBatch` / 按 key 删除，**从不触碰 `deleteRange` / 墓碑链**，
  即 T-38-4 的改动对它是惰性代码路径。
- T-38-4 的门因此把门 1 固定为 `--seed 0x8c40347c`（见 `.agents/tasks/T-38-4/check.sh` 注释）。

## 影响

- `zig build test`（CI 的测试步）有 ~10% 概率**假红**，会掩盖真回归、浪费排查时间。
- 失败模式 2（`ModelMismatch`）**不能排除是真 DB 缺陷**：如果 model 簿记是对的，
  那就是「写进去的 key 读不回来」——那是数据面问题，比测试 flaky 严重得多。必须先查清。

## 处置建议

1. **先查 SIGSEGV**：确认是测试自身的簿记 bug（`del_keys` 释放两次 / 释放后仍用）还是
   DB 侧返回了悬垂指针。定位到具体行后，若纯属测试簿记 → 修测试。
2. **再查 ModelMismatch**：用失败 seed 抓最小复现；判断是 model 记账错还是 DB 真丢了 key。
   若是后者 → 按数据面缺陷另立 issue（高优先级）。
3. **短期止血**：CI 与各任务的验收门固定 seed（T-38-4 已如此做），避免假红。
4. **长期**：修根因后恢复随机 seed（fuzz 的价值就在随机覆盖）。
5. 修完后在 `issues/README.md` §4 记录「测试总数口径」的经验教训：
   `zig build test` 的汇总计数**只统计本次实际执行的 run-test step，缓存命中的计 0**
   —— 报总数必须用**冷缓存 + `--summary all` + 绿跑**，否则会得到偏小的假总数
   （T-38-4 期间 conductor 就被这个机制误导过一次：实测 539 vs 真实 543）。

## 验收

- 随机 seed 连跑 ≥ 50 次全绿（或明确记录仍存在的失败率与原因）；
- 若 `ModelMismatch` 被判定为 DB 缺陷，则本 issue 只关「测试簿记」部分，数据面部分另立；
- 修完后 CI 的 `zig build test` 恢复随机 seed 且稳定。


---

## 根因定位（2026-09-20，conductor 侦察 + 实证）

> 结论：**两个独立根因**，一个在脚手架、一个在 DB。原「处置建议」第 1/2 条的答案已实证。

### 根因 1（脚手架）：`delete_batch` 下标/计数错配 → SIGSEGV

`tests/fuzz/api_batch_fuzz_test.zig` 的 `delete_batch` 分支把结果**写在下标 `i`**，却用 **`actual_dn`** 切片：

```zig
var del_entries: [8]cube.Entry = undefined;
var del_keys:    [8][]u8        = undefined;
var actual_dn: usize = 0;
for (0..dn) |i| {
    ...
    if (actual_key_len == 0) continue;   // ← 跳过赋值，但 i 已前进 → 数组留洞
    del_keys[i]    = ctx.allocator.dupe(u8, key) catch return pos;
    del_entries[i] = .{ .key = del_keys[i], .value = "", .tombstone = true };
    actual_dn += 1;
}
if (actual_dn > 0) {
    ctx.db.putBatch(del_entries[0..actual_dn]) catch {          // ← 洞里的 undefined 喂给 DB
        for (0..actual_dn) |i| ctx.allocator.free(del_keys[i]); // ← undefined 指针交给 free
        return pos;
    };
    for (0..actual_dn) |i| { ... ctx.model.fetchRemove(del_keys[i]); }
}
```

`key_len == 0` 即触发 `continue` → 数组留洞 → `del_entries[0..actual_dn]` 含 **undefined 条目**、
`free(del_keys[i])` 收到 **undefined 指针（0xaa 填充）** → **SIGSEGV at 0xaaaaaaaaaaaaaaaa**（实测栈落在 `:146`）。

对照：`putBatch` 分支的同名循环**正确**（`break` 在任何赋值之前；空 key 分支也照样赋值 ⇒ `[0..actual_n]` 恒连续）；
`range_delete_fuzz_test.zig` / `api_fuzz_test.zig` 用 `consumed` 不用数组 ⇒ 不受影响。**只有 `delete_batch` 中招。**

**实证**（conductor 在 worktree 里只打这一处修复，用 `--seed` 空格形式）：

| seed | 修前 | 只修洞后 |
|---|---|---|
| `0x37c6c92f` | SIGSEGV @0xaaaa（:146） | **GREEN** ✅ |
| `0x00000001` / `0xfeedface` | GREEN | GREEN |

→ 任务 **T-56**（分支 `t56-fuzz-harness`，RED `bcabfa1`）。

### 根因 2（DB 真缺陷）：空 key 端点与 `null` 编码混淆 → 全库遮蔽

修掉根因 1 后，`0xd184e5f9` / `0x12345678` **仍然红** ⇒ 是**另一个**根因。逐层深挖后定位到 DB：

```
[1.put-aaa-bbb]      visible=2 ec=2 keys: aaa bbb
[2.delRange-all]     visible=0 ec=0
[3.put-ccc]          visible=1 ec=1 keys: ccc
[4.put-ddd]          visible=2 ec=2 keys: ccc ddd
--- put empty key ---
[5.after-put-empty]  visible=0 ec=3 keys:      ← 物理 3 条，可见 0 条
get(ccc) = null
```

根因在 `src/format.zig` 的 `TombBound`：用「存 len 0、无 flag」表示 `null`（无界），
而空 key 端点 `{bytes:"", append_zero:false}` 编码与之**完全相同** ⇒ 给空 key 打洞留下的
`[min, "")` 段解码后变成 `[min, null)` = **全库**。

**这不是测试的锅**（`put("")` 返回成功，空 key 在 DB 接受范围内）⇒ **已另立 T-57（高优先级，数据面）**：
`issues/T-57-empty-key-tombstone-bound-ambiguous.md`。

### 分工结论

| 根因 | 归属 | 交付物 |
|---|---|---|
| 脚手架下标错配（SIGSEGV） | **T-56**（本 issue 的「测试簿记」部分） | 分支 `t56-fuzz-harness`，RED `bcabfa1`，门 `.agents/tasks/T-56/check.sh` |
| DB 空 key 端点编码（ModelMismatch） | **T-57**（数据面，另立） | 分支 `t57-empty-key`，RED `9119cc7`，门 `.agents/tasks/T-57/check.sh` |

按原「处置建议」第 2 条：`ModelMismatch` 判定为 **DB 缺陷** ⇒ 本 issue 只关「测试簿记」部分，
数据面部分由 T-57 承接。两个任务的 `ModelMismatch` seed 在 T-57 落地后才应转绿。


---

## 交付与验收记录（2026-09-20，已 closed）

- **分支** `t56-fuzz-harness`：RED `bcabfa1`（conductor 预写）→ GREEN `e4109eb`（impl ws1-pi2）
  → **合并 `c7b7642`**（`--no-ff`）
- **修法**：`delete_batch` 的赋值下标从**循环变量 `i`** 改为**计数器 `actual_dn`**
  （循环捕获 `|i|` → `|_|`），使 `[0..actual_dn]` **恒为已赋值前缀** ——
  undefined 条目不再被喂给 `putBatch`、undefined 指针（0xaa）不再交给 `free`。
- **三方多签**：
  - **review**（ws1-pi1，纯静态）**approve**，Blocking 0 / Non-blocking 4。
    **构造性论证**（不是靠 seed 碰运气）：枚举循环**全部退出路径** ——
    `break`（任何赋值之前）/ `continue`（任何赋值之前）/ OOM 的 `catch return`（直接退出函数，
    数组之后不再被消费）⇒ 前缀恒稠密；消费点唯一且都落在 `[0..actual_dn]` 内。
    并**亲测**确认两个 `ModelMismatch` seed **仍然红** ⇒ **守卫未被放水**。
  - **test**（ws1-pi3，独立）**PASS**：门 6/6；独立构造空洞输入驱动（不依赖 RED 的两个测试）；
    **27-seed 扫描：SIGSEGV 0 次**；守卫 seed 复跑仍红（可达性证据）；RED 逐字对比未改。
  - **conductor** 复跑门 @ `e4109eb`：**6/6 PASS**。
- **C7 同类排查**（实现者 + 评审各自独立扫 `tests/fuzz/` 全目录）：**仅 `delete_batch` 一处中招**；
  `putBatch` 分支虽然也写 `[i]`，但它的 `break` 在任何赋值之前、空 key 分支也照样赋值
  ⇒ `[0..actual_n]` 恒连续（**正确**）；`range_delete_fuzz_test.zig` / `api_fuzz_test.zig`
  用 `consumed` 算术推进、无批量数组 ⇒ 不受影响。
- **非阻塞（留档；均为预存问题，非本次引入）**：
  - **NB-1** `putBatch` 空键「用 `("","")` 占位并发出去」vs `delete_batch`「跳过」的**不对称**
    —— 预存（RED 里两侧都已是该行为）。**该占位路径正是 T-57 的触发面**（fuzz 由此 `put("","")`）；
    T-57 落地后该不对称无害，但两侧语义差异**目前无注释说明**，后续簿记整理时值得补。
  - **NB-2** OOM 路径微泄漏（`dupe(...) catch return pos` 会漏掉本轮已 dupe 的 key/val）——
    **两分支预存**、`testing.allocator` 在 fuzz 中不 OOM ⇒ 当前不可达。
  - **NB-3** `get_all` 的 `db.get(...) catch continue` 在 get 出错时**静默跳过**该 key 的模型比对
    —— 守卫的**静默弱化通道**（预存、当前不可达；`range_delete_fuzz_test.zig` 的 `verify_all` 同模式）。
    若要修需 conductor 定夺错误策略，未动。
  - **NB-4** `r2` 只固定一条 seed —— 覆盖面由 review 的构造性论证补足，无需动作。
- **集成验证**（main `c7b7642`）：`zig build test` 随机 seed **连跑 2 次均 EXIT=0**；
  两个历史坏 seed `0xd184e5f9` / `0x37c6c92f` **均 EXIT=0** ⇒ **CI 假红恢复稳定**
  （修复前约 10% 假红）。

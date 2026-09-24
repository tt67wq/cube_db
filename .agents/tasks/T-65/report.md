# T-65 Report — 杂项清剿（T-55 / T-45 / T-47）

- **分支**: `t65-misc`（自 main `34e6a01`）
- **提交**:
  - `5263c6e` fix(T-55): is_shard 前缀匹配改精确匹配 4 分片文件名
  - `7ddee0b` fix(T-45): leafOverflowScenario 第三步 insert 改指向当前 root
  - `9d74588` docs(T-47): cherry 4632fcb（教学文档 splice 化，95+/81−）
  - `abee35e` docs(T-47): B1 重写 + 行号复验更新 + N-1 复合内联阈值同步
  - `87d8075` fix(T-45): R2 回炉——z 键互异，实证恢复 split found=true inline 变体覆盖

## 刀 1 — T-55（精确匹配）

`build.zig` `is_shard`：`startsWith(rel, "insertbatch_sweep_")` →
`eql` 精确匹配 `insertbatch_sweep_{a,b,c,d}_test.zig` 四个真分片。

证据：

- `zig build test-one -Dfilter=shardRange` → rc=0（partition 守卫回归闭包，≥1 命中）
- `zig build test-one -Dfilter=insertbatch_sweep_a` → rc=1 **响亮失败**
  （addFail：filter 未命中；真分片仍被排除）
- 默认门总数不变：src/ 与 tests/ 零改动，仅判定逻辑收窄（g5 动态期望自证）

## 刀 2 — T-45（sweep stale root）

`tests/btree_storage/insert_split_budget_test.zig` `leafOverflowScenario`：

- 新增 `var root = wr.new_root;`，每步 insert 后用返回的 `WriteResult.new_root` 更新；
  第三步 overwrite 目标由 `wr.new_root`（batch 后的旧根，已在 dirty 表内排队）改为当前 root。
- **R2 勘误（评审 01b6879 FAIL 回炉）**：R1 版 report 称「m 不切块、z3 仍在原叶、
  precheck 照旧重定向」——**失实**，评审插桩实证：m 必切块（93+707+3445=4245 > 4068，
  found=false），且五个 z 种子键全同（`bigKey` 皆填 'z'+'k'×677），切块后 branch 分隔键
  与 overwrite 键相等，路由 `≥` 落到只含 z4 的尾块页（entry_start=3，预检 3+3688 ≤ 4068）
  → overwrite 走**快路径**，`insertIntoLeafSplit found=true` 命中 ×0（修前 ×38），
  inline 旧值 split-found overwrite 变体覆盖归零。
- **R2 修法（路线 (a)，评审建议量纲采纳）**：
  1. 五个 z 键互异：`z_bufs[i][1] = 'a'+i`（za/zb/zc/zd/ze，长度不变 678B）；
  2. 第三步 overwrite 键改用种子保存的 `z3_key = seed[6+3].key`
     （不能再用 `bigKey(&z_bufs[3], "z")` 重填——会把 'd' 抹回 'zkk…' 变成
     未命中键，R2 首版探针即抓到此错：SPLIT found=false vlen=3000 ×26）。
- **改后命中机制（已实证）**：z3='zd…' < 分隔键 'ze…' → 路由到尾块前页
  （payload 3556，z3 为最后一条，entry_start=2867、tail=0），新 entry 3688B
  使预检 2867+3688+0=6555 > 4068 → 必进 `insertIntoLeafSplit` **found=true**，
  且 value 3000 ≤ inlineValueBudget(678)=3377 → **inline 旧值变体**（非 overflow，
  overflow 变体已有 btree_leaf_budget_test:142 兜底）。insert 返回 3 页 splice →
  root 再次 buildBranchLevels，场景原有的 m 切块/splice 练习不受影响。
- **PROBE 证据（临时插桩 `insertIntoLeafSplit` 入口 + 快路径出口，探针未入 commit，
  src/ 零 diff）**：`zig build test-one -Dfilter=insert_split_budget` 全套件 45 次场景运行：
  - `PROBE SPLIT found=true vlen=3000` → **×45**（每场景恰 1 次，z3 overwrite）
  - `PROBE SPLIT found=false vlen=1` ×127（m 切块，每场景 1 次 × 运行数 + 场景外）
  - `PROBE FAST *` → ×0；`PROBE SPLIT found=false vlen=3000` → ×0（R2 首版路由错误形态已消除）
- 断言只强不弱：sweep 故障注入范围（countAllocs 动态标定）不变；本变体覆盖
  由 ×0 恢复至每场景 ×1。
- `insert_split_budget` filter 两连跑均绿；全量 `zig build test` rc=0 fc=0。

## 刀 3 — T-47（评估 → 救）

### 评估

| 项 | 结论 |
|---|---|
| 交付物 4632fcb 可达性 | `git cat-file -e` 通过（ref 可能已 prune，对象存活） |
| docs 漂移（4632fcb~1 → 34e6a01） | **零**（lecture_btree.html 无变化），cherry 干净落盘 |
| src 漂移 | btree.zig +65/−8：N-1（`inlineValueBudget` 复合内联阈值）+ 常量偏移 +36 |
| 8 处行号引用 | 逐条复验：**全部因 +36 偏移失效**（52-58→52-57 / 247→280 / 1043→1079 / 1304→1340 / 1461-1521→1497-1561 / 1508-1521→1535-1555 / 1671→1707；`btree.zig:11` 不变）——已逐条修正并回验源码 |
| split_key 残留 | 4 处均为历史标注/局部 `split_keys` ArrayList（:772 已废弃注记、:999/:1187 现行机制），不误导 |
| B1（:820-822） | 评审 review.md **已灭失**（.agents/tasks/T-47/ 未入库、无归档）→ 按评审思路重做：替换文本依据现行 `insertIntoBranch` 溢出路径（整层重建打包页 + splice 上抛 + 父层 ci 处整合 + root 才冒泡 buildBranchLevels），与 §5.4 一致 |
| 新失真 | **1 处**：N-1 使溢出阈值从 `value.len > 3800` 变为复合感知 `inlineValueBudget(key)`，文档 8 处旧表述/代码片段失真 → 已同步（常数块补 `inlineValueBudget`、阈值行文、needsOverflow/leafPayloadSize/encodeLeafPayload 片段、流程图 step、2 处 §5.1/§5.3 行文） |

### 裁决：救（低成本）

契约字面阈值「行号全存活 + 无新失真」因 src 漂移不满足，但漂移**可精确量化且已修完**：
行号 8 处机械平移 +36、N-1 失真 8 处局部替换（非结构性），总成本远低于「弃 + 重写」。
选择 cherry 4632fcb（评审已验证其 splice 表述与代码逐字对应）+ 后补 B1/N-1 的路线，
diff 最小。**注意**：此为对契约阈值的从宽执行（成本导向），已如实列证，交 conductor 复核。

### 复审自查表

| 项 | 结果 |
|---|---|
| 行号 8 处逐条 | ✓（见上，均对当前 src/btree.zig 验证） |
| split_key 残留 | ✓ 4 处均历史标注/局部 ArrayList |
| B1 段落 | ✓ 与 §5.4 及 `insertIntoBranch`/`insert`（1497-1561）现行实现一致 |
| N-1 表述 | ✓ `inlineValueBudget = min(3800, NODE_PAYLOAD_CAP-3-10-key_len)`，饱和语义已述 |
| 越界 | ✓ diff 仅 docs/lecture_btree.html |

## 硬约束

- src/ 零 diff ✓（g4）
- check.sh `git add -f` 入库 ✓（g6）
- Linux 容器冒烟 ✓（g8，g1/g3 复跑）

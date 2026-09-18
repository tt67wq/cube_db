# T-54-D 调查报告 — T4（branch-producer fault sweep）170s 拆解

- **角色**：调查（不实施）。**本文不含任何代码改动**；worktree 与 `c09666f` 的
  `build.zig / tests/ / src/` diff 为空（已验证，`git diff c09666f -- build.zig tests/ src/` = 0 行），
  `zig build test` 复验 exit 0（44/44 steps，476/477 pass，1 skip）。
- **契约注记**：任务给的契约路径 `.agents/tasks/T-54-D/task.md` 在磁盘上不存在
  （conductor 未落盘或未同步）；本文按 prompt 内联的「必须回答 6 问」执行。
- **方法注记**：所有数字来自独立 probe（`/tmp/t54d_probe.zig`，手动 `zig test` +
  与 build runner 相同的模块接线，**不经过、不修改 build.zig**），复刻 T4 的
  `branchOverflowScenario` 并加分相计时 / 分配计数 / `getrusage` RSS 采样。
  probe 保留在 /tmp 供 conductor 复核；repo 零改动。

## 0. 数字总览（Debug，本机实测）

| 量 | 值 |
|---|---|
| 一次干净 scenario 全程 | **~1.81-1.83s**，21852 次分配，248 页，live bytes ~0.98MB |
| phase A（4×500 seed，建两层树） | ~0.78s，9449 次分配（43%），120 页 |
| phase B（2000-entry 溢出 batch） | ~1.03s，12403 次分配（57%），+128 页 |
| sweep 故障点数 | **82**（`first=total-|80=21772`，`last=total+2=21854`） |
| 故障点落点 | **全部 82 个都在 phase B 的最后 82 次分配里**（占总分配 0.37%） |
| 实测单故障点迭代 | ~1.83s（sweep replica：20 点用了 36.5s） |
| 校准（countAllocs） | 1 次完整 run，~1.8s，**只跑一次**（非每点） |
| 推算 T4 总耗时 | 82×1.83+1.8 ≈ 152s（实测 170.3s，Δ≈12% 为测试二进制环境/负载差） |
| RSS 增长 | **~26MB/迭代（Debug，单调线性）**；82 点 ≈ ~1G ✓ 与 MaxRSS:1G 吻合 |

## 1. Q1：sweep 什么？多少个故障点？

`T4` 的 fault sweep 是**分配序号故障注入**：对一次干净 scenario 的
**全部 21852 次分配**中的**最后 82 个分配序号**（21772..21853）逐个注入
`error.OutOfMemory`——每个序号一次全新端到端 run（`FailingAllocator{fail_index=N}`
包住 `std.testing.allocator`）。每次 run 的断言（两层）：

1. 结果要么成功、要么恰好 `error.OutOfMemory`（绝不 UAF 崩 / 其他错误码）；
2. run 结束后 `std.testing.allocator` 的泄漏检查通过（errdefer 正确释放）。

「80」是测试里**写死的校准宽度**（`first = total -| 80`），注释称这最后 ~80
个分配「覆盖 leaf chunk loop、branch chunk loop（两个被测 producer）和 splice
handoff」——即 sweep 的**意图**是打穿 `insertBatchIntoLeaf` / `insertBatchIntoBranch`
两个 chunk 循环 + `buildBranchLevels` 的 splice 交接处的全部分配点。

## 2. Q2：每个故障点每次迭代做多少工作？

每个故障点 = **完整重建整个场景**：

- `MemPageStore.init(alloc, 100000)`——注意：**100000 只是上限，页按需分配**
  （probe 实测整棵树只用 248 页 ≈ 1MB；init 本身近零成本）；
- phase A：4×500-entry batch 建两层树（root branch ≈ 63 children + 63 leaves）；
- phase B：2000-entry 溢出 batch（新增 63 leaf → root children 126 > 64 →
  root 溢出 → splice → **branch chunk loop 被测路径**）；
- 合计 ~21852 次分配 / ~1.83s（Debug）/ live 内存 ~1MB。

由于故障点全部位于 phase B 的 99.4% 深度（B 从第 9449 次分配开始，故障点
21772+），**每个迭代都完整跑完 phase A + 99% 的 phase B 才失败**——即
~99.6% 的迭代工作量是「与被测故障点无关的前缀」。

## 3. Q3：是否 O(N²)？

**不是严格 O(N²)，但「每点重做构建」属实，且浪费比例极端**：

- 校准（`countAllocs`）只跑 **1 次**（非每点重做）——不存在校准层面的平方；
- 但**每个故障点都重做一遍完整构建**（含 100% 的 phase A）：82 个点 ×
  21852 次分配 = **1.79M 次分配，其中真正服务于被测目标的只有 82×82 ≈
  6.7k 次（0.37%）**；时间上 82×1.83s ≈ 150s，其中 phase A 前缀（可复用）
  占 43%（~63s），phase B 的前 12321 次分配（到故障窗口起点为止的部分，
  理论可复用）又占 phase B 的 99.4%（~58s）——**真正不可省的「故障窗口内」
  工作只有 ~30s 上限，实际只有几秒**。
- 结构化描述：成本 = O(W × S)，W=82（宽度）、S=场景成本（~1.8s）；
  「平方感」来自 S 被故意做大（2000-entry 场景是触发 branch 溢出的最小
  量级），而 W 又是 80 的固定宽度——两者相乘。

## 4. Q4：MaxRSS 1G 从哪来？

**不是预分配、不是单笔大分配、不是泄漏——是 `std.testing.allocator`
（`DebugAllocator`）free 后留存（retain）随迭代次数线性累积**：

- `MemPageStore.init(100000)` 只设上限，页按需分配（248 页 ≈ 1MB）；
- 单次迭代的 live 峰值 ~1-2MB；
- probe 实测（干净迭代、正确 free、泄漏检查通过）：RSS **每迭代 +26MB
  （Debug）单调递增**，12 迭代 134→419MB；真实 sweep replica（失败迭代）
  同样 ~26MB/迭代。真实 T4 二进制 82 迭代 ≈ 基数 + 82×~12MB ≈ 1G，
  与 zig 报的 `MaxRSS:1G` 吻合。
- 机制层面：DebugAllocator 的 free 不把内存还给 OS（bucket 留存 + safety
  特性），且本场景的留存**未被后续迭代复用**（同样的确定性分配序列，
  RSS 却线性涨——复用没有发生；具体 bucket 内部行为未进一步解剖，
  对方案评估无影响，见下）。
- ⚠️ **顺带发现（对方案 (c) 关键）**：同样的 probe 在 **ReleaseSafe 下留存
  ~82-103MB/迭代、ReleaseFast ~104MB/迭代**（12 迭代即 1.3G）——若把测试
  二进制切到优化模式而不减迭代数，82 迭代 RSS ≈ **~7-8G**，会直接爆掉
  CI 的 `-j2 --maxrss 4GB`。

## 5. Q5：四个候选方案对比

预估口径：T4 = 82 迭代 × ~1.83s（Debug）≈ 150-170s 基线；`zig build test`
其他 step：core_format 46s、crash 36s；目标 wall < 70s。

| 方案 | 做法 | 预估 T4 耗时 | 预估 `zig build test` wall | 语义保持 | 主要风险 |
|---|---|---|---|---|---|
| **(a) 分片并行** | 82 个故障点拆 4 片（如 21772-21792 / …92-…12 / …12-…32 / …32-…54），每片一个 test 二进制（4 个 top-level aggregator，白拿 auto-discovery 并行） | 每片 ~21 点 ×1.83 + 校准 1.8 ≈ **~40s**（4 片并行，12 核机器） | **~50s**（关键路径变为 core_format 46s + btree 分片 40s 并行） | ✅ **100%**：同样 82 个故障点、同样断言，只是分布到 4 个进程 | RSS 合计 ~1.4G（4×~350MB，安全）；每片重复 1 次校准（+1.8s×4，可忽略）；新增 4 个小文件 + 组装结构（build.zig 可不动） |
| (b) 优化校准 / 前缀复用 | 建一次 seed 树并快照（~120 页 memcpy，<1ms/次），每迭代只重放 phase B，fail_index 减去前缀 9449 | 82×1.03 + 2 ≈ **~86s** | **~90s**（btree step 86s 成为关键路径） | ✅ 等价（分配序列确定性：同输入同树 → 同分配计数）| **单独不达门**（86s > 70s）；且 RSS 不变（B 的 12k 次分配/迭代照旧走 testing.allocator，~1G）；快照/恢复要小心 freelist/dirty 复位，实现复杂度最高 |
| (c) 降迭代成本 | 三个子变体：**(c1) 缩场景**：seed 4×500→1×500（A 0.78→0.19s）、batch 2000→~1850（触发 root 溢出需 ≥~64 leaf ≈ 1850 entry，几乎不可再缩）→ 场景 1.83→~1.05s；**(c2) 缩宽度** 82→~25 点；**(c3) 优化模式** ReleaseSafe | (c1) 82×1.05 ≈ **~88s**；(c2) 25×1.83 ≈ **~46s**；(c3) 82×~0.12 ≈ **~10s** | (c1) ~90s ✗；(c2) ~50s ✓；(c3) ~50s ✓ | (c1) ✅ 路径等价但**不达门**；(c2) ❌ **故障点 -70%，sweep 强度实质降低**；(c3) ✅ 点数不变，但 Debug 专属的 UB/溢出检查丢失（本测试的核心断言 UAF/泄漏靠 FailingAllocator+泄漏检查，ReleaseSafe 下仍有效） | (c3) **RSS ~7-8G 爆 CI 预算**（§4），单独不可行；(c2) 与「不减覆盖」红线冲突；(c1) 单独无效 |
| (d) 隔离 | 把 insertbatch_owned（或仅 T4）挪出 `zig build test`，进独立命名 step（同 fuzz 模式） | 不变（~170s，按需/nightly 跑） | **~50s**（btree step 剩 ~10s，关键路径 core_format 46s） | ❌ **默认验收门里少 4 个用例**（T-42 的 UAF/泄漏回归要等 nightly 才暴露） | 覆盖面回退是本质代价，与母 issue「不减覆盖面」精神冲突；仅当 conductor 接受「默认门 + nightly 双层」时可行 |

（组合参考：(b)+(c1) ≈ 82×0.6+2 ≈ ~51s ✓ 语义 100% 且不爆 RSS——前缀复用 +
缩 seed；实现复杂度高于 (a)，收益同为 ~50s。(c3) 任何组合都受 RSS 制约。）

## 6. Q6：推荐方案

**推荐 (a) 分片并行**（4 片，每片 ~21 个故障点）：

- **预估最终 wall：`zig build test` ≈ 50s**（btree 最慢分片 ~40s 与
  core_format 46s 并行，整机关键路径 ~46-50s）——达成 < 70s 门；
- 语义 **零损失**：82 个故障点、两层断言（OOM-only + 泄漏检查）一个不少，
  不碰断言/覆盖/skip，是最符合本任务红线的方案；
- 实现量小：4 个片文件 + 4 个 top-level aggregator（tests/ 自动发现，
  **build.zig 可以完全不动**，避开与 T-54-B/E 的串行域冲突）；共享 helper
  （scenario/sweep/countAllocs）抽到 `insertbatch_sweep_helpers.zig` 一次；
- RSS 代价可控：~1.4G 峰值合计（CI `-j2` 下同时只有 2 片 ≈ ~0.7G，安全）；
- 次选（若 conductor 想避免新文件）：(b)+(c1) 组合（前缀复用+缩 seed），
  同样 ~50s、语义 100%，但实现复杂度和出错面都更大。

**不建议**：(c2)（减故障点=降覆盖）与 (d)（默认门丢用例）触碰红线；
(c3)（优化模式）单用必爆 CI RSS 预算（§4 的 ~7-8G 发现），若未来与
「按迭代重建底层 allocator」或「每 N 点重置 DebugAllocator」配合可再评估。

## 7. 附录：probe 复现方法

```bash
# 与 build runner 相同接线的独立 probe（repo 零改动）：
zig test -ODebug --dep cube_db -Mroot=/tmp/t54d_probe.zig \
  -ODebug --dep zio -Mcube_db=src/root.zig \
  -ODebug --dep zio_options \
  -Mzio=zig-pkg/zio-0.17.0-xHbVVMs7KQDQv6kgwE6sVhFoTWa0cyHnc9c3T07cN2aI/src/zio.zig \
  -Mzio_options=.zig-cache/c/31e85e14ee90c92c4916cf9c988891cc/options.zig \
  -lc --cache-dir .zig-cache --global-cache-dir ~/.cache/zig
# 输出：分相耗时/分配数/页数、sweep 落点分布、逐迭代 RSS、真实 sweep replica 计时
```

原始输出摘录（Debug）：
```
RUN 0: phaseA(4x500 seed)=767.4ms allocs=9449 pages=120 | phaseB(2000 overflow)=1020.8ms
      allocs=12403 pages=248 | total=1788.2ms allocs=21852 pages=248 bytes=979112
SWEEP: total=21852 phaseA_allocs=9449 phaseB_allocs=12403 first=21772
       last_exclusive=21854 fault_points=82 in_phaseA=0 in_phaseB=82
ITER 11: self_maxrss=418.8MB   (RSS 线性 +26MB/迭代)
SWEEP20: 20 fault points took 36544.2ms total, 1827.2ms/iter   (真实 sweep replica)
```

# T-38-9 Report — 重建完整 S3 交错场景（gcTombstones/punch × 并发 staging + reopen）

- **分支**: `t38-9-s3-interleave`（基于 main @ `f22e28d`，含 T-38-7/8 合入）
- **结论**: **GREEN** —— check.sh 3/3 PASS（gate rc=0）；零 src/ 改动；无新 bug
- **新文件**: `tests/staging_tombstone/t389_s3_interleave_test.zig`（2 用例，全 FilePageStore 真落盘）

## 场景不变量清单

**S1 — deleteRange × punch × flusher × gcTombstones 并发交错 + reopen**（`t389 S1`）：

线程编排（deleter 先起保证链非空，gc/flusher 随后，putter 最后）：
- deleter：循环 `deleteRange("d000000","e")`（50µs 间隔，passes>0 断言）
- putter：1500 轮，每轮 put 范围外 `a{i}` + 范围内 `d{i}`（d-put 命中区间墓碑 → 同 commit punch，INV-RT1；窗口 ~300ms）
- flusher：1ms 循环 `db.flush()`（t387 T2 workerFlusher 模式）
- **gc 线程：2ms 循环 `db.gcTombstones()` 多轮（passes>0 断言），与 deleteRange/punch 提交竞争 write_mutex**

不变量（三口径 = entryCount / select 计数 / 逐 key get，每节点全查）：
1. 三口径一致（任意交错后）
2. 无幻影（key 集有界：`a/d` + 6 位下标）、在场者值正确
3. 无复活：d-key 一旦不可见不再可见（deleter 停后可见集单调保持）
4. 范围外精确：flush 后 `a{0..1499}` 全在场（a_exact）
5. 确定性 punch 收口：put 回 `d000000` 必须可见
6. 墓碑链真落盘（`tomb_head≠0`，version=3）——防假绿
7. reopen 后 1-6 全部保持（节点 C）

节点：A（交错后，staged 子集态）→ punch 收口 + flush → B（范围外精确 + 单调保持）→ close/reopen → C。

**S2 — T-60 多线程复测：同一被遮蔽 key 的并发重复点删**（`t389 S2`）：

前置 `put a; put b; deleteRange("b","c")`（b 遮蔽物理 live）→ 4 线程 × 60 轮：
每轮 `db.delete("b")` + 一个范围外 `z{t}{m}` put → staging 混批（大量重复 tomb req
+ live put 同批提交，正是 T-60 形态）× 0.5ms flusher 交错。

不变量（终态全确定，不依赖交错）：
1. 精确计数 `entryCount == 1 + 4×60`（a + 全部 z-key）——once-set 补偿按 key 净账，不多补不少补
2. select 逐条核对：a、z 值正确，**b 出现即 PhantomKey（复活即爆）**
3. 三口径一致；`get("b")` 为 null
4. gcTombstones：interval 只压 tree tombstone → 收割后计数不动、b 不复活
5. reopen 后全部保持

## 交错参数

| 参数 | 值 |
|---|---|
| S1 putter 窗口 | 1500 轮 × 100µs sleep ≈ 300ms（+提交耗时） |
| S1 deleter / gc 间隔 | 50µs / 2ms |
| S1 flusher 间隔 | 1ms |
| S2 线程 × 轮次 | 4 × 60（240 次重复点删 + 240 混批 put） |
| 文件总耗时 | ~3s/次（远低于 40s/场景、3min/文件盒） |

fsync=false（process-crash 模型，同 t387 先例；power-fail 归 T-38-5 职责）。

## 测试效力实证（非 vacuous green）

- deleter/gc passes>0 断言防假跑；`requireTombOnDisk` 防无链假绿
- **S1 punch 交错实锤**：范围内 d-put 在区间墓碑存活期提交必然走 planTombPunch 打洞（INV-RT1），putter 与 deleter 生命周期重叠 300ms
- **S2 突变验证**：临时禁用 db.zig 的 once-set（`compensated.append` 置空）→ S2 立即 RED（`TestExpectedEqual`）→ 还原后 GREEN。证明 S2 确实锁定 T-60 语义，非恒绿。（突变仅在本地临时执行，src/ 最终 diff 为零）

## 门逐条（bash check.sh <worktree>）

| 门 | 结果 |
|---|---|
| gate1 `test-one -Dfilter=t389` ×3 | PASS（3/3 rc=0，无 flake；单次 ~3s） |
| gate2 `git diff merge-base..HEAD -- src/` | PASS（空） |
| gate3 全量 `zig build test --seed 0x8c40347c` | PASS（rc=0，failed-command=0） |

RESULT: PASS (3/3)，exit 0。

## T-55 双发现自查

新文件被 `test-one -Dfilter=t389` 与全量 suite 双发现（gate1/gate3 分别实证）。

## 冻结 repro

无 —— 未发现新 bug。

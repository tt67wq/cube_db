# Issue T-60 — T-38-8 修复的残余漂移：第二遍补偿按 req 不按 key 去重，同批重复点删过度补偿 +1

- **状态**: closed（T-38-8 R2 @78eff59 once-set 修复，合入 `4adf813`）
- **发现于**: T-38-8 评审（cube_db-pi1，`review.md` @ `aca7936`，verdict changes-requested）
- **被评审 SHA**: `4d27725`
- **严重度**: 高（与 T-59 同级反向）—— 三口径静默失恒、公开 API 100% 确定触发

## 症状（评审者探针实证）

`src/db.zig:1081-1102` 的 T-59 第二遍对 `reqs` 逐条补偿 `revive_count += 1`，
但 `insertBatch` 对同 key 相邻重复 **last-wins 去重**（writer.zig:735-745）→ 落盘只有一次 -1。
N 条重复 tomb req → 补偿 +N、insert -1 → 净 +(N-1) 漂移。

```
put a; put b; deleteRange("b","c");
delete("b"); delete("b"); flush();   // 同批两条 tomb(b)
// expect entryCount==1 → found 2
```

`putBatch([tomb(b),tomb(b)])`、`WriteTxn` 内同 key 两次 delete + commit 均可达。
P2a/P2b 只锁了 `[tomb,put]`/`[put,tomb]`，纯重复 `[tomb,tomb]` 形态未覆盖。

## 修复方向（评审者给出）

第二遍前按 key last-wins 去重（镜像 insertBatch 语义）或对已补偿 key 记 once-set；
punch 循环天然按 key 幂等（tobs 渐进更新），第二遍向同一语义对齐。
回归用例：P2 扩 `[tomb,tomb]` 与 `delete×2→flush` 两形态。

## 关联

- T-38-8 round 2 = 本 issue 的修复轮（同一分支 `t38-8-count-drift` 续做）
- NB-1 遗留债（完整 S3 交错场景重建）经评审裁决另立后续任务，见 T-38-8 review.md §6

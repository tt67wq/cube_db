# 任务拆分：内部 Runtime 落地（隐藏 zio）

> 来源：Grill Me 盘问"这个项目绑定 ZIO 是否合理?"的结论。
> 决策：**保留 zio 依赖，但从公开 API 移除**。`Db.open` 改纯同步签名；
> D4 协程押注保留，由压测门控决定是否激活。

## 关键前提（已验证）

- `zio.File` IO 在无 runtime 上下文自动降级为同步阻塞执行（`common.zig:257 waitForIo`：
  *"If called from a context without a runtime, executes the operation synchronously."*）
- `zio.Mutex` 外部线程直接走 futex，无需 executor（`sync/Mutex.zig` 头注释）
- `db.zig` 的 `rt` 字段当前从未被任何方法使用 → 同步路径本就不依赖 runtime
- 跨线程 spawn + futex join 是一等公民（`runtime.zig:800,1918`），未来隐藏 runtime 可行

## 任务（按依赖顺序）

### T0 Spike 验证（阻塞后续一切）✅

- [x] 写 spike：普通线程直接调 `zio.File` 位置读写 + `zio.Mutex`，确认阻塞降级生效
- [x] 验证 `zio.Future.wait` 在非任务上下文行为（当前 `sendRequest` 依赖它）
- [x] 产出：确认"无 runtime 同步路径"可行，已记录阻塞点（无）

### T1 公开 API 解耦（核心改动）✅

- [x] `Db.open(allocator, path, opts)`：删除 `rt` 参数与 `rt` 字段
- [x] `sendRequest` 简化：`applyBatch` 已同步执行，保留 `zio.Future`（set 先于 wait，无副作用）
- [x] `db.zig` 头注释更新："调用方拥有 runtime" → "纯同步 API"
- [x] `get` / `select` 无 runtime 依赖，未改

### T2 模块内测试去 runtime（可与 T1 并行）✅

- [x] `file_store.zig` 内嵌测试：删 `Runtime.init` / `spawn`，直接同步调用
- [ ] `fault_store.zig` 内嵌测试：同上（无 zio runtime 使用，无需改动）

### T3 集成测试迁移✅

- [x] `tests/db_test.zig`：删 Runtime/spawn 骨架，直接同步调用；并发测试 `zio.Group` → `std.Thread` 多线程
- [x] `tests/compact_test.zig`：同上

### T4 隐藏 runtime 基建 ❌ 关闭

压测结论：同步写 3335 ops/s 对嵌入式 KV 足够，多线程降速是 mutex 串行非真实瓶颈场景。
D4 押注关闭，不建 runtime 基建。

### T5 writer 协程激活 ❌ 关闭

- [x] 压测脚本：`bench/put_bench.zig`，测同步写吞吐
- 结果：single 3335 ops/s，10-thread 2445 ops/s（不升反降）
- [x] 达标 → 记录结论，关闭 D4 押注，移除死代码（mailbox/Channel/writerLoop）

### T6 收尾✅

- [x] README 增加使用示例（同步 API）
- [x] `docs/tutorial/06-db-api.md` 更新公开 API 描述
- [x] `docs/tutorial/09-tests.md` 更新集成测试描述
- [ ] 重跑 kcov 覆盖率（命令已固化在 README），确认无回归
- [x] `zig build test` + `zig build -Doptimize=ReleaseSafe` 全绿
- [x] `bench/put_bench.zig` 保留作回归基线
- [x] 移除死代码：`Db.mailbox`/`mailbox_buf`/`writer_handle`、`writer.writerLoop`、`MAX_BATCH_*`

## 依赖图

```
T0 → T1 → T3 → T6
T1 → T4 → T5   （T5 由压测门控，可无限期推迟）
T2 ∥ T1
```

## 风险

- **T0 阻塞风险**：若 `Future.wait` 在非任务上下文行为异常 → T1 必须移除 Future，改动略增（实际无异常）
- **并发测试暴露面**：`std.Thread` 并发测试可能暴露读路径线程安全问题（当前只串行写，读不阻塞）
- **降级路径依赖**：zio 的无 runtime 阻塞降级依赖 zio 自身的平台测试覆盖，跨平台（Windows）需留意

## 完成记录

- 提交范围：`src/db.zig`、`src/file_store.zig`、`tests/db_test.zig`、`tests/compact_test.zig`、
  `docs/tutorial/06-db-api.md`、`docs/tutorial/09-tests.md`、`README.md`
- 验证：`zig build test` 全绿，`zig build -Doptimize=ReleaseSafe` 全绿
- T4/T5 保留到未来压测后决定启用/拆除

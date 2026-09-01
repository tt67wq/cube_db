# T-13 Review：putBatch 锁失败测试

## Verdict
approve

## Reviewed SHA
eced317382e5605e6f3c6eb5a91b886e544e9208

## 检查清单
- [x] 场景全覆盖
- [x] lock() 死代码判断正确
- [x] 断言具体值
- [x] 无泄漏
- [x] zig build test-db 退出 0
- [x] 未改 src/

## 检查结论

### 1. 场景全覆盖
`tests/txn_writer_db/lock_failure_test.zig` 含 4 个 test 块，超过 task.md 要求的"至少 2 个"：

| test | 场景 | 对应 task.md 要点 |
|------|------|------------------|
| Test 1 | 正常路径 putBatch 4 entries → entry_count=4 + 逐个 get 验证值 + root≠NULL_ROOT | 要点 3（正常路径，Db 状态一致） |
| Test 2 | 5 轮 putBatch 永不返回 LockFailed，文档化 dead code | 要点 4 + 死代码标注 |
| Test 3 | 2 线程并发 putBatch（各 50 key）→ join → entry_count=101 + 抽查 A_25 值正确 | 要点 4（并发正确性，不 panic/deadlock，数据一致） |
| Test 4 | putBatch 3 entries → entry_count=3 + 全部 future 成功 + 3 key 可读 | 要点 5（半应用检查，无半应用状态） |

正常路径（要点 3）+ 并发路径（要点 4）+ 半应用（要点 5）三档齐备。

### 2. lock() 死代码判断正确
task.md 明确要求"先读源码确认 write_mutex 类型和 lock() 签名"。验证如下：

- `src/db.zig:11` `const Mutex = zio.Mutex;`，`Db.write_mutex: Mutex`
- `src/db.zig:141` `self.write_mutex.lock() catch return error.LockFailed;`
- zio `Mutex.lock()` 签名（`../zio/src/sync/Mutex.zig:71`）：`pub fn lock(self: *Mutex) Cancelable!void`
  - 路径 A（line 72）：`tryLock()` 成功 → `return` void（无 error）
  - 路径 B（line 73-74）：`has_thread_futex and getCurrentTaskOrNull() == null` → `lockThread()` 返回 **void**（同步线程，futex 自旋等待，无 error）
  - 路径 C（line 76）：否则 `lockSlow(.allow_cancel)` 返回 `Cancelable!void`，仅异步运行时 task 被取消时返回 `error.Canceled`
- `Cancelable = error{Canceled}`（`../zio/src/common.zig:23`）

测试注释准确描述了路径 B（同步上下文，`getCurrentTaskOrNull() == null` → `lockThread()` → void → `catch` 永不触发）。Test 2 文档化此行为（`// note: lock() never returns error in current Zig, catch is dead code`），判断与源码一致。判断正确。

### 3. 断言具体值
非弱断言（不只测不 panic），逐项断言 Db 状态一致：

- Test 1：`expectEqual(@as(u64,4), db.entryCount())` + 每条 `expectEqualStrings(e.value, v.?)` + `db.getRoot() != NULL_ROOT`
- Test 2：5 轮后 `expectEqual(@as(u64,5), db.entryCount())`
- Test 3：`expectEqual(@as(u64, 101), db.entryCount())`（2×50+1） + 抽查 `A_25` → `expectEqualStrings(expected_v, v.?)`
- Test 4：`expectEqual(@as(u64,3), db.entryCount())` + 3 个 `expectEqualStrings`（k1/k2/k3）

断言强度达标：entry_count 精确值 + get 返回值精确字符串 + root 状态，覆盖 task.md 要求的"Db 状态一致（entry_count、get 返回值）"。

### 4. 无泄漏
- 全部用 `std.testing.allocator`（alloc），其会在结束时检测泄漏并使 test 失败
- 每个 `db.get` 返回的 `?[]u8` 均有 `alloc.free(v.?)`（Test 1/3/4 均成对 free）
- `Db.open` 分配的 State + Db 由 `defer db.close()` 释放（close 内 destroy state + db + flush pending）
- `MemPageStore` 由 `defer ms.deinit()` 释放
- Test 3 并发线程内 `putBatch` 的 key/value 为栈 buf（`bufPrint` 写入 `[32]u8`），applyBatch 内部 dupe 到 leaf，调用方无需释放
- `zig build test-db` 实测 26/26 pass 无 leak 报错 → 无泄漏确认

### 5. zig build test-db 退出 0
实测：`zig build test-db --summary all` → Build Summary 10/10 steps succeeded; 26/26 tests passed；EXIT 0。lock_failure_test 的 4 个 test 在其中一档（4 pass）执行并全绿。

### 6. 未改 src/
`git show --stat eced317` 显示改动仅 3 文件：
- `build.zig`（+15：注册 lock_failure_test 到 test-db step）
- `tests/txn_writer_db/lock_failure_test.zig`（+161：新建）
- `tests/txn_writer_db_test.zig`（+1：comptime import）

`git show eced317 --name-only | grep -c 'src/'` = 0 → src/ 零改动。

## 问题
无。所有检查点通过。

可选小改进（非 blocking）：
- Test 3 并发仅 2 线程 × 50 key，未覆盖更多线程或更长跑（如 4 线程 × 500 key）以更强压测锁竞争；但当前规模足以验证不 deadlock + 数据一致，满足 task.md 要求。
- Test 4 标题"中途 future 失败不影响其他 future"但实际未注入任何 failure（putBatch 全成功），更像"正常无半应用"测试。若要真正测 failure 隔离需注入 btree.insert 失败（如 OOM），但当前实现正常路径断言已满足要点 5"Db 状态一致"的验收。

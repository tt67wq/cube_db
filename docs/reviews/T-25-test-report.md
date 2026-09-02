# T-25 Test Report: 讲义 §5.1 扩写验收

- **Tester**: w-lucky-valley（非作者；作者 ws1-pi1）
- **Tested**: `main@8dc614a + uncommitted docs change`（主 checkout 工作区，s51 sha256 `f513ffff…e5fee` 已复核一致）
- **被测代码基线**: worktree `worktree/lucky-valley-dabc` @ `8dc614a`（与被测文档同源）
- **日期**: 2026-09-02

## Result: ✅ PASS

## 环境指纹

```
$ zig version
0.16.0
$ uname -sr
Darwin 25.6.0 (arm64)
$ python3 --version
Python 3.x（系统）
```

## 测试项

### T1. 契约验收命令（必须 exit 0）

```
$ python3 /Users/admin/Project/Zig/cube_db/.agents/tasks/T-25/check_s51.py
PASS: s51 region has 5 <h4> sections, 2 note boxes, keywords present, tail unchanged
exit=0
```

**PASS**。附加核验：`baseline_tail.html` 与当前文件 `<h3 id="s52">` 之后内容逐字节一致。

### T2. 被测对象完整性

```
$ python3 <sha256 of s51 region>   # 契约给定命令
f513ffff01312f2bc24106a1adb181b90e84dcb875ecde36c5bce2fc842e5fee
```

**PASS** — 与任务下发值一致，评审对象锁定。

### T3. 构建回归

```
$ zig build          # worktree @ 8dc614a
exit=0
```

**PASS** — 零警告输出，构建正常。

### T4. 相关测试（文档改动不应影响，验证无意外破坏）

按契约「仓库既有 btree 测试入口」（build.zig:342 `test-btree` 等）逐项执行：

```
zig build test-btree   → exit=0
zig build test-writer  → exit=0
zig build test-ps      → exit=0
zig build test-db      → exit=0
zig build test-mvcc    → exit=0
zig build test-format  → exit=0
zig build test-overflow→ exit=0
zig build test-txn-arena→ exit=0
zig build test-compact → exit=0
zig build test-crc32   → exit=0
zig build test-fuzz    → exit=0
```

**PASS** — 全部通过。

### T5. 全量 `zig build test`（记录观察）

多次运行结果不稳定：部分轮次 exit=0，部分轮次打印 `failed command: .zig-cache/.../test` ×2 但最终 exit 仍为 0（Zig 0.16 并行 test 调度下退出码聚合异常）。定位到间歇失败的两个重型性能/内存画像测试：

- `tests/core_format/slab_memory_test.zig`（100K batch + delete-all 的活跃页数断言，:55）
- `tests/crash_insertbatch_pb/pb_fps_ordered_test.zig`（FilePageStore 1M putBatch，page_allocator，机器负载敏感）

判定：**预存 flaky，与本任务无关**。依据：(a) 被测改动仅 docs/lecture_btree.html，未触碰 src/tests/build.zig；(b) 失败发生在与其无调用关系的独立测试二进制中；(c) 所有相关 scoped step 稳定通过。建议另立任务跟踪该两例稳定性。

## 汇总

| 项 | 结果 |
|----|------|
| check_s51.py（acceptance） | exit 0 ✅ |
| s51 sha256 锁定 | 一致 ✅ |
| zig build | PASS ✅ |
| scoped 测试（11 个 step） | 全部 PASS ✅ |
| zig build test 全量 | 间歇 flaky（预存、非本改动所致），见 T5 ⚠️ |

**总体：PASS**

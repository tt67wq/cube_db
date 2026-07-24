# 09 - 测试体系

## 本章目标

读完本章，你应该能：
- 理解 `cube_db` 的测试为什么分层。
- 看懂单元测试、集成测试、崩溃注入测试、模型测试。
- 知道如何添加新的测试。

---

## 1. 为什么测试很重要？

存储引擎的 bug 往往很严重：
- 数据丢失。
- 文件损坏。
- 并发竞争导致读错数据。
- 崩溃后无法恢复。

手工测试很难覆盖所有场景。所以 `cube_db` 用自动化测试，分不同层次验证。

---

## 2. 测试分层

| 层次 | 范围 | 文件 | 特点 |
|------|------|------|------|
| 单元测试 | 单个模块纯逻辑 | `src/*.zig` 里的 `test` 块 | 无 IO，毫秒级 |
| 集成测试 | 全链路真文件 | `tests/db_test.zig` | 用临时文件，直接同步调用 |
| 崩溃测试 | 故障注入 | `src/fault_store.zig` | 模拟断电、撕裂写 |
| 模型测试 | 随机序列对比 | `src/btree.zig` 的模型测试 | 用 `StringHashMap` 当参考模型 |

---

## 3. 单元测试：MemStore 是基石

`src/store.zig` 提供 `MemStore`：用内存数组模拟文件。

示例：

```zig
test "store: append node + pread roundtrip" {
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    const data = "nodepayload";
    const off = try s.append(data);
    try std.testing.expectEqual(@as(u64, 0), off);

    var buf: [16]u8 = undefined;
    const n = try s.read(&buf, off);
    try std.testing.expectEqualStrings(data, buf[0..n]);
}
```

单元测试的好处：
- 快：内存操作，不碰磁盘。
- 稳定：没有文件路径、权限、并发等外部因素。
- 可注入：可以破坏内存数据，模拟崩溃。

---

## 4. 集成测试：真文件 + zio runtime

`tests/db_test.zig` 里的 `withDb` 模板：

```zig
fn withDb(comptime body: fn (db: *Db) anyerror!void) !void {
    const path = "cube_db_itest.db";
    zio.Dir.cwd().deleteFile(path) catch {};
    defer zio.Dir.cwd().deleteFile(path) catch {};

    const db = try Db.open(std.testing.allocator, path, .{});
    defer db.close() catch {};
    try body(db);
}
```

所有 DB 操作通过同步 API 直接调用，不再需要在 zio runtime 协程里执行。

集成测试验证：
- open → put → get → close 全链路。
- 重开后数据还在。
- 并发 put 不丢失（多线程 std.Thread）。

---

## 5. 崩溃注入测试：FaultStore

`src/fault_store.zig` 用 `MemStore` 包装出故障注入能力。

例如：

```zig
test "fault: header torn (crc bad) -> fall back to previous" {
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();

    _ = try ms.appendHeaderRecord(.{ .btree_root = 1, ... });
    _ = try ms.appendHeaderRecord(.{ .btree_root = 2, ... });

    // 破坏最后一个 header 记录的 payload 区一字节（去 marker：记录 = len(4)+payload(38)+crc(4)，
    //   翻倒数第 6 字节即 payload 区）→ CRC 失败
    const total = ms.logical_len;
    ms.data.items[@intCast(total - 6)] ^= 0xff;

    const r = try store_mod.getLatestHeader(std.testing.allocator, ms.store());
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 1), r.?.header.btree_root);
}
```

这类测试让“崩溃后恢复”变成可重复的代码验证。

---

## 6. 模型测试：最重要的防线

`src/btree.zig` 的这条测试是核心：

```zig
test "btree: model test random ops vs StringHashMap (seed 7)"
```

思路：
1. 维护一个 `std.StringHashMap([]u8)` 作为“真相”。
2. 随机生成 put/delete 操作序列。
3. 同时打到 `btree` 和 `StringHashMap`。
4. 每步后对比单个 key 的 get 结果。
5. 最后全量 `select(null, null)` 与 `StringHashMap` 比对条目数。

为什么比手工用例强？
- 随机生成几千次操作，覆盖大量边界情况。
- 手工很难想到“连续删除再插入同一个 key”这种组合。
- 一旦失败，seed 固定后可以复现。

模型测试是 `cube_db` B-tree 正确性的主力防线。

---

## 7. build.zig 自动发现测试

`build.zig` 会自动把 `tests/*.zig` 加进测试步骤：

```zig
var tests_dir = b.build_root.handle.openDir(io, "tests", .{ .iterate = true }) catch { return; };
var tests_iter = tests_dir.iterate();
while (tests_iter.next(io) catch null) |entry| {
    if (entry.kind != .file) continue;
    if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
    // add test
}
```

这意味着：你只需要在 `tests/` 下新建一个 `.zig` 文件，运行 `zig build test` 就会自动跑它。

---

## 8. 运行测试

```bash
# 跑全部测试
zig build test

# 检查 ReleaseSafe 无警告
zig build -Doptimize=ReleaseSafe
```

当前 `cube_db` 的全部测试都通过。

---

## 9. 如何添加新测试？

单元测试：在对应 `src/*.zig` 文件末尾加 `test` 块：

```zig
test "my module: behavior description" {
    var ms = MemStore.init(std.testing.allocator);
    defer ms.deinit();
    // 测试逻辑
}
```

集成测试：在 `tests/` 下新建文件，例如 `tests/my_test.zig`：

```zig
const std = @import("std");
const cube = @import("cube_db");
const Db = cube.Db;

test "my integration test" {
    const path = "my_test.db";
    zio.Dir.cwd().deleteFile(path) catch {};
    defer zio.Dir.cwd().deleteFile(path) catch {};

    const db = try Db.open(std.testing.allocator, path, .{});
    defer db.close() catch {};
    // 操作，断言
}
```

不需要修改 `build.zig`。

---

## 10. 本章小结

- 测试分单元、集成、崩溃注入、模型测试四层。
- `MemStore` 让单元测试快速无副作用。
- 集成测试跑真文件和同步 API。
- 并发测试使用 `std.Thread` 多线程。
- `FaultStore` 让崩溃场景可重复测试。
- 模型测试用随机序列对比参考模型，是 B-tree 正确性的主力防线。

---

## 11. 本章练习

1. 给 `btree.zig` 加一条模型测试，用另一个 seed（比如 42）跑 5000 次操作。
2. 在 `tests/db_test.zig` 加一条：并发 5 个线程，每个 put/delete 后立刻 get 验证。
3. 写一条崩溃测试：先 put 一个 key，然后在 `Db.open` 模拟“header 没写就崩溃”，验证重开后数据丢失但不损坏。
4. 统计 `src/` 里一共有多少个 `test` 块（提示：用 `grep -c 'test "'`）。
5. 思考：为什么模型测试要用固定 seed？如果 seed 随机，失败后会带来什么麻烦？

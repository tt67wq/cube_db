# Fuzzy 测试操作手册

## 快速命令

```bash
# CI 回归 + smoke（推荐，~2 秒）
zig build test-fuzz

# 全量单测 + fuzz
zig build test && zig build test-fuzz
```

## 测试架构

四个 fuzz 目标，分三个优先级批次：

| 目标 | 文件 | oracle（什么是 bug） | 迭代数 |
|------|------|---------------------|--------|
| 探针 | `probe_test.zig` | 框架自检，不崩就行 | 1000 |
| WAL 解析 | `wal_fuzz_test.zig` | 任意字节不 panic，合法 roundtrip，CRC 损坏报错 | 1000 |
| DB API | `api_fuzz_test.zig` | 随机 op 序列 vs `StringHashMap` 参考模型对账 | 100 |
| 页格式 | `format_fuzz_test.zig` | 任意字节解码不 panic | 1000 |

测试结构：每个文件包含两个测试 block——

- **smoke**: `fuzz.fuzzLoop()` 随机生成 `Smith` 输入，跑 N 次
- **corpus**: `fuzz.replayCorpus()` 读取 `tests/fuzz/corpus/<target>/` 下文件确定性重放

## 项目结构

```
tests/fuzz/
├── common.zig              # 公共框架：fuzzLoop + fuzzLongRun + replayCorpus
├── probe_test.zig          # F1: 探针测试
├── wal_fuzz_test.zig       # F2: WAL 解析 fuzz
├── api_fuzz_test.zig       # F3: DB API 操作序列 fuzz
├── format_fuzz_test.zig    # F4: 页格式解码 fuzz
└── corpus/
    ├── probe/              # 探针 corpus（当前空）
    ├── wal/                # WAL crash corpus
    ├── api/                # API mismatch corpus
    └── format/             # 格式 crash corpus
```

## 发现 crash 后的操作

### 1. 保存 crash 输入到 corpus

crash 输入作为 `.bin` 文件保存在 `tests/fuzz/corpus/<target>/`，下次 `replayCorpus` 会自动重放。

### 2. 加确定性单测

在对应的 `*_fuzz_test.zig` 文件里加一个 `test` block，用已知 crash 输入构造 `Smith`，验证修复不再崩：

```zig
test "regression: crash_123" {
    var ctx: usize = 0;
    var smith = std.testing.Smith{ .in = &[_]u8{ 0xFF, 0x00, ... } };
    try myFuzzTarget(&ctx, &smith);
}
```

### 3. 修复 → 确认回归通过

```bash
zig build test-fuzz    # 新 corpus 重放 + smoke 全 green
zig build test         # 全量单测不崩
```

## 本地长跑

`fuzz.fuzzLongRun(ctx, target, max_time_ms, seed)` 按时间预算跑循环，不用改迭代数：

```zig
// 在测试文件里，替换 fuzz.fuzzLoop 为 fuzz.fuzzLongRun
test "WAL long run" {
    var ctx: usize = 0;
    const seed = std.testing.random_seed;
    _ = try fuzz.fuzzLongRun(usize, &ctx, walParseTestOne, 30_000, seed);
}
```

然后跑 `zig build test-fuzz`。30 秒后自动停，无 crash 无 leak 则 green。

`fuzzLongRun` 使用 `.awake` 单调时钟，不受系统时间跳变影响，每 64 轮检查一次 deadline（~100ns 精度）。

### 建 build option（可选）

在 `build.zig` 的 fuzz 测试块里加 `-Dfuzz-long=<ms>` 参数控制，默认 0 跳过。
每个目标读 option 后决定是否跑 long-run 测试。

## 泄漏检测

### 当前机制

`std.testing.allocator` 在每个 test 结束后自动检测泄漏。如果 fuzz 目标有泄漏，
test runner 会报告 `[DebugAllocator] (err): memory address 0x... leaked:` 并 exit 1。

### 逐轮泄漏检测（未实现）

`fuzzLongRun` 的逐轮泄漏检查因 `DebugAllocator.deinit()` 会在中途触发 `std.debug.log`，
导致 test runner 的 `log_err_count > 0` 而 exit 1（即使 test 断言通过）。

**workaround 方向**：
- 用 `std.heap.GeneralPurposeAllocator(.{ .verbose_log = false })` 替代 `testing.allocator`
- 每 N 轮检查 `gpa.detectLeaks()` 是否 > 0
- 但需要改 fuzz 目标接口（传 allocator 而不是硬编码 `testing.allocator`）

当前 end-of-test 泄漏检测已够用：慢泄漏会被累加，最后 `deinit` 会抓到。

## oracle 细则

### WAL 解析 oracle

- 任意字节输入不能 panic（segfault/UB/index out of bounds）
- 合法 WAL 条目（含 CRC）必须被正确解析，roundtrip 正确
- CRC 损坏：解析必须跳过该条目（从下个字节重试），不能静默返回损坏数据

### DB API oracle

- `api_fuzz_test` 里的 `execOneOp` 对每次 get 执行一致性检查
- `error.ModelMismatch` 说明 Db 和 `StringHashMap` 参考模型不一致——这是 bug
- 覆盖 put/get/delete 三种操作

### 页格式 oracle

- `decodePageHeader(buf)` 对任意 24 字节不能 panic
- `decodeMetaPayload(buf)` 对任意 payload 不能 panic
- 非法输入可能返回垃圾值，但不能 UB

## 已知限制

### Zig 0.16.0 `-ffuzz` 编译器 bug

```text
error: expected type '*const debug.StackTrace', found '*builtin.StackTrace'
/Users/admin/.asdf/installs/zig/0.16.0/lib/compiler/test_runner.zig:566
```

`zig test --fuzz` 在 0.16.0 发行版不可用。**workaround**：我们的 `fuzzLoop` 直接生成随机 `Smith.in` 字节，绕过 `-ffuzz`，实现了相同的结构化输入模型（只缺 coverage guidance）。

修复方式：用 `--test-runner` 指定修复后的 test runner，或升级到修复该 bug 的 Zig 版本。

### 无 coverage guidance

当前 `fuzzLoop` 和 `fuzzLongRun` 是纯随机扫描，不是 coverage-guided 的 AFL/libFuzzer 风格。发现新路径的效率较低，但作为 CI smoke 足够。要真正的 coverage-guided fuzz 需要 `-ffuzz` bug 修掉。

### 逐轮泄漏检测未实现

见上方"泄漏检测"章节。`DebugAllocator.deinit()` 的日志机制导致 mid-run 检查不可行，目前只有 end-of-test 泄漏检测。
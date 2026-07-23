# cube_db

用 Zig 0.16.0 写的嵌入式键值存储，参考 [CubDB](https://github.com/lucasavila00/cubdb) 架构：

- 嵌入式 KV 引擎：`get` / `put` / `delete` / `select`
- append-only 数据文件
- 不可变 B-tree（Copy-on-Write）
- compaction 回收旧版本

完整实现说明见 [`docs/tutorial/`](docs/tutorial/)。

## 依赖

- Zig 0.16.0
- 本地 `../zio` 仓库（`build.zig.zon` 的 path 依赖）

## 构建与测试

```bash
zig build test
```

## Benchmark

20 格矩阵（5 op × 2 规模 × 2 value 尺寸）。**必须 ReleaseFast**，Debug 数字无意义。

```bash
zig build bench -Doptimize=ReleaseFast                  # 全量
zig build bench -Dbench-scale=small -Doptimize=ReleaseFast  # smoke / 快跑
```

`-Dbench-scale` 取 `all`|`small`|`large`（默认 `all`）。设计见 `docs/benchmark-design.md`。

### 结论（NVMe，ReleaseFast）

基准矩阵主要数字与判读：

| 维度 | small | large | 结论 |
|---|---|---|---|
| put 100B | 498 us/op | 706 us/op | small→large 变陡 ~1.4×，热在 fsync（~400us/op 固定成本），B-tree 深度次要 |
| put 10KB | 3.9 ms/op | 3.8 ms/op | 几乎不随规模变，IO 带宽主导（~10KB/fsync） |
| get 100B | 251 us/op | 494 us/op | large 翻倍 → B-tree 查找 / 随机读随深度变热；仍远快于 put（无 fsync） |
| get 10KB | 786 us/op | 1.3 ms/op | IO + 查找双重成本 |
| delete 100B | 416 us/op | — | 同 put 路径（墓碑 + fsync），成本接近 put |

要点：

1. **fsync 是绝对热点**。put/delete 每 op 固定 ~400–700us，≈ fsync 延迟；putNoFsync 未测但引擎开销上限即此。
2. **put 10KB vs 100B 差值 ≈ 写盘时间**：3.8ms − 0.7ms ≈ 3.1ms/10KB ≈ ~3.2 MB/s 落盘带宽，fsync 串行拖后腿。
3. **get 远快于 put**（251us vs 498us，无 fsync），符合预期；large get 翻倍 → 查找 / page cache 未命中随规模上升，优化点在 B-tree 查找与读路径。
4. **compact**：small 100B ~4s / 10KB ~35s，全量重写（seq read + write + sync），~100MB 耗 35s ≈ ~2.9 MB/s —— fsync 串行与单线程重写是瓶颈，多线程重写 / 流式 sync 是优化方向。
5. **COW dirt 放大**：large×100B 预载（1M puts）产生 ~4.7GB 物理文件（live ~120MB，~33×），auto-compact 当前是 stub 未自动回收——手动 `compact()` 或后台 compactor 是必需。

> **最高 ROI 优化**：开组提交 / 批量 fsync（`sendRequest` 现每 op 1 元素 batch + 1 fsync），put/delete 吞吐可提升 1–2 个量级；其次 get 查找路径与 compact 流式化。

> 注：delete large / select large / compact large 单格耗时长（fsync 次数 × 1M 或全量重写 1GB+），未在 50min 内跑完；形态与 small 同构，按规模线性放。

## 使用示例

```zig
const cube = @import("cube_db");
const Db = cube.Db;

const db = try Db.open(allocator, "my.db", .{});
defer db.close() catch {};

try db.put("hello", "world");
const v = try db.get("hello");
if (v) |value| {
    // value 由 allocator 分配，用完 free
    allocator.free(value);
}
```

`Db.open` 是**纯同步 API**，不需要调用方准备 `zio.Runtime`。
内部文件 IO 通过 zio 的阻塞降级机制执行，未来启用 writer 协程（D4）时调用方也无感。

## 测试覆盖率

Zig 0.16.0 没有内置覆盖率，这里用 [kcov](https://simonkagstrom.github.io/kcov/) 收集。

### 1. 安装 kcov

```bash
brew install kcov
```

### 2. 临时 options 模块

`zig test` 命令行不会生成 `build.zig` 里的 `zio_options` 模块，需要先写一份临时文件：

```bash
cat > /tmp/zio_options.zig <<'EOF'
pub const backend: ?[]const u8 = null;
pub const ResolveBeneathMode = enum { strict, best_effort };
pub const resolve_beneath_mode = ResolveBeneathMode.best_effort;
pub const no_hacks = false;
pub const task_migration = true;
EOF
```

### 3. 收集 src 单测覆盖率

```bash
rm -rf /tmp/cov_src
zig test --test-cmd kcov \
  --test-cmd --include-pattern="$PWD" \
  --test-cmd /tmp/cov_src --test-cmd-bin \
  --dep zio -Mroot=src/root.zig \
  --dep zio_options -Mzio=../zio/src/zio.zig \
  -Mzio_options=/tmp/zio_options.zig
```

### 4. 收集集成测试覆盖率

```bash
rm -rf /tmp/cov_db /tmp/cov_compact

zig test --test-cmd kcov \
  --test-cmd --include-pattern="$PWD" \
  --test-cmd /tmp/cov_db --test-cmd-bin \
  --dep cube_db --dep zio -Mroot=tests/db_test.zig \
  --dep zio_options -Mzio=../zio/src/zio.zig \
  --dep zio -Mcube_db=src/root.zig \
  -Mzio_options=/tmp/zio_options.zig

zig test --test-cmd kcov \
  --test-cmd --include-pattern="$PWD" \
  --test-cmd /tmp/cov_compact --test-cmd-bin \
  --dep cube_db --dep zio -Mroot=tests/compact_test.zig \
  --dep zio_options -Mzio=../zio/src/zio.zig \
  --dep zio -Mcube_db=src/root.zig \
  -Mzio_options=/tmp/zio_options.zig
```

### 5. 合并并查看报告

```bash
rm -rf /tmp/cov_merged
kcov --merge /tmp/cov_merged /tmp/cov_src /tmp/cov_db /tmp/cov_compact
open /tmp/cov_merged/kcov-merged/index.html
```

### 当前覆盖率

42 个测试全部通过，项目代码覆盖率 **96.9%**（1436 / 1482 行）。

| 文件 | 覆盖率 |
|------|--------|
| `src/format.zig` | 100.0% |
| `src/btree.zig` | 99.3% |
| `src/fault_store.zig` | 97.3% |
| `src/db.zig` | 95.3% |
| `src/store.zig` | 92.9% |
| `src/file_store.zig` | 91.8% |
| `src/writer.zig` | 80.4% |
| `src/root.zig` | 50.0% |

主要未覆盖部分是 `src/root.zig` 的占位导出函数，以及 `src/writer.zig` 的部分错误分支。

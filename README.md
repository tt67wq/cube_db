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

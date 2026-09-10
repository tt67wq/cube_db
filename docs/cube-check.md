# cube_check 使用文档

`cube_check` 是 cube_db 的**离线完整性校验工具**（T-35 Part B 引入）。它扫描数据库文件的
每一个数据页，对每页做整页 CRC 校验，用于**主动巡检**落盘数据是否发生位腐坏（bit rot）、
部分写入或静默损坏。它在文件上做只读扫描，不改写任何内容。

> 与读路径 CRC 档位的区别：读路径的 `Options.crc_check`（`off`/`sample`/`full`）是在
> **热读取**时按策略校验被访问到的页；`cube_check scrub` 是**离线**地、**无条件地**逐页
> 校验 `[FIRST_DATA_PAGE ..= meta.last_page]` 全部数据页，二者用途不同、可叠加使用。

---

## 目录

1. [安装与构建](#1-安装与构建)
2. [基本用法](#2-基本用法)
3. [退出码](#3-退出码)
4. [输出说明](#4-输出说明)
5. [典型场景](#5-典型场景)
6. [限制与注意事项](#6-限制与注意事项)
7. [实现与测试](#7-实现与测试)

---

## 1. 安装与构建

依赖与主库一致：Zig 0.16.0 + 本地 `../zio` 仓库。

```bash
# 编译并安装可执行文件到 zig-out/bin/cube_check
zig build
```

运行目标（无需手动找二进制路径）：

```bash
zig build cube-check -- scrub <db-path>
```

也可直接运行编译产物：

```bash
./zig-out/bin/cube_check scrub <db-path>
```

---

## 2. 基本用法

```
Usage: cube_check scrub <db-path>
```

| 参数 | 说明 |
|---|---|
| `scrub` | 子命令，执行离线完整性校验（当前唯一子命令） |
| `<db-path>` | 数据库文件路径（`FilePageStore` 使用的文件） |

示例：

```bash
# 校验一个数据库文件
./zig-out/bin/cube_check scrub data/cube.db

# 用构建目标运行（等价）
zig build cube-check -- scrub data/cube.db

# 查看帮助与退出码说明
./zig-out/bin/cube_check --help
# 或
./zig-out/bin/cube_check -h
```

校验是只读的：打开文件后对每个数据页读页、跑 `verifyPageChecksum`，**不写回、不修复、
不改写任何页**。要恢复损坏数据，需从备份或副本重建。

---

## 3. 退出码

| 退出码 | 常量 | 含义 |
|---|---|---|
| `0` | `EXIT_OK` | 全部数据页通过 CRC 校验（无损坏） |
| `1` | `EXIT_USAGE` | 用法错误：参数错误、无法打开 DB 文件、或文件无有效 meta 页 |
| `2` | `EXIT_CORRUPT` | 发现损坏：至少一个数据页 CRC 校验失败 |

可直接用于脚本判断：

```bash
if ./zig-out/bin/cube_check scrub "$DB"; then
  echo "OK: 数据完整"
elif [ $? -eq 2 ]; then
  echo "损坏: 发现 CRC 失败页"
else
  echo "用法/打开错误"
fi
```

---

## 4. 输出说明

- 每个 CRC 失败的数据页输出一行，标注页号与页类型：

  ```
  page 33: CRC FAILED (type BRANCH)
  page 64: CRC FAILED (type LEAF)
  ```

  页类型取值：`FREE` / `META` / `BRANCH` / `LEAF` / `OVERFLOW`；无法识别时输出
  `(type <数字>, unknown)`。

- 汇总一行：

  ```
  scrub: total=101 passed=98 failed=3
  ```

- 存在失败页时，追加一行失败页号列表：

  ```
  failed pages: 33 64 90
  ```

- 校验通过时仅输出汇总（`failed=0`），退出码为 `0`。

---

## 5. 典型场景

- **周期性巡检**：对长时间运行的在线库，定期离线 scrub，尽早发现位腐坏。
- **部署/迁移前体检**：把 DB 从备份恢复、跨机拷贝或升级引擎前先跑一遍，确认源文件完整。
- **故障排查**：读路径 `crc_check` 报 `error.CorruptCrc` 时，用 scrub 全量定位损坏页。
- **CI 冒烟**：在测试中写入样本库后对每页做损坏注入（参考 `tests/cube_check_test.zig`），
  断言 scrub 精确检出并给出正确退出码（M13/M14/M15）。

---

## 6. 限制与注意事项

- **要求排他访问**：`FilePageStore` 打开时持有排他文件锁（flock）。**DB 不能被任何写进程
  占用**——在线写的库需先停止写入（或对该库的副本执行），否则无法打开。
- **只读、不修复**：scrub 只报告 CRC 失败页，不做页级修复或恢复；损坏页需从备份恢复。
- **逐页全量**：它校验 `[FIRST_DATA_PAGE ..= meta.last_page]` 区间内的所有页，与读路径
  `crc_check` 的抽样规则无关（`scrub` 不看档位，无条件逐页校验）。因此大库会比较耗时
  （每页一次 CRC），适合离线批跑而非在线热读路径。
- **无 meta 即报错**：文件存在但没有有效 meta 页（例如空文件或初始化前状态）返回
  `EXIT_USAGE`（`error.NoMeta`）。
- **校验范围以 meta.last_page 为准**：已回收进 freelist 的页是否分配以 meta 为准；
  scrub 校验的是"已被分配的最高页"以内的页区间，逐页判定 CRC。

---

## 7. 实现与测试

- **实现**：`src/cube_check.zig`。
  - 核心逻辑是库函数 `scrub(allocator, store, writer)`，返回 `ScrubReport`
    （`total` / `passed` / `failed[]`），逐页调用 `format.verifyPageChecksum`。
  - `main` 只做 argv 解析与退出码映射，`--help`/`-h` 打印帮助并返回 `0`。
  - 页类型诊断取自 `format.decodePageHeader`，对损坏页是尽力而为的提示。
- **测试**：`tests/cube_check_test.zig`。
  - 单元层直接测 `scrub`（干净库全过、单页损坏检出、多页损坏逐个列出、无 meta 报错）。
  - CLI 层（M15）通过子进程断言退出码映射（`zig-out/bin/cube_check` 需先 `zig build`；
    若无该产物，此用例跳过）。
- **集成**：由 build.zig 的 `zig build test` 自动发现 `tests/*.zig` 纳入回归。

---

## 相关

- 读路径 CRC 档位：`Options.crc_check`（`off` / `sample` / `full`），见 `src/btree.zig`
  （`CrcCheck`）与 `docs/usage.md`。
- 校验实现：`src/format.zig`（`verifyPageChecksum` / `decodePageHeader`）。

# 01 - 项目结构与构建

## 本章目标

读完本章，你应该能：
- 说出 `cube_db` 项目里每个目录/文件的作用。
- 理解 `build.zig` 和 `build.zig.zon` 在做什么。
- 能独立运行 `zig build test` 并看懂测试结果。

---

## 1. 为什么先讲项目结构？

新手看代码，最容易犯的错误是：直接打开 `src/main.zig`，然后从第一个函数开始读，最后发现看不懂“为什么这个函数存在”。

一个项目就像一座大楼：
- 构建脚本（`build.zig`）是施工方案。
- 模块划分（`src/*.zig`）是楼层分工。
- 依赖（`build.zig.zon`）是外包材料。

先看结构，再读细节，才能知道每块代码属于哪一层。

---

## 2. 目录结构

```
cube_db/
├── build.zig              # 构建脚本
├── build.zig.zon          # 包配置与依赖
├── docs/
│   ├── DESIGN.md          # 设计文档（必读参考）
│   ├── PROGRESS.md        # 实现进度
│   └── tutorial/          # 本教程
├── src/
│   ├── root.zig           # 库入口
│   ├── main.zig           # 可执行入口（占位）
│   ├── format.zig         # 文件格式
│   ├── store.zig          # Store 抽象 + 内存实现
│   ├── file_store.zig     # 真实文件实现
│   ├── fault_store.zig    # 故障注入实现
│   ├── btree.zig          # B-tree 索引
│   ├── writer.zig         # 写路径状态与 batch
│   └── db.zig             # 公开 API
└── tests/
    ├── db_test.zig        # 集成测试
    └── compact_test.zig   # compaction 测试
```

---

## 3. `build.zig` 是干什么？

Zig 项目用 `build.zig` 描述“这个项目要编译成什么、依赖什么、怎么测试”。可以把它理解成 Makefile / CMake / package.json 的 Zig 版本。

`cube_db` 的 `build.zig` 主要做了四件事：

### 3.1 引入 `zio` 依赖

```zig
const zio_dep = b.dependency("zio", .{ .target = target, .optimize = optimize });
const zio_mod = zio_dep.module("zio");
```

这表示 `cube_db` 依赖一个名为 `zio` 的 Zig 模块，它提供异步运行时和文件 IO。

### 3.2 定义库模块 `cube_db`

```zig
const mod = b.addModule("cube_db", .{
    .root_source_file = b.path("src/root.zig"),
    .target = target,
    .optimize = optimize,
});
mod.addImport("zio", zio_mod);
```

这表示：外部代码可以通过 `@import("cube_db")` 引入这个库，库的入口文件是 `src/root.zig`。

### 3.3 定义可执行文件

```zig
const exe = b.addExecutable(.{
    .name = "cube_db",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cube_db", .module = mod },
            .{ .name = "zio", .module = zio_mod },
        },
    }),
});
```

目前 `main.zig` 只是打印一句话，说明项目能编译成功。真正业务逻辑在库里。

### 3.4 注册测试

```zig
const mod_tests = b.addTest(.{ .root_module = mod });
const exe_tests = b.addTest(.{ .root_module = exe.root_module });

var tests_dir = b.build_root.handle.openDir(io, "tests", .{ .iterate = true }) catch { return; };
// 遍历 tests/*.zig，每个都加进 test step
```

三种测试：
1. 库模块测试（`src/` 里的 `test` 块）。
2. 可执行文件测试（`main.zig` 的 `test`）。
3. `tests/` 目录下的 `.zig` 文件（自动发现，不用手动注册）。

---

## 4. `build.zig.zon` 是干什么？

`build.zig.zon` 是 Zig 的“包清单”：

```zig
.{
    .name = .cube_db,
    .version = "0.0.0",
    .fingerprint = 0x561af1326a981d69,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .zio = .{
            .path = "../zio",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "tests",
    },
}
```

含义：
- 项目名 `cube_db`，版本 `0.0.0`。
- 要求 Zig 最低版本 `0.16.0`。
- 依赖 `zio`，并且用的是本地路径 `../zio`，而不是从网络下载。
- `paths` 表示发布包时包含哪些目录。

为什么用本地路径？因为 MVP 阶段直接把 `zio` 放在同级目录，方便联调。

---

## 5. `src/root.zig` 导出了什么？

`root.zig` 是库的“门面”。其他项目引用 `cube_db` 时，看到的就是这里导出的内容。

```zig
const std = @import("std");

pub const format = @import("format.zig");
pub const store = @import("store.zig");
pub const btree = @import("btree.zig");
pub const file_store = @import("file_store.zig");
pub const writer = @import("writer.zig");
pub const db = @import("db.zig");
pub const fault_store = @import("fault_store.zig");

pub const Header = format.Header;
pub const Options = db.Options;
pub const Db = db.Db;

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}
```

重点：
- `@import("format.zig")` 会把 `format.zig` 当做一个模块导入。
- `pub const Db = db.Db;` 把内部 `db.zig` 的 `Db` 类型重新导出，方便外部使用。
- `add` 函数是一个占位，测试 `root.zig` 能否正常编译导出。

外部使用方式：

```zig
const cube = @import("cube_db");
const db = try cube.Db.open(...);
```

---

## 6. 各模块职责

| 文件 | 职责 | 一句话说明 |
|------|------|------------|
| `src/main.zig` | 可执行入口 | 目前只打印 `build ok`，业务不在此 |
| `src/root.zig` | 库入口 | 把内部模块整理后对外暴露 |
| `src/format.zig` | 文件格式 | 定义 header、节点、记录、CRC 编解码 |
| `src/store.zig` | Store 抽象 | 运行时接口 + 内存实现（MemStore） |
| `src/file_store.zig` | 真实文件实现 | 基于 `zio.File` 的位置 IO |
| `src/fault_store.zig` | 故障注入 | 包装 MemStore，模拟崩溃 |
| `src/btree.zig` | B-tree 索引 | 查找、插入、删除、范围查询 |
| `src/writer.zig` | 写状态 | batch 应用、header 提交、状态更新 |
| `src/db.zig` | 公开 API | open/close/get/put/delete/select/compact |
| `tests/*.zig` | 测试 | 集成测试和 compaction 测试 |

---

## 7. 常用命令

打开终端，进入项目根目录：

```bash
# 编译可执行文件
zig build

# 跑全部测试
zig build test

# 运行可执行文件
zig build run

# 检查 ReleaseSafe 无警告
zig build -Doptimize=ReleaseSafe
```

如果 `zig build test` 输出没有任何报错，最后退出码是 0，就说明所有测试通过。

---

## 8. 本章小结

- `build.zig` 是 Zig 的构建脚本，决定项目怎么编译、怎么测试。
- `build.zig.zon` 是包清单，声明依赖和版本要求。
- `src/root.zig` 是库的入口，外部代码通过它访问 `Db`。
- 真正业务逻辑分散在 `format.zig`、`store.zig`、`btree.zig`、`writer.zig`、`db.zig` 里。

---

## 9. 本章练习

1. 运行 `zig build test`，确认全部测试通过。
2. 打开 `src/main.zig`，把 `build ok` 改成你的名字，再运行 `zig build run`，看输出是否变化。
3. 在 `src/root.zig` 里把 `add` 函数删掉，然后运行 `zig build test`，观察测试失败（因为 `main.zig` 的测试依赖 `add`）。

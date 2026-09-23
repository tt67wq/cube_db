# Issue T-61 — check.sh 家族的「固定 seed」是误会：`--seed` 是 zig build 的图遍历随机选项，不是 fuzz 种子

- **状态**: closed（T-61-1 交付：fuzz 经 CUBE_FUZZ_SEED/-Dfuzz-seed 真固定+失败路径必印+verbose 门控回显；「固定 seed 复现」现在物理成立。合入 2eb8ac9，CI 绿）
- **发现于**: CI 失败排查（run 35564844844，github.com/tt67wq/cube_db）
- **复现**: 任意 worktree 跑 `bash .agents/tasks/T-38-8/check.sh <wt>`——其中 `zig build test --seed 0x8c40347c` 的 `--seed` 实际是 zig build 全局选项（"For shuffling dependency traversal order"，`zig build --help` 可见）
- **影响**: 所有任务门里声称的"固定 seed 复现"从未固定过 fuzz 种子。`tests/fuzz/*` 用 `std.testing.random_seed`（进程随机），本地与 CI 均为随机——门结果不可按 seed 复现，红一次也无处追 seed
- **修复方向**: fuzz 测试自己解析 `--seed`（std.testing 原生支持 `zig build test-one -- --seed N`? 或经 args 转发）并把实际 seed 打印到 stdout（失败时能抄）；check.sh 相应改为转发 + 记录。属测试基建改进，非产品缺陷
- **关联**: T-56（fuzz 假红）、当前 CI 红（未定位，疑随机或 Linux 特有）
- **判据来源**: 本地 60 连绿（6×全量 + 30×fuzz filter）+ `--totallybogus` 拒绝而 `--seed` 接受的对照实验

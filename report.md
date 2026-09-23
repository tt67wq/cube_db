# T-62 Report — 修 crash 测试的 Linux flock reopen 缺陷（CI 红归零）

- **分支**: `t62-flock-reopen`（基线 main `9c25325`）
- **结论**: **GREEN** —— check.sh 5/5 PASS（容器内：两失败 filter 绿 + staging_tombstone 绿 + 全量 rc=0 fc=0 + 零 src diff）
- **src/ 改动**: **0**（gate5 实证）；只改 tests/（8 文件 + 共享 helper test_diag.zig）

## 根因（以实测证据修正 issue 的初始假设）

issue 假设「parent 持有先前句柄未 deinit 就 reopen」。实测普查（见下）显示两个 CI 失败
站点（crash_harness :56、freelist :397）**在顺序语义下并无同路径双开**——真正的机制在
Linux 严格 flock 语义下有两类：

1. **继承者续命锁**（Shape C/H 实证）：`fork` 复制整个 fd 表——子进程会把父进程（或
   并行 suite 里其他执行）已退出持有者的锁经继承的 OFD「续命」，持有者死了锁还在，
   parent reopen 撞 EWOULDBLOCK。storm 复现下 200ms×10 重试都不收敛（持有者存活随
   负载延长），外部 `/proc/*/fd` 观察者抓到存活持有者（`pid=45693 fd=3 -> ...deleted`）。
2. **并行 suite 的同路径跨执行冲突**（storm 实证）：8 个 filter 循环并发时，同一测试
   路径被多个执行同时 create/unlink/lock，`unlink` 与下一执行的 `open(O_CREAT)` 竞态
   窗口内，上一个执行的 armed 子进程（SIGABRT trace 打印期间 fd 仍持有）就是活的持有者。

macOS 之所以全绿：BSD/XNU 的 flock 按进程关联，同进程新 fd 再 flock 直接转换成功——
宽容语义掩盖了这两类雷。Linux 上 `flock(2)` 语义：per-OFD、同进程双开冲突、锁随最后一个
fd 关闭释放——产品语义（src/file_page_store.zig:160-167 的注释）本来就是 Linux 语义，
**零 src 改动**成立。

## 修复（全部 tests/ 侧，断言零改动）

1. **子进程入口卫生 `closeInheritedFds()`**：fork 子进程第一步关闭继承 fd（3..1023，
   保留 stdio；filelock A3 保留管道写端）。锁的生命周期从此严格归属于真正的持有者，
   继承者续命类彻底消除。
2. **parent reopen 站点 `initStoreWithRetry(FilePageStore, alloc, path, 10)`**：仅对
   `error.FileLocked` 有界重试（10×50ms=500ms），其他错误立即返回。持有者（本测试的
   子进程，waitpid/SIGKILL+reap 或自身退出）死后锁必然释放（probe Shapes B/E/F/G：
   exit/SIGKILL/no-reap/mmap-1TB 全部干净释放），瞬态窗口内重试收敛。**不吸收、不改
   断言**——耗尽后照常返回 error.FileLocked（真锁冲突仍红）。
3. **防回归注记**：8 个改动的测试文件头部 + test_diag.zig helper 块注释，写明
   macOS/Linux flock 语义差与两条卫生措施的必要性，防止后人写回宽容假设。

helper 放 `tests/crash_insertbatch_pb/test_diag.zig`（该目录 5 文件共享）；`crash_harness_test.zig`
经 import 使用同 helper；`tests/core_format/filelock_test.zig` 目录独立，helper 本地副本。

## 普查站点表（§2：全部 `FilePageStore.init`/`Db.open` reopen 站点）

| 文件 | 站点 | 处置 |
|---|---|---|
| crash_harness_test.zig | :41/:77 子进程 init、:65/:97/:112 parent reopen | 已修（hygiene + retry）；**CI 红点 :56 → 修后 :65 retry** |
| freelist_persist_crash_test.zig | :195 pre、:212 子、:229/:270/:277/:369/:399 reopen | 已修；**CI 红点 :397（T5-r 双 reopen 循环）→ :399 retry** |
| t385_tomb_chain_delete_crash_test.zig | :85/:115/:184/:192/:226/:271/:335 + 子 :98/:294 | 已修（storm 下本文件是最大 reproducer） |
| tomb_chain_crash_test.zig | :142/:244/:277/:285/:330 + 子 :158 | 已修（storm 第二 reproducer） |
| crash_putbatch_test.zig | :100/:140/:155/:172/:197/:221/:252 + 子 :41 | 已修（forkKill9 的 kill-9 站点同型） |
| crash_meta_midwrite_test.zig | :89/:118/:147/:169/:198 + 子 :41/:67 | 已修（CI 35482673490 曾红 :134→verifyMetaConsistency） |
| crash_recovery_framework.zig | :42/:51/:67/:82/:108/:139/:158/:220/:234/:249/:264/:292/:321/:340/:349/:358/:375/:384/:393 + 子 :177/:192 | 已修（CI 35488371899/35485554056/35482673490/35318872200 红点 :232） |
| filelock_test.zig | A1-fork :159、A3 :193、A3 reopen :222 | 已修（A3 即 CI 35482673490 红点 :174——「唯一持有者 SIGKILL+reap 后 reopen 仍 FileLocked」的实锤）；A2/A1 无 fork 无并发持有者，保持原样 |
| src/file_page_store.zig | init 的错误映射 :165-175 | **blocked-不需要**：错误映射本就正确（仅 EWOULDBLOCK/EAGAIN→FileLocked，其余 OpenFailed），Linux 严格互斥是文档语义，产品代码不动 |

无「不改产品代码就修不好」的站点。

## 复现与验证（证据链）

1. **CI 红**：run 35697695176（crash_harness :56 + freelist :397）、35564844844/35564809797/
   35504658636（T5-r）、35488371899/35485554056（recovery_framework + T5-r）、35482673490
   （midwrite + recovery_framework + filelock A3）、35318872200（midwrite + recovery_framework）
   —— 6+ 次独立红，全在 fork-reopen 站点。
2. **flock 语义 probe（x86_64 容器，C）**：Shape A 同进程双开=EWOULDBLOCK、C 继承者续命
   =EWOULDBLOCK、H 孙进程继承=EWOULDBLOCK；B/E/F/G exit/SIGKILL/no-reap/mmap-1TB 单持有者
   死亡全部干净释放 → 「锁存活」必有活持有者/继承者。
3. **storm 复现（arm64 容器 + 容器原生 fs）**：8 个 filter 并发循环——修前 **11 次
   FileLocked**（t385/tomb_chain 全家，含 buildPreState/checkAfterCrash 站点）；串行 ×48
   全绿（并发是必要条件）；内部 dump 报「无持有者」+ 外部 /proc 观察者抓到持有者（内部
   dump 的 64 fd 上限是原因之一，外部扫全量 fd）。
4. **修后 storm**：同条件 32 轮并发 run **0 FileLocked**。
5. **修后全量（arm64 容器 -j2）**：573/574，唯一失败 `cube_check CLI subprocess` 为容器
   环境固有产物（std.process.spawn，与本缺陷无关、修前同样存在）。
6. **check.sh 5/5 PASS**（T62_IMG=t62-debian-arm64，容器原生 fs）：gate1 crash harness 绿、
   gate2 freelist_persist 绿、gate3 staging_tombstone 绿、gate4 全量 rc=0 fc=0、gate5 src/ 干净。

## 复现命令

```
docker run -d --name t62 --entrypoint /bin/bash <img> -c 'sleep 7200'
tar -C <repo> --exclude=./.zig-cache -cf - . | docker exec -i t62 bash -c 'mkdir -p /t62 && tar -C /t62 -xf -'
# storm（复现态）：
for f in t385 tomb_chain freelist_persist; do (for r in 1 2 3 4; do
  zig build test-one -Dfilter="$f" > /tmp/log 2>&1; grep -l FileLocked /tmp/log && echo REPRO; done) & done
```

## 环境注记（gate 可复跑性）

- 任务给的 `ziglang/zig:0.16.0` 镜像不存在（pull 404）；CI 的 x86_64 路径在本地不可完整
  复刻（qemu 模拟 zig 编译器确定性 SEGV）。gate 实跑用 `T62_IMG=t62-debian-arm64`
  （debian + zig 0.16 aarch64 + libc6-dev + wrapper 注入 `-Dcpu=apple_m1`——arm64 baseline
  缺 CRC 扩展，crc32_hw.zig 内联 asm 需要；CI x86_64 走软件回退，无需 wrapper）。
- flock 语义按 OFD，与架构无关——arm64 容器验证对 x86_64 CI 有效。
- check.sh 已原生支持 `T62_IMG` 覆盖；验收门在容器内实跑通过（见上）。

## Diff 摘要

- `tests/crash_insertbatch_pb/test_diag.zig`：+56（initStoreWithRetry / closeInheritedFds helpers + 语义注记）
- 7 个 crash 系列测试文件：子进程入口 `tdiag.closeInheritedFds(&.{})`（filelock A3 保留管道 fd）、
  parent reopen/多开站点 `tdiag.initStoreWithRetry(..., 10)`、文件头防回归注记
- `tests/core_format/filelock_test.zig`：同款 helper 本地副本 + A1-fork/A3 子进程 hygiene
  （A3 保留 `fds[1]`）+ A3 reopen retry + 注记
- 合计 9 files changed, 180 insertions(+), 53 deletions(-)；src/ 0 diff

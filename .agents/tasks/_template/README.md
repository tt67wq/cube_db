# Linux 容器门模板（T-61-1）

`linux_gate.sh`：把任意 ref 的仓库内容送进 Linux 容器原生 fs 跑测试 filter。
T-62 容器配方的通用化（配方源自 T-62 report 环境注记）。

```
bash linux_gate.sh <repo-or-worktree> <ref> "<filter1>" ["<filter2>" ...]
GATE_IMG=t62-debian-arm64   # 可覆盖，默认 t62-debian-arm64
```

## 三条铁律

1. **不许 `-v` 挂 macOS 卷测 flock**。virtiofs/gRPC-FUSE 上 flock 语义失真
   （宿主 macOS 按进程关联的宽容语义透传进容器），锁测试会假绿/假红。
   内容一律 `git archive` 进容器（原生 ext4/overlayfs）再跑。任何 flock 相关
   gate 若用了挂载卷，结果无效。
2. **没有官方 zig 0.16.0 镜像层**（`ziglang/zig:0.16.0` pull 404）。自建镜像
   （debian + zig 0.16 aarch64 + libc6-dev + linux-libc-dev），且 aarch64
   baseline 缺 CRC 扩展而 `src/crc32_hw.zig` 用内联 asm，故镜像内 `/usr/local/bin/zig`
   是 wrapper，为 build 命令注入 `-Dcpu=apple_m1`。重建镜像时必须带上 wrapper，
   否则 CRC 单测编不过。
3. **arm64 容器结果对 x86_64 CI 的外推边界**：flock(2) per-OFD 冲突判定、
   fork fd 表继承、进程/信号语义都是内核层、与 CPU 架构无关——可外推；
   但 **CRC 硬件路径不在覆盖内**（x86_64 CI 走自身特性检测），且 qemu 跑
   zig 编译器本身会 SEGV、不可用。容器绿 ≠ CI 终审绿：CI 真绿才算收口。

## T-63 流程断言（conductor 自用，SOP）

派单集成侧在合并 worker 产物前做机械断言（一行）：

```bash
[ "$(git -C <主checkout> branch --show-current)" = "main" ] || echo "BLOCK: 主 checkout 不在 main，拒绝合并"
```

契约模板（task.md.example / review-task.md.example）已含硬约束行：
「commit 只准落在你的 worktree 路径内；主 checkout 是 conductor 领地」。
事故背景：issues/T-63（worker 把 commit 打进 conductor checkout，两方工作树互相污染）。

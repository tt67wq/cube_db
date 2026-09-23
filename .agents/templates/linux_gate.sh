#!/usr/bin/env bash
# linux_gate.sh — T-61-1 模板：Linux 容器原生 fs 门（T-62 配方抽通用）
#
# 用法:
#   bash linux_gate.sh <repo-or-worktree-path> <ref> "<filter1>" ["<filter2>" ...]
#   GATE_IMG=t62-debian-arm64   # 覆盖镜像（默认 t62-debian-arm64）
#
# 流程: git archive <ref> → 容器 /gate（原生 fs，非 macOS 挂载卷）→ 逐 filter
#       `zig build test-one -Dfilter=<f>` → 汇总退出码。
# 退出码: 0 = 全绿；1 = 任一 filter 红 / 环境缺失。
#
# 三条铁律见同目录 README.md（virtiofs 假绿 / 镜像无官方 0.16.0 层 / arm64→x86_64 外推边界）。
set -uo pipefail
REPO="${1:?usage: linux_gate.sh <repo-path> <ref> <filter...>}"
REF="${2:?usage: linux_gate.sh <repo-path> <ref> <filter...>}"
shift 2
[ $# -ge 1 ] || { echo "need at least one filter"; exit 1; }
FILTERS=("$@")
IMG="${GATE_IMG:-t62-debian-arm64}"
C=linux_gate_$$_$RANDOM
FAIL=0

command -v docker >/dev/null 2>&1 || { echo "docker missing"; exit 1; }
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "image $IMG not present"; exit 1; }
git -C "$REPO" rev-parse --verify "$REF" >/dev/null 2>&1 || { echo "ref $REF not found"; exit 1; }

docker rm -f "$C" >/dev/null 2>&1
docker run -d --name "$C" --entrypoint /bin/bash "$IMG" -c 'sleep 7200' >/dev/null
trap 'docker rm -f "$C" >/dev/null 2>&1 || true' EXIT

# 内容经 git archive 进容器（原生 fs）——绝不 -v 挂 macOS 卷（virtiofs 上
# flock 语义失真，锁测试会假绿/假红，见 README 铁律 1）。
git -C "$REPO" archive --format=tar "$REF" | docker exec -i "$C" bash -c 'mkdir -p /gate && tar -C /gate -xf -'
docker exec "$C" bash -lc 'dpkg -s libc6-dev >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq libc6-dev linux-libc-dev >/dev/null; }' >/dev/null 2>&1

echo "== linux_gate @ $(git -C "$REPO" log --oneline -1 "$REF") (img=$IMG) =="
for f in "${FILTERS[@]}"; do
  if docker exec "$C" bash -c "cd /gate && zig build test-one -Dfilter=\"$f\" 2>&1"; then
    echo "  [PASS] filter=\"$f\""
  else
    echo "  [FAIL] filter=\"$f\""
    FAIL=1
  fi
done

[ "$FAIL" -eq 0 ] && echo "== RESULT: PASS ==" || echo "== RESULT: FAIL =="
exit "$FAIL"

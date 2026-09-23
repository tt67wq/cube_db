#!/usr/bin/env bash
# T-53-1 gate: 新判据绿 + crash 家族假拒回归 + Linux 容器通道 + 全量 + src 白名单
set -uo pipefail
WT="${1:?usage: check.sh <worktree>}"
WT=$(cd "$WT" && pwd); REF=t53-1-torn-meta
GATE_SEED=0x8c40347c; FAIL=0
pass(){ echo "  [PASS] $1"; }; fail(){ echo "  [FAIL] $1"; FAIL=1; }
cd "$WT"
echo "== T-53-1 gate @ $(git log --oneline -1) =="
ok=1; for i in 1 2 3; do zig build test-one -Dfilter=t535 >/dev/null 2>&1 || { ok=0; echo "  run $i red"; }; done
[ "$ok" -eq 1 ] && pass "gate1 t535 x3 green (RED->GREEN, no flake)" || fail "gate1 t535 red/flaky"
bad=$(git diff --name-only 652c319..HEAD -- src/ | grep -vE '^src/(db|file_page_store)\.zig$' || true)
n=$(git diff --name-only 652c319..HEAD -- src/ | wc -l | tr -d ' ')
[ "${bad:-}" = "" ] && [ "$n" -ge 0 ] && pass "gate2 src/ whitelist ($n file(s))" || fail "gate2 src outside whitelist: $bad"
# 目录级 filter：crash_insertbatch_pb 全家（含 freelist_amp_red？——否：该文件在
# core_format/。目录 filter 不会误抓 test-t39-red 的 RED-by-design 用例）。
zig build test-one -Dfilter=crash_insertbatch_pb >/dev/null 2>&1 && pass "gate3 crash families green (no false-reject)" || fail "gate3 crash family RED (假拒!)"
out=$(zig build test 2>&1); rc=$?; fnc=$(printf '%s' "$out" | /usr/bin/grep -c 'failed command:' || true)
[ "$rc" -eq 0 ] && [ "$fnc" -eq 0 ] && pass "gate4 full suite rc=0 fc=0" || { fail "gate4 full rc=$rc fc=$fnc"; printf '%s' "$out" | grep -E 'failed command:|error:' | head -5; }
if command -v docker >/dev/null 2>&1 && docker image inspect t62-debian-arm64 >/dev/null 2>&1; then
  docker rm -f t53gate >/dev/null 2>&1
  docker run -d --name t53gate --entrypoint /bin/bash t62-debian-arm64 -c 'sleep 3600' >/dev/null
  trap 'docker rm -f t53gate >/dev/null 2>&1||true' EXIT
  git -C "$WT" archive --format=tar "$REF" | docker exec -i t53gate bash -c 'mkdir -p /t && tar -C /t -xf -'
  if docker exec t53gate bash -c 'cd /t && zig build test-one -Dfilter=t535 && zig build test-one -Dfilter=crash_insertbatch_pb' >/dev/null 2>&1; then
    pass "gate5 Linux container: t535 + crash_insertbatch_pb green"
  else fail "gate5 Linux container RED"; fi
else fail "gate5 docker/image unavailable"; fi
[ "$FAIL" -eq 0 ] && echo "== RESULT: PASS (5/5) ==" || echo "== RESULT: FAIL =="
exit "$FAIL"

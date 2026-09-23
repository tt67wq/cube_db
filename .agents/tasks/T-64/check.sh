#!/usr/bin/env bash
# T-64 gate: t535 全家 x3（含新 t5/t6 + R3 收紧）+ src 白名单 + macOS 全量 + Linux 容器冒烟
set -uo pipefail
WT="${1:?usage: check.sh <worktree>}"
WT=$(cd "$WT" && pwd); BASE=7b9288c; REF=t64-nbs; FAIL=0
pass(){ echo "  [PASS] $1"; }; fail(){ echo "  [FAIL] $1"; FAIL=1; }
cd "$WT"
echo "== T-64 gate @ $(git log --oneline -1) =="
ok=1; for i in 1 2 3; do zig build test-one -Dfilter=t535 >/dev/null 2>&1 || { ok=0; echo "  run $i red"; }; done
[ "$ok" -eq 1 ] && pass "gate1 t535 (incl t5/t6/R3) x3 green no flake" || fail "gate1 t535 red/flaky"
bad=$(git diff --name-only $BASE..HEAD -- src/ | grep -v '^src/file_page_store.zig$' || true)
[ -z "$bad" ] && pass "gate2 src/ whitelist (file_page_store only)" || fail "gate2 outside whitelist: $bad"
git diff --name-only $BASE..HEAD -- docs/usage.md | grep -q . && pass "gate3 usage.md touched (NB-1 doc)" || fail "gate3 usage.md untouched (T-64 item 1 missing)"
out=$(zig build test 2>&1); rc=$?; fnc=$(printf '%s' "$out" | /usr/bin/grep -c 'failed command:' || true)
[ "$rc" -eq 0 ] && [ "$fnc" -eq 0 ] && pass "gate4 macOS full suite rc=0 fc=0" || { fail "gate4 full rc=$rc fc=$fnc"; printf '%s' "$out" | grep -E 'failed command:|error:' | head -5; }
if docker image inspect t62-debian-arm64 >/dev/null 2>&1; then
  docker rm -f t64gate >/dev/null 2>&1
  docker run -d --name t64gate --entrypoint /bin/bash t62-debian-arm64 -c 'sleep 3600' >/dev/null
  trap 'docker rm -f t64gate >/dev/null 2>&1||true' EXIT
  git -C "$WT" archive --format=tar "$REF" | docker exec -i t64gate bash -c 'mkdir -p /t && tar -C /t -xf -'
  docker exec t64gate bash -c 'cd /t && zig build test-one -Dfilter=t535 && zig build test-one -Dfilter=crash_insertbatch_pb' >/dev/null 2>&1 \
    && pass "gate5 Linux container: t535 + crash_insertbatch_pb green" || fail "gate5 Linux container RED"
else fail "gate5 docker image missing"; fi
[ "$FAIL" -eq 0 ] && echo "== RESULT: PASS (5/5) ==" || echo "== RESULT: FAIL =="
exit "$FAIL"

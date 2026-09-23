#!/usr/bin/env bash
# T-58 gate: ±1 边界锁死 x3 + src 白名单 + usage 真值 + 双平台
set -uo pipefail
WT="${1:?usage: check.sh <worktree>}"
WT=$(cd "$WT" && pwd); FAIL=0
pass(){ echo "  [PASS] $1"; }; fail(){ echo "  [FAIL] $1"; FAIL=1; }
cd "$WT"; BASE=$(git merge-base HEAD main)
echo "== T-58 gate @ $(git log --oneline -1) =="
ok=1; for i in 1 2 3; do zig build test-one -Dfilter=t58 >/dev/null 2>&1 || { ok=0; echo "  run $i red"; }; done
[ "$ok" -eq 1 ] && pass "gate1 t58 x3 green no flake" || fail "gate1 t58 red/flaky"
bad=$(git diff --name-only "$BASE"..HEAD -- src/ | grep -vE '^src/(db|btree)\.zig$' || true)
[ -z "$bad" ] && pass "gate2 src/ whitelist (db/btree)" || fail "gate2 outside whitelist: $bad"
git diff --name-only "$BASE"..HEAD -- docs/usage.md | grep -q . && pass "gate3 usage.md updated" || fail "gate3 usage.md untouched"
git ls-files --error-unmatch .agents/tasks/T-58/check.sh >/dev/null 2>&1 && pass "gate4 check.sh tracked on branch (NB3 discipline)" || fail "gate4 check.sh NOT committed (git add -f required)"
out=$(zig build test 2>&1); rc=$?; fnc=$(printf '%s' "$out" | /usr/bin/grep -c 'failed command:' || true)
[ "$rc" -eq 0 ] && [ "$fnc" -eq 0 ] && pass "gate5 macOS full suite rc=0 fc=0" || { fail "gate5 full rc=$rc fc=$fnc"; printf '%s' "$out" | grep -E 'failed command:|error:' | head -5; }
if docker image inspect t62-debian-arm64 >/dev/null 2>&1; then
  docker rm -f t58gate >/dev/null 2>&1
  docker run -d --name t58gate --entrypoint /bin/bash t62-debian-arm64 -c 'sleep 3600' >/dev/null
  trap 'docker rm -f t58gate >/dev/null 2>&1||true' EXIT
  git -C "$WT" archive --format=tar HEAD | docker exec -i t58gate bash -c 'mkdir -p /t && tar -C /t -xf -'
  docker exec t58gate bash -c 'cd /t && zig build test-one -Dfilter=t58 && zig build test-one -Dfilter=range_tombstone' >/dev/null 2>&1 && pass "gate6 Linux container: t58 + range_tombstone(墓碑面不误伤) green" || fail "gate6 Linux container RED"
else fail "gate6 docker image missing"; fi
[ "$FAIL" -eq 0 ] && echo "== RESULT: PASS (6/6) ==" || echo "== RESULT: FAIL =="
exit "$FAIL"

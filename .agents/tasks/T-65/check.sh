#!/usr/bin/env bash
# T-65 gate: 三刀机械验收 + src 零 diff + check.sh 入库 + 双平台
set -uo pipefail
WT="${1:?usage: check.sh <worktree>}"
WT=$(cd "$WT" && pwd); BASE=34e6a01; FAIL=0
pass(){ echo "  [PASS] $1"; }; fail(){ echo "  [FAIL] $1"; FAIL=1; }
cd "$WT"
echo "== T-65 gate @ $(git log --oneline -1) =="
# T-55: guard 进闭包、真分片仍排除（响亮失败）
if zig build test-one -Dfilter=shardRange >/dev/null 2>&1; then pass "g1 partition guard 进 test-one（filter=shardRange 命中且绿）"; else fail "g1 shardRange filter 不绿"; fi
if zig build test-one -Dfilter=insertbatch_sweep_a >/dev/null 2>&1; then fail "g2 真分片竟进了 test-one 闭包（应响亮失败）"; else pass "g2 真分片仍排除（响亮失败 rc!=0）"; fi
# T-45: 该测试文件绿 ×2
ok=1; for i in 1 2; do zig build test-one -Dfilter=insert_split_budget >/dev/null 2>&1 || ok=0; done
[ "$ok" -eq 1 ] && pass "g3 insert_split_budget x2 green" || fail "g3 insert_split_budget red/flaky"
# src 零 diff + 覆盖中性（默认门即全量）
[ -z "$(git diff --name-only $BASE..HEAD -- src/)" ] && pass "g4 src/ zero diff" || fail "g4 src/ changed"
out=$(zig build test 2>&1); rc=$?; n=$(printf '%s' "$out" | /usr/bin/grep -c 'failed command:' || true)
[ "$rc" -eq 0 ] && [ "$n" -eq 0 ] && pass "g5 macOS full suite rc=0 fc=0 (coverage-neutral 动态期望自证)" || { fail "g5 full rc=$rc fc=$n"; printf '%s' "$out" | grep -E 'failed command:|error:' | head -5; }
git ls-files --error-unmatch .agents/tasks/T-65/check.sh >/dev/null 2>&1 && pass "g6 check.sh tracked (纪律)" || fail "g6 check.sh NOT committed"
# T-47 形态门：docs 要么未动(弃)要么纯 docs(救)——src/tests 之外的 lecture 改动只许该文件
badf=$(git diff --name-only $BASE..HEAD -- docs/ | grep -v '^docs/lecture_btree.html$' || true)
[ -z "$badf" ] && pass "g7 docs/ diff 仅限 lecture（或零 diff=弃单评估）" || fail "g7 docs/ 越界: $badf"
if docker image inspect t62-debian-arm64 >/dev/null 2>&1; then
  docker rm -f t65gate >/dev/null 2>&1
  docker run -d --name t65gate --entrypoint /bin/bash t62-debian-arm64 -c 'sleep 3600' >/dev/null
  trap 'docker rm -f t65gate >/dev/null 2>&1||true' EXIT
  git -C "$WT" archive --format=tar HEAD | docker exec -i t65gate bash -c 'mkdir -p /t && tar -C /t -xf -'
  docker exec t65gate bash -c 'cd /t && zig build test-one -Dfilter=shardRange && zig build test-one -Dfilter=insert_split_budget' >/dev/null 2>&1 && pass "g8 Linux 容器: g1g3 复跑绿" || fail "g8 Linux container RED"
else fail "g8 docker image missing"; fi
[ "$FAIL" -eq 0 ] && echo "== RESULT: PASS (8/8) ==" || echo "== RESULT: FAIL =="
exit "$FAIL"

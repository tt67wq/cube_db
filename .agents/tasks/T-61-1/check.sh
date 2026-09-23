#!/usr/bin/env bash
# T-61-1 gate: seed 固定实证 + fuzz/全家 + src 零 diff + 模板齐备
# R2（review @bc2311e B1 裁决收口）：gate1 重写 ——
#   (a) 固定 seed 成功路径必须 fc=0（B1 回归：verbose 门外任何 stderr 都会炸全部 fc=0 门）
#   (b) 显式 seed 的回显只在 CUBE_TEST_VERBOSE=1 下可见（tdiag 同款约定）
#   (c) 非法 CUBE_FUZZ_SEED 在 verbose 下告警（NB1）
# gate2 文案修正（NB4）：未设 seed 时成功路径零输出是 B1 修复后的正确行为。
set -uo pipefail
WT="${1:?usage: check.sh <worktree>}"
WT=$(cd "$WT" && pwd); FAIL=0
pass(){ echo "  [PASS] $1"; }; fail(){ echo "  [FAIL] $1"; FAIL=1; }
cd "$WT"
echo "== T-61-1 gate @ $(git log --oneline -1) =="
S=0xc0ffee
# (a) 固定 seed、不带 verbose：rc=0 且 fc=0（B1 回归断言）
o1=$(zig build test-one -Dfilter=fuzz -Dfuzz-seed=$S 2>&1); r1=$?
fc1=$(printf '%s' "$o1" | /usr/bin/grep -c 'failed command:' || true)
# (b) 同 run 带 verbose：seed 回显可见
o2=$(CUBE_TEST_VERBOSE=1 zig build test-one -Dfilter=fuzz -Dfuzz-seed=$S 2>&1); r2=$?
# (c) 非法 seed：verbose 告警 + 照常绿
o3=$(CUBE_TEST_VERBOSE=1 CUBE_FUZZ_SEED=banana zig build test-one -Dfilter=fuzz 2>&1); r3=$?
if [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && [ "$r3" -eq 0 ] && [ "$fc1" -eq 0 ]; then
  if grep -q 'fuzz seed=0xc0ffee' <<<"$o2"; then
    if grep -q "ignoring invalid CUBE_FUZZ_SEED='banana'" <<<"$o3"; then
      pass "gate1 fuzz -Dfuzz-seed: fc=0 w/o verbose (B1) + echo under verbose + invalid-seed warn (NB1)"
    else fail "gate1 invalid-seed warning missing under verbose (NB1)"; fi
  else fail "gate1 seed echo missing under CUBE_TEST_VERBOSE=1"; fi
else fail "gate1 seeded runs rc=$r1/$r2/$r3 fc=$fc1 (B1: fc must be 0 w/o verbose)"; fi
if zig build test-one -Dfilter=fuzz >/dev/null 2>&1; then pass "gate2 fuzz default (random seed) green (silent on success — correct post-B1 behavior)"; else fail "gate2 fuzz unseeded RED"; fi
T=.agents/tasks/_template
[ -f "$WT/$T/linux_gate.sh" ] && [ -f "$WT/$T/README.md" ] && [ -f "$WT/$T/task.md.example" ] && pass "gate3 template dir complete (linux_gate+README+task.example)" || fail "gate3 templates missing under $T"
[ -z "$(git diff --name-only 652c319..HEAD -- src/)" ] && pass "gate4 src/ untouched" || fail "gate4 src/ changed"
out=$(zig build test 2>&1); rc=$?; fnc=$(printf '%s' "$out" | /usr/bin/grep -c 'failed command:' || true)
[ "$rc" -eq 0 ] && [ "$fnc" -eq 0 ] && pass "gate5 full suite rc=0 fc=0" || { fail "gate5 full rc=$rc fc=$fnc"; printf '%s' "$out" | grep -E 'failed command:|error:' | head -5; }
[ "$FAIL" -eq 0 ] && echo "== RESULT: PASS (5/5) ==" || echo "== RESULT: FAIL =="
exit "$FAIL"

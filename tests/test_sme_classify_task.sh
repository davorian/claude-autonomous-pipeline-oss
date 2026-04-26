#!/bin/bash
# test_sme_classify_task.sh — Tests for the heuristic task_type classifier.
#
# Usage: bash test_sme_classify_task.sh

set -euo pipefail

PASS=0
FAIL=0
TEST_TMPDIR=""
SCRIPT_DIR="$(cd "$(dirname "$0")/../bin" && pwd)"
CLASSIFY="$SCRIPT_DIR/sme-classify-task"

_setup() { TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/sme_classify_test.XXXXXX"); }
_teardown() { [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"; TEST_TMPDIR=""; }
_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "        $2"; }

_classify() {
  local content="$1"
  local spec="$TEST_TMPDIR/spec.md"
  printf '%s' "$content" > "$spec"
  "$CLASSIFY" --spec "$spec"
}

_assert_type() {
  local label="$1" expected="$2" content="$3"
  _setup
  out=$(_classify "$content")
  actual=$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["task_type"])')
  [ "$expected" = "$actual" ] && _pass "$label" || _fail "$label" "expected=$expected actual=$actual rationale=$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["task_type_rationale"])')"
  _teardown
}

echo "=== sme-classify-task ==="

# bugfix
_assert_type "fix + file ref → bugfix" bugfix \
  "Fix the bug in lib/auth.ex where login fails on empty password."

_assert_type "defect + file ref → bugfix" bugfix \
  "Defect: src/handler.ts crashes on null input."

# refactor
_assert_type "refactor → refactor" refactor \
  "Refactor the goal-assignment route to extract the assignment logic."

_assert_type "consolidate → refactor" refactor \
  "Consolidate three duplicate validators into a shared module."

# new-pattern
_assert_type "introduce + pattern → new-pattern" new-pattern \
  "Introduce the discriminated-union pattern across all error-handling code."

_assert_type "establish + convention → new-pattern" new-pattern \
  "Establish a convention for naming integration tests as *.integration.test.ts."

# cross-cutting (multiple repos mentioned)
_assert_type "two known repos → cross-cutting" cross-cutting \
  "Update both user_home and platform to handle the new event payload."

_assert_type "across services phrase → cross-cutting" cross-cutting \
  "Roll out the new auth header across services."

# greenfield (no file refs)
_assert_type "from scratch → greenfield" greenfield \
  "Build a new dashboard from scratch. Should fetch data and render charts."

# feature (default)
_assert_type "default → feature" feature \
  "Add a setting in lib/settings.ex so users can toggle dark mode."

# bugfix beats refactor when both signals present
_assert_type "bugfix outranks refactor on tie" bugfix \
  "Fix a bug in src/foo.ts and refactor while you're there."

# Standalone JSON output is well-formed
_setup
spec="$TEST_TMPDIR/spec.md"
echo "any old content" > "$spec"
out=$("$CLASSIFY" --spec "$spec")
echo "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' \
  && _pass "stdout is valid JSON" || _fail "stdout is valid JSON"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "task_type" in d and "task_type_source" in d and "task_type_rationale" in d' \
  && _pass "JSON has all three required keys" || _fail "JSON has all three required keys"
_teardown

# --human gives readable output
_setup
spec="$TEST_TMPDIR/spec.md"
echo "fix bug in src/foo.ts" > "$spec"
out=$("$CLASSIFY" --spec "$spec" --human)
echo "$out" | grep -q "task_type:" \
  && _pass "--human prefixed with 'task_type:'" || _fail "--human prefixed"
_teardown

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# test_vacuousness_pass_1.sh — Tests for D2: TDD-ordering gate (Pass 1)
#
# Covers: phase_vacuousness_pass_1 + helpers
#         (_vacuous_pass_1_run_tests, _vacuous_pass_1_emit_artefact)
#         in bin/auto_claude.
#
# Tests will FAIL until D2 is implemented — that is correct.
#
# Usage: bash test_vacuousness_pass_1.sh

set -euo pipefail

PASS=0
FAIL=0
TEST_TMPDIR=""

_setup_tmp() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ac_vac_pass1.XXXXXX")
}

_teardown_tmp() {
  [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
  TEST_TMPDIR=""
}

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "        $2"; }

_assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] && _pass "$label" || _fail "$label" "expected='$expected' actual='$actual'"
}

_assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  echo "$haystack" | grep -q "$needle" && _pass "$label" || _fail "$label" "'$needle' not found"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AC="$REPO_ROOT/bin/auto_claude"
[ -f "$AC" ] || AC="$HOME/bin/auto_claude"

_source_pass_1() {
  log() { :; }
  warn() { :; }
  err()  { :; }
  run_claude()       { echo "stub run_claude"; }
  run_claude_fresh() { echo "stub run_claude_fresh"; }

  eval "$(awk '/^_jq_update[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^_state_get[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^_init_state[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^phase_vacuousness_pass_1[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
}

_seed_state_with_test_intent_files() {
  local files_csv="$1"
  local arr
  arr=$(echo "$files_csv" | jq -R -s -c 'split(",") | map(select(. != ""))')
  jq --argjson f "$arr" '.deterministic.test_intent.files_added = $f' "$STATE_FILE" > "$STATE_FILE.tmp" \
    && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# ─── D2: behaviour ───────────────────────────────────────────────────────────

test_1_returns_ok_when_zero_new_test_files() {
  echo "Test 1: phase returns :ok immediately when test_intent added 0 files (no work to do)"
  _setup_tmp
  _source_pass_1

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="t"
  BASELINE_COMMIT=""
  EXPLAIN_DIR="$TEST_TMPDIR/.explain"
  mkdir -p "$EXPLAIN_DIR"
  _init_state
  _seed_state_with_test_intent_files ""

  declare -F phase_vacuousness_pass_1 >/dev/null 2>&1 || { _fail "phase defined" "missing"; _teardown_tmp; return; }

  # Sentinel: if _run_all_suites is called we set this — assert it stays empty
  RAN_SUITES=0
  _run_all_suites() { RAN_SUITES=1; return 0; }

  local rc=0
  phase_vacuousness_pass_1 >/dev/null 2>&1 || rc=$?

  _assert_eq "phase exits 0" "0" "$rc"
  _assert_eq "_run_all_suites NOT invoked when no test files" "0" "$RAN_SUITES"

  _teardown_tmp
}

test_2_flags_test_that_passes_pre_impl_as_vacuous() {
  echo "Test 2: a test that passes BEFORE implementation runs is flagged vacuous"
  _setup_tmp
  _source_pass_1

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="t"
  BASELINE_COMMIT=""
  EXPLAIN_DIR="$TEST_TMPDIR/.explain"
  mkdir -p "$EXPLAIN_DIR"
  _init_state
  _seed_state_with_test_intent_files "test/foo_test.exs"

  declare -F phase_vacuousness_pass_1 >/dev/null 2>&1 || { _fail "phase defined" "missing"; _teardown_tmp; return; }

  # Stub: pretend the new test passed (i.e. _run_all_suites returns 0 — vacuous)
  _run_all_suites() {
    LAST_PASSED_SUITES="foo_test"
    LAST_FAILED_SUITES=""
    LAST_TEST_OUTPUT="1 test, 0 failures"
    return 0
  }
  AUTO_REWRITE_VACUOUS=0

  local rc=0
  phase_vacuousness_pass_1 >/dev/null 2>&1 || rc=$?

  # Hard-fail by default when vacuousness detected
  [ "$rc" -ne 0 ] && _pass "phase hard-fails on vacuous test" || _fail "phase hard-fails on vacuous test" "rc=$rc"

  # Artefact must exist and list the vacuous test
  [ -f "$EXPLAIN_DIR/vacuousness_pass_1.json" ] && _pass "artefact emitted" || _fail "artefact emitted" "no $EXPLAIN_DIR/vacuousness_pass_1.json"
  if [ -f "$EXPLAIN_DIR/vacuousness_pass_1.json" ]; then
    local count
    count=$(jq '.vacuous_tests | length' "$EXPLAIN_DIR/vacuousness_pass_1.json" 2>/dev/null || echo 0)
    [ "$count" -ge 1 ] && _pass "vacuous_tests array populated" || _fail "vacuous_tests array populated" "count=$count"
  fi

  _teardown_tmp
}

test_3_returns_ok_when_all_new_tests_fail() {
  echo "Test 3: when all new tests fail (TDD-red), phase returns 0 and emits empty report"
  _setup_tmp
  _source_pass_1

  STATE_FILE="$TEST_TMPDIR/state.json"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="t"
  BASELINE_COMMIT=""
  EXPLAIN_DIR="$TEST_TMPDIR/.explain"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  mkdir -p "$EXPLAIN_DIR"
  _init_state
  _seed_state_with_test_intent_files "test/foo_test.exs"

  declare -F phase_vacuousness_pass_1 >/dev/null 2>&1 || { _fail "phase defined" "missing"; _teardown_tmp; return; }

  _run_all_suites() {
    LAST_PASSED_SUITES=""
    LAST_FAILED_SUITES="foo_test"
    LAST_TEST_OUTPUT="1 test, 1 failure (no impl yet)"
    return 1
  }
  AUTO_REWRITE_VACUOUS=0

  local rc=0
  phase_vacuousness_pass_1 >/dev/null 2>&1 || rc=$?

  _assert_eq "phase exits 0 (TDD-red is good)" "0" "$rc"

  if [ -f "$EXPLAIN_DIR/vacuousness_pass_1.json" ]; then
    local count
    count=$(jq '.vacuous_tests | length' "$EXPLAIN_DIR/vacuousness_pass_1.json" 2>/dev/null || echo 99)
    _assert_eq "no vacuous tests in report" "0" "$count"
  fi

  _teardown_tmp
}

test_4_preserves_caller_last_failed_suites_globals() {
  echo "Test 4: phase saves and restores LAST_FAILED_SUITES around _run_all_suites (A006 contract)"
  _setup_tmp
  _source_pass_1

  STATE_FILE="$TEST_TMPDIR/state.json"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="t"
  BASELINE_COMMIT=""
  EXPLAIN_DIR="$TEST_TMPDIR/.explain"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  mkdir -p "$EXPLAIN_DIR"
  _init_state
  _seed_state_with_test_intent_files "test/foo_test.exs"

  declare -F phase_vacuousness_pass_1 >/dev/null 2>&1 || { _fail "phase defined" "missing"; _teardown_tmp; return; }

  _run_all_suites() {
    LAST_PASSED_SUITES="inner_pass"
    LAST_FAILED_SUITES="inner_fail"
    LAST_TEST_OUTPUT="inner output"
    return 1
  }

  LAST_PASSED_SUITES="caller_pass"
  LAST_FAILED_SUITES="caller_fail"
  LAST_TEST_OUTPUT="caller output"
  AUTO_REWRITE_VACUOUS=0

  phase_vacuousness_pass_1 >/dev/null 2>&1 || true

  _assert_eq "LAST_PASSED_SUITES restored" "caller_pass" "$LAST_PASSED_SUITES"
  _assert_eq "LAST_FAILED_SUITES restored" "caller_fail" "$LAST_FAILED_SUITES"
  _assert_eq "LAST_TEST_OUTPUT restored"   "caller output" "$LAST_TEST_OUTPUT"

  _teardown_tmp
}

test_5_auto_rewrite_retries_then_hard_fails() {
  echo "Test 5: AUTO_REWRITE_VACUOUS triggers up to VACUOUSNESS_RETRY_LIMIT retries then hard-fails"
  _setup_tmp
  _source_pass_1

  STATE_FILE="$TEST_TMPDIR/state.json"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="t"
  BASELINE_COMMIT=""
  EXPLAIN_DIR="$TEST_TMPDIR/.explain"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  mkdir -p "$EXPLAIN_DIR"
  _init_state
  _seed_state_with_test_intent_files "test/foo_test.exs"

  declare -F phase_vacuousness_pass_1 >/dev/null 2>&1 || { _fail "phase defined" "missing"; _teardown_tmp; return; }

  CALLS=0
  REWRITE_CALLS=0
  _run_all_suites() {
    CALLS=$((CALLS + 1))
    LAST_PASSED_SUITES="foo"; LAST_FAILED_SUITES=""; LAST_TEST_OUTPUT="vacuous again"
    return 0
  }
  run_claude() { REWRITE_CALLS=$((REWRITE_CALLS + 1)); echo "stub rewrite"; }

  AUTO_REWRITE_VACUOUS=1
  VACUOUSNESS_RETRY_LIMIT=2

  local rc=0
  phase_vacuousness_pass_1 >/dev/null 2>&1 || rc=$?

  [ "$rc" -ne 0 ] && _pass "hard-fails after retry limit" || _fail "hard-fails after retry limit" "rc=$rc"
  [ "$REWRITE_CALLS" -le 2 ] && _pass "retry capped at 2" || _fail "retry capped at 2" "REWRITE_CALLS=$REWRITE_CALLS"
  [ "$CALLS" -ge 2 ] && _pass "tests re-run on each retry" || _fail "tests re-run on each retry" "CALLS=$CALLS"

  _teardown_tmp
}

test_6_uses_state_not_git_for_file_discovery() {
  echo "Test 6: phase reads test files from state.deterministic.test_intent.files_added (not git)"
  _setup_tmp
  _source_pass_1

  STATE_FILE="$TEST_TMPDIR/state.json"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="t"
  BASELINE_COMMIT=""
  EXPLAIN_DIR="$TEST_TMPDIR/.explain"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  mkdir -p "$EXPLAIN_DIR"
  _init_state
  _seed_state_with_test_intent_files "test/seeded_from_state_test.exs"

  declare -F phase_vacuousness_pass_1 >/dev/null 2>&1 || { _fail "phase defined" "missing"; _teardown_tmp; return; }

  RECEIVED_FILTER=""
  _run_all_suites() {
    RECEIVED_FILTER="${SUITE_FILE_FILTER:-}"
    LAST_PASSED_SUITES=""; LAST_FAILED_SUITES="x"; LAST_TEST_OUTPUT="ok"
    return 1
  }

  phase_vacuousness_pass_1 >/dev/null 2>&1 || true

  _assert_contains "filter sourced from state file" "$RECEIVED_FILTER" "seeded_from_state_test.exs"

  _teardown_tmp
}

# ─── Run ─────────────────────────────────────────────────────────────────────

echo "=== D2: vacuousness Pass 1 (TDD-ordering gate) tests ==="
echo ""
test_1_returns_ok_when_zero_new_test_files; echo ""
test_2_flags_test_that_passes_pre_impl_as_vacuous; echo ""
test_3_returns_ok_when_all_new_tests_fail; echo ""
test_4_preserves_caller_last_failed_suites_globals; echo ""
test_5_auto_rewrite_retries_then_hard_fails; echo ""
test_6_uses_state_not_git_for_file_discovery

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ $FAIL -gt 0 ] && exit 1 || exit 0

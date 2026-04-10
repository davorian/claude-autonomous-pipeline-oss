#!/bin/bash
# test_auto_claude_state.sh — Tests for state file management and context packs
#
# Covers: _init_state, _state_get, _jq_update, _build_context_pack,
#         _update_test_results, _update_deterministic_state
#
# Usage: bash test_auto_claude_state.sh

set -euo pipefail

PASS=0
FAIL=0
TEST_TMPDIR=""

_setup_tmp() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ac_state_test.XXXXXX")
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

_assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  echo "$haystack" | grep -q "$needle" && _fail "$label" "'$needle' unexpectedly found" || _pass "$label"
}

# Source state functions from auto_claude without running anything
_source_state_functions() {
  log() { :; }

  local ac="$1"

  # _jq_update depends on STATE_FILE being set
  eval "$(sed -n '/_jq_update()/,/^}/p' "$ac")"
  eval "$(sed -n '/_state_get()/,/^}/p' "$ac")"
  eval "$(sed -n '/_init_state()/,/^}/p' "$ac")"
  eval "$(sed -n '/_update_test_results()/,/^}/p' "$ac")"

  # _build_context_pack is a large case statement — extract to end of function
  eval "$(awk '/_build_context_pack\(\)/,/^\}$/' "$ac")"
}

AC="$HOME/bin/auto_claude"
[ -f "$AC" ] || AC="$(dirname "$0")/auto_claude"

# ─── Tests ────────────────────────────────────────────────────────────────────

test_1_init_state_valid_json() {
  echo "Test 1: _init_state produces valid JSON with required top-level keys"
  _setup_tmp
  _source_state_functions "$AC"

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="test-project"
  BASELINE_COMMIT="abc123"

  _init_state

  local valid
  jq "." "$STATE_FILE" >/dev/null 2>&1 && valid="ok" || valid="invalid"
  _assert_eq "state file is valid JSON" "ok" "$valid"

  for key in schema_version run phases deterministic semantic; do
    local val
    val=$(jq -r ".${key} // \"missing\"" "$STATE_FILE")
    _assert_eq "has key: $key" "true" "$([ "$val" != "missing" ] && echo true || echo false)"
  done

  _assert_eq "status is running" "running" "$(jq -r '.run.status' "$STATE_FILE")"
  _assert_eq "project name" "test-project" "$(jq -r '.run.project_name' "$STATE_FILE")"
  _assert_eq "baseline commit" "abc123" "$(jq -r '.run.baseline_commit' "$STATE_FILE")"

  _teardown_tmp
}

test_2_jq_update_atomic() {
  echo "Test 2: _jq_update writes atomically and preserves existing keys"
  _setup_tmp
  _source_state_functions "$AC"

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="test"
  BASELINE_COMMIT=""
  _init_state

  _jq_update '.run.status = "completed"'
  _assert_eq "status updated" "completed" "$(jq -r '.run.status' "$STATE_FILE")"

  # Existing keys must survive the update
  _assert_eq "project name preserved" "test" "$(jq -r '.run.project_name' "$STATE_FILE")"

  _teardown_tmp
}

test_3_update_test_results() {
  echo "Test 3: _update_test_results writes pass/fail suites correctly"
  _setup_tmp
  _source_state_functions "$AC"

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="test"
  BASELINE_COMMIT=""
  _init_state

  LAST_PASSED_SUITES="jest vitest"
  LAST_FAILED_SUITES="e2e"
  _update_test_results "fail" "3"

  _assert_eq "final status" "fail" "$(jq -r '.deterministic.test_results.final_status' "$STATE_FILE")"
  _assert_eq "iterations" "3" "$(jq -r '.deterministic.test_results.iterations_needed' "$STATE_FILE")"
  _assert_eq "jest pass" "pass" "$(jq -r '.deterministic.test_results.suites.jest.status' "$STATE_FILE")"
  _assert_eq "e2e fail" "fail" "$(jq -r '.deterministic.test_results.suites.e2e.status' "$STATE_FILE")"

  _teardown_tmp
}

test_4_context_pack_fresh_review_excludes_intent() {
  echo "Test 4: fresh_review context pack excludes plan_intent (no anchoring bias)"
  _setup_tmp
  _source_state_functions "$AC"

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="test"
  BASELINE_COMMIT=""
  _init_state

  # Write a state with plan_intent populated
  _jq_update '.semantic.plan_intent = "Build a thing that does stuff"'
  _jq_update '.deterministic.files_changed = ["src/foo.ts", "src/bar.ts"]'
  _jq_update '.semantic.completed_quality_phases = ["skill_chain"]'

  local pack
  pack=$(_build_context_pack "fresh_review")

  _assert_not_contains "fresh_review omits plan_intent" "$pack" "Build a thing that does stuff"
  _assert_contains "fresh_review includes files" "$pack" "src/foo.ts"
  _assert_contains "fresh_review includes completed phases" "$pack" "skill_chain"

  _teardown_tmp
}

test_5_context_pack_skill_chain_includes_intent() {
  echo "Test 5: skill_chain context pack includes plan_intent"
  _setup_tmp
  _source_state_functions "$AC"

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="test"
  BASELINE_COMMIT=""
  _init_state

  _jq_update '.semantic.plan_intent = "Add search feature"'
  _jq_update '.deterministic.files_changed = ["src/search.ts"]'
  _jq_update '.deterministic.test_results.final_status = "pass"'
  _jq_update '.deterministic.test_results.iterations_needed = 1'

  local pack
  pack=$(_build_context_pack "skill_chain")

  _assert_contains "skill_chain includes plan_intent" "$pack" "Add search feature"
  _assert_contains "skill_chain includes files" "$pack" "src/search.ts"
  _assert_contains "skill_chain includes test status" "$pack" "pass"

  _teardown_tmp
}

test_6_context_pack_unknown_phase_returns_full_state() {
  echo "Test 6: Unknown phase falls through to full state summary"
  _setup_tmp
  _source_state_functions "$AC"

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="test"
  BASELINE_COMMIT=""
  _init_state

  _jq_update '.semantic.plan_intent = "Something important"'

  local pack
  pack=$(_build_context_pack "unknown_phase")

  _assert_contains "unknown phase gets full summary" "$pack" "Session Summary"

  _teardown_tmp
}

test_7_context_pack_handles_missing_state_file() {
  echo "Test 7: _build_context_pack gracefully handles missing state file"
  _setup_tmp
  _source_state_functions "$AC"

  STATE_FILE="$TEST_TMPDIR/nonexistent_state.json"

  local pack
  pack=$(_build_context_pack "skill_chain")

  _assert_contains "fallback message on missing state" "$pack" "state unavailable"

  _teardown_tmp
}

test_8_state_get_returns_empty_on_missing_key() {
  echo "Test 8: _state_get returns empty string for missing keys without crashing"
  _setup_tmp
  _source_state_functions "$AC"

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="test"
  BASELINE_COMMIT=""
  _init_state

  local val
  val=$(_state_get '.semantic.nonexistent_key // empty')
  _assert_eq "missing key returns empty" "" "$val"

  _teardown_tmp
}

# ─── Run ──────────────────────────────────────────────────────────────────────

echo "=== auto_claude state & context pack tests ==="
echo ""
test_1_init_state_valid_json; echo ""
test_2_jq_update_atomic; echo ""
test_3_update_test_results; echo ""
test_4_context_pack_fresh_review_excludes_intent; echo ""
test_5_context_pack_skill_chain_includes_intent; echo ""
test_6_context_pack_unknown_phase_returns_full_state; echo ""
test_7_context_pack_handles_missing_state_file; echo ""
test_8_state_get_returns_empty_on_missing_key

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ $FAIL -gt 0 ] && exit 1 || exit 0

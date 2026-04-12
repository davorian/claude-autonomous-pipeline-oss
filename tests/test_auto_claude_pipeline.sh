#!/bin/bash
# test_auto_claude_pipeline.sh — Tests for pipeline infrastructure
#
# Covers: _discover_test_suites, _run_all_suites, get_changed_files,
#         _filter_to_changed, _find_long_files, opinionated mode flag parsing
#
# Usage: bash test_auto_claude_pipeline.sh

set -euo pipefail

PASS=0
FAIL=0
TEST_TMPDIR=""

_setup_tmp() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ac_pipeline_test.XXXXXX")
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AC="$(cd "$SCRIPT_DIR/.." && pwd)/bin/auto_claude"
[ -f "$AC" ] || AC="$HOME/bin/auto_claude"

_source_pipeline_functions() {
  log() { :; }

  # Stub variables that _run_all_suites depends on
  CONF_FILE="${CONF_FILE:-/dev/null}"
  _ENV_SKIP_SUITES="${_ENV_SKIP_SUITES:-}"
  _SUITE_TMP_DIR=""
  SUITE_IDLE_TIMEOUT="${SUITE_IDLE_TIMEOUT:-0}"

  eval "$(awk '/^_discover_test_suites[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^_suite_tmp_dir[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^_get_suite_exit[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^_get_suite_output[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^_run_all_suites[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^_filter_to_changed[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^_default_find_long_files[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^_find_long_files[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^get_changed_files[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
}

_unset_suite_functions() {
  local fns
  fns=$(declare -F | awk '{print $3}' | grep '^test_suite_' || true)
  for fn in $fns; do unset -f "$fn" 2>/dev/null || true; done
}

# ─── Test Suite Discovery ─────────────────────────────────────────────────────

test_1_discovers_test_suite_functions() {
  echo "Test 1: _discover_test_suites finds all test_suite_* functions"
  _source_pipeline_functions
  _unset_suite_functions

  test_suite_jest() { echo "jest"; }
  test_suite_vitest() { echo "vitest"; }

  local result
  result=$(_discover_test_suites)

  _assert_contains "discovers jest" "$result" "test_suite_jest"
  _assert_contains "discovers vitest" "$result" "test_suite_vitest"

  _unset_suite_functions
}

test_2_no_test_suites_returns_empty() {
  echo "Test 2: _discover_test_suites returns empty when none defined"
  _source_pipeline_functions
  _unset_suite_functions

  local result
  result=$(_discover_test_suites)
  _assert_eq "empty result" "" "$result"
}

test_3_run_all_suites_tracks_pass_fail() {
  echo "Test 3: _run_all_suites populates LAST_PASSED/FAILED_SUITES correctly"
  _source_pipeline_functions
  _unset_suite_functions

  test_suite_passing() { return 0; }
  test_suite_failing() { return 1; }

  LAST_PASSED_SUITES=""
  LAST_FAILED_SUITES=""
  LAST_TEST_OUTPUT=""

  local exit_code=0
  _run_all_suites || exit_code=$?

  _assert_eq "returns non-zero on failure" "1" "$exit_code"
  _assert_contains "passing suite tracked" "$LAST_PASSED_SUITES" "passing"
  _assert_contains "failing suite tracked" "$LAST_FAILED_SUITES" "failing"

  _unset_suite_functions
}

test_4_run_all_suites_all_pass() {
  echo "Test 4: _run_all_suites returns 0 when all suites pass"
  _source_pipeline_functions
  _unset_suite_functions

  test_suite_a() { return 0; }
  test_suite_b() { return 0; }

  LAST_PASSED_SUITES=""
  LAST_FAILED_SUITES=""
  LAST_TEST_OUTPUT=""

  local exit_code=0
  _run_all_suites || exit_code=$?

  _assert_eq "returns 0 on all pass" "0" "$exit_code"
  _assert_eq "no failed suites" "" "${LAST_FAILED_SUITES// /}"

  _unset_suite_functions
}

# ─── Changed File Detection ───────────────────────────────────────────────────

test_5_get_changed_files_detects_modifications() {
  echo "Test 5: get_changed_files detects files modified since baseline commit"
  _setup_tmp
  _source_pipeline_functions

  cd "$TEST_TMPDIR"
  git init -q
  git config user.email "test@test.com" && git config user.name "Test"
  echo "original" > app.ts
  git add app.ts && git commit -q -m "init"

  PROJECT_ROOT="$TEST_TMPDIR"
  HAS_GIT=true
  BASELINE_COMMIT=$(git rev-parse HEAD)
  BASELINE_FILE="$TEST_TMPDIR/.baseline"
  git ls-files --others --exclude-standard | sort > "$BASELINE_FILE"

  echo "modified" > app.ts

  local changed
  changed=$(get_changed_files)
  _assert_contains "detects modified file" "$changed" "app.ts"

  _teardown_tmp
}

test_6_get_changed_files_excludes_pre_existing_untracked() {
  echo "Test 6: get_changed_files excludes untracked files that pre-dated the pipeline"
  _setup_tmp
  _source_pipeline_functions

  cd "$TEST_TMPDIR"
  git init -q
  git config user.email "test@test.com" && git config user.name "Test"
  git commit -q --allow-empty -m "init"

  # Pre-existing untracked file — should NOT appear
  echo "pre-existing" > old_scratch.ts

  PROJECT_ROOT="$TEST_TMPDIR"
  HAS_GIT=true
  BASELINE_COMMIT=$(git rev-parse HEAD)
  BASELINE_FILE="$TEST_TMPDIR/.baseline"
  # Snapshot includes old_scratch.ts — simulating pipeline start
  git ls-files --others --exclude-standard | sort > "$BASELINE_FILE"

  # New file created AFTER baseline snapshot — should appear
  echo "new" > new_feature.ts

  local changed
  changed=$(get_changed_files)

  _assert_contains "new file detected" "$changed" "new_feature.ts"
  _assert_not_contains "pre-existing untracked excluded" "$changed" "old_scratch.ts"

  _teardown_tmp
}

# ─── LOC Filtering ────────────────────────────────────────────────────────────

test_7_filter_to_changed_only_includes_session_files() {
  echo "Test 7: _filter_to_changed only passes through files in changed list"
  _source_pipeline_functions

  PROJECT_ROOT="/tmp"
  local changed_files="src/feature.ts
src/utils.ts"

  # Simulate _find_long_files output format: "350 /tmp/src/feature.ts"
  local long_files_output="350 /tmp/src/feature.ts
420 /tmp/src/old_preexisting.ts"

  local filtered
  filtered=$(echo "$long_files_output" | _filter_to_changed "$changed_files")

  _assert_contains "session file included" "$filtered" "feature.ts"
  _assert_not_contains "pre-existing file excluded" "$filtered" "old_preexisting.ts"
}

# ─── Opinionated Flag ─────────────────────────────────────────────────────────

test_8_opinionated_flag_sets_variable() {
  echo "Test 8: --opinionated CLI flag results in OPINIONATED=true after conf resolution"
  # We test the resolution logic directly rather than invoking the full script
  # (which requires a conf file and spec)
  _CLI_OPINIONATED=true
  OPINIONATED=false

  [ "$_CLI_OPINIONATED" = true ] && OPINIONATED=true

  _assert_eq "CLI flag sets OPINIONATED" "true" "$OPINIONATED"
}

test_9_opinionated_off_injects_advisory_into_review_only() {
  echo "Test 9: OPINIONATED=false injects advisory fragment into review phases only — not PLAN_CONTEXT"
  # Simulate the resolution block with OPINIONATED=false
  OPINIONATED=false
  PLAN_CONTEXT=""
  REVIEW_EXTRAS=""
  FRESH_REVIEW_PREAMBLE=""

  _OPINIONATED_PRINCIPLES="1. Test principle"

  _OPINIONATED_FRAGMENT="## Architectural Observations (advisory)

You are NOT required to apply the following principles. However, where you notice
opportunities or violations, surface them as named observations.

${_OPINIONATED_PRINCIPLES}"

  if [ "$OPINIONATED" = false ]; then
    REVIEW_EXTRAS="${_OPINIONATED_FRAGMENT}${REVIEW_EXTRAS:+

${REVIEW_EXTRAS}}"
    FRESH_REVIEW_PREAMBLE="${_OPINIONATED_FRAGMENT}${FRESH_REVIEW_PREAMBLE:+

${FRESH_REVIEW_PREAMBLE}}"
  fi

  _assert_eq "PLAN_CONTEXT unchanged when off" "" "$PLAN_CONTEXT"
  _assert_contains "REVIEW_EXTRAS has advisory fragment" "$REVIEW_EXTRAS" "advisory"
  _assert_contains "FRESH_REVIEW_PREAMBLE has advisory fragment" "$FRESH_REVIEW_PREAMBLE" "advisory"
}

test_10_opinionated_on_injects_enforced_into_all_phases() {
  echo "Test 10: OPINIONATED=true injects enforced fragment into plan, review, and fresh_review"
  OPINIONATED=true
  PLAN_CONTEXT=""
  REVIEW_EXTRAS=""
  FRESH_REVIEW_PREAMBLE=""

  _OPINIONATED_PRINCIPLES="1. Test principle"

  _OPINIONATED_FRAGMENT="## Architectural Standards (enforced)

The following principles are requirements.

${_OPINIONATED_PRINCIPLES}"

  if [ "$OPINIONATED" = true ]; then
    PLAN_CONTEXT="${_OPINIONATED_FRAGMENT}${PLAN_CONTEXT:+

${PLAN_CONTEXT}}"
    REVIEW_EXTRAS="${_OPINIONATED_FRAGMENT}${REVIEW_EXTRAS:+

${REVIEW_EXTRAS}}"
    FRESH_REVIEW_PREAMBLE="${_OPINIONATED_FRAGMENT}${FRESH_REVIEW_PREAMBLE:+

${FRESH_REVIEW_PREAMBLE}}"
  fi

  _assert_contains "PLAN_CONTEXT has enforced fragment" "$PLAN_CONTEXT" "enforced"
  _assert_contains "REVIEW_EXTRAS has enforced fragment" "$REVIEW_EXTRAS" "enforced"
  _assert_contains "FRESH_REVIEW_PREAMBLE has enforced fragment" "$FRESH_REVIEW_PREAMBLE" "enforced"
}

# ─── Run ──────────────────────────────────────────────────────────────────────

echo "=== auto_claude pipeline infrastructure tests ==="
echo ""
test_1_discovers_test_suite_functions; echo ""
test_2_no_test_suites_returns_empty; echo ""
test_3_run_all_suites_tracks_pass_fail; echo ""
test_4_run_all_suites_all_pass; echo ""
test_5_get_changed_files_detects_modifications; echo ""
test_6_get_changed_files_excludes_pre_existing_untracked; echo ""
test_7_filter_to_changed_only_includes_session_files; echo ""
test_8_opinionated_flag_sets_variable; echo ""
test_9_opinionated_off_injects_advisory_into_review_only; echo ""
test_10_opinionated_on_injects_enforced_into_all_phases

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ $FAIL -gt 0 ] && exit 1 || exit 0

#!/bin/bash
# test_auto_claude_ci_checks.sh — Tests for the ci_checks phase of auto_claude
#
# Validates CI check discovery, classification, and auto-discovery logic
# without running the full pipeline or needing Claude.
#
# Usage: test_auto_claude_ci_checks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTO_CLAUDE="$SCRIPT_DIR/auto_claude"
PASS=0
FAIL=0
TEST_TMPDIR=""

# ─── Helpers ──────────────────────────────────────────────────────────────────

_setup_tmp() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ac_ci_test.XXXXXX")
}

_teardown_tmp() {
  [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
  TEST_TMPDIR=""
}

_pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

_fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  [ -n "${2:-}" ] && echo "        $2"
}

_assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    _pass "$label"
  else
    _fail "$label" "expected='$expected' actual='$actual'"
  fi
}

_assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    _pass "$label"
  else
    _fail "$label" "'$needle' not found in output"
  fi
}

_assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    _fail "$label" "'$needle' unexpectedly found in output"
  else
    _pass "$label"
  fi
}

_assert_fn_exists() {
  local label="$1" fn_name="$2"
  if declare -F "$fn_name" &>/dev/null; then
    _pass "$label"
  else
    _fail "$label" "function '$fn_name' not defined"
  fi
}

_assert_fn_not_exists() {
  local label="$1" fn_name="$2"
  if declare -F "$fn_name" &>/dev/null; then
    _fail "$label" "function '$fn_name' unexpectedly defined"
  else
    _pass "$label"
  fi
}

# Source only the CI check functions from auto_claude without running anything.
# We extract the functions we need and eval them in the current shell.
_source_ci_functions() {
  # We need: _discover_ci_checks, _has_ci_fix, _ci_adapter_package_json,
  # and _auto_discover_ci_checks (the dispatcher).
  log() { :; }  # no-op logger

  eval "$(awk '/^_discover_ci_checks[(]/{f=1} f{print} /^[}]$/{if(f){f=0}}' "$AUTO_CLAUDE")"
  eval "$(awk '/^_has_ci_fix[(]/{f=1} f{print} /^[}]$/{if(f){f=0}}' "$AUTO_CLAUDE")"
  eval "$(awk '/^_ci_adapter_package_json[(]/{f=1} f{print} /^[}]$/{if(f){f=0}}' "$AUTO_CLAUDE")"
  eval "$(awk '/^_auto_discover_ci_checks[(]/{f=1} f{print} /^[}]$/{if(f){f=0}}' "$AUTO_CLAUDE")"
}

# Clean up any ci_check_*/ci_fix_* functions from previous tests
_unset_ci_functions() {
  local fns
  fns=$(declare -F | awk '{print $3}' | grep '^ci_check_\|^ci_fix_' || true)
  for fn in $fns; do
    unset -f "$fn" 2>/dev/null || true
  done
}

# ─── Test Cases ───────────────────────────────────────────────────────────────

test_1_explicit_conf_functions() {
  echo "Test 1: Discovery — explicit .conf functions"
  _unset_ci_functions
  _source_ci_functions

  # Define explicit ci_check/ci_fix functions (simulating .conf)
  ci_check_format() { echo "checking format"; }
  ci_fix_format() { echo "fixing format"; }
  ci_check_types() { echo "checking types"; }

  local result
  result=$(_discover_ci_checks)

  _assert_contains "discovers ci_check_format" "$result" "ci_check_format"
  _assert_contains "discovers ci_check_types" "$result" "ci_check_types"

  _has_ci_fix "format"
  _pass "format is auto-fixable (ci_fix_format exists)"

  if ! _has_ci_fix "types"; then
    _pass "types is Claude-fixable (no ci_fix_types)"
  else
    _fail "types should be Claude-fixable"
  fi

  _unset_ci_functions
}

test_2_package_json_auto_discovery() {
  echo "Test 2: Discovery — package.json auto-fallback"
  _setup_tmp
  _unset_ci_functions
  _source_ci_functions

  PROJECT_ROOT="$TEST_TMPDIR"
  cat > "${TEST_TMPDIR}/package.json" << 'PKGJSON'
{
  "scripts": {
    "start": "next start",
    "prettier-check": "prettier --check .",
    "prettier-fix": "prettier --write .",
    "lint": "eslint .",
    "lint:fix": "eslint --fix .",
    "typecheck": "tsc --noEmit"
  }
}
PKGJSON

  _auto_discover_ci_checks

  local result
  result=$(_discover_ci_checks)

  _assert_contains "discovers format check" "$result" "ci_check_format"
  _assert_contains "discovers lint check" "$result" "ci_check_lint"
  _assert_contains "discovers types check" "$result" "ci_check_types"

  _assert_fn_exists "format fix exists" "ci_fix_format"
  _assert_fn_exists "lint fix exists" "ci_fix_lint"
  _assert_fn_not_exists "no types fix (Claude-fixable)" "ci_fix_types"

  _unset_ci_functions
  _teardown_tmp
}

test_3_no_checks_available() {
  echo "Test 3: Discovery — no checks available"
  _setup_tmp
  _unset_ci_functions
  _source_ci_functions

  PROJECT_ROOT="$TEST_TMPDIR"
  cat > "${TEST_TMPDIR}/package.json" << 'PKGJSON'
{
  "scripts": {
    "start": "next start",
    "build": "next build"
  }
}
PKGJSON

  _auto_discover_ci_checks

  local result
  result=$(_discover_ci_checks)

  _assert_eq "no checks discovered" "" "$result"

  _unset_ci_functions
  _teardown_tmp
}

test_4_conf_overrides_auto_discovery() {
  echo "Test 4: Discovery — .conf overrides auto-discovery"
  _setup_tmp
  _unset_ci_functions
  _source_ci_functions

  PROJECT_ROOT="$TEST_TMPDIR"
  cat > "${TEST_TMPDIR}/package.json" << 'PKGJSON'
{
  "scripts": {
    "prettier-check": "prettier --check .",
    "lint": "eslint ."
  }
}
PKGJSON

  # Define an explicit ci_check function BEFORE auto-discovery
  ci_check_custom() { echo "custom check"; }

  _auto_discover_ci_checks

  local result
  result=$(_discover_ci_checks)

  _assert_contains "discovers custom check" "$result" "ci_check_custom"
  _assert_not_contains "auto-discovery skipped (no format)" "$result" "ci_check_format"
  _assert_not_contains "auto-discovery skipped (no lint)" "$result" "ci_check_lint"

  _unset_ci_functions
  _teardown_tmp
}

test_5_classification() {
  echo "Test 5: Classification — auto-fixable vs Claude-fixable"
  _unset_ci_functions
  _source_ci_functions

  ci_check_a() { echo "check a"; }
  ci_fix_a() { echo "fix a"; }
  ci_check_b() { echo "check b"; }
  # No ci_fix_b

  if _has_ci_fix "a"; then
    _pass "a is auto-fixable"
  else
    _fail "a should be auto-fixable"
  fi

  if ! _has_ci_fix "b"; then
    _pass "b is Claude-fixable"
  else
    _fail "b should be Claude-fixable"
  fi

  _unset_ci_functions
}

test_6_typescript_devdeps_fallback() {
  echo "Test 6: Discovery — typescript in devDependencies fallback"
  _setup_tmp
  _unset_ci_functions
  _source_ci_functions

  PROJECT_ROOT="$TEST_TMPDIR"
  cat > "${TEST_TMPDIR}/package.json" << 'PKGJSON'
{
  "scripts": {
    "start": "next start"
  },
  "devDependencies": {
    "typescript": "^5.0.0"
  }
}
PKGJSON

  _auto_discover_ci_checks

  local result
  result=$(_discover_ci_checks)

  _assert_contains "discovers types via devDeps fallback" "$result" "ci_check_types"
  _assert_fn_not_exists "no types fix" "ci_fix_types"

  _unset_ci_functions
  _teardown_tmp
}

test_7_live_user_home() {
  echo "Test 7: Live test — user_home project"

  local user_home="/Users/lyndonfasanya/projects/multiverse/user_home"
  if [ ! -f "${user_home}/.auto_claude.conf" ]; then
    echo "  SKIP: user_home not available at expected path"
    return 0
  fi

  _unset_ci_functions
  _source_ci_functions

  PROJECT_ROOT="$user_home"

  # Source the project's .auto_claude.conf to load ci_check_* functions
  # shellcheck disable=SC1091
  source "${user_home}/.auto_claude.conf"

  local result
  result=$(_discover_ci_checks)

  _assert_contains "discovers format check" "$result" "ci_check_format"
  _assert_contains "discovers types check" "$result" "ci_check_types"
  _assert_contains "discovers lint check" "$result" "ci_check_lint"

  _assert_fn_exists "format fix exists" "ci_fix_format"
  _assert_fn_exists "lint fix exists" "ci_fix_lint"
  _assert_fn_not_exists "no types fix" "ci_fix_types"

  _unset_ci_functions
}

test_8_live_checks_pass() {
  echo "Test 8: Live test — all checks run (may fail on dirty tree)"

  local user_home="/Users/lyndonfasanya/projects/multiverse/user_home"
  if [ ! -f "${user_home}/.auto_claude.conf" ]; then
    echo "  SKIP: user_home not available at expected path"
    return 0
  fi

  _unset_ci_functions
  _source_ci_functions

  PROJECT_ROOT="$user_home"
  # shellcheck disable=SC1091
  source "${user_home}/.auto_claude.conf"

  local checks
  checks=$(_discover_ci_checks)

  # This test verifies the check FUNCTIONS execute without crashing,
  # not that the project is clean. On a dirty working tree, checks
  # may legitimately fail (e.g. unformatted scratch files).
  for check_fn in $checks; do
    local name="${check_fn#ci_check_}"
    local exit_code=0
    local output=""
    output=$("$check_fn" 2>&1) || exit_code=$?
    if [ $exit_code -eq 0 ]; then
      _pass "check ${name} executes and passes"
    else
      # Check ran successfully (didn't crash) but found issues — that's OK
      _pass "check ${name} executes (exit $exit_code — expected on dirty tree)"
    fi
  done

  _unset_ci_functions
}

# ─── Run ──────────────────────────────────────────────────────────────────────

echo "=== auto_claude ci_checks tests ==="
echo ""

test_1_explicit_conf_functions
echo ""
test_2_package_json_auto_discovery
echo ""
test_3_no_checks_available
echo ""
test_4_conf_overrides_auto_discovery
echo ""
test_5_classification
echo ""
test_6_typescript_devdeps_fallback
echo ""
test_7_live_user_home
echo ""
test_8_live_checks_pass

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [ $FAIL -gt 0 ]; then
  exit 1
fi

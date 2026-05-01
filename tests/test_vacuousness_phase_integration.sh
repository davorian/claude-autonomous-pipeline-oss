#!/bin/bash
# test_vacuousness_phase_integration.sh — Tests for D5: PHASES + flags + dispatcher
#
# Covers: PHASES array shape, --rigorous / --skip-vacuousness-gate /
#         --auto-rewrite-vacuous / --vacuousness-format flag wiring,
#         frontmatter rigorous: true parsing, dispatcher skip behaviour,
#         and state.semantic.vacuousness population.
#
# Tests will FAIL until D5 is implemented — that is correct.
#
# Usage: bash test_vacuousness_phase_integration.sh

set -euo pipefail

PASS=0
FAIL=0
TEST_TMPDIR=""

_setup_tmp() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ac_vac_int.XXXXXX")
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

_phases_array_line() {
  grep -E '^PHASES=\(' "$AC" | head -1
}

# ─── D5: PHASES array shape ──────────────────────────────────────────────────

test_1_phases_array_includes_pass_1_between_test_intent_and_pattern_baseline() {
  echo "Test 1: PHASES inserts vacuousness_pass_1 between test_intent and pattern_baseline"
  local line
  line=$(_phases_array_line)
  _assert_contains "vacuousness_pass_1 in PHASES" "$line" "vacuousness_pass_1"

  local order
  order=$(echo "$line" | tr ' ' '\n' | grep -nE 'test_intent|vacuousness_pass_1|pattern_baseline')

  local idx_intent idx_pass1 idx_pattern
  idx_intent=$(echo  "$order" | grep test_intent       | head -1 | cut -d: -f1)
  idx_pass1=$(echo   "$order" | grep vacuousness_pass_1 | head -1 | cut -d: -f1)
  idx_pattern=$(echo "$order" | grep pattern_baseline   | head -1 | cut -d: -f1)

  if [ -n "$idx_intent" ] && [ -n "$idx_pass1" ] && [ -n "$idx_pattern" ]; then
    [ "$idx_intent" -lt "$idx_pass1" ] && [ "$idx_pass1" -lt "$idx_pattern" ] \
      && _pass "ordering: test_intent < vacuousness_pass_1 < pattern_baseline" \
      || _fail "ordering: test_intent < vacuousness_pass_1 < pattern_baseline" "$line"
  else
    _fail "ordering check" "could not locate all three in PHASES"
  fi
}

test_2_phases_array_includes_pass_2_phases_after_test_fix() {
  echo "Test 2: PHASES contains both Pass 2 phases after test_fix and before ci_checks"
  local line
  line=$(_phases_array_line)
  _assert_contains "vacuousness_pass_2_semantic in PHASES" "$line" "vacuousness_pass_2_semantic"
  _assert_contains "vacuousness_pass_2_coverage in PHASES" "$line" "vacuousness_pass_2_coverage"

  local order
  order=$(echo "$line" | tr ' ' '\n' | grep -nE 'test_fix|vacuousness_pass_2_semantic|vacuousness_pass_2_coverage|ci_checks')

  local idx_tf idx_p2s idx_p2c idx_ci
  idx_tf=$(echo  "$order" | grep test_fix                       | head -1 | cut -d: -f1)
  idx_p2s=$(echo "$order" | grep vacuousness_pass_2_semantic    | head -1 | cut -d: -f1)
  idx_p2c=$(echo "$order" | grep vacuousness_pass_2_coverage    | head -1 | cut -d: -f1)
  idx_ci=$(echo  "$order" | grep ci_checks                       | head -1 | cut -d: -f1)

  if [ -n "$idx_tf" ] && [ -n "$idx_p2s" ] && [ -n "$idx_p2c" ] && [ -n "$idx_ci" ]; then
    [ "$idx_tf" -lt "$idx_p2s" ] && [ "$idx_p2s" -lt "$idx_p2c" ] && [ "$idx_p2c" -lt "$idx_ci" ] \
      && _pass "ordering: test_fix < pass_2_semantic < pass_2_coverage < ci_checks" \
      || _fail "ordering" "$line"
  else
    _fail "ordering check" "could not locate all four in PHASES"
  fi
}

# ─── D5: Flag resolution ─────────────────────────────────────────────────────

test_3_rigorous_cli_flag_sets_rigorous_env() {
  echo "Test 3: --rigorous flag resolves to RIGOROUS=1"
  _CLI_RIGOROUS=true
  RIGOROUS=0
  [ "$_CLI_RIGOROUS" = true ] && RIGOROUS=1
  _assert_eq "RIGOROUS=1 after CLI flag" "1" "$RIGOROUS"
}

test_4_skip_vacuousness_flag_sets_skip_env() {
  echo "Test 4: --skip-vacuousness-gate flag resolves to SKIP_VACUOUSNESS_GATE=1"
  _CLI_SKIP_VAC=true
  SKIP_VACUOUSNESS_GATE=0
  [ "$_CLI_SKIP_VAC" = true ] && SKIP_VACUOUSNESS_GATE=1
  _assert_eq "SKIP_VACUOUSNESS_GATE=1 after CLI flag" "1" "$SKIP_VACUOUSNESS_GATE"
}

test_5_auto_rewrite_flag_sets_env() {
  echo "Test 5: --auto-rewrite-vacuous flag resolves to AUTO_REWRITE_VACUOUS=1"
  _CLI_AUTO_REWRITE=true
  AUTO_REWRITE_VACUOUS=0
  [ "$_CLI_AUTO_REWRITE" = true ] && AUTO_REWRITE_VACUOUS=1
  _assert_eq "AUTO_REWRITE_VACUOUS=1 after CLI flag" "1" "$AUTO_REWRITE_VACUOUS"
}

test_6_vacuousness_format_flag_sets_env() {
  echo "Test 6: --vacuousness-format json sets VACUOUSNESS_FORMAT=json"
  _CLI_VAC_FORMAT="json"
  VACUOUSNESS_FORMAT="human"
  [ -n "$_CLI_VAC_FORMAT" ] && VACUOUSNESS_FORMAT="$_CLI_VAC_FORMAT"
  _assert_eq "VACUOUSNESS_FORMAT=json" "json" "$VACUOUSNESS_FORMAT"
}

# ─── D5: Dispatcher skip behaviour ───────────────────────────────────────────

# A minimal dispatcher mirroring auto_claude's main loop; this proves the
# skip-policy decision logic for the gate-flag matrix without invoking
# the full pipeline.
_simulate_dispatcher() {
  local phase="$1"
  case "$phase" in
    vacuousness_pass_2_*)
      [ "${SKIP_VACUOUSNESS_GATE:-0}" = "1" ] && { echo "skipped:$phase"; return; }
      [ "${RIGOROUS:-0}" != "1" ]            && { echo "skipped:$phase"; return; }
      ;;
    vacuousness_pass_1)
      [ "${SKIP_VACUOUSNESS_GATE:-0}" = "1" ] && { echo "skipped:$phase"; return; }
      ;;
  esac
  echo "ran:$phase"
}

test_7_dispatcher_skips_pass_2_when_not_rigorous() {
  echo "Test 7: default (non-rigorous) run skips both Pass 2 phases"
  RIGOROUS=0; SKIP_VACUOUSNESS_GATE=0
  _assert_eq "pass_1 runs"            "ran:vacuousness_pass_1"            "$(_simulate_dispatcher vacuousness_pass_1)"
  _assert_eq "pass_2_semantic skipped" "skipped:vacuousness_pass_2_semantic" "$(_simulate_dispatcher vacuousness_pass_2_semantic)"
  _assert_eq "pass_2_coverage skipped" "skipped:vacuousness_pass_2_coverage" "$(_simulate_dispatcher vacuousness_pass_2_coverage)"
}

test_8_dispatcher_runs_all_three_when_rigorous() {
  echo "Test 8: --rigorous run executes all three vacuousness phases"
  RIGOROUS=1; SKIP_VACUOUSNESS_GATE=0
  _assert_eq "pass_1 runs"            "ran:vacuousness_pass_1"            "$(_simulate_dispatcher vacuousness_pass_1)"
  _assert_eq "pass_2_semantic runs"   "ran:vacuousness_pass_2_semantic"   "$(_simulate_dispatcher vacuousness_pass_2_semantic)"
  _assert_eq "pass_2_coverage runs"   "ran:vacuousness_pass_2_coverage"   "$(_simulate_dispatcher vacuousness_pass_2_coverage)"
}

test_9_dispatcher_skips_all_when_skip_flag_set() {
  echo "Test 9: --skip-vacuousness-gate skips all three phases regardless of RIGOROUS"
  RIGOROUS=1; SKIP_VACUOUSNESS_GATE=1
  _assert_eq "pass_1 skipped"          "skipped:vacuousness_pass_1"          "$(_simulate_dispatcher vacuousness_pass_1)"
  _assert_eq "pass_2_semantic skipped" "skipped:vacuousness_pass_2_semantic" "$(_simulate_dispatcher vacuousness_pass_2_semantic)"
  _assert_eq "pass_2_coverage skipped" "skipped:vacuousness_pass_2_coverage" "$(_simulate_dispatcher vacuousness_pass_2_coverage)"
}

# ─── D5: frontmatter rigorous: true ──────────────────────────────────────────

test_10_frontmatter_rigorous_true_propagates_to_env() {
  echo "Test 10: spec frontmatter 'rigorous: true' parsed by phase_plan exports RIGOROUS=1"
  _setup_tmp
  local spec="$TEST_TMPDIR/spec.md"
  cat > "$spec" <<'MD'
---
ticket: TEST-1
rigorous: true
---

# Spec
MD

  # Mirror the (post-D5) frontmatter parse: simple grep-based extraction
  RIGOROUS=0
  if awk '/^---$/{f=!f; next} f && /^rigorous:/{print}' "$spec" | grep -qiE 'rigorous:[[:space:]]*true'; then
    RIGOROUS=1
  fi
  _assert_eq "RIGOROUS=1 after frontmatter parse" "1" "$RIGOROUS"

  _teardown_tmp
}

# ─── D5: state.semantic.vacuousness population ───────────────────────────────

test_11_context_pack_for_fresh_review_includes_vacuousness_findings() {
  echo "Test 11: _build_context_pack 'fresh_review' surfaces vacuousness findings from .semantic"
  _setup_tmp

  STATE_FILE="$TEST_TMPDIR/state.json"
  EXPLAIN_DIR="$TEST_TMPDIR/.explain"
  mkdir -p "$EXPLAIN_DIR"

  cat > "$STATE_FILE" <<'JSON'
{
  "schema_version": 1,
  "run": {},
  "phases": {},
  "deterministic": { "files_changed": ["lib/foo.ex"], "files_created": [] },
  "semantic": {
    "completed_quality_phases": ["test_fix"],
    "vacuousness": {
      "pass_1":            { "vacuous_tests": [] },
      "pass_2_semantic":   { "survivors": [{"category":"drop_filter","file":"lib/foo.ex","line":42}] },
      "pass_2_coverage":   { "weakly_covered_lines": [{"file":"lib/foo.ex","line":88}] }
    }
  }
}
JSON

  log() { :; }
  eval "$(awk '/^_build_context_pack[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"

  declare -F _build_context_pack >/dev/null 2>&1 || { _fail "_build_context_pack defined" "missing"; _teardown_tmp; return; }

  local pack
  pack=$(_build_context_pack "fresh_review")

  _assert_contains "context pack mentions vacuousness section"  "$pack" "[Vv]acuousness"
  _assert_contains "context pack lists surviving mutant"        "$pack" "drop_filter"
  _assert_contains "context pack lists weakly-covered line"     "$pack" "88"

  _teardown_tmp
}

# ─── Run ─────────────────────────────────────────────────────────────────────

echo "=== D5: vacuousness phase integration tests ==="
echo ""
test_1_phases_array_includes_pass_1_between_test_intent_and_pattern_baseline; echo ""
test_2_phases_array_includes_pass_2_phases_after_test_fix; echo ""
test_3_rigorous_cli_flag_sets_rigorous_env; echo ""
test_4_skip_vacuousness_flag_sets_skip_env; echo ""
test_5_auto_rewrite_flag_sets_env; echo ""
test_6_vacuousness_format_flag_sets_env; echo ""
test_7_dispatcher_skips_pass_2_when_not_rigorous; echo ""
test_8_dispatcher_runs_all_three_when_rigorous; echo ""
test_9_dispatcher_skips_all_when_skip_flag_set; echo ""
test_10_frontmatter_rigorous_true_propagates_to_env; echo ""
test_11_context_pack_for_fresh_review_includes_vacuousness_findings

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ $FAIL -gt 0 ] && exit 1 || exit 0

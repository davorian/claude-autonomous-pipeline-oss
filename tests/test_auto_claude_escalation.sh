#!/bin/bash
# test_auto_claude_escalation.sh — Tests for approach journal, tiered escalation, and TDD state
#
# Covers: _record_approach, _format_approach_journal, _tier_for_iteration,
#         escalation state schema, TDD state schema, _build_ownership_context
#
# Usage: bash test_auto_claude_escalation.sh

set -euo pipefail

PASS=0
FAIL=0
TEST_TMPDIR=""

_setup_tmp() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ac_escalation_test.XXXXXX")
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
  echo "$haystack" | grep -qF "$needle" && _pass "$label" || _fail "$label" "'$needle' not found"
}

_assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  echo "$haystack" | grep -qF "$needle" && _fail "$label" "'$needle' unexpectedly found" || _pass "$label"
}

# Source functions from auto_claude
_source_functions() {
  log() { :; }

  local ac="$1"

  eval "$(sed -n '/_jq_update()/,/^}/p' "$ac")"
  eval "$(sed -n '/_state_get()/,/^}/p' "$ac")"
  eval "$(sed -n '/_init_state()/,/^}/p' "$ac")"
  eval "$(sed -n '/_format_approach_journal()/,/^}/p' "$ac")"
  eval "$(sed -n '/_tier_for_iteration()/,/^}/p' "$ac")"

  # _build_context_pack is a large case statement — extract to end of function
  eval "$(awk '/_build_context_pack\(\)/,/^\}$/' "$ac")"

  # _build_ownership_context
  eval "$(sed -n '/_build_ownership_context()/,/^}/p' "$ac")"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AC="$(cd "$SCRIPT_DIR/.." && pwd)/bin/auto_claude"
[ -f "$AC" ] || AC="$HOME/bin/auto_claude"

# ─── Tests ────────────────────────────────────────────────────────────────────

test_1_init_state_has_approach_journal() {
  echo "Test 1: _init_state includes approach_journal as empty array"
  _setup_tmp
  _source_functions "$AC"

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="test-project"
  BASELINE_COMMIT="abc123"

  _init_state

  local journal
  journal=$(jq '.deterministic.approach_journal' "$STATE_FILE")
  _assert_eq "approach_journal is empty array" "[]" "$journal"

  local tier_reached
  tier_reached=$(jq '.deterministic.escalation.tier_reached' "$STATE_FILE")
  _assert_eq "escalation.tier_reached is 0" "0" "$tier_reached"

  local tdd_status
  tdd_status=$(jq -r '.deterministic.tdd_status' "$STATE_FILE")
  _assert_eq "tdd_status is null" "null" "$tdd_status"

  local intent_map
  intent_map=$(jq -r '.semantic.intent_map' "$STATE_FILE")
  _assert_eq "intent_map is null" "null" "$intent_map"

  local pattern_baseline
  pattern_baseline=$(jq -r '.semantic.pattern_baseline' "$STATE_FILE")
  _assert_eq "pattern_baseline is null" "null" "$pattern_baseline"

  local conformance
  conformance=$(jq -r '.semantic.conformance_findings' "$STATE_FILE")
  _assert_eq "conformance_findings is null" "null" "$conformance"

  _teardown_tmp
}

test_2_tier_for_iteration_defaults() {
  echo "Test 2: _tier_for_iteration returns correct tier with default thresholds"
  _setup_tmp
  _source_functions "$AC"

  TIER_2_AT=3
  TIER_3_AT=4
  TIER_4_AT=5

  local t1 t2 t3 t4 t5
  t1=$(_tier_for_iteration 1)
  t2=$(_tier_for_iteration 2)
  t3=$(_tier_for_iteration 3)
  t4=$(_tier_for_iteration 4)
  t5=$(_tier_for_iteration 5)

  _assert_eq "iteration 1 = tier 1" "1" "$t1"
  _assert_eq "iteration 2 = tier 1" "1" "$t2"
  _assert_eq "iteration 3 = tier 2" "2" "$t3"
  _assert_eq "iteration 4 = tier 3" "3" "$t4"
  _assert_eq "iteration 5 = tier 4" "4" "$t5"

  _teardown_tmp
}

test_3_tier_for_iteration_custom() {
  echo "Test 3: _tier_for_iteration respects custom thresholds"
  _setup_tmp
  _source_functions "$AC"

  TIER_2_AT=2
  TIER_3_AT=3
  TIER_4_AT=4

  local t1 t2 t3 t4
  t1=$(_tier_for_iteration 1)
  t2=$(_tier_for_iteration 2)
  t3=$(_tier_for_iteration 3)
  t4=$(_tier_for_iteration 4)

  _assert_eq "iteration 1 = tier 1" "1" "$t1"
  _assert_eq "iteration 2 = tier 2" "2" "$t2"
  _assert_eq "iteration 3 = tier 3" "3" "$t3"
  _assert_eq "iteration 4 = tier 4" "4" "$t4"

  _teardown_tmp
}

test_4_format_approach_journal_empty() {
  echo "Test 4: _format_approach_journal returns empty string when journal is empty"
  _setup_tmp
  _source_functions "$AC"

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="test-project"
  BASELINE_COMMIT="abc123"

  _init_state

  local result
  result=$(_format_approach_journal)
  _assert_eq "empty journal returns empty string" "" "$result"

  _teardown_tmp
}

test_5_format_approach_journal_populated() {
  echo "Test 5: _format_approach_journal formats entries correctly"
  _setup_tmp
  _source_functions "$AC"

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="test-project"
  BASELINE_COMMIT="abc123"

  _init_state

  # Add some journal entries
  _jq_update '.deterministic.approach_journal += [{"iteration": 1, "summary": "Fixed import path", "error_class": "module_not_found", "files_touched": ["src/a.ts"]}]'
  _jq_update '.deterministic.approach_journal += [{"iteration": 2, "summary": "Added missing type export", "error_class": "type_error", "files_touched": ["src/b.ts", "src/c.ts"]}]'

  local result
  result=$(_format_approach_journal)

  _assert_contains "contains PREVIOUS ATTEMPTS header" "$result" "PREVIOUS ATTEMPTS"
  _assert_contains "contains iteration 1" "$result" "Iteration 1"
  _assert_contains "contains iteration 2" "$result" "Iteration 2"
  _assert_contains "contains summary" "$result" "Fixed import path"
  _assert_contains "contains error class" "$result" "module_not_found"

  _teardown_tmp
}

test_6_context_pack_skill_chain_has_journal() {
  echo "Test 6: skill_chain context pack includes approach journal"
  _setup_tmp
  _source_functions "$AC"

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="test-project"
  BASELINE_COMMIT="abc123"
  EXPLAIN_DIR="$TEST_TMPDIR/explain"
  mkdir -p "$EXPLAIN_DIR"

  _init_state

  # Add journal entry
  _jq_update '.deterministic.approach_journal += [{"iteration": 1, "summary": "Fixed type mismatch", "error_class": "type_error", "files_touched": ["src/x.ts"]}]'

  local pack
  pack=$(_build_context_pack "skill_chain")

  _assert_contains "skill_chain pack has journal" "$pack" "Approach journal"
  _assert_contains "skill_chain pack has iteration" "$pack" "Iteration 1"
  _assert_contains "skill_chain pack has summary" "$pack" "Fixed type mismatch"

  _teardown_tmp
}

test_7_context_pack_final_has_escalation() {
  echo "Test 7: final context pack includes escalation and journal info"
  _setup_tmp
  _source_functions "$AC"

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="test-project"
  BASELINE_COMMIT="abc123"
  EXPLAIN_DIR="$TEST_TMPDIR/explain"
  mkdir -p "$EXPLAIN_DIR"

  _init_state

  # Set escalation state
  _jq_update '.deterministic.escalation.tier_reached = 3'
  _jq_update --arg d "Wrong adapter interface" '.deterministic.escalation.diagnosis = $d'
  _jq_update --arg c "B" '.deterministic.escalation.chosen = $c'

  local pack
  pack=$(_build_context_pack "final")

  _assert_contains "final pack has escalation" "$pack" "Escalation"
  _assert_contains "final pack has tier" "$pack" "tier 3"
  _assert_contains "final pack has diagnosis" "$pack" "Wrong adapter interface"
  _assert_contains "final pack has chosen" "$pack" "Chosen alternative: B"

  _teardown_tmp
}

test_8_context_pack_final_no_escalation() {
  echo "Test 8: final context pack says 'No escalation needed' when tier_reached <= 1"
  _setup_tmp
  _source_functions "$AC"

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="test-project"
  BASELINE_COMMIT="abc123"
  EXPLAIN_DIR="$TEST_TMPDIR/explain"
  mkdir -p "$EXPLAIN_DIR"

  _init_state

  local pack
  pack=$(_build_context_pack "final")

  _assert_contains "final pack says no escalation" "$pack" "No escalation needed"

  _teardown_tmp
}

test_9_context_pack_final_has_conformance() {
  echo "Test 9: final context pack includes pattern conformance when populated"
  _setup_tmp
  _source_functions "$AC"

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="test-project"
  BASELINE_COMMIT="abc123"
  EXPLAIN_DIR="$TEST_TMPDIR/explain"
  mkdir -p "$EXPLAIN_DIR"

  _init_state

  # Set conformance findings
  _jq_update '.semantic.conformance_findings = {"deviations": [{"verdict": "revert", "area": "error handling", "action_taken": "reverted to try/catch"}, {"verdict": "keep", "area": "state management", "rationale": "useState is simpler for ephemeral state"}], "conforms": ["P001"]}'

  local pack
  pack=$(_build_context_pack "final")

  _assert_contains "final pack has conformance" "$pack" "Pattern conformance"
  _assert_contains "final pack has reverted" "$pack" "reverted to try/catch"
  _assert_contains "final pack has kept" "$pack" "useState is simpler"

  _teardown_tmp
}

test_10_context_pack_fresh_review_has_deviations() {
  echo "Test 10: fresh_review context pack includes pattern deviations from explain dir"
  _setup_tmp
  _source_functions "$AC"

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="test-project"
  BASELINE_COMMIT="abc123"
  EXPLAIN_DIR="$TEST_TMPDIR/explain"
  mkdir -p "$EXPLAIN_DIR"

  _init_state

  # Write conformance findings to explain dir
  echo '{"deviations": [{"verdict": "keep", "area": "imports", "rationale": "barrel re-export needed"}], "conforms": ["P002"]}' > "$EXPLAIN_DIR/conformance_findings.json"

  local pack
  pack=$(_build_context_pack "fresh_review")

  _assert_contains "fresh_review pack has deviation" "$pack" "KEPT"
  _assert_contains "fresh_review pack has challenge" "$pack" "Challenge this"

  _teardown_tmp
}

test_11_ownership_context_empty_when_no_ownership() {
  echo "Test 11: _build_ownership_context returns empty when no ownership loaded"
  _setup_tmp
  _source_functions "$AC"

  OWNERSHIP_OWNS=""
  OWNERSHIP_READS=""
  OWNERSHIP_MUST_NOT_TOUCH=""

  local result
  result=$(_build_ownership_context)
  _assert_eq "empty ownership returns empty" "" "$result"

  _teardown_tmp
}

test_12_ownership_context_populated() {
  echo "Test 12: _build_ownership_context returns formatted context when ownership loaded"
  _setup_tmp
  _source_functions "$AC"

  OWNERSHIP_OWNS="src/a.ts
src/b.ts"
  OWNERSHIP_READS="src/types.ts"
  OWNERSHIP_MUST_NOT_TOUCH="src/shared.ts"

  local result
  result=$(_build_ownership_context)

  _assert_contains "has OWN header" "$result" "OWN (read-write)"
  _assert_contains "has READ header" "$result" "READ (read-only)"
  _assert_contains "has MUST NOT TOUCH header" "$result" "MUST NOT TOUCH"
  _assert_contains "has TODO instruction" "$result" "TODO(boundary)"

  _teardown_tmp
}

test_13_journal_empty_in_context_pack() {
  echo "Test 13: context pack shows '(no iterations needed)' when journal is empty"
  _setup_tmp
  _source_functions "$AC"

  STATE_FILE="$TEST_TMPDIR/state.json"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="test-project"
  BASELINE_COMMIT="abc123"
  EXPLAIN_DIR="$TEST_TMPDIR/explain"
  mkdir -p "$EXPLAIN_DIR"

  _init_state

  local pack
  pack=$(_build_context_pack "skill_chain")

  _assert_contains "empty journal shows no iterations" "$pack" "(no iterations needed)"

  _teardown_tmp
}

# ─── Run all tests ──────────────────────────────────────────────────────────
echo "=== auto_claude escalation, journal & TDD state tests ==="
echo ""

test_1_init_state_has_approach_journal
echo ""
test_2_tier_for_iteration_defaults
echo ""
test_3_tier_for_iteration_custom
echo ""
test_4_format_approach_journal_empty
echo ""
test_5_format_approach_journal_populated
echo ""
test_6_context_pack_skill_chain_has_journal
echo ""
test_7_context_pack_final_has_escalation
echo ""
test_8_context_pack_final_no_escalation
echo ""
test_9_context_pack_final_has_conformance
echo ""
test_10_context_pack_fresh_review_has_deviations
echo ""
test_11_ownership_context_empty_when_no_ownership
echo ""
test_12_ownership_context_populated
echo ""
test_13_journal_empty_in_context_pack
echo ""

echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ $FAIL -gt 0 ] && exit 1 || exit 0

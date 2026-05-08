#!/bin/bash
# test_vacuousness_pass_2_semantic.sh — Tests for D3: semantic-mutation gate (Gate 2)
#
# Covers: phase_vacuousness_pass_2_semantic + _vacuous_apply_mutant helper
#         in bin/auto_claude.
#
# Tests will FAIL until D3 is implemented — that is correct.
#
# Usage: bash test_vacuousness_pass_2_semantic.sh

set -euo pipefail

PASS=0
FAIL=0
TEST_TMPDIR=""

_setup_tmp() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ac_vac_pass2s.XXXXXX")
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
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AC="$REPO_ROOT/bin/auto_claude"
[ -f "$AC" ] || AC="$HOME/bin/auto_claude"

_source_pass_2_semantic() {
  log()  { :; }
  warn() { :; }
  err()  { :; }
  run_claude()       { echo "stub run_claude"; }
  run_claude_fresh() { echo "stub run_claude_fresh"; }
  _load_vacuousness_taxonomy() { echo "TAXONOMY_STUB"; }

  eval "$(awk '/^_jq_update[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^_state_get[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^_init_state[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^_vacuous_apply_mutant[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^phase_vacuousness_pass_2_semantic[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
}

# ─── D3: _vacuous_apply_mutant primitive ─────────────────────────────────────

test_1_apply_mutant_swaps_then_restores_file_contents() {
  echo "Test 1: _vacuous_apply_mutant swaps mutated content in, runs callback, restores original"
  _setup_tmp
  _source_pass_2_semantic
  declare -F _vacuous_apply_mutant >/dev/null 2>&1 || { _fail "helper defined" "missing"; _teardown_tmp; return; }

  local target="$TEST_TMPDIR/impl.ex"
  printf '%s\n' "ORIGINAL_CONTENT" > "$target"
  local mutated="$TEST_TMPDIR/mutated.ex"
  printf '%s\n' "MUTATED_CONTENT" > "$mutated"

  local seen_during_run=""
  _runner_callback() { seen_during_run=$(cat "$target"); return 1; }

  _vacuous_apply_mutant "$target" "$mutated" _runner_callback >/dev/null 2>&1 || true

  _assert_contains "callback saw mutated content while applied" "$seen_during_run" "MUTATED_CONTENT"
  _assert_eq "original restored after callback" "ORIGINAL_CONTENT" "$(cat "$target")"

  _teardown_tmp
}

test_2_apply_mutant_restores_on_callback_failure() {
  echo "Test 2: trap-protected restore — original returned even if callback fails non-zero"
  _setup_tmp
  _source_pass_2_semantic
  declare -F _vacuous_apply_mutant >/dev/null 2>&1 || { _fail "helper defined" "missing"; _teardown_tmp; return; }

  local target="$TEST_TMPDIR/impl.ex"
  printf '%s\n' "ORIG" > "$target"
  local mutated="$TEST_TMPDIR/mutated.ex"
  printf '%s\n' "MUT" > "$mutated"

  _failing_callback() { return 99; }
  _vacuous_apply_mutant "$target" "$mutated" _failing_callback >/dev/null 2>&1 || true

  _assert_eq "file restored after failing callback" "ORIG" "$(cat "$target")"

  _teardown_tmp
}

test_3_apply_mutant_returns_callback_status_for_kill_classification() {
  echo "Test 3: helper returns the callback exit code so caller can classify killed vs survived"
  _setup_tmp
  _source_pass_2_semantic
  declare -F _vacuous_apply_mutant >/dev/null 2>&1 || { _fail "helper defined" "missing"; _teardown_tmp; return; }

  local target="$TEST_TMPDIR/impl.ex"
  printf '%s\n' "x" > "$target"
  local mutated="$TEST_TMPDIR/mutated.ex"
  printf '%s\n' "y" > "$mutated"

  _killed_runner()   { return 1; }   # tests fail under mutant → killed
  _survived_runner() { return 0; }   # tests still pass → survived

  local rc_killed=0 rc_survived=0
  _vacuous_apply_mutant "$target" "$mutated" _killed_runner   >/dev/null 2>&1 || rc_killed=$?
  _vacuous_apply_mutant "$target" "$mutated" _survived_runner >/dev/null 2>&1 || rc_survived=$?

  [ "$rc_killed" -ne 0 ] && _pass "killed runner returns non-zero" || _fail "killed runner returns non-zero" "rc=$rc_killed"
  _assert_eq "survived runner returns 0" "0" "$rc_survived"

  _teardown_tmp
}

test_4_apply_mutant_no_bash_4_features() {
  echo "Test 4: _vacuous_apply_mutant uses no bash-4-only constructs (3.2 portability)"
  _source_pass_2_semantic
  declare -F _vacuous_apply_mutant >/dev/null 2>&1 || { _fail "helper defined" "missing"; return; }

  local body
  body=$(declare -f _vacuous_apply_mutant)

  _assert_not_contains "no declare -A" "$body" "declare -A"
  _assert_not_contains "no mapfile" "$body" "mapfile"
  _assert_not_contains "no readarray" "$body" "readarray"
  _assert_not_contains "no echo -e" "$body" "echo -e"
}

# ─── D3: phase behaviour ─────────────────────────────────────────────────────

test_5_phase_emits_artefact_with_survivors_array() {
  echo "Test 5: phase emits vacuousness_pass_2_semantic.json with a survivors array"
  _setup_tmp
  _source_pass_2_semantic
  declare -F phase_vacuousness_pass_2_semantic >/dev/null 2>&1 || { _fail "phase defined" "missing"; _teardown_tmp; return; }

  STATE_FILE="$TEST_TMPDIR/state.json"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="t"
  BASELINE_COMMIT=""
  EXPLAIN_DIR="$TEST_TMPDIR/.explain"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  mkdir -p "$EXPLAIN_DIR"
  _init_state

  # Stub: pretend Claude produced one mutant per file and it survived
  run_claude_fresh() {
    cat <<'JSON'
[
  {"category":"no_op_body","file":"lib/foo.ex","line":10,"original":"do: real(x)","mutated":"do: %{}","provenance":"taxonomy","applies_to_lang":"elixir"}
]
JSON
  }
  _run_all_suites() { LAST_FAILED_SUITES=""; LAST_TEST_OUTPUT="all green under mutant"; return 0; }

  jq '.deterministic.files_changed = ["lib/foo.ex"]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  RIGOROUS=1
  EXPECTED_SURVIVORS=""

  phase_vacuousness_pass_2_semantic >/dev/null 2>&1 || true

  [ -f "$EXPLAIN_DIR/vacuousness_pass_2_semantic.json" ] && _pass "artefact emitted" || _fail "artefact emitted" "missing"
  if [ -f "$EXPLAIN_DIR/vacuousness_pass_2_semantic.json" ]; then
    local s
    s=$(jq '.survivors | length' "$EXPLAIN_DIR/vacuousness_pass_2_semantic.json" 2>/dev/null || echo 0)
    [ "$s" -ge 1 ] && _pass "survivor recorded when no test fails under mutant" \
                   || _fail "survivor recorded when no test fails under mutant" "survivors=$s"
  fi

  _teardown_tmp
}

test_6_compile_failure_classified_as_invalid_not_survivor() {
  echo "Test 6: a mutant that fails the syntax check goes into invalid_mutants, NOT survivors"
  _setup_tmp
  _source_pass_2_semantic
  declare -F phase_vacuousness_pass_2_semantic >/dev/null 2>&1 || { _fail "phase defined" "missing"; _teardown_tmp; return; }

  STATE_FILE="$TEST_TMPDIR/state.json"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="t"; BASELINE_COMMIT=""
  EXPLAIN_DIR="$TEST_TMPDIR/.explain"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  mkdir -p "$EXPLAIN_DIR"
  _init_state

  run_claude_fresh() {
    cat <<'JSON'
[
  {"category":"swap_column","file":"lib/foo.ex","line":12,"original":"u.id","mutated":"<<<broken syntax>>>","provenance":"taxonomy","applies_to_lang":"elixir"}
]
JSON
  }
  # Stubbed syntax check ALWAYS fails — every mutant is invalid
  SYNTAX_CHECK_COMMAND="false"
  _run_all_suites() { _fail "should not run tests on invalid mutant" "_run_all_suites called"; return 0; }

  jq '.deterministic.files_changed = ["lib/foo.ex"]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  RIGOROUS=1; EXPECTED_SURVIVORS=""

  phase_vacuousness_pass_2_semantic >/dev/null 2>&1 || true

  if [ -f "$EXPLAIN_DIR/vacuousness_pass_2_semantic.json" ]; then
    local s i
    s=$(jq '.survivors | length' "$EXPLAIN_DIR/vacuousness_pass_2_semantic.json" 2>/dev/null || echo 99)
    i=$(jq '.invalid_mutants | length' "$EXPLAIN_DIR/vacuousness_pass_2_semantic.json" 2>/dev/null || echo 0)
    _assert_eq "no survivors when all mutants invalid" "0" "$s"
    [ "$i" -ge 1 ] && _pass "invalid_mutants populated" || _fail "invalid_mutants populated" "i=$i"
  fi

  _teardown_tmp
}

test_7_expected_survivors_filter_suppresses_match() {
  echo "Test 7: EXPECTED_SURVIVORS suppresses a known-equivalent mutant from the survivors array"
  _setup_tmp
  _source_pass_2_semantic
  declare -F phase_vacuousness_pass_2_semantic >/dev/null 2>&1 || { _fail "phase defined" "missing"; _teardown_tmp; return; }

  STATE_FILE="$TEST_TMPDIR/state.json"
  PROJECT_ROOT="$TEST_TMPDIR"; PROJECT_NAME="t"; BASELINE_COMMIT=""
  EXPLAIN_DIR="$TEST_TMPDIR/.explain"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  mkdir -p "$EXPLAIN_DIR"
  _init_state

  run_claude_fresh() {
    cat <<'JSON'
[
  {"category":"drop_filter","file":"lib/foo.ex","line":42,"original":"where: true","mutated":"","provenance":"taxonomy","applies_to_lang":"elixir"}
]
JSON
  }
  _run_all_suites() { return 0; }   # mutant survives — would normally be flagged

  jq '.deterministic.files_changed = ["lib/foo.ex"]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  RIGOROUS=1
  EXPECTED_SURVIVORS="lib/foo.ex:42:drop_filter"

  phase_vacuousness_pass_2_semantic >/dev/null 2>&1 || true

  if [ -f "$EXPLAIN_DIR/vacuousness_pass_2_semantic.json" ]; then
    local s
    s=$(jq '.survivors | length' "$EXPLAIN_DIR/vacuousness_pass_2_semantic.json" 2>/dev/null || echo 99)
    _assert_eq "EXPECTED_SURVIVORS filtered the match out" "0" "$s"
  fi

  _teardown_tmp
}

test_8_phase_writes_findings_to_state_semantic() {
  echo "Test 8: phase records findings into state.semantic.vacuousness.pass_2_semantic"
  _setup_tmp
  _source_pass_2_semantic
  declare -F phase_vacuousness_pass_2_semantic >/dev/null 2>&1 || { _fail "phase defined" "missing"; _teardown_tmp; return; }

  STATE_FILE="$TEST_TMPDIR/state.json"
  PROJECT_ROOT="$TEST_TMPDIR"; PROJECT_NAME="t"; BASELINE_COMMIT=""
  EXPLAIN_DIR="$TEST_TMPDIR/.explain"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  mkdir -p "$EXPLAIN_DIR"
  _init_state

  run_claude_fresh() { echo "[]"; }
  _run_all_suites() { return 1; }
  jq '.deterministic.files_changed = ["lib/foo.ex"]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  RIGOROUS=1; EXPECTED_SURVIVORS=""

  phase_vacuousness_pass_2_semantic >/dev/null 2>&1 || true

  local present
  present=$(jq '.semantic.vacuousness.pass_2_semantic // "missing"' "$STATE_FILE")
  [ "$present" != '"missing"' ] && _pass ".semantic.vacuousness.pass_2_semantic populated" \
                                || _fail ".semantic.vacuousness.pass_2_semantic populated" "still missing"

  _teardown_tmp
}

# ─── Run ─────────────────────────────────────────────────────────────────────

echo "=== D3: vacuousness Pass 2 (semantic mutation) tests ==="
echo ""
test_1_apply_mutant_swaps_then_restores_file_contents; echo ""
test_2_apply_mutant_restores_on_callback_failure; echo ""
test_3_apply_mutant_returns_callback_status_for_kill_classification; echo ""
test_4_apply_mutant_no_bash_4_features; echo ""
test_5_phase_emits_artefact_with_survivors_array; echo ""
test_6_compile_failure_classified_as_invalid_not_survivor; echo ""
test_7_expected_survivors_filter_suppresses_match; echo ""
test_8_phase_writes_findings_to_state_semantic

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ $FAIL -gt 0 ] && exit 1 || exit 0

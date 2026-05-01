#!/bin/bash
# test_vacuousness_pass_2_coverage.sh — Tests for D4: coverage-driven gate (Gate 3)
#
# Covers: phase_vacuousness_pass_2_coverage in bin/auto_claude.
#
# Tests will FAIL until D4 is implemented — that is correct.
#
# Usage: bash test_vacuousness_pass_2_coverage.sh

set -euo pipefail

PASS=0
FAIL=0
TEST_TMPDIR=""

_setup_tmp() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ac_vac_pass2c.XXXXXX")
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

_source_pass_2_coverage() {
  log()  { :; }
  warn() { :; }
  err()  { :; }
  run_claude()       { echo "stub"; }
  run_claude_fresh() { echo "[]"; }
  _load_vacuousness_taxonomy() { echo "STUB"; }

  eval "$(awk '/^_jq_update[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^_state_get[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^_init_state[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^_vacuous_apply_mutant[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
  eval "$(awk '/^phase_vacuousness_pass_2_coverage[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
}

_seed_coverage_artefact() {
  local path="$1"
  cat > "$path" <<'JSON'
{
  "files": {
    "lib/foo.ex": {
      "lines": [
        {"line": 10, "count": 3},
        {"line": 11, "count": 0},
        {"line": 12, "count": 5}
      ]
    }
  }
}
JSON
}

# ─── D4: phase behaviour ─────────────────────────────────────────────────────

test_1_reads_existing_coverage_map_artefact() {
  echo "Test 1: phase reads coverage from EXPLAIN_DIR/coverage_map.json when present"
  _setup_tmp
  _source_pass_2_coverage
  declare -F phase_vacuousness_pass_2_coverage >/dev/null 2>&1 || { _fail "phase defined" "missing"; _teardown_tmp; return; }

  STATE_FILE="$TEST_TMPDIR/state.json"
  PROJECT_ROOT="$TEST_TMPDIR"
  PROJECT_NAME="t"; BASELINE_COMMIT=""
  EXPLAIN_DIR="$TEST_TMPDIR/.explain"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  mkdir -p "$EXPLAIN_DIR"
  _init_state
  _seed_coverage_artefact "$EXPLAIN_DIR/coverage_map.json"

  COVERAGE_RAN=0
  run_coverage() { COVERAGE_RAN=1; }   # would-be fallback
  jq '.deterministic.files_changed = ["lib/foo.ex"]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  RIGOROUS=1

  phase_vacuousness_pass_2_coverage >/dev/null 2>&1 || true

  _assert_eq "fallback coverage NOT triggered when artefact present" "0" "$COVERAGE_RAN"

  _teardown_tmp
}

test_2_uncovered_lines_reported_without_running_mutations() {
  echo "Test 2: lines with coverage_count==0 surface as uncovered_lines, no mutation run"
  _setup_tmp
  _source_pass_2_coverage
  declare -F phase_vacuousness_pass_2_coverage >/dev/null 2>&1 || { _fail "phase defined" "missing"; _teardown_tmp; return; }

  STATE_FILE="$TEST_TMPDIR/state.json"
  PROJECT_ROOT="$TEST_TMPDIR"; PROJECT_NAME="t"; BASELINE_COMMIT=""
  EXPLAIN_DIR="$TEST_TMPDIR/.explain"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  mkdir -p "$EXPLAIN_DIR"
  _init_state
  _seed_coverage_artefact "$EXPLAIN_DIR/coverage_map.json"

  jq '.deterministic.files_changed = ["lib/foo.ex"]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

  MUTATIONS_AT_LINE_11=0
  _vacuous_apply_mutant() {
    case "$*" in
      *":11 "*|*":11"*) MUTATIONS_AT_LINE_11=1 ;;
    esac
    return 1
  }
  RIGOROUS=1

  phase_vacuousness_pass_2_coverage >/dev/null 2>&1 || true

  if [ -f "$EXPLAIN_DIR/vacuousness_pass_2_coverage.json" ]; then
    local u
    u=$(jq '.uncovered_lines | length' "$EXPLAIN_DIR/vacuousness_pass_2_coverage.json" 2>/dev/null || echo 0)
    [ "$u" -ge 1 ] && _pass "uncovered line surfaced in report" || _fail "uncovered line surfaced in report" "u=$u"
  fi
  _assert_eq "no mutation invoked at uncovered line 11" "0" "$MUTATIONS_AT_LINE_11"

  _teardown_tmp
}

test_3_weakly_covered_line_reported_when_mutant_survives() {
  echo "Test 3: a covered line whose targeted mutant survives is reported as weakly_covered"
  _setup_tmp
  _source_pass_2_coverage
  declare -F phase_vacuousness_pass_2_coverage >/dev/null 2>&1 || { _fail "phase defined" "missing"; _teardown_tmp; return; }

  STATE_FILE="$TEST_TMPDIR/state.json"
  PROJECT_ROOT="$TEST_TMPDIR"; PROJECT_NAME="t"; BASELINE_COMMIT=""
  EXPLAIN_DIR="$TEST_TMPDIR/.explain"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  mkdir -p "$EXPLAIN_DIR"
  _init_state
  _seed_coverage_artefact "$EXPLAIN_DIR/coverage_map.json"

  jq '.deterministic.files_changed = ["lib/foo.ex"]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

  # All targeted mutations survive (rc 0 = tests still pass)
  _vacuous_apply_mutant() { return 0; }
  RIGOROUS=1

  phase_vacuousness_pass_2_coverage >/dev/null 2>&1 || true

  if [ -f "$EXPLAIN_DIR/vacuousness_pass_2_coverage.json" ]; then
    local w
    w=$(jq '.weakly_covered_lines | length' "$EXPLAIN_DIR/vacuousness_pass_2_coverage.json" 2>/dev/null || echo 0)
    [ "$w" -ge 1 ] && _pass "weakly_covered_lines populated" || _fail "weakly_covered_lines populated" "w=$w"

    local has_pct
    has_pct=$(jq '.weakly_covered_lines[0] | has("coverage_pct")' "$EXPLAIN_DIR/vacuousness_pass_2_coverage.json" 2>/dev/null || echo false)
    _assert_eq "weakly_covered entry has coverage_pct" "true" "$has_pct"
  fi

  _teardown_tmp
}

test_4_clean_run_returns_ok_with_empty_arrays() {
  echo "Test 4: no uncovered lines + all mutants killed → empty arrays + exit 0"
  _setup_tmp
  _source_pass_2_coverage
  declare -F phase_vacuousness_pass_2_coverage >/dev/null 2>&1 || { _fail "phase defined" "missing"; _teardown_tmp; return; }

  STATE_FILE="$TEST_TMPDIR/state.json"
  PROJECT_ROOT="$TEST_TMPDIR"; PROJECT_NAME="t"; BASELINE_COMMIT=""
  EXPLAIN_DIR="$TEST_TMPDIR/.explain"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  mkdir -p "$EXPLAIN_DIR"
  _init_state

  cat > "$EXPLAIN_DIR/coverage_map.json" <<'JSON'
{ "files": { "lib/foo.ex": { "lines": [ {"line": 10, "count": 5}, {"line": 11, "count": 5} ] } } }
JSON
  jq '.deterministic.files_changed = ["lib/foo.ex"]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

  _vacuous_apply_mutant() { return 1; }   # all mutants killed
  RIGOROUS=1

  local rc=0
  phase_vacuousness_pass_2_coverage >/dev/null 2>&1 || rc=$?

  _assert_eq "phase exits 0 on clean run" "0" "$rc"
  if [ -f "$EXPLAIN_DIR/vacuousness_pass_2_coverage.json" ]; then
    local w u
    w=$(jq '.weakly_covered_lines | length' "$EXPLAIN_DIR/vacuousness_pass_2_coverage.json" 2>/dev/null || echo 99)
    u=$(jq '.uncovered_lines | length'      "$EXPLAIN_DIR/vacuousness_pass_2_coverage.json" 2>/dev/null || echo 99)
    _assert_eq "weakly_covered_lines empty"    "0" "$w"
    _assert_eq "uncovered_lines empty"          "0" "$u"
  fi

  _teardown_tmp
}

test_5_falls_back_when_coverage_map_missing() {
  echo "Test 5: when coverage_map.json absent, phase logs warning and runs its own coverage pass"
  _setup_tmp
  _source_pass_2_coverage
  declare -F phase_vacuousness_pass_2_coverage >/dev/null 2>&1 || { _fail "phase defined" "missing"; _teardown_tmp; return; }

  STATE_FILE="$TEST_TMPDIR/state.json"
  PROJECT_ROOT="$TEST_TMPDIR"; PROJECT_NAME="t"; BASELINE_COMMIT=""
  EXPLAIN_DIR="$TEST_TMPDIR/.explain"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  mkdir -p "$EXPLAIN_DIR"
  _init_state
  # NOTE: coverage_map.json deliberately NOT seeded
  jq '.deterministic.files_changed = ["lib/foo.ex"]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

  FALLBACK_RAN=0
  COVERAGE_COMMAND="$TEST_TMPDIR/cov.sh"
  cat > "$COVERAGE_COMMAND" <<EOF
#!/bin/bash
echo "ran-fallback" > "$TEST_TMPDIR/cov-marker"
exit 0
EOF
  chmod +x "$COVERAGE_COMMAND"

  WARN_OUTPUT=""
  warn() { WARN_OUTPUT="${WARN_OUTPUT}${*}"$'\n'; }

  RIGOROUS=1
  phase_vacuousness_pass_2_coverage >/dev/null 2>&1 || true

  [ -f "$TEST_TMPDIR/cov-marker" ] && _pass "fallback coverage command invoked" \
                                   || _fail "fallback coverage command invoked" "marker missing"
  echo "$WARN_OUTPUT" | grep -qiE 'coverage|fallback|missing' \
    && _pass "warning emitted about missing artefact" \
    || _fail "warning emitted about missing artefact" "no relevant warn() output captured"

  _teardown_tmp
}

test_6_weakly_covered_entry_includes_suggested_assertion() {
  echo "Test 6: weakly_covered_lines entries include a suggested_assertion field for auto-rewrite"
  _setup_tmp
  _source_pass_2_coverage
  declare -F phase_vacuousness_pass_2_coverage >/dev/null 2>&1 || { _fail "phase defined" "missing"; _teardown_tmp; return; }

  STATE_FILE="$TEST_TMPDIR/state.json"
  PROJECT_ROOT="$TEST_TMPDIR"; PROJECT_NAME="t"; BASELINE_COMMIT=""
  EXPLAIN_DIR="$TEST_TMPDIR/.explain"
  SPEC_FILE="$TEST_TMPDIR/spec.md"
  mkdir -p "$EXPLAIN_DIR"
  _init_state
  _seed_coverage_artefact "$EXPLAIN_DIR/coverage_map.json"

  jq '.deterministic.files_changed = ["lib/foo.ex"]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  _vacuous_apply_mutant() { return 0; }
  run_claude() { echo "Suggested: assert that the function returns the count of deleted rows, not just a non-zero map."; }
  RIGOROUS=1

  phase_vacuousness_pass_2_coverage >/dev/null 2>&1 || true

  if [ -f "$EXPLAIN_DIR/vacuousness_pass_2_coverage.json" ]; then
    local has_field
    has_field=$(jq '[.weakly_covered_lines[] | has("suggested_assertion")] | all' \
                "$EXPLAIN_DIR/vacuousness_pass_2_coverage.json" 2>/dev/null || echo false)
    _assert_eq "every weakly_covered entry has suggested_assertion" "true" "$has_field"
  fi

  _teardown_tmp
}

# ─── Run ─────────────────────────────────────────────────────────────────────

echo "=== D4: vacuousness Pass 2 (coverage-driven mutation) tests ==="
echo ""
test_1_reads_existing_coverage_map_artefact; echo ""
test_2_uncovered_lines_reported_without_running_mutations; echo ""
test_3_weakly_covered_line_reported_when_mutant_survives; echo ""
test_4_clean_run_returns_ok_with_empty_arrays; echo ""
test_5_falls_back_when_coverage_map_missing; echo ""
test_6_weakly_covered_entry_includes_suggested_assertion

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ $FAIL -gt 0 ] && exit 1 || exit 0

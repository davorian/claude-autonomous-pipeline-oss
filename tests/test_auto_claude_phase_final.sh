#!/bin/bash
# test_auto_claude_phase_final.sh — Tests for phase_final git staging logic
#
# Validates that the auto-commit stage loop handles all git check-ignore
# exit codes without triggering the ERR trap (the line 1431 bug).
#
# Usage: test_auto_claude_phase_final.sh

set -euo pipefail

PASS=0
FAIL=0
TEST_TMPDIR=""

_setup_tmp() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ac_final_test.XXXXXX")
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
  echo "$haystack" | grep -q "$needle" && _pass "$label" || _fail "$label" "'$needle' not found in output"
}

_assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  echo "$haystack" | grep -q "$needle" && _fail "$label" "'$needle' unexpectedly found" || _pass "$label"
}

# The fixed staging loop — extracted so tests can call it directly.
# This mirrors exactly what's in phase_final after the fix.
_stage_changed_files() {
  local changed_files="$1"
  echo "$changed_files" | sed '/\.auto_claude/d; /\.claude\/plans\//d' | while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$PROJECT_ROOT/$f" ] || continue
    local _ci_rc=0
    git check-ignore -q "$PROJECT_ROOT/$f" 2>/dev/null || _ci_rc=$?
    # 0=ignored(skip), 1=not-ignored(stage), 128=error(skip safely)
    [ "$_ci_rc" -eq 1 ] && git add "$PROJECT_ROOT/$f" || true
  done
}

# ─── Tests ────────────────────────────────────────────────────────────────────

test_1_ignored_file_not_staged() {
  echo "Test 1: Gitignored file is skipped"
  _setup_tmp
  cd "$TEST_TMPDIR"
  git init -q
  git config user.email "test@test.com" && git config user.name "Test"
  echo "node_modules/" > .gitignore
  mkdir -p node_modules/pkg && echo "lib" > node_modules/pkg/index.js
  git add .gitignore && git commit -q -m "init"

  PROJECT_ROOT="$TEST_TMPDIR"
  _stage_changed_files "node_modules/pkg/index.js"

  local staged
  staged=$(git diff --cached --name-only)
  _assert_not_contains "ignored file not staged" "$staged" "node_modules"
  _teardown_tmp
}

test_2_normal_file_gets_staged() {
  echo "Test 2: Normal file is staged"
  _setup_tmp
  cd "$TEST_TMPDIR"
  git init -q
  git config user.email "test@test.com" && git config user.name "Test"
  git commit -q --allow-empty -m "init"
  echo "hello" > src.ts

  PROJECT_ROOT="$TEST_TMPDIR"
  _stage_changed_files "src.ts"

  local staged
  staged=$(git diff --cached --name-only)
  _assert_contains "normal file staged" "$staged" "src.ts"
  _teardown_tmp
}

test_3_idea_dir_does_not_crash_pipeline() {
  echo "Test 3: .idea path (regression — the line 1431 bug)"
  # The bug: git check-ignore exits 128 when a path is untracked AND not in
  # .gitignore (e.g. a fresh repo with no .gitignore entry for .idea).
  # Old code: `! git check-ignore ...` — exit 128 escapes the negation and
  # fires the ERR trap, crashing the pipeline at phase_final (line 1431).
  # New code: captures exit code explicitly — 128 hits || true safely.
  #
  # Note: if .idea IS in .gitignore (exit 0), it gets skipped.
  # If it is NOT in .gitignore (exit 1), it gets staged — that's correct;
  # the fix is crash-prevention, not staging-prevention for unignored paths.
  _setup_tmp
  cd "$TEST_TMPDIR"
  git init -q
  git config user.email "test@test.com" && git config user.name "Test"
  git commit -q --allow-empty -m "init"
  mkdir -p .idea && echo "<project/>" > .idea/workspace.xml  # NOT in .gitignore

  PROJECT_ROOT="$TEST_TMPDIR"

  local exit_code=0
  (
    set -euo pipefail
    trap 'exit 1' ERR
    _stage_changed_files ".idea/workspace.xml"
  ) || exit_code=$?

  # The only contract here is: pipeline must not crash (exit 0)
  _assert_eq ".idea does not crash pipeline" "0" "$exit_code"

  # Separate scenario: when .idea IS gitignored, it should not be staged
  echo ".idea/" >> .gitignore
  git add .gitignore && git commit -q -m "add gitignore"
  git reset HEAD .idea/workspace.xml 2>/dev/null || true  # unstage if staged above

  _stage_changed_files ".idea/workspace.xml"
  local staged
  staged=$(git diff --cached --name-only 2>/dev/null || echo "")
  _assert_not_contains ".idea not staged when gitignored" "$staged" ".idea"

  _teardown_tmp
}

test_4_auto_claude_artifacts_filtered() {
  echo "Test 4: .auto_claude* runtime files filtered before staging"
  _setup_tmp
  cd "$TEST_TMPDIR"
  git init -q
  git config user.email "test@test.com" && git config user.name "Test"
  git commit -q --allow-empty -m "init"
  echo "{}" > .auto_claude_state.json
  echo "real change" > app.ts

  PROJECT_ROOT="$TEST_TMPDIR"
  _stage_changed_files ".auto_claude_state.json
app.ts"

  local staged
  staged=$(git diff --cached --name-only)
  _assert_not_contains "state file not staged" "$staged" ".auto_claude_state"
  _assert_contains "app.ts staged" "$staged" "app.ts"
  _teardown_tmp
}

test_5_nonexistent_file_skipped() {
  echo "Test 5: File in changed list but not on disk is safely skipped"
  _setup_tmp
  cd "$TEST_TMPDIR"
  git init -q
  git config user.email "test@test.com" && git config user.name "Test"
  git commit -q --allow-empty -m "init"

  PROJECT_ROOT="$TEST_TMPDIR"

  local exit_code=0
  (
    set -euo pipefail
    trap 'exit 1' ERR
    _stage_changed_files "ghost/does/not/exist.ts"
  ) || exit_code=$?

  _assert_eq "missing file does not crash" "0" "$exit_code"
  _teardown_tmp
}

# ─── Run ──────────────────────────────────────────────────────────────────────

echo "=== auto_claude phase_final staging tests ==="
echo ""
test_1_ignored_file_not_staged; echo ""
test_2_normal_file_gets_staged; echo ""
test_3_idea_dir_does_not_crash_pipeline; echo ""
test_4_auto_claude_artifacts_filtered; echo ""
test_5_nonexistent_file_skipped

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ $FAIL -gt 0 ] && exit 1 || exit 0

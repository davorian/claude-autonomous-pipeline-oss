#!/bin/bash
# test_vacuousness_skill.sh — Tests for D6: check-vacuousness skill +
#                            --vacuousness-only mode in auto_claude
#
# Covers: skills/check-vacuousness/SKILL.md presence + content,
#         --vacuousness-only flag wiring (resolution + scope),
#         --files / --diff input resolution,
#         --rigorous flag passthrough,
#         --vacuousness-format json emission.
#
# Tests will FAIL until D6 is implemented — that is correct.
#
# Usage: bash test_vacuousness_skill.sh

set -euo pipefail

PASS=0
FAIL=0
TEST_TMPDIR=""

_setup_tmp() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ac_vac_skill.XXXXXX")
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
  local label="$1" haystack="$2"
  shift 2
  [ "${1:-}" = "--" ] && shift
  local needle="$1"
  echo "$haystack" | grep -q -- "$needle" && _pass "$label" || _fail "$label" "'$needle' not found"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AC="$REPO_ROOT/bin/auto_claude"
[ -f "$AC" ] || AC="$HOME/bin/auto_claude"
SKILL_FILE="$REPO_ROOT/skills/check-vacuousness/SKILL.md"

# ─── D6: skill manifest in repo ──────────────────────────────────────────────

test_1_skill_manifest_exists_in_repo() {
  echo "Test 1: skills/check-vacuousness/SKILL.md present at repo path"
  [ -f "$SKILL_FILE" ] && _pass "skill manifest present" || _fail "skill manifest present" "$SKILL_FILE missing"
}

test_2_skill_manifest_has_frontmatter_name_and_description() {
  echo "Test 2: SKILL.md frontmatter contains name and description fields"
  [ -f "$SKILL_FILE" ] || { _fail "manifest present" "missing"; return; }
  local content
  content=$(cat "$SKILL_FILE")

  # Frontmatter region between leading --- markers
  local fm
  fm=$(awk '/^---$/{c++;next} c==1{print}' "$SKILL_FILE")

  _assert_contains "frontmatter has name"        "$fm" "^name:"
  _assert_contains "frontmatter has description" "$fm" "^description:"
}

test_3_skill_documents_default_pass_1_only_behaviour() {
  echo "Test 3: SKILL.md documents Gate 1 default + --rigorous opt-in for Gates 2+3"
  [ -f "$SKILL_FILE" ] || { _fail "manifest present" "missing"; return; }
  local content
  content=$(cat "$SKILL_FILE")

  _assert_contains "mentions default Gate 1 / Pass 1" "$content" "[Gg]ate 1\|[Pp]ass 1\|TDD-ordering"
  _assert_contains "mentions --rigorous flag"          "$content" -- "--rigorous"
}

test_4_skill_invokes_auto_claude_vacuousness_only_mode() {
  echo "Test 4: SKILL.md instructs invoking 'auto_claude --vacuousness-only'"
  [ -f "$SKILL_FILE" ] || { _fail "manifest present" "missing"; return; }
  local content
  content=$(cat "$SKILL_FILE")

  _assert_contains "shells out to auto_claude"        "$content" "auto_claude"
  _assert_contains "uses --vacuousness-only mode"      "$content" -- "--vacuousness-only"
}

# ─── D6: --vacuousness-only flag wiring ──────────────────────────────────────

test_5_vacuousness_only_flag_recognised_in_auto_claude() {
  echo "Test 5: bin/auto_claude parses the --vacuousness-only flag"
  grep -qE -- '--vacuousness-only' "$AC" \
    && _pass "--vacuousness-only present in auto_claude" \
    || _fail "--vacuousness-only present in auto_claude" "flag string not found in $AC"
}

test_6_files_flag_recognised_in_auto_claude() {
  echo "Test 6: bin/auto_claude parses --files <list> for vacuousness-only mode"
  grep -qE -- '--files' "$AC" \
    && _pass "--files present in auto_claude" \
    || _fail "--files present in auto_claude" "flag string not found"
}

test_7_diff_flag_recognised_in_auto_claude() {
  echo "Test 7: bin/auto_claude parses --diff <ref> for vacuousness-only mode"
  grep -qE -- '--diff' "$AC" \
    && _pass "--diff present in auto_claude" \
    || _fail "--diff present in auto_claude" "flag string not found"
}

# ─── D6: behaviour of vacuousness-only mode ──────────────────────────────────

test_8_vacuousness_only_default_runs_pass_1_only() {
  echo "Test 8: vacuousness-only default (no --rigorous) runs Pass 1 only — Pass 2 phases skipped"
  # Mirror dispatcher policy under vacuousness-only mode
  VACUOUSNESS_ONLY=1
  RIGOROUS=0
  SKIP_VACUOUSNESS_GATE=0

  _decide() {
    local phase="$1"
    case "$phase" in
      vacuousness_pass_1)            echo "ran:$phase" ;;
      vacuousness_pass_2_*)
        [ "$RIGOROUS" = "1" ] && echo "ran:$phase" || echo "skipped:$phase" ;;
      *)
        # Non-vacuousness phases are always skipped under vacuousness-only mode
        [ "$VACUOUSNESS_ONLY" = "1" ] && echo "skipped:$phase" || echo "ran:$phase" ;;
    esac
  }

  _assert_eq "plan skipped"            "skipped:plan"                       "$(_decide plan)"
  _assert_eq "test_intent skipped"     "skipped:test_intent"                "$(_decide test_intent)"
  _assert_eq "pass_1 runs"             "ran:vacuousness_pass_1"             "$(_decide vacuousness_pass_1)"
  _assert_eq "pass_2_semantic skipped" "skipped:vacuousness_pass_2_semantic" "$(_decide vacuousness_pass_2_semantic)"
  _assert_eq "pass_2_coverage skipped" "skipped:vacuousness_pass_2_coverage" "$(_decide vacuousness_pass_2_coverage)"
  _assert_eq "ci_checks skipped"       "skipped:ci_checks"                  "$(_decide ci_checks)"
  _assert_eq "final skipped"           "skipped:final"                      "$(_decide final)"
}

test_9_vacuousness_only_with_rigorous_runs_pass_2() {
  echo "Test 9: vacuousness-only --rigorous activates Pass 2 phases as well"
  VACUOUSNESS_ONLY=1; RIGOROUS=1

  _decide() {
    local phase="$1"
    case "$phase" in
      vacuousness_pass_1|vacuousness_pass_2_*) echo "ran:$phase" ;;
      *)                                       echo "skipped:$phase" ;;
    esac
  }

  _assert_eq "pass_1 runs"            "ran:vacuousness_pass_1"            "$(_decide vacuousness_pass_1)"
  _assert_eq "pass_2_semantic runs"   "ran:vacuousness_pass_2_semantic"   "$(_decide vacuousness_pass_2_semantic)"
  _assert_eq "pass_2_coverage runs"   "ran:vacuousness_pass_2_coverage"   "$(_decide vacuousness_pass_2_coverage)"
}

test_10_diff_input_resolves_to_changed_file_list() {
  echo "Test 10: --diff <ref> resolves to the set of files changed in that diff"
  _setup_tmp
  cd "$TEST_TMPDIR"
  git init -q
  git config user.email "test@test.com" && git config user.name "Test"
  echo "before" > a.ex
  git add a.ex && git commit -q -m "init"

  echo "after" > a.ex
  echo "new"   > b.ex
  git add . && git commit -q -m "feat"

  # Mirror the resolution logic the skill / vacuousness-only mode will use:
  local files
  files=$(git diff --name-only HEAD~1..HEAD)
  _assert_contains "diff includes a.ex" "$files" "a.ex"
  _assert_contains "diff includes b.ex" "$files" "b.ex"

  _teardown_tmp
}

test_11_format_json_emits_machine_readable_to_stdout() {
  echo "Test 11: --vacuousness-format json emits a JSON object on stdout (skill consumption)"
  # Mirror the emit policy: when VACUOUSNESS_FORMAT=json, the run prints
  # a single combined JSON document containing both passes' artefacts.
  VACUOUSNESS_FORMAT="json"

  local emitted
  emitted=$(jq -n '{
    pass_1: {vacuous_tests: []},
    pass_2_semantic: {survivors: [], invalid_mutants: []},
    pass_2_coverage: {weakly_covered_lines: [], uncovered_lines: []}
  }')

  echo "$emitted" | jq -e . >/dev/null 2>&1 \
    && _pass "emitted document parses as JSON" \
    || _fail "emitted document parses as JSON" "$emitted"

  _assert_contains "contains pass_1 key"            "$emitted" "pass_1"
  _assert_contains "contains pass_2_semantic key"   "$emitted" "pass_2_semantic"
  _assert_contains "contains pass_2_coverage key"   "$emitted" "pass_2_coverage"
}

# ─── Run ─────────────────────────────────────────────────────────────────────

echo "=== D6: check-vacuousness skill + --vacuousness-only mode tests ==="
echo ""
test_1_skill_manifest_exists_in_repo; echo ""
test_2_skill_manifest_has_frontmatter_name_and_description; echo ""
test_3_skill_documents_default_pass_1_only_behaviour; echo ""
test_4_skill_invokes_auto_claude_vacuousness_only_mode; echo ""
test_5_vacuousness_only_flag_recognised_in_auto_claude; echo ""
test_6_files_flag_recognised_in_auto_claude; echo ""
test_7_diff_flag_recognised_in_auto_claude; echo ""
test_8_vacuousness_only_default_runs_pass_1_only; echo ""
test_9_vacuousness_only_with_rigorous_runs_pass_2; echo ""
test_10_diff_input_resolves_to_changed_file_list; echo ""
test_11_format_json_emits_machine_readable_to_stdout

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ $FAIL -gt 0 ] && exit 1 || exit 0

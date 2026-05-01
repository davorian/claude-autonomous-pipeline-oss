#!/bin/bash
# test_vacuousness_taxonomy.sh — Tests for D1: mutation taxonomy + bash loader
#
# Covers: docs/vacuousness_taxonomy.md content + _load_vacuousness_taxonomy helper
#         in bin/auto_claude.
#
# Tests will FAIL until D1 is implemented — that is correct.
#
# Usage: bash test_vacuousness_taxonomy.sh

set -euo pipefail

PASS=0
FAIL=0
TEST_TMPDIR=""

_setup_tmp() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ac_vacuous_taxo.XXXXXX")
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
TAXONOMY_FILE="$REPO_ROOT/docs/vacuousness_taxonomy.md"

_source_taxonomy_loader() {
  log() { :; }
  warn() { :; }
  eval "$(awk '/^_load_vacuousness_taxonomy[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"
}

# ─── D1: Taxonomy file content ───────────────────────────────────────────────

test_1_taxonomy_file_exists_in_repo() {
  echo "Test 1: docs/vacuousness_taxonomy.md exists at repo root"
  [ -f "$TAXONOMY_FILE" ] && _pass "taxonomy file present" || _fail "taxonomy file present" "missing: $TAXONOMY_FILE"
}

test_2_taxonomy_contains_all_eight_categories() {
  echo "Test 2: taxonomy lists all eight required mutation categories"
  [ -f "$TAXONOMY_FILE" ] || { _fail "taxonomy file present" "missing"; return; }
  local content
  content=$(cat "$TAXONOMY_FILE")

  for cat in no_op_body drop_side_effect drop_filter swap_query_subject swap_column invert_boolean skip_iteration constant_return; do
    _assert_contains "category present: $cat" "$content" "$cat"
  done
}

test_3_taxonomy_excludes_random_byte_mutations() {
  echo "Test 3: taxonomy explicitly excludes operator-level / random mutations"
  [ -f "$TAXONOMY_FILE" ] || { _fail "taxonomy file present" "missing"; return; }
  local content
  content=$(cat "$TAXONOMY_FILE")

  _assert_contains "out-of-taxonomy section present" "$content" "Out of taxonomy"
  _assert_contains "operator-level explicitly excluded" "$content" "[Oo]perator-level"
}

test_4_taxonomy_documents_json_record_schema() {
  echo "Test 4: taxonomy file documents the Mutation JSON record schema"
  [ -f "$TAXONOMY_FILE" ] || { _fail "taxonomy file present" "missing"; return; }
  local content
  content=$(cat "$TAXONOMY_FILE")

  for field in category file line original mutated provenance; do
    _assert_contains "schema field: $field" "$content" "$field"
  done
}

test_5_taxonomy_json_example_is_valid_json() {
  echo "Test 5: at least one fenced JSON example in the taxonomy parses with jq"
  [ -f "$TAXONOMY_FILE" ] || { _fail "taxonomy file present" "missing"; return; }

  local extracted
  extracted=$(awk '/^```json/{flag=1;next}/^```/{flag=0}flag' "$TAXONOMY_FILE" | head -200)
  [ -n "$extracted" ] || { _fail "fenced JSON block exists" 'no ```json fences found'; return; }

  echo "$extracted" | jq -e . >/dev/null 2>&1 \
    && _pass "fenced JSON example parses" \
    || _fail "fenced JSON example parses" "jq rejected the example"
}

# ─── D1: Bash loader ─────────────────────────────────────────────────────────

test_6_loader_returns_non_empty_when_file_present() {
  echo "Test 6: _load_vacuousness_taxonomy returns non-empty content when file is present"
  _source_taxonomy_loader

  if ! declare -F _load_vacuousness_taxonomy >/dev/null 2>&1; then
    _fail "loader function defined" "_load_vacuousness_taxonomy not found in $AC"
    return
  fi

  PROJECT_ROOT="$REPO_ROOT"
  local out
  out=$(_load_vacuousness_taxonomy 2>/dev/null || true)

  [ -n "$out" ] && _pass "loader returns non-empty output" || _fail "loader returns non-empty output" "empty"
}

test_7_loader_falls_back_with_warning_when_file_missing() {
  echo "Test 7: loader emits a non-fatal warning + fallback when taxonomy file is missing"
  _source_taxonomy_loader
  declare -F _load_vacuousness_taxonomy >/dev/null 2>&1 || { _fail "loader defined" "missing"; return; }

  _setup_tmp
  PROJECT_ROOT="$TEST_TMPDIR"
  VACUOUSNESS_TAXONOMY_PATH="$TEST_TMPDIR/missing.md"

  local out exit_code=0
  out=$(_load_vacuousness_taxonomy 2>&1) || exit_code=$?

  _assert_eq "loader does not hard-fail when file missing" "0" "$exit_code"
  # Output must mention either fallback or warning
  echo "$out" | grep -qiE 'fallback|warn|missing' && _pass "loader signals fallback/warning" || _fail "loader signals fallback/warning" "$out"

  _teardown_tmp
}

test_8_loader_caches_after_first_read() {
  echo "Test 8: loader caches taxonomy contents — second call hits cache, not the file"
  _source_taxonomy_loader
  declare -F _load_vacuousness_taxonomy >/dev/null 2>&1 || { _fail "loader defined" "missing"; return; }

  _setup_tmp
  local fake_file="$TEST_TMPDIR/taxonomy.md"
  printf '%s\n' "ORIGINAL" > "$fake_file"

  PROJECT_ROOT="$TEST_TMPDIR"
  VACUOUSNESS_TAXONOMY_PATH="$fake_file"
  unset _VACUOUSNESS_TAXONOMY_CACHE 2>/dev/null || true

  local first second
  first=$(_load_vacuousness_taxonomy 2>/dev/null)
  printf '%s\n' "MUTATED" > "$fake_file"
  second=$(_load_vacuousness_taxonomy 2>/dev/null)

  _assert_eq "second call returns cached (ORIGINAL) content despite file change" "$first" "$second"

  _teardown_tmp
}

test_9_loader_no_bash_4_features() {
  echo "Test 9: loader implementation contains no bash-4-only features"
  declare -F _load_vacuousness_taxonomy >/dev/null 2>&1 || _source_taxonomy_loader
  declare -F _load_vacuousness_taxonomy >/dev/null 2>&1 || { _fail "loader defined" "missing"; return; }

  local body
  body=$(declare -f _load_vacuousness_taxonomy)

  _assert_not_contains "no declare -A" "$body" "declare -A"
  _assert_not_contains "no mapfile" "$body" "mapfile"
  _assert_not_contains "no readarray" "$body" "readarray"
}

# ─── Run ─────────────────────────────────────────────────────────────────────

echo "=== D1: vacuousness taxonomy tests ==="
echo ""
test_1_taxonomy_file_exists_in_repo; echo ""
test_2_taxonomy_contains_all_eight_categories; echo ""
test_3_taxonomy_excludes_random_byte_mutations; echo ""
test_4_taxonomy_documents_json_record_schema; echo ""
test_5_taxonomy_json_example_is_valid_json; echo ""
test_6_loader_returns_non_empty_when_file_present; echo ""
test_7_loader_falls_back_with_warning_when_file_missing; echo ""
test_8_loader_caches_after_first_read; echo ""
test_9_loader_no_bash_4_features

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ $FAIL -gt 0 ] && exit 1 || exit 0

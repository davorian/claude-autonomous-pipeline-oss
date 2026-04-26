#!/bin/bash
# test_sme_ab_score.sh — Tests for sme-ab-score (manual scoring).
#
# Usage: bash test_sme_ab_score.sh

set -euo pipefail
PASS=0; FAIL=0; TEST_TMPDIR=""
SCRIPT_DIR="$(cd "$(dirname "$0")/../bin" && pwd)"
SCORE="$SCRIPT_DIR/sme-ab-score"

_setup() { TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/sme_score_test.XXXXXX"); }
_teardown() { [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"; TEST_TMPDIR=""; }
_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "        $2"; }

echo "=== sme-ab-score ==="

# 1. Append a row, well-formed
_setup
"$SCORE" --run-id abc-123 --score 4 --note "minor cleanup" \
  --out "$TEST_TMPDIR/scores.jsonl" >/dev/null 2>&1
[ -f "$TEST_TMPDIR/scores.jsonl" ] && _pass "scores.jsonl created" || _fail "scores.jsonl created"
last=$(tail -n1 "$TEST_TMPDIR/scores.jsonl")
[ "$(echo "$last" | jq -r .run_id)" = "abc-123" ] && _pass "run_id stored" || _fail "run_id stored"
[ "$(echo "$last" | jq -r .score)" = "4" ] && _pass "score stored as int" || _fail "score stored as int"
[ "$(echo "$last" | jq -r .score_source)" = "manual" ] && _pass "source=manual" || _fail "source=manual"
[ "$(echo "$last" | jq -r .note)" = "minor cleanup" ] && _pass "note stored" || _fail "note stored"
_teardown

# 2. Reject score outside 1..5
_setup
"$SCORE" --run-id x --score 0 --out "$TEST_TMPDIR/s.jsonl" 2>/tmp/err.log \
  && _fail "rejects score=0" || _pass "rejects score=0"
"$SCORE" --run-id x --score 6 --out "$TEST_TMPDIR/s.jsonl" 2>/tmp/err.log \
  && _fail "rejects score=6" || _pass "rejects score=6"
"$SCORE" --run-id x --score abc --out "$TEST_TMPDIR/s.jsonl" 2>/tmp/err.log \
  && _fail "rejects non-integer" || _pass "rejects non-integer"
_teardown

# 3. Multiple appends — append-only, no overwrite
_setup
"$SCORE" --run-id A --score 3 --out "$TEST_TMPDIR/s.jsonl" >/dev/null 2>&1
"$SCORE" --run-id A --score 4 --note "revised" --out "$TEST_TMPDIR/s.jsonl" >/dev/null 2>&1
"$SCORE" --run-id B --score 5 --out "$TEST_TMPDIR/s.jsonl" >/dev/null 2>&1
n=$(wc -l < "$TEST_TMPDIR/s.jsonl" | tr -d ' ')
[ "$n" = "3" ] && _pass "three rows kept (append-only)" || _fail "three rows kept" "got $n"
# Latest score for run-id A should be the most recent (4 with revised note)
latest_a=$(grep '"run_id":"A"' "$TEST_TMPDIR/s.jsonl" | tail -n1 | jq -r .score)
[ "$latest_a" = "4" ] && _pass "latest row wins on read" || _fail "latest row wins" "$latest_a"
_teardown

# 4. Missing required args
"$SCORE" --score 3 2>/dev/null && _fail "missing --run-id" || _pass "rejects missing --run-id"
"$SCORE" --run-id x 2>/dev/null && _fail "missing --score" || _pass "rejects missing --score"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

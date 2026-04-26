#!/bin/bash
# test_sme_ab_report.sh — Tests for sme-ab-report aggregator.
#
# Usage: bash test_sme_ab_report.sh

set -euo pipefail

PASS=0
FAIL=0
TEST_TMPDIR=""
SCRIPT_DIR="$(cd "$(dirname "$0")/../bin" && pwd)"
SME_REPORT="$SCRIPT_DIR/sme-ab-report"

_setup() { TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/sme_report_test.XXXXXX"); }
_teardown() { [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"; TEST_TMPDIR=""; }
_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "        $2"; }

_assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  echo "$haystack" | grep -qF -- "$needle" \
    && _pass "$label" \
    || _fail "$label" "needle not found: '$needle' in: $haystack"
}
_assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  echo "$haystack" | grep -qF -- "$needle" \
    && _fail "$label" "unexpected: $needle" \
    || _pass "$label"
}

_emit_row() {
  local out="$1" task="$2" mode="$3" outcome="$4" duration="$5" added="${6:-0}" preamble="${7:-0}"
  local run_id="${8:-r-$RANDOM-$RANDOM}" pair_id="${9:-}" source="${10:-manual}"
  jq -nc \
    --arg run_id "$run_id" --arg pair_id "$pair_id" \
    --arg task "$task" --arg mode "$mode" --arg outcome "$outcome" \
    --arg duration "$duration" --arg added "$added" --arg preamble "$preamble" \
    --arg source "$source" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      run_id: $run_id, spec: "x", repo_id: "acme__widget",
      task_type: $task, task_type_source: $source, task_type_rationale: "test",
      sme_mode: $mode,
      pair_id: (if $pair_id == "" then null else $pair_id end),
      started_at: $ts, finished_at: $ts,
      duration_seconds: ($duration | tonumber), outcome: $outcome,
      exit_code: (if $outcome == "success" then 0 else 1 end),
      phases_completed: 13,
      git_diff_added: ($added | tonumber), git_diff_removed: 5,
      baseline_sha: "x", final_sha: "y",
      preamble_size_chars: ($preamble | tonumber),
      worktree_path: "x",
      review_score: null
    }' >> "$out"
}

_emit_score() {
  local out="$1" run_id="$2" score="$3"
  jq -nc \
    --arg run_id "$run_id" --arg score "$score" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{run_id: $run_id, score: ($score | tonumber), score_source: "manual", scored_at: $ts, note: null, pr_number: null}' \
    >> "$out"
}

echo "=== sme-ab-report ==="

# 1. Empty runs.jsonl prints "no data"
_setup
out=$("$SME_REPORT" --in "$TEST_TMPDIR/empty.jsonl")
_assert_contains "empty file: 'no data'" "$out" "no data"
_teardown

# 2. Five runs across 2 task_types — sensible aggregate
_setup
RUNS="$TEST_TMPDIR/runs.jsonl"
touch "$RUNS"
_emit_row "$RUNS" feature off success 100 50  0
_emit_row "$RUNS" feature on  success  90 50 200
_emit_row "$RUNS" feature on  success  85 60 250
_emit_row "$RUNS" bugfix  off success  30 10  0
_emit_row "$RUNS" bugfix  on  success  35 10 100
out=$("$SME_REPORT" --in "$RUNS")
_assert_contains "lists feature task_type"      "$out" "task_type: feature"
_assert_contains "lists bugfix task_type"       "$out" "task_type: bugfix"
_assert_contains "shows total run count (5)"    "$out" "5 run(s)"
_assert_contains "feature: SME-on=2"            "$out" "SME-on=2"
_assert_contains "feature: SME-off=1"           "$out" "SME-off=1"
_assert_contains "metric column"                "$out" "metric"
_teardown

# 3. SME-on faster on duration → negative delta
_setup
RUNS="$TEST_TMPDIR/runs.jsonl"
touch "$RUNS"
_emit_row "$RUNS" feature off success 200 50  0
_emit_row "$RUNS" feature on  success 100 50 200
out=$("$SME_REPORT" --in "$RUNS")
# Mean duration: on=100 off=200 → delta = (100-200)/200 = -50%
_assert_contains "negative delta when SME-on faster" "$out" "-50.0%"
_teardown

# 4. SME-on slower → positive delta + flag
_setup
RUNS="$TEST_TMPDIR/runs.jsonl"
touch "$RUNS"
_emit_row "$RUNS" feature off success 100 50   0
_emit_row "$RUNS" feature on  success 200 50 200
out=$("$SME_REPORT" --in "$RUNS")
# Mean duration: on=200 off=100 → delta = +100% — flagged
_assert_contains "positive delta when SME-on slower" "$out" "+100.0%"
_assert_contains "flag for slower SME-on"            "$out" "duration > 10% slower"
_teardown

# 5. SME-on lower success rate → flag
_setup
RUNS="$TEST_TMPDIR/runs.jsonl"
touch "$RUNS"
_emit_row "$RUNS" feature off success 100 50   0
_emit_row "$RUNS" feature off success 100 50   0
_emit_row "$RUNS" feature on  failed  100 50 200
_emit_row "$RUNS" feature on  failed  100 50 200
out=$("$SME_REPORT" --in "$RUNS")
_assert_contains "flag for lower success rate" "$out" "success rate"
_teardown

# 6. --task-type filter restricts output
_setup
RUNS="$TEST_TMPDIR/runs.jsonl"
touch "$RUNS"
_emit_row "$RUNS" feature off success 100 50  0
_emit_row "$RUNS" bugfix  off success  30 10  0
out=$("$SME_REPORT" --in "$RUNS" --task-type feature)
_assert_contains     "filter shows requested task" "$out" "task_type: feature"
_assert_not_contains "filter excludes other task"  "$out" "task_type: bugfix"
_teardown

# 7. Single-mode data — section says comparison-needs-both
_setup
RUNS="$TEST_TMPDIR/runs.jsonl"
touch "$RUNS"
_emit_row "$RUNS" feature off success 100 50  0
out=$("$SME_REPORT" --in "$RUNS")
_assert_contains "single-mode message" "$out" "need ≥1 run in each mode"
_teardown

# 8. Score join: latest score per run_id is reflected in the row aggregate
_setup
RUNS="$TEST_TMPDIR/runs.jsonl"
SCORES="$TEST_TMPDIR/scores.jsonl"
touch "$RUNS" "$SCORES"
_emit_row "$RUNS" feature off success 100 50 0   r-off-1
_emit_row "$RUNS" feature on  success 90  50 200 r-on-1
_emit_score "$SCORES" r-off-1 3
_emit_score "$SCORES" r-on-1 5
out=$("$SME_REPORT" --in "$RUNS" --scores "$SCORES")
_assert_contains "score row in output"   "$out" "review_score"
_assert_contains "scored_count surfaced" "$out" "2 scored"
_teardown

# 9. Latest-score-wins on multiple appends for same run_id
_setup
RUNS="$TEST_TMPDIR/runs.jsonl"
SCORES="$TEST_TMPDIR/scores.jsonl"
touch "$RUNS" "$SCORES"
_emit_row "$RUNS" feature off success 100 50 0 r-A
_emit_row "$RUNS" feature on  success 90  50 200 r-B
_emit_score "$SCORES" r-A 1
sleep 1
_emit_score "$SCORES" r-A 5     # later append for the same run wins
_emit_score "$SCORES" r-B 4
out=$("$SME_REPORT" --in "$RUNS" --scores "$SCORES")
# Off side has score=5 (latest of two for r-A), On side has 4
_assert_contains "off mean reflects latest score" "$out" "5.0 (1-5)"
_teardown

# 10. Paired-runs section shows up when pair_id is set
_setup
RUNS="$TEST_TMPDIR/runs.jsonl"
touch "$RUNS"
PAIR=p-1
_emit_row "$RUNS" feature off success 100 50 0   r-pair-off "$PAIR"
_emit_row "$RUNS" feature on  success 90  50 200 r-pair-on  "$PAIR"
out=$("$SME_REPORT" --in "$RUNS")
_assert_contains "paired section header" "$out" "## paired-runs"
_assert_contains "1 pair counted"        "$out" "(1 pairs)"
_assert_contains "SME-on faster on duration" "$out" "SME-on faster on duration:    1/1"
_teardown

# 11. --paired-only suppresses per-task-type aggregate
_setup
RUNS="$TEST_TMPDIR/runs.jsonl"
touch "$RUNS"
_emit_row "$RUNS" feature off success 100 50 0   r-pair-off p-1
_emit_row "$RUNS" feature on  success 90  50 200 r-pair-on  p-1
out=$("$SME_REPORT" --in "$RUNS" --paired-only)
echo "$out" | grep -q "task_type: feature" \
  && _fail "--paired-only suppresses task_type sections" "task_type section still shown" \
  || _pass "--paired-only suppresses task_type sections"
_assert_contains "paired section still shown" "$out" "## paired-runs"
_teardown

# 12. --classifier-audit shows source breakdown
_setup
RUNS="$TEST_TMPDIR/runs.jsonl"
touch "$RUNS"
_emit_row "$RUNS" feature off success 100 50 0 r-1 "" auto
_emit_row "$RUNS" feature on  success 90  50 200 r-2 "" auto
_emit_row "$RUNS" bugfix  off success 100 50 0 r-3 "" manual
_emit_row "$RUNS" bugfix  on  success 90  50 200 r-4 "" manual-override
out=$("$SME_REPORT" --in "$RUNS" --classifier-audit)
_assert_contains "audit header"          "$out" "## classifier audit"
_assert_contains "auto count"            "$out" "auto"
_assert_contains "manual count"          "$out" "manual"
_assert_contains "manual-override count" "$out" "manual-override"
_assert_contains "override target shown" "$out" "→ bugfix"
_teardown

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

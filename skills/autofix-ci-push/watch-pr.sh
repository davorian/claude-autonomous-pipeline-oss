#!/usr/bin/env bash
# watch-pr.sh — background watcher for the autofix-ci-push skill.
#
# Polls a PR's CI (aggregated across ALL checks), its UNRESOLVED review/bot
# threads, and its review decision. Exits (printing what changed) as soon as
# there is something worth acting on:
#   - CI resolves (any check pending -> every check terminal: pass or fail), or
#   - a NEW unresolved review/bot thread appears (Bugbot finding, human comment), or
#   - the review decision changes (APPROVED / CHANGES_REQUESTED).
#
# Check-name AGNOSTIC: aggregates every check's `bucket` rather than watching one
# named check, so it works across repos and CI providers (CircleCI's `build`, a
# GitHub Actions `ci` job, etc.) and survives checks being added/renamed.
#
# Designed for run_in_background. On exit the harness re-invokes Claude, which
# runs the skill's categorise -> fix -> surface -> reply/resolve flow on whatever
# changed, then re-arms this watcher. Silent (stderr only) until something changes.
#
# Usage: watch-pr.sh <pr> <owner/repo> [poll_seconds] [max_polls]
#   defaults: poll_seconds=60, max_polls=40 (~40 min ceiling).

set -uo pipefail
PR="${1:?pr number required}"
REPO="${2:?owner/repo required}"
POLL="${3:-60}"
MAX="${4:-40}"
OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

# Aggregate CI state across ALL checks (check-name agnostic):
#   pending - no checks yet, or any check still pending/in-progress
#   fail    - all checks terminal AND at least one failed/cancelled
#   pass    - all checks terminal and none failed (skipped/neutral is fine)
ci_state() {
  gh pr checks "$PR" --repo "$REPO" --json bucket --jq '
    [.[].bucket] as $b
    | if (($b | length) == 0) then "pending"
      elif ($b | map(. == "pending") | any) then "pending"
      elif ($b | map(. == "fail" or . == "cancel") | any) then "fail"
      else "pass" end' 2>/dev/null
}
unresolved_threads() {
  gh api graphql -f query='
    { repository(owner: "'"$OWNER"'", name: "'"$NAME"'") {
        pullRequest(number: '"$PR"') {
          reviewThreads(first: 100) { nodes { id isResolved } } } } }' \
    --jq '[.data.repository.pullRequest.reviewThreads.nodes[]
           | select(.isResolved==false) | .id] | sort | join(",")' 2>/dev/null
}
review_decision() {
  gh pr view "$PR" --repo "$REPO" --json reviewDecision --jq '.reviewDecision // ""' 2>/dev/null
}

BASE_CI=$(ci_state); BASE_THREADS=$(unresolved_threads); BASE_DECISION=$(review_decision)
echo "[watch-pr] #$PR baseline: ci='${BASE_CI:-?}' decision='${BASE_DECISION:-}' unresolved=[${BASE_THREADS}]" >&2

has_new_thread() {  # any id in $2 (now) that is not in $1 (baseline)
  local base="$1" now="$2" id
  IFS=',' read -ra ids <<< "$now"
  for id in "${ids[@]}"; do
    [ -z "$id" ] && continue
    case ",$base," in *",$id,"*) : ;; *) return 0 ;; esac
  done
  return 1
}

for ((i=1; i<=MAX; i++)); do
  sleep "$POLL"
  CUR_CI=$(ci_state); CUR_THREADS=$(unresolved_threads); CUR_DECISION=$(review_decision)

  REASON=""
  # CI resolved (left pending for a terminal pass/fail).
  if [ "$CUR_CI" != "$BASE_CI" ] && [ -n "$CUR_CI" ] && [ "$CUR_CI" != "pending" ]; then
    REASON="ci:${BASE_CI:-?}->${CUR_CI}"
  fi
  # New unresolved thread (Bugbot / human review comment).
  if has_new_thread "$BASE_THREADS" "$CUR_THREADS"; then
    REASON="${REASON:+$REASON; }new-review-thread"
  fi
  # Review decision changed.
  if [ "$CUR_DECISION" != "$BASE_DECISION" ] && [ -n "$CUR_DECISION" ]; then
    REASON="${REASON:+$REASON; }review-decision:${BASE_DECISION:-none}->${CUR_DECISION}"
  fi

  if [ -n "$REASON" ]; then
    echo "WATCH-PR FIRED (#$PR) after ~$((i*POLL))s: $REASON"
    echo "ci: ${BASE_CI:-?} -> ${CUR_CI:-?}"
    echo "decision: ${BASE_DECISION:-none} -> ${CUR_DECISION:-none}"
    echo "unresolved threads now: [${CUR_THREADS}]"
    gh pr checks "$PR" --repo "$REPO" 2>/dev/null
    exit 0
  fi
done

echo "WATCH-PR IDLE (#$PR): no actionable change after ~$((MAX*POLL/60)) min."
echo "state: ci='${BASE_CI:-?}' decision='${BASE_DECISION:-}' unresolved=[${BASE_THREADS}]"
exit 0

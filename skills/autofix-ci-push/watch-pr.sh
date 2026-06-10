#!/usr/bin/env bash
# watch-pr.sh — background watcher for the autofix-ci-push skill.
#
# Polls FIVE signals on a PR and exits the moment any becomes actionable:
#   1. CI state (aggregated across ALL checks, head-SHA agnostic)
#   2. Unresolved review/bot threads (NEW threads since baseline — inline)
#   3. Review decision (APPROVED / CHANGES_REQUESTED transitions)
#   4. Merge state (CONFLICTING / DIRTY / BEHIND / BLOCKED — UNKNOWN skipped)
#   5. New issue-level comments from non-automation authors (top-level PR
#      comments — the channel human reviewers tend to use; Bugbot
#      inline findings come through signal 2, so don't double-count)
#
# Check-name AGNOSTIC: aggregates every check's `bucket` rather than watching
# one named check, so it works across CI providers and survives renames.
#
# Automation-bot filter (configurable via $WATCH_PR_AUTOMATION_BOTS env var):
#   github-actions, supabase, dependabot, renovate, vercel, coderabbitai,
#   netlify, cloudflare-workers-and-pages, copilot-pull-request-reviewer
#   `[bot]` suffix is stripped before matching, so `github-actions[bot]` ==
#   `github-actions`.
#
# Designed for run_in_background. On exit the harness re-invokes Claude, which
# runs the autofix-ci-push skill's full sweep on whatever changed, then
# re-arms this watcher if the PR isn't yet ship-ready. Silent (stderr only)
# until something changes.
#
# Usage: watch-pr.sh <pr> <owner/repo> [poll_seconds] [max_polls]
#   defaults: poll_seconds=60, max_polls=240 (~4 h ceiling — was 40 ≈ 40 min
#             which is too short for human review cadences).
#
# Test mode: set $WATCH_PR_GH to a stub command for unit tests; defaults to `gh`.

set -uo pipefail

PR="${1:?pr number required}"
REPO="${2:?owner/repo required}"
POLL="${3:-60}"
MAX="${4:-240}"
OWNER="${REPO%%/*}"
NAME="${REPO##*/}"
GH="${WATCH_PR_GH:-gh}"

DEFAULT_BOTS="github-actions,supabase,dependabot,renovate,vercel,coderabbitai,netlify,cloudflare-workers-and-pages,copilot-pull-request-reviewer"
AUTOMATION_BOTS="${WATCH_PR_AUTOMATION_BOTS:-$DEFAULT_BOTS}"

# Aggregate CI state across ALL checks:
#   pending - no checks yet, or any check still pending/in-progress
#   fail    - all checks terminal AND at least one failed/cancelled
#   pass    - all checks terminal and none failed (skipped/neutral is fine)
ci_state() {
  "$GH" pr checks "$PR" --repo "$REPO" --json bucket --jq '
    [.[].bucket] as $b
    | if (($b | length) == 0) then "pending"
      elif ($b | map(. == "pending") | any) then "pending"
      elif ($b | map(. == "fail" or . == "cancel") | any) then "fail"
      else "pass" end' 2>/dev/null
}

unresolved_threads() {
  "$GH" api graphql -f query='
    { repository(owner: "'"$OWNER"'", name: "'"$NAME"'") {
        pullRequest(number: '"$PR"') {
          reviewThreads(first: 100) { nodes { id isResolved } } } } }' \
    --jq '[.data.repository.pullRequest.reviewThreads.nodes[]
           | select(.isResolved==false) | .id] | sort | join(",")' 2>/dev/null
}

review_decision() {
  "$GH" pr view "$PR" --repo "$REPO" --json reviewDecision --jq '.reviewDecision // ""' 2>/dev/null
}

# Merge state — returns "unknown" if GitHub hasn't computed yet (don't fire
# on UNKNOWN, wait for the next poll).
merge_state() {
  "$GH" pr view "$PR" --repo "$REPO" --json mergeable,mergeStateStatus --jq '
    .mergeable as $m | .mergeStateStatus as $s
    | if ($m == "UNKNOWN" or $s == "UNKNOWN") then "unknown"
      elif ($m == false or $s == "CONFLICTING" or $s == "DIRTY") then "conflicting"
      elif ($s == "BEHIND") then "behind"
      elif ($s == "BLOCKED") then "blocked"
      elif ($s == "CLEAN" or $s == "UNSTABLE") then "clean"
      else "other" end' 2>/dev/null
}

# Issue-level comments — returns "id|login,id|login,..." with [bot] suffix
# stripped from the login. Empty string on failure.
issue_comments() {
  "$GH" api "repos/$OWNER/$NAME/issues/$PR/comments" --jq '
    [.[] | "\(.id)|\((.user.login // "") | sub("\\[bot\\]$"; ""))"] | join(",")
  ' 2>/dev/null
}

# Is $1 (login) in the comma-separated automation bot list?
is_automation_bot() {
  local login="$1"
  case ",$AUTOMATION_BOTS," in
    *",$login,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# True iff $2 (now) contains an id|login entry whose id is not in $1 (baseline)
# AND whose login is not an automation bot.
has_new_human_comment() {
  local base="$1" now="$2" entry id login
  IFS=',' read -ra entries <<< "$now"
  for entry in ${entries[@]+"${entries[@]}"}; do
    [ -z "$entry" ] && continue
    id="${entry%%|*}"
    login="${entry##*|}"
    case ",$base," in *",$id|"*) continue ;; esac   # known id, skip
    is_automation_bot "$login" && continue          # bot, skip
    return 0  # new + human
  done
  return 1
}

has_new_thread() {  # any id in $2 (now) that is not in $1 (baseline)
  local base="$1" now="$2" id
  IFS=',' read -ra ids <<< "$now"
  for id in ${ids[@]+"${ids[@]}"}; do
    [ -z "$id" ] && continue
    case ",$base," in *",$id,"*) : ;; *) return 0 ;; esac
  done
  return 1
}

BASE_CI=$(ci_state)
BASE_THREADS=$(unresolved_threads)
BASE_DECISION=$(review_decision)
BASE_MERGE=$(merge_state)
BASE_COMMENTS=$(issue_comments)
echo "[watch-pr] #$PR baseline: ci='${BASE_CI:-?}' merge='${BASE_MERGE:-?}' decision='${BASE_DECISION:-}' unresolved=[${BASE_THREADS}] comments=$(echo "$BASE_COMMENTS" | awk -F, '{print NF}')" >&2

for ((i=1; i<=MAX; i++)); do
  sleep "$POLL"
  CUR_CI=$(ci_state)
  CUR_THREADS=$(unresolved_threads)
  CUR_DECISION=$(review_decision)
  CUR_MERGE=$(merge_state)
  CUR_COMMENTS=$(issue_comments)

  REASON=""
  # CI resolved (left pending for a terminal pass/fail).
  if [ "$CUR_CI" != "$BASE_CI" ] && [ -n "$CUR_CI" ] && [ "$CUR_CI" != "pending" ]; then
    REASON="ci:${BASE_CI:-?}->${CUR_CI}"
  fi
  # New unresolved inline thread (Bugbot, Cursor, Copilot inline, human inline).
  if has_new_thread "$BASE_THREADS" "$CUR_THREADS"; then
    REASON="${REASON:+$REASON; }new-review-thread"
  fi
  # Review decision changed.
  if [ "$CUR_DECISION" != "$BASE_DECISION" ] && [ -n "$CUR_DECISION" ]; then
    REASON="${REASON:+$REASON; }review-decision:${BASE_DECISION:-none}->${CUR_DECISION}"
  fi
  # Merge state changed — but skip UNKNOWN (don't fire on a not-yet-computed read).
  if [ "$CUR_MERGE" != "$BASE_MERGE" ] && [ -n "$CUR_MERGE" ] && [ "$CUR_MERGE" != "unknown" ]; then
    REASON="${REASON:+$REASON; }merge-state:${BASE_MERGE:-?}->${CUR_MERGE}"
  fi
  # New top-level comment from a non-automation author.
  if has_new_human_comment "$BASE_COMMENTS" "$CUR_COMMENTS"; then
    REASON="${REASON:+$REASON; }new-issue-comment"
  fi

  if [ -n "$REASON" ]; then
    echo "WATCH-PR FIRED (#$PR) after ~$((i*POLL))s: $REASON"
    echo "ci:       ${BASE_CI:-?} -> ${CUR_CI:-?}"
    echo "merge:    ${BASE_MERGE:-?} -> ${CUR_MERGE:-?}"
    echo "decision: ${BASE_DECISION:-none} -> ${CUR_DECISION:-none}"
    echo "unresolved threads now: [${CUR_THREADS}]"
    "$GH" pr checks "$PR" --repo "$REPO" 2>/dev/null
    exit 0
  fi
done

echo "WATCH-PR IDLE (#$PR): no actionable change after ~$((MAX*POLL/60)) min."
echo "state: ci='${BASE_CI:-?}' merge='${BASE_MERGE:-?}' decision='${BASE_DECISION:-}' unresolved=[${BASE_THREADS}]"
exit 0

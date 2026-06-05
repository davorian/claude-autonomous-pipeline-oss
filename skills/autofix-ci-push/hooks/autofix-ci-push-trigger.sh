#!/usr/bin/env bash
# autofix-ci-push-trigger.sh — PostToolUse hook on Bash (macOS / multi-repo).
#
# When a `git push` to a feature branch succeeds, this SYNCHRONOUS hook resolves
# the branch's PR + owner/repo and injects an instruction (PostToolUse
# `additionalContext`) telling Claude to ARM the autofix-ci-push watchdog now —
# a background watch-pr.sh that polls CI / reviews / threads / merge-state and
# wakes Claude the instant something is actionable.
#
# WHY SYNCHRONOUS (no `async`): async PostToolUse hooks have their stdout
# IGNORED — additionalContext only reaches the model from a synchronous hook.
# (That is exactly why the old deferred-reminder design never fired.) The hook
# still exits in microseconds for non-push Bash calls, so the gh latency is only
# paid on an actual `git push`.
#
# Also writes a queue marker: the record the watcher is armed from, and the
# fallback that autofix-ci-push-surface.sh uses to remind Claude if the watcher
# was never armed.
#
# Output schema (authoritative for current Claude Code):
#   {"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"..."}}
# exit 0 always — a hook must never break the push.

set -uo pipefail

INPUT=$(cat || true)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
TOOL_COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
TOOL_RESPONSE=$(printf '%s' "$INPUT" | jq -r '.tool_response // empty' 2>/dev/null || true)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)

# Only react to Bash git-push calls.
[ "$TOOL_NAME" != "Bash" ] && exit 0
printf '%s' "$TOOL_COMMAND" | grep -qE '(^|[[:space:]&;|])git[[:space:]]([^&;|]*[[:space:]])?push([[:space:]]|$)' || exit 0
# Ignore dry-runs / help (no real push). `--` ends grep options.
printf '%s' "$TOOL_COMMAND" | grep -qE -- '--(help|dry-run)\b' && exit 0

# Skip pushes that look like they failed.
if printf '%s' "$TOOL_RESPONSE" | grep -qiE 'rejected|fatal:|permission denied|protected branch'; then
  echo "[autofix-ci-push-trigger] push appears to have failed; not arming" >&2
  exit 0
fi

# Operate in the repo the push ran in — this is what makes the trigger repo-aware.
WORKDIR="$CWD"
{ [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; } || WORKDIR="$PWD"
cd "$WORKDIR" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

BRANCH=$(git branch --show-current 2>/dev/null || true)
[ -z "$BRANCH" ] && BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
case "$BRANCH" in
  ''|main|master|production|prod|HEAD|unknown) exit 0 ;;
esac

# Resolve owner/repo + PR# via gh (uses this repo's remote → repo-aware).
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
[ -z "$REPO" ] && exit 0
PR=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")

# Marker: watcher input + fallback record.
QUEUE_DIR="$HOME/.claude/autofix-queue"
mkdir -p "$QUEUE_DIR/processed"
TS=$(date +%s)
SAFE_BRANCH="${BRANCH//\//_}"
MARKER="$QUEUE_DIR/${TS}-${SAFE_BRANCH}.pending"
cat >"$MARKER" <<EOF
{
  "branch": "$BRANCH",
  "repo": "$REPO",
  "pr": "${PR:-}",
  "head_sha": "$HEAD_SHA",
  "pushed_at": $TS,
  "due_at": $((TS + 300)),
  "status": "pending"
}
EOF

# No PR yet → nothing to watch; surface fallback will note it on the next prompt.
if [ -z "$PR" ]; then
  echo "[autofix-ci-push-trigger] pushed '$BRANCH' to $REPO but no open PR yet; not arming" >&2
  exit 0
fi

WATCH="$HOME/.claude/skills/autofix-ci-push/watch-pr.sh"
CONTEXT="You just pushed branch '$BRANCH' -> PR #$PR ($REPO). Arm the autofix-ci-push watchdog for this push now, once: invoke the autofix-ci-push skill in watch mode for PR #$PR -- triage the current merge-readiness state (CI / merge-state / threads / reviews), then launch the watcher  $WATCH $PR $REPO  via Bash with run_in_background:true so it polls and wakes you the moment something is actionable. Arming is a single non-blocking background call -- if the user's current request is unrelated, arm first, then carry on. Auto-fix only mechanical findings using the repo's own toolchain (formatter / linter / tests); when the toolchain or a fix is uncertain, surface instead of editing. On arming, move the queue marker for branch '$BRANCH' to ~/.claude/autofix-queue/processed/ so the fallback reminder does not fire."

jq -n --arg ctx "$CONTEXT" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}'
exit 0

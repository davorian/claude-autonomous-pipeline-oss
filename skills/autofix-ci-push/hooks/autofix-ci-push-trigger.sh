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
# tool_response may be a plain string or an object {stdout,stderr}. `git push`
# writes its result ("To <remote>" / "<old>..<new>  <branch> -> <branch>") to
# STDERR, so normalise both shapes into one text blob we can parse below.
PUSH_OUT=$(printf '%s' "$INPUT" | jq -r '
  .tool_response
  | if type == "object" then ((.stdout // "") + "\n" + (.stderr // "")) else (. // "") end
' 2>/dev/null || true)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)

# Only react to Bash git-push calls.
[ "$TOOL_NAME" != "Bash" ] && exit 0
printf '%s' "$TOOL_COMMAND" | grep -qE '(^|[[:space:]&;|])git[[:space:]]([^&;|]*[[:space:]])?push([[:space:]]|$)' || exit 0
# Ignore dry-runs / help (no real push). `--` ends grep options.
printf '%s' "$TOOL_COMMAND" | grep -qE -- '--(help|dry-run)\b' && exit 0

# Skip pushes that look like they failed.
if printf '%s' "$PUSH_OUT" | grep -qiE 'rejected|fatal:|permission denied|protected branch'; then
  echo "[autofix-ci-push-trigger] push appears to have failed; not arming" >&2
  exit 0
fi

# Resolve the repo + branch ACTUALLY pushed. The session cwd (.cwd) is NOT
# reliable: a `cd other-repo && git push` runs in a different directory, so
# resolving from .cwd announced the wrong PR (this hook used to fire the same
# PR on EVERY push, whatever repo it ran in). Prefer the push OUTPUT — the
# "To <remote>" + "-> <branch>" lines git prints on success are authoritative
# regardless of cwd.
REPO=""
BRANCH=""
PUSHED_URL=$(printf '%s' "$PUSH_OUT" | grep -oE '^To .+' | tail -1 | sed -E 's#^To[[:space:]]+##')
if [ -n "$PUSHED_URL" ]; then
  # owner/repo from any remote form: git@github.com:o/r.git, host-alias:o/r.git,
  # https://github.com/o/r.git, ssh://git@host/o/r(.git) → o/r
  REPO=$(printf '%s' "$PUSHED_URL" | sed -E 's#\.git$##; s#.*[:/]([^:/]+/[^:/]+)$#\1#')
  # The pushed ref line: "<local> -> <remote>" (also "* [new branch] <l> -> <r>").
  BRANCH=$(printf '%s' "$PUSH_OUT" | grep -oE '[^[:space:]]+ -> [^[:space:]]+' | tail -1 | sed -E 's#.*-> ##')
fi

# Fallback when the output isn't parseable: the last `cd <dir>` in the command (a
# cross-repo push cds first), else .cwd; then fill any gaps via gh in that dir.
if [ -z "$REPO" ] || [ -z "$BRANCH" ]; then
  CD_TARGET=$(printf '%s' "$TOOL_COMMAND" | grep -oE 'cd[[:space:]]+[^&|;]+' | tail -1 | sed -E 's#^cd[[:space:]]+##; s#[[:space:]]+$##')
  case "$CD_TARGET" in "~"*) CD_TARGET="$HOME${CD_TARGET#\~}" ;; esac
  WORKDIR=""
  { [ -n "$CD_TARGET" ] && [ -d "$CD_TARGET" ]; } && WORKDIR="$CD_TARGET"
  { [ -z "$WORKDIR" ] && [ -n "$CWD" ] && [ -d "$CWD" ]; } && WORKDIR="$CWD"
  [ -z "$WORKDIR" ] && WORKDIR="$PWD"
  if cd "$WORKDIR" 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    [ -z "$BRANCH" ] && BRANCH=$(git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    [ -z "$REPO" ] && REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
  fi
fi

[ -z "$REPO" ] && exit 0
case "$BRANCH" in
  ''|main|master|production|prod|HEAD|unknown) exit 0 ;;
esac

# PR# for the pushed repo+branch — repo-explicit, so this no longer depends on
# the process cwd at all.
PR=$(gh pr list --repo "$REPO" --head "$BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
HEAD_SHA=$(printf '%s' "$PUSH_OUT" | grep -oE '[0-9a-f]{7,40}\.\.[0-9a-f]{7,40}' | tail -1 | sed -E 's#.*\.\.##')

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

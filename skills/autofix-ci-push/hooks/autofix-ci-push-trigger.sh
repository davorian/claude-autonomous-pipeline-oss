#!/usr/bin/env bash
# autofix-ci-push-trigger.sh — PostToolUse hook on Bash (macOS).
#
# When a `git push` Bash call succeeds, drop a queue marker under
# ~/.claude/autofix-queue/ stamped with a `due_at` 10 minutes out. The companion
# autofix-ci-push-surface.sh hook (UserPromptSubmit) ripens due markers and
# surfaces them to Claude as a <system-reminder>, which the autofix-ci-push
# skill then processes.
#
# No background process is spawned: macOS lacks `setsid`, and the surface hook
# only runs on user prompts anyway — so ripeness is computed inline from
# `due_at` rather than via a detached `sleep`. Silent on success; diagnostics
# go to stderr only.

set -euo pipefail

INPUT=$(cat || true)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
TOOL_COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
TOOL_RESPONSE=$(echo "$INPUT" | jq -r '.tool_response // empty' 2>/dev/null || true)

# Only react to Bash git-push calls.
[ "$TOOL_NAME" != "Bash" ] && exit 0
echo "$TOOL_COMMAND" | grep -qE '(^|[[:space:]&;|])git[[:space:]]([^&;|]*[[:space:]])?push([[:space:]]|$)' || exit 0
# Ignore dry-runs / help (no real push happened). `--` ends grep options so the
# pattern's leading `--` isn't parsed as a flag.
echo "$TOOL_COMMAND" | grep -qE -- '--(help|dry-run)\b' && exit 0

# Skip pushes that look like they failed (conservative — hook payload shapes vary).
if echo "$TOOL_RESPONSE" | grep -qiE 'rejected|fatal:|permission denied|protected branch'; then
  echo "[autofix-ci-push-trigger] push appears to have failed; not scheduling" >&2
  exit 0
fi

# Resolve branch: push-response line -> cd-path rev-parse -> cwd rev-parse -> unknown.
BRANCH=$( (echo "$TOOL_RESPONSE" | grep -oE '[a-f0-9]+\.\.[a-f0-9]+[[:space:]]+\S+[[:space:]]+->[[:space:]]+\S+' | head -1 | awk '{print $NF}') 2>/dev/null || true)
if [ -z "$BRANCH" ]; then
  CD_PATH=$( (echo "$TOOL_COMMAND" | grep -oE 'cd[[:space:]]+\S+' | head -1 | awk '{print $2}') 2>/dev/null || true)
  if [ -n "$CD_PATH" ] && [ -d "$CD_PATH" ]; then
    BRANCH=$(git -C "$CD_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  fi
fi
[ -z "$BRANCH" ] && BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

# Sanitize: the response parsing above can capture multi-line junk
# ("origin/master\nSwitched"), trailing newlines ("origin/main\n") or JSON
# artifacts ("...to-use\","). Keep the first line, trim leading whitespace, drop
# everything from the first non-branch character, then strip a leading remote so
# fetch refs (origin/master) collapse to the bare name and get excluded below.
BRANCH=$(printf '%s' "$BRANCH" | head -n1 | sed -E 's#^[[:space:]]+##; s#[^A-Za-z0-9._/-].*$##')
BRANCH="${BRANCH#origin/}"

# Nothing to watch for empty/default-branch pushes — PRs live on feature branches.
case "$BRANCH" in
  ''|main|master|production|prod|unknown|HEAD) exit 0 ;;
esac

QUEUE_DIR="$HOME/.claude/autofix-queue"
mkdir -p "$QUEUE_DIR/processed"

TS=$(date +%s)
SAFE_BRANCH="${BRANCH//\//_}"
PENDING="$QUEUE_DIR/${TS}-${SAFE_BRANCH}.pending"

cat >"$PENDING" <<EOF
{
  "branch": "$BRANCH",
  "pushed_at": $TS,
  "due_at": $((TS + 600)),
  "status": "pending"
}
EOF

echo "[autofix-ci-push-trigger] queued CI/bot check for '$BRANCH' (ripens in 10 min)" >&2
exit 0

#!/usr/bin/env bash
# autofix-ci-push-surface.sh — UserPromptSubmit hook (FALLBACK only).
#
# Primary delivery is now the SYNCHRONOUS trigger hook, which injects an
# "arm the watchdog" instruction immediately after a push. This hook is the
# safety net: if a push marker is still `pending` (watcher never armed) past its
# short `due_at` window (~5 min), remind Claude once, then move it to processed/
# so it fires only once.
#
# Stdout from this hook becomes additional context for Claude.

set -uo pipefail

QUEUE_DIR="$HOME/.claude/autofix-queue"
[ -d "$QUEUE_DIR" ] || exit 0
mkdir -p "$QUEUE_DIR/processed"
NOW=$(date +%s)

shopt -s nullglob
PENDING_FILES=("$QUEUE_DIR"/*.pending)
[ ${#PENDING_FILES[@]} -eq 0 ] && exit 0

for f in "${PENDING_FILES[@]}"; do
  [ -f "$f" ] || continue

  DUE_AT=$(jq -r '.due_at // 0' "$f" 2>/dev/null || echo 0)
  [ "$DUE_AT" -gt "$NOW" ] 2>/dev/null && continue   # not yet due — leave pending

  BRANCH=$(jq -r '.branch // "unknown"' "$f" 2>/dev/null || echo "unknown")
  REPO=$(jq -r '.repo // ""' "$f" 2>/dev/null || echo "")
  PR=$(jq -r '.pr // ""' "$f" 2>/dev/null || echo "")
  PUSHED_AT=$(jq -r '.pushed_at // 0' "$f" 2>/dev/null || echo 0)
  AGE_MIN=$(( (NOW - PUSHED_AT) / 60 ))

  if [ -n "$PR" ] && [ "$PR" != "null" ]; then
    TARGET="PR #$PR ($REPO)"
    ACTION="arm the autofix-ci-push watchdog for it now (invoke the skill in watch mode, which launches watch-pr.sh $PR $REPO in the background)"
  else
    TARGET="branch '$BRANCH' ($REPO) — no open PR was found at push time"
    ACTION="open a PR if that was intended, then arm the watchdog"
  fi

  cat <<EOF
<system-reminder>
AUTOFIX-CI-PUSH fallback: you pushed $TARGET about ${AGE_MIN} min ago and the watchdog was not armed. If it still isn't running, $ACTION. Per the skill's hard rules: SILENT WHEN GREEN — only report if something is actionable. Defer to the user's current priorities; arming is a single non-blocking background call.
</system-reminder>
EOF

  mv "$f" "$QUEUE_DIR/processed/" 2>/dev/null || true
done

exit 0

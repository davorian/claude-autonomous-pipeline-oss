#!/usr/bin/env bash
# autofix-ci-push-surface.sh — UserPromptSubmit hook (macOS).
#
# On every user message, scan ~/.claude/autofix-queue/ for *.pending markers
# whose `due_at` has elapsed (10-min ripening, computed inline — no background
# process needed). For each ripe marker, emit a <system-reminder> telling Claude
# to invoke the autofix-ci-push skill on the marker's branch+PR, then move the
# marker to processed/ so it fires only once.
#
# Stdout from this hook becomes additional context for Claude.

set -euo pipefail

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
  # Not ripe yet — leave it pending for a later prompt.
  [ "$DUE_AT" -gt "$NOW" ] 2>/dev/null && continue

  BRANCH=$(jq -r '.branch // "unknown"' "$f" 2>/dev/null || echo "unknown")
  PUSHED_AT=$(jq -r '.pushed_at // 0' "$f" 2>/dev/null || echo 0)
  AGE_MIN=$(( (NOW - PUSHED_AT) / 60 ))

  cat <<EOF
<system-reminder>
AUTOFIX-CI-PUSH ready: a push to branch '$BRANCH' completed about ${AGE_MIN} minutes ago. Invoke the autofix-ci-push skill to check CI status and bot findings on the corresponding PR. Per the skill's hard rules: SILENT WHEN ALL GREEN — only report findings if there's something actionable. Honour the user's current priorities first; this can be deferred, but should be addressed before the user moves on from this PR.
</system-reminder>
EOF

  mv "$f" "$QUEUE_DIR/processed/" 2>/dev/null || true
done

exit 0

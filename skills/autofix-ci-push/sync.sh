#!/usr/bin/env bash
# sync.sh — keep this repo's autofix-ci-push copy aligned with the live install
# under ~/.claude.
#
# IMPORTANT — this is a FORK, not a mirror. The repo copy is DELIBERATELY
# GENERICIZED (stack-neutral, for OSS): generic formatter/linter/test-runner
# names, no project-specific ticket prefixes, CI gates or memory links. The live
# copy under ~/.claude is specialised to its host project. They are MEANT to
# differ — so the default action here is a read-only DIFF REPORT, not a copy.
#
# Workflow: improve the live skill → run `./sync.sh` → see which files drifted and
# by how much → port the *logic* into the genericized repo copy by hand (re-
# genericizing as you go). That is exactly how the repo stays current without
# losing its stack-neutrality.
#
# `pull` / `push` blind-copy modes exist for convenience (the scripts differ only
# by a few genericized comments), but they WILL clobber genericization on
# SKILL.md / SETUP.md — they warn and ask first. Prefer diff + hand-port.
#
# Usage:
#   ./sync.sh            # default: report in-sync / DIFFERS per file (read-only)
#   ./sync.sh diff -v    # also print the full unified diffs (< repo  > live)
#   ./sync.sh pull       # copy LIVE -> REPO  (asks; clobbers genericization)
#   ./sync.sh push       # copy REPO -> LIVE  (asks; injects generic text into live)

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_SKILL="$HOME/.claude/skills/autofix-ci-push"
LIVE_HOOKS="$HOME/.claude/hooks"

# live_path | repo_path | label   (SETUP.md is repo-only — no live counterpart, not mapped)
MAP=(
  "$LIVE_SKILL/SKILL.md|$SKILL_DIR/SKILL.md|SKILL.md"
  "$LIVE_SKILL/watch-pr.sh|$SKILL_DIR/watch-pr.sh|watch-pr.sh"
  "$LIVE_HOOKS/autofix-ci-push-trigger.sh|$SKILL_DIR/hooks/autofix-ci-push-trigger.sh|hooks/autofix-ci-push-trigger.sh"
  "$LIVE_HOOKS/autofix-ci-push-surface.sh|$SKILL_DIR/hooks/autofix-ci-push-surface.sh|hooks/autofix-ci-push-surface.sh"
)

CMD="${1:-diff}"
VERBOSE=0
[ "${1:-}" = "-v" ] && { CMD="diff"; VERBOSE=1; }
[ "${2:-}" = "-v" ] && VERBOSE=1

report() {
  local drift=0 entry live repo label liveonly repoonly
  printf '%-42s %s\n' "FILE" "STATE"
  printf '%-42s %s\n' "----" "-----"
  for entry in "${MAP[@]}"; do
    IFS='|' read -r live repo label <<<"$entry"
    if [ ! -f "$live" ]; then printf '%-42s %s\n' "$label" "live MISSING"; drift=1; continue; fi
    if [ ! -f "$repo" ]; then printf '%-42s %s\n' "$label" "repo MISSING"; drift=1; continue; fi
    if diff -q "$live" "$repo" >/dev/null 2>&1; then
      printf '%-42s %s\n' "$label" "in sync"
    else
      liveonly=$(diff "$repo" "$live" | grep -c '^>' || true)
      repoonly=$(diff "$repo" "$live" | grep -c '^<' || true)
      printf '%-42s %s\n' "$label" "DIFFERS  (live-only: ${liveonly}, repo-only: ${repoonly})"
      drift=1
      if [ "$VERBOSE" = 1 ]; then
        echo "------- $label  (< repo   > live) -------"
        diff "$repo" "$live" || true
        echo
      fi
    fi
  done
  echo
  if [ "$drift" = 1 ]; then
    echo "Drift present. 'live-only' lines are candidate new logic to PORT into the"
    echo "(genericized) repo copy; 'repo-only' lines are mostly the genericization"
    echo "itself. Port by hand — don't blind-copy. Re-run with -v to see the diffs."
  else
    echo "All mapped files identical."
  fi
}

confirm() { printf '%s [y/N] ' "$1"; read -r a; case "$a" in y|Y|yes|YES) return 0 ;; *) echo "aborted."; return 1 ;; esac; }

copy_all() {  # $1 = live (pull) | repo (push)
  local entry live repo label
  for entry in "${MAP[@]}"; do
    IFS='|' read -r live repo label <<<"$entry"
    if [ "$1" = "live" ]; then
      [ -f "$live" ] || { echo "skip (live missing): $label"; continue; }
      mkdir -p "$(dirname "$repo")" && cp "$live" "$repo" && echo "pulled  $label"
    else
      [ -f "$repo" ] || { echo "skip (repo missing): $label"; continue; }
      mkdir -p "$(dirname "$live")" && cp "$repo" "$live" && echo "pushed  $label"
    fi
  done
}

case "$CMD" in
  diff) report ;;
  pull)
    echo "PULL copies LIVE -> REPO. This RE-INJECTS host-project specifics into the"
    echo "genericized SKILL.md / SETUP.md (real commands, ticket prefixes, etc.) — you"
    echo "would then need to re-genericize. The scripts are mostly safe."
    confirm "Copy live -> repo for all mapped files?" && copy_all live
    ;;
  push)
    echo "PUSH copies REPO -> LIVE. This OVERWRITES your working skill with the"
    echo "genericized text (placeholder commands instead of your real ones)."
    confirm "Copy repo -> live for all mapped files?" && copy_all repo
    ;;
  -h|--help|help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) echo "usage: ./sync.sh [diff [-v] | pull | push | help]"; exit 2 ;;
esac

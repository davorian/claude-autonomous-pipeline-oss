#!/usr/bin/env bash
# Tests for watch-pr.sh.
#
# Each test:
#   1. Builds a gh-stub script that returns scripted responses across polls.
#   2. Runs watch-pr.sh with WATCH_PR_GH=<stub> and tiny POLL (1s).
#   3. Asserts on the watcher's stdout (the FIRED line or IDLE line).
#
# Per-channel counters: ci.0 is baseline, ci.1 is first-poll, ci.2 is second,
# etc. (Same for threads / decision / merge / comments.) This means fixtures
# read like a timeline, not a raw call sequence.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../watch-pr.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
ok()   { echo "  ok:   $1"; PASS=$((PASS+1)); }

# Stub `gh` dispatches by argv to a channel name, then reads fixture
# "$fixtures/<channel>.<n>" where n is a per-channel counter.
make_stub() {
  local stub="$1" fixtures="$2"
  cat > "$stub" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"pr checks"*--json*bucket*)  CHANNEL=ci ;;
  *graphql*reviewThreads*)      CHANNEL=threads ;;
  *reviewDecision*)             CHANNEL=decision ;;
  *mergeable*mergeStateStatus*) CHANNEL=merge ;;
  *"issues/"*"/comments"*)      CHANNEL=comments ;;
  *)                            CHANNEL=other ;;
esac
CF="$stub.counter.\$CHANNEL"
[ -f "\$CF" ] || echo 0 > "\$CF"
N=\$(cat "\$CF"); echo \$((N+1)) > "\$CF"
F="$fixtures/\$CHANNEL.\$N"
if [ -f "\$F" ]; then
  if [ "\$(cat "\$F")" = "__FAIL__" ]; then
    # Simulate a transient gh/API failure: error body on stdout, non-zero exit
    # (mirrors a real 401 — the body that previously leaked into the signal).
    echo '{"message":"Requires authentication","status":"401"}'
    exit 1
  fi
  cat "\$F"
else
  echo ""
fi
EOF
  chmod +x "$stub"
}

# Helper: write one cycle of fixtures.
# Args: fx-dir cycle ci threads decision merge comments
write_cycle() {
  local fx="$1" n="$2" ci="$3" th="$4" dec="$5" mrg="$6" cmt="$7"
  printf '%s\n' "$ci"  > "$fx/ci.$n"
  printf '%s\n' "$th"  > "$fx/threads.$n"
  printf '%s\n' "$dec" > "$fx/decision.$n"
  printf '%s\n' "$mrg" > "$fx/merge.$n"
  printf '%s\n' "$cmt" > "$fx/comments.$n"
}

# ── Test 1: baseline logs correctly, no change → IDLE ──────────────────
test_idle() {
  local name="$1"; local fx="$TMP/$name/fx"; mkdir -p "$fx"
  local stub="$TMP/$name/gh"; make_stub "$stub" "$fx"
  for n in 0 1 2; do write_cycle "$fx" "$n" "pass" "" "" "behind" ""; done
  out=$(WATCH_PR_GH="$stub" "$WATCH" 1 owner/repo 1 2 2>&1)
  echo "$out" | grep -q "WATCH-PR IDLE" && ok "$name" || fail "$name: $out"
}

# ── Test 2: CI flips pending → fail → FIRED ────────────────────────────
test_ci_fires() {
  local name="$1"; local fx="$TMP/$name/fx"; mkdir -p "$fx"
  local stub="$TMP/$name/gh"; make_stub "$stub" "$fx"
  write_cycle "$fx" 0 "pending" "" "" "behind" ""
  write_cycle "$fx" 1 "fail"    "" "" "behind" ""
  out=$(WATCH_PR_GH="$stub" "$WATCH" 1 owner/repo 1 3 2>&1)
  echo "$out" | grep -q "WATCH-PR FIRED" && echo "$out" | grep -q "ci:pending->fail" \
    && ok "$name" || fail "$name: $out"
}

# ── Test 3: new review thread fires ────────────────────────────────────
test_thread_fires() {
  local name="$1"; local fx="$TMP/$name/fx"; mkdir -p "$fx"
  local stub="$TMP/$name/gh"; make_stub "$stub" "$fx"
  write_cycle "$fx" 0 "pending" "thr-1"       "" "behind" ""
  write_cycle "$fx" 1 "pending" "thr-1,thr-2" "" "behind" ""
  out=$(WATCH_PR_GH="$stub" "$WATCH" 1 owner/repo 1 3 2>&1)
  echo "$out" | grep -q "new-review-thread" && ok "$name" || fail "$name: $out"
}

# ── Test 4: new top-level comment from a HUMAN fires ───────────────────
test_human_comment_fires() {
  local name="$1"; local fx="$TMP/$name/fx"; mkdir -p "$fx"
  local stub="$TMP/$name/gh"; make_stub "$stub" "$fx"
  write_cycle "$fx" 0 "pending" "" "" "behind" "1|github-actions"
  write_cycle "$fx" 1 "pending" "" "" "behind" "1|github-actions,2|humanReviewer"
  out=$(WATCH_PR_GH="$stub" "$WATCH" 1 owner/repo 1 3 2>&1)
  echo "$out" | grep -q "new-issue-comment" && ok "$name" || fail "$name: $out"
}

# ── Test 5: new top-level comment from a BOT does NOT fire ─────────────
test_bot_comment_silent() {
  local name="$1"; local fx="$TMP/$name/fx"; mkdir -p "$fx"
  local stub="$TMP/$name/gh"; make_stub "$stub" "$fx"
  write_cycle "$fx" 0 "pending" "" "" "behind" ""
  write_cycle "$fx" 1 "pending" "" "" "behind" "1|github-actions"
  write_cycle "$fx" 2 "pending" "" "" "behind" "1|github-actions,2|supabase"
  out=$(WATCH_PR_GH="$stub" "$WATCH" 1 owner/repo 1 2 2>&1)
  echo "$out" | grep -q "WATCH-PR IDLE" && ok "$name" \
    || fail "$name: should have stayed IDLE — $out"
}

# ── Test 6: merge state CONFLICTING fires ──────────────────────────────
test_merge_state_fires() {
  local name="$1"; local fx="$TMP/$name/fx"; mkdir -p "$fx"
  local stub="$TMP/$name/gh"; make_stub "$stub" "$fx"
  write_cycle "$fx" 0 "pending" "" "" "clean"       ""
  write_cycle "$fx" 1 "pending" "" "" "conflicting" ""
  out=$(WATCH_PR_GH="$stub" "$WATCH" 1 owner/repo 1 3 2>&1)
  echo "$out" | grep -q "merge-state:clean->conflicting" && ok "$name" || fail "$name: $out"
}

# ── Test 7: UNKNOWN merge does NOT fire ────────────────────────────────
test_unknown_merge_silent() {
  local name="$1"; local fx="$TMP/$name/fx"; mkdir -p "$fx"
  local stub="$TMP/$name/gh"; make_stub "$stub" "$fx"
  write_cycle "$fx" 0 "pending" "" "" "clean"   ""
  write_cycle "$fx" 1 "pending" "" "" "unknown" ""
  write_cycle "$fx" 2 "pending" "" "" "unknown" ""
  out=$(WATCH_PR_GH="$stub" "$WATCH" 1 owner/repo 1 2 2>&1)
  echo "$out" | grep -q "WATCH-PR IDLE" && ok "$name" \
    || fail "$name: should not fire on unknown — $out"
}

# ── Test 8: review decision change fires ───────────────────────────────
test_decision_fires() {
  local name="$1"; local fx="$TMP/$name/fx"; mkdir -p "$fx"
  local stub="$TMP/$name/gh"; make_stub "$stub" "$fx"
  write_cycle "$fx" 0 "pending" "" "REVIEW_REQUIRED" "behind" ""
  write_cycle "$fx" 1 "pending" "" "APPROVED"        "behind" ""
  out=$(WATCH_PR_GH="$stub" "$WATCH" 1 owner/repo 1 3 2>&1)
  echo "$out" | grep -q "review-decision:REVIEW_REQUIRED->APPROVED" && ok "$name" || fail "$name: $out"
}

# ── Test 9: configurable bot list via env var ──────────────────────────
test_custom_bot_list() {
  local name="$1"; local fx="$TMP/$name/fx"; mkdir -p "$fx"
  local stub="$TMP/$name/gh"; make_stub "$stub" "$fx"
  write_cycle "$fx" 0 "pending" "" "" "behind" ""
  write_cycle "$fx" 1 "pending" "" "" "behind" "1|myCustomBot"
  write_cycle "$fx" 2 "pending" "" "" "behind" "1|myCustomBot"
  out=$(WATCH_PR_AUTOMATION_BOTS=myCustomBot WATCH_PR_GH="$stub" "$WATCH" 1 owner/repo 1 2 2>&1)
  echo "$out" | grep -q "WATCH-PR IDLE" && ok "$name" \
    || fail "$name: custom bot should have been filtered — $out"
}

# ── Test 10: human comment via custom bot list — verifies allowlist filters
#            ONLY listed bots, anyone else (including default-bots) fires.
test_default_bots_overridden() {
  local name="$1"; local fx="$TMP/$name/fx"; mkdir -p "$fx"
  local stub="$TMP/$name/gh"; make_stub "$stub" "$fx"
  # Custom list contains ONLY myCustomBot. github-actions (in the default
  # list) should now be treated as human → its comment should FIRE.
  write_cycle "$fx" 0 "pending" "" "" "behind" ""
  write_cycle "$fx" 1 "pending" "" "" "behind" "1|github-actions"
  out=$(WATCH_PR_AUTOMATION_BOTS=myCustomBot WATCH_PR_GH="$stub" "$WATCH" 1 owner/repo 1 3 2>&1)
  echo "$out" | grep -q "new-issue-comment" && ok "$name" \
    || fail "$name: env override should narrow allowlist — $out"
}

# ── Test 11: a transient API error mid-poll skips the poll (no false fire) ──
# Regression for the 401 that leaked into unresolved_threads and fired a phantom
# "new-review-thread". Poll 1's threads call fails (simulated 401); the watcher
# must skip the poll and end IDLE, not fire.
test_transient_error_no_false_fire() {
  local name="$1"; local fx="$TMP/$name/fx"; mkdir -p "$fx"
  local stub="$TMP/$name/gh"; make_stub "$stub" "$fx"
  write_cycle "$fx" 0 "pass" "" "REVIEW_REQUIRED" "blocked" ""
  printf '%s\n' "pass"            > "$fx/ci.1"
  printf '%s\n' "__FAIL__"        > "$fx/threads.1"
  printf '%s\n' "REVIEW_REQUIRED" > "$fx/decision.1"
  printf '%s\n' "blocked"         > "$fx/merge.1"
  printf '%s\n' ""                > "$fx/comments.1"
  out=$(WATCH_PR_GH="$stub" "$WATCH" 1 owner/repo 1 2 2>&1)
  echo "$out" | grep -q "WATCH-PR IDLE" && ok "$name" \
    || fail "$name: transient error must skip the poll, not fire — $out"
}

echo "Running watch-pr.sh tests…"
test_idle                    "1 baseline-no-change-idle"
test_ci_fires                "2 ci-pending-to-fail-fires"
test_thread_fires            "3 new-review-thread-fires"
test_human_comment_fires     "4 new-human-comment-fires"
test_bot_comment_silent      "5 bot-comment-silent"
test_merge_state_fires       "6 merge-conflicting-fires"
test_unknown_merge_silent    "7 unknown-merge-silent"
test_decision_fires          "8 review-decision-fires"
test_custom_bot_list         "9 custom-bot-list-filters"
test_default_bots_overridden "10 env-override-narrows-allowlist"
test_transient_error_no_false_fire "11 transient-api-error-skips-poll"

echo
echo "watch-pr.sh tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# test_sme_init.sh — Tests for sme-init bootstrap utility.
#
# Usage: bash test_sme_init.sh

set -euo pipefail

PASS=0
FAIL=0
TEST_TMPDIR=""
SCRIPT_DIR="$(cd "$(dirname "$0")/../bin" && pwd)"
SME_INIT="$SCRIPT_DIR/sme-init"

_setup_tmp() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/sme_init_test.XXXXXX")
  # Override SME_ROOT location so tests don't pollute ~/.claude-pipeline
  export HOME="$TEST_TMPDIR/home"
  mkdir -p "$HOME"
}

_teardown_tmp() {
  [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
  TEST_TMPDIR=""
}

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "        $2"; }

_assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] && _pass "$label" || _fail "$label" "expected='$expected' actual='$actual'"
}

_assert_file_exists() {
  local label="$1" path="$2"
  [ -e "$path" ] && _pass "$label" || _fail "$label" "missing: $path"
}

_assert_symlink_to() {
  local label="$1" link="$2" target="$3"
  [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ] \
    && _pass "$label" \
    || _fail "$label" "link=$link target=$target actual=$(readlink "$link" 2>/dev/null || echo MISSING)"
}

# Create a minimal fake "repo" with .recovery_artifacts and a git remote
_make_fake_repo() {
  local path="$1" owner="${2:-acme}" repo_name="${3:-widget}"
  mkdir -p "$path/.recovery_artifacts" "$path/.phase_handoffs"
  echo '{"intent_envelopes":[]}' > "$path/.recovery_artifacts/intent_envelopes.json"
  echo '{"invariants":[]}' > "$path/.recovery_artifacts/invariants.json"
  echo '{"phase":"build_intent_envelopes"}' > "$path/.phase_handoffs/build_intent_envelopes.handoff.json"
  if command -v git >/dev/null 2>&1; then
    git -C "$path" init -q 2>/dev/null
    git -C "$path" remote add origin "git@github.com:${owner}/${repo_name}.git" 2>/dev/null || true
  fi
}

echo "=== sme-init ==="

# 1. Happy path — repo with recovery + remote
_setup_tmp
REPO="$TEST_TMPDIR/sample-repo"
_make_fake_repo "$REPO" "acme" "widget"
"$SME_INIT" "$REPO" >/dev/null
SME="$HOME/.claude-pipeline/repos/acme__widget/sme"
_assert_file_exists "creates sme/ directory"             "$SME"
_assert_symlink_to  "recovery/ symlink to repo"          "$SME/recovery" "$REPO/.recovery_artifacts"
_assert_symlink_to  "handoffs/ symlink to repo"          "$SME/handoffs" "$REPO/.phase_handoffs"
_assert_file_exists "journal/tickets.jsonl created"      "$SME/journal/tickets.jsonl"
_assert_file_exists "journal/gotchas.jsonl created"      "$SME/journal/gotchas.jsonl"
_assert_file_exists "digest.md generated"                "$SME/digest.md"
grep -q "intent_envelopes.json" "$SME/digest.md" \
  && _pass "digest lists recovery artifacts" \
  || _fail "digest lists recovery artifacts" "no intent_envelopes.json in digest"
_teardown_tmp

# 2. Missing recovery — error with remediation message
_setup_tmp
REPO="$TEST_TMPDIR/no-recovery"
mkdir -p "$REPO"
if "$SME_INIT" "$REPO" 2>/tmp/sme_init_err.log; then
  _fail "exits non-zero on missing recovery"
else
  _pass "exits non-zero on missing recovery"
  grep -q "reposAnalyser" /tmp/sme_init_err.log \
    && _pass "error message references reposAnalyser" \
    || _fail "error message references reposAnalyser" "got: $(cat /tmp/sme_init_err.log)"
fi
rm -f /tmp/sme_init_err.log
_teardown_tmp

# 3. Idempotent — re-run does not fail and refreshes digest
_setup_tmp
REPO="$TEST_TMPDIR/sample-repo"
_make_fake_repo "$REPO" "acme" "widget"
"$SME_INIT" "$REPO" >/dev/null
DIGEST="$HOME/.claude-pipeline/repos/acme__widget/sme/digest.md"
sleep 1   # ensure mtime can change
"$SME_INIT" "$REPO" >/dev/null
_assert_file_exists "second run preserves sme/" "$HOME/.claude-pipeline/repos/acme__widget/sme"
[ -f "$DIGEST" ] && _pass "second run regenerates digest" || _fail "second run regenerates digest"
_teardown_tmp

# 4. No git remote — falls back to dirname slug
_setup_tmp
REPO="$TEST_TMPDIR/parent/childname"
mkdir -p "$REPO/.recovery_artifacts" "$REPO/.phase_handoffs"
echo '{}' > "$REPO/.recovery_artifacts/some.json"
"$SME_INIT" "$REPO" >/dev/null
_assert_file_exists "fallback repo_id from dirname" \
  "$HOME/.claude-pipeline/repos/parent__childname/sme"
_teardown_tmp

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

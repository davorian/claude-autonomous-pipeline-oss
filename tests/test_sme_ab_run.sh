#!/bin/bash
# test_sme_ab_run.sh — Tests for sme-ab-run harness wrapper.
#
# Tests use a fake `auto_claude` binary that records its arguments and
# the AUTO_CLAUDE_PROMPT_PREAMBLE env var, so we can verify the harness
# wires SME priming through correctly without invoking real Claude.
#
# Usage: bash test_sme_ab_run.sh

set -euo pipefail

PASS=0
FAIL=0
TEST_TMPDIR=""
SCRIPT_DIR="$(cd "$(dirname "$0")/../bin" && pwd)"
SME_INIT="$SCRIPT_DIR/sme-init"
SME_AB="$SCRIPT_DIR/sme-ab-run"
SME_CTX="$SCRIPT_DIR/sme-prompt-context"

_setup() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/sme_ab_test.XXXXXX")
  export HOME="$TEST_TMPDIR/home"
  mkdir -p "$HOME/bin"
  # Stage a fake auto_claude that records env + args, then exits 0
  FAKE_AC="$HOME/bin/fake_auto_claude"
  cat > "$FAKE_AC" <<'FAKEEOF'
#!/bin/bash
echo "spec=$1" > "$AC_RECORD_FILE"
echo "preamble_set=${AUTO_CLAUDE_PROMPT_PREAMBLE:+yes}" >> "$AC_RECORD_FILE"
echo "preamble_chars=${#AUTO_CLAUDE_PROMPT_PREAMBLE}" >> "$AC_RECORD_FILE"
exit "${AC_EXIT_CODE:-0}"
FAKEEOF
  chmod +x "$FAKE_AC"
  # sme-ab-run resolves sme-prompt-context relative to --auto-claude — make
  # the real binary discoverable next to the fake auto_claude.
  ln -s "$SME_CTX" "$HOME/bin/sme-prompt-context"
  export AC_RECORD_FILE="$TEST_TMPDIR/ac_record"
}
_teardown() { [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"; TEST_TMPDIR=""; unset AC_RECORD_FILE AC_EXIT_CODE; }

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "        $2"; }

_assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] && _pass "$label" || _fail "$label" "expected='$expected' actual='$actual'"
}

_make_repo() {
  local path="$1"
  mkdir -p "$path/.recovery_artifacts"
  cat > "$path/.recovery_artifacts/invariants.json" <<'EOF'
{"invariants":[{"invariant_id":"inv-foo","description":"Foo is unique per bar","related_subjects":["foo","bar"],"evidence":[{"source":"lib/foo.ex"}]}]}
EOF
  cat > "$path/.recovery_artifacts/policies.json" <<'EOF'
{"policies":[]}
EOF
  cat > "$path/.recovery_artifacts/intent_envelopes.json" <<'EOF'
{"intent_envelopes":[]}
EOF
  git -C "$path" init -q
  git -C "$path" remote add origin "git@github.com:acme/widget.git" 2>/dev/null || true
  ( cd "$path" && git config user.email "t@t" && git config user.name "t" \
    && echo "x" > placeholder.txt && git add . && git commit -q -m "initial" )
}

echo "=== sme-ab-run ==="

# 1. Rejects unknown task_type
_setup
"$SME_AB" --spec /dev/null --task-type bogus --sme-mode off 2>/tmp/err.log && \
  _fail "rejects unknown task_type" || _pass "rejects unknown task_type"
grep -q "task_type must be one of" /tmp/err.log && _pass "error message lists valid types" \
  || _fail "error message lists valid types" "got: $(cat /tmp/err.log)"
_teardown

# 2. Rejects bad sme-mode
_setup
"$SME_AB" --spec /dev/null --task-type bugfix --sme-mode maybe 2>/tmp/err.log && \
  _fail "rejects bad sme-mode" || _pass "rejects bad sme-mode"
_teardown

# 3. SME-mode off run: no preamble, row appended with sme_mode=off
_setup
REPO="$TEST_TMPDIR/repo"
_make_repo "$REPO"
"$SME_INIT" "$REPO" >/dev/null
SPEC="$REPO/spec.md"
echo "do something with foo" > "$SPEC"
( cd "$REPO" && "$SME_AB" --spec "$SPEC" --task-type bugfix --sme-mode off \
    --auto-claude "$FAKE_AC" --out "$TEST_TMPDIR/runs.jsonl" \
    --repo-id "acme__widget" >/dev/null 2>&1 ) || true
[ -f "$TEST_TMPDIR/runs.jsonl" ] && _pass "runs.jsonl created" || _fail "runs.jsonl created"
last=$(tail -n1 "$TEST_TMPDIR/runs.jsonl")
_assert_eq "row sme_mode=off" "off" "$(echo "$last" | jq -r .sme_mode)"
_assert_eq "row task_type=bugfix" "bugfix" "$(echo "$last" | jq -r .task_type)"
_assert_eq "row outcome=success" "success" "$(echo "$last" | jq -r .outcome)"
_assert_eq "off mode → preamble_size_chars=0" "0" "$(echo "$last" | jq -r .preamble_size_chars)"
grep -q "preamble_set=$" "$AC_RECORD_FILE" || grep -q "preamble_set=" "$AC_RECORD_FILE" \
  && _pass "auto_claude received empty preamble" \
  || _fail "auto_claude received empty preamble" "$(cat "$AC_RECORD_FILE")"
_teardown

# 4. SME-mode on run: preamble set, row reflects positive size
_setup
REPO="$TEST_TMPDIR/repo"
_make_repo "$REPO"
"$SME_INIT" "$REPO" >/dev/null
SPEC="$REPO/spec.md"
echo "change foo for bar in lib/foo.ex" > "$SPEC"
( cd "$REPO" && "$SME_AB" --spec "$SPEC" --task-type feature --sme-mode on \
    --auto-claude "$FAKE_AC" --out "$TEST_TMPDIR/runs.jsonl" \
    --repo-id "acme__widget" >/dev/null 2>&1 ) || true
last=$(tail -n1 "$TEST_TMPDIR/runs.jsonl")
_assert_eq "row sme_mode=on" "on" "$(echo "$last" | jq -r .sme_mode)"
preamble_chars=$(echo "$last" | jq -r .preamble_size_chars)
[ "$preamble_chars" -gt 0 ] && _pass "on mode → preamble_size_chars > 0 ($preamble_chars)" \
  || _fail "on mode → preamble_size_chars > 0" "$preamble_chars"
grep -q "preamble_set=yes" "$AC_RECORD_FILE" \
  && _pass "auto_claude received non-empty preamble" \
  || _fail "auto_claude received non-empty preamble" "$(cat "$AC_RECORD_FILE")"
_teardown

# 5. Failed run still appends a row with outcome=failed
_setup
REPO="$TEST_TMPDIR/repo"
_make_repo "$REPO"
"$SME_INIT" "$REPO" >/dev/null
SPEC="$REPO/spec.md"
echo "x" > "$SPEC"
export AC_EXIT_CODE=42
( cd "$REPO" && "$SME_AB" --spec "$SPEC" --task-type other --sme-mode off \
    --auto-claude "$FAKE_AC" --out "$TEST_TMPDIR/runs.jsonl" \
    --repo-id "acme__widget" >/dev/null 2>&1 ) || true
last=$(tail -n1 "$TEST_TMPDIR/runs.jsonl")
_assert_eq "outcome=failed on non-zero exit" "failed" "$(echo "$last" | jq -r .outcome)"
_assert_eq "exit_code captured" "42" "$(echo "$last" | jq -r .exit_code)"
_teardown

# 6. Each row is well-formed jsonl (one valid JSON per line)
_setup
REPO="$TEST_TMPDIR/repo"
_make_repo "$REPO"
"$SME_INIT" "$REPO" >/dev/null
SPEC="$REPO/spec.md"
echo "x" > "$SPEC"
for mode in off on off; do
  ( cd "$REPO" && "$SME_AB" --spec "$SPEC" --task-type bugfix --sme-mode "$mode" \
      --auto-claude "$FAKE_AC" --out "$TEST_TMPDIR/runs.jsonl" \
      --repo-id "acme__widget" >/dev/null 2>&1 ) || true
done
total=$(wc -l < "$TEST_TMPDIR/runs.jsonl" | tr -d ' ')
_assert_eq "three rows appended" "3" "$total"
parsed=$(jq -c . "$TEST_TMPDIR/runs.jsonl" 2>&1 | wc -l | tr -d ' ')
_assert_eq "all rows parse as JSON" "3" "$parsed"
_teardown

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

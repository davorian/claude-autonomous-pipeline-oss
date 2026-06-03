#!/bin/bash
# test_new_claude_gate.sh — smoke tests for bin/new-claude-gate
#
# Exercises the scaffold against a sandbox dir: validates file generation,
# settings.json patching, hook syntax, and end-to-end hook behaviour (block
# vs pass with flag). No live ~/.claude/ writes.

set -uo pipefail

CLI="${CLI:-$(dirname "$0")/../bin/new-claude-gate}"
[[ -x "$CLI" ]] || { echo "FAIL: $CLI not executable"; exit 1; }

PASS=0
FAIL=0

assert() {
  local label="$1"; shift
  if "$@" > /dev/null 2>&1; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

# ----------------------------------------------------------------------------
# fresh sandbox
# ----------------------------------------------------------------------------
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"; rm -f /tmp/claude-test-pii.flag' EXIT

mkdir -p "$SANDBOX/memory" "$SANDBOX/skills" "$SANDBOX/hooks"
echo '{"hooks":{"PreToolUse":[]}}' > "$SANDBOX/settings.json"
echo "# MEMORY.md" > "$SANDBOX/memory/MEMORY.md"

# ----------------------------------------------------------------------------
# Phase 1: dry-run validation
# ----------------------------------------------------------------------------
echo "═══ Phase 1: dry-run (no files should be written) ═══"

"$CLI" --target-dir "$SANDBOX" \
       --name test-pii --desc 'test' --why 'test reason' \
       --gated 'mcp__slack-multiverse__slack_send_message' \
       --dry-run > /dev/null 2>&1
dry_exit=$?
assert_eq "dry-run exits 0" "0" "$dry_exit"
assert "dry-run does NOT write memory file" test ! -f "$SANDBOX/memory/feedback_test_pii.md"
assert "dry-run does NOT write skill file" test ! -f "$SANDBOX/skills/test-pii/SKILL.md"
assert "dry-run does NOT write hook file" test ! -f "$SANDBOX/hooks/test-pii-gate.sh"

# ----------------------------------------------------------------------------
# Phase 2: real run with MCP-only matcher
# ----------------------------------------------------------------------------
echo "═══ Phase 2: real run (MCP-only) ═══"

"$CLI" --target-dir "$SANDBOX" \
       --name test-pii --desc 'redact pii' --why 'incident X' \
       --gated 'mcp__slack-multiverse__slack_send_message' > /dev/null 2>&1
assert "writes memory file"  test -f "$SANDBOX/memory/feedback_test_pii.md"
assert "writes skill file"   test -f "$SANDBOX/skills/test-pii/SKILL.md"
assert "writes hook (exec)"  test -x "$SANDBOX/hooks/test-pii-gate.sh"

assert "hook is valid bash"  bash -n "$SANDBOX/hooks/test-pii-gate.sh"

# settings.json gets patched with the new entry
matcher=$(jq -r '.hooks.PreToolUse[0].matcher' "$SANDBOX/settings.json")
assert_eq "settings matcher" "mcp__slack-multiverse__slack_send_message" "$matcher"

cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$SANDBOX/settings.json")
assert_eq "settings command" "$SANDBOX/hooks/test-pii-gate.sh" "$cmd"

# MEMORY.md gets an entry
assert "MEMORY.md mentions new file" grep -qF "feedback_test_pii.md" "$SANDBOX/memory/MEMORY.md"

# ----------------------------------------------------------------------------
# Phase 3: hook block/pass behaviour
# ----------------------------------------------------------------------------
echo "═══ Phase 3: hook behaviour ═══"

# T1: gated tool without flag → exit 2
out=$(echo '{"tool_name":"mcp__slack-multiverse__slack_send_message","tool_input":{}}' \
      | bash "$SANDBOX/hooks/test-pii-gate.sh" 2>&1)
exit_code=$?
assert_eq "block exit code" "2" "$exit_code"
assert "block emits 'GATE blocked'" grep -q "GATE blocked" <<< "$out"

# T2: gated tool with flag → exit 0 + flag consumed
touch /tmp/claude-test-pii.flag
echo '{"tool_name":"mcp__slack-multiverse__slack_send_message","tool_input":{}}' \
      | bash "$SANDBOX/hooks/test-pii-gate.sh" > /dev/null 2>&1
exit_code=$?
assert_eq "pass exit code" "0" "$exit_code"
assert "flag consumed after pass" test ! -f /tmp/claude-test-pii.flag

# T3: non-gated tool → exit 0 even without flag
echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}' \
      | bash "$SANDBOX/hooks/test-pii-gate.sh" > /dev/null 2>&1
exit_code=$?
assert_eq "non-gated tool passes through" "0" "$exit_code"

# ----------------------------------------------------------------------------
# Phase 4: Bash regex matcher
# ----------------------------------------------------------------------------
echo "═══ Phase 4: Bash regex matcher ═══"

# Re-run scaffold with a Bash pattern (use --force to overwrite the test-pii gate
# in the sandbox).
"$CLI" --target-dir "$SANDBOX" --force \
       --name test-pii --desc 'redact pii' --why 'incident X' \
       --gated 'Bash:UNIQ_TEST_PATTERN_4xy' --skip-settings --skip-memory-index > /dev/null 2>&1
assert "force regenerates the hook" test -f "$SANDBOX/hooks/test-pii-gate.sh"

# T4: Bash matching the pattern blocks
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo something UNIQ_TEST_PATTERN_4xy here"}}' \
      | bash "$SANDBOX/hooks/test-pii-gate.sh" 2>&1)
exit_code=$?
assert_eq "Bash matching pattern blocks" "2" "$exit_code"
assert "Bash block emits 'GATE blocked'" grep -q "GATE blocked" <<< "$out"

# T5: Bash NOT matching the pattern passes
echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
      | bash "$SANDBOX/hooks/test-pii-gate.sh" > /dev/null 2>&1
exit_code=$?
assert_eq "Bash unrelated passes" "0" "$exit_code"

# ----------------------------------------------------------------------------
# Phase 5: idempotency of settings.json patching
# ----------------------------------------------------------------------------
echo "═══ Phase 5: settings idempotency ═══"

# Reset sandbox to a clean state
rm -rf "$SANDBOX"/{memory,skills,hooks,settings.json}
mkdir -p "$SANDBOX"/{memory,skills,hooks}
echo '{"hooks":{"PreToolUse":[]}}' > "$SANDBOX/settings.json"
echo "# MEMORY.md" > "$SANDBOX/memory/MEMORY.md"

"$CLI" --target-dir "$SANDBOX" --name test-pii --desc 't' --why 't' \
       --gated 'mcp__slack-multiverse__slack_send_message' > /dev/null 2>&1
count1=$(jq '.hooks.PreToolUse | length' "$SANDBOX/settings.json")
"$CLI" --target-dir "$SANDBOX" --force --name test-pii --desc 't' --why 't' \
       --gated 'mcp__slack-multiverse__slack_send_message' > /dev/null 2>&1
count2=$(jq '.hooks.PreToolUse | length' "$SANDBOX/settings.json")
assert_eq "second run keeps PreToolUse at 1 entry (idempotent)" "$count1" "$count2"

# ----------------------------------------------------------------------------
# summary
# ----------------------------------------------------------------------------
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Result: $PASS pass, $FAIL fail"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ $FAIL -eq 0 ]]

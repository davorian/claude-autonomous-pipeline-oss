#!/bin/bash
# test_sme_preamble.sh — Tests for AUTO_CLAUDE_PROMPT_PREAMBLE injection.
#
# Covers _build_full_prompt — the backwards-compatible preamble injector
# used by sme-ab-run to thread SME priming context into auto_claude.
#
# Usage: bash test_sme_preamble.sh

set -euo pipefail

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "        $2"; }

_assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] && _pass "$label" || _fail "$label" "expected='$expected' actual='$actual'"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AC="$(cd "$SCRIPT_DIR/.." && pwd)/bin/auto_claude"
[ -f "$AC" ] || AC="$HOME/bin/auto_claude"
[ -f "$AC" ] || { echo "ERROR: cannot find auto_claude"; exit 1; }

# Source just _build_full_prompt — same awk-based extraction pattern used
# by tests/test_auto_claude_pipeline.sh.
NO_QUESTIONS="DO_NOT_ASK_QUESTIONS"
eval "$(awk '/^_build_full_prompt[(]/{found=1} found{print} /^[}]$/{if(found){found=0}}' "$AC")"

echo "=== _build_full_prompt ==="

# 1. Preamble unset → backwards-compatible (just prompt + NO_QUESTIONS)
unset AUTO_CLAUDE_PROMPT_PREAMBLE
out=$(_build_full_prompt "do the thing")
_assert_eq "unset env: original BC form" "do the thing DO_NOT_ASK_QUESTIONS" "$out"

# 2. Empty preamble → treated as unset (BC form, no leading newlines)
AUTO_CLAUDE_PROMPT_PREAMBLE=""
out=$(_build_full_prompt "do the thing")
_assert_eq "empty env: original BC form" "do the thing DO_NOT_ASK_QUESTIONS" "$out"

# 3. Set preamble → prepended with blank-line separator
AUTO_CLAUDE_PROMPT_PREAMBLE="### SME priming
fact one
fact two"
out=$(_build_full_prompt "do the thing")
expected="### SME priming
fact one
fact two

do the thing DO_NOT_ASK_QUESTIONS"
_assert_eq "set env: preamble + blank + prompt + NO_QUESTIONS" "$expected" "$out"

# 4. Single-line preamble
AUTO_CLAUDE_PROMPT_PREAMBLE="single line preamble"
out=$(_build_full_prompt "the prompt")
expected="single line preamble

the prompt DO_NOT_ASK_QUESTIONS"
_assert_eq "single-line preamble works" "$expected" "$out"

# 5. Preamble with internal whitespace and special characters preserved
AUTO_CLAUDE_PROMPT_PREAMBLE="line one
  indented two
**bold** _italic_ \`code\`"
out=$(_build_full_prompt "p")
expected="line one
  indented two
**bold** _italic_ \`code\`

p DO_NOT_ASK_QUESTIONS"
_assert_eq "internal whitespace and markdown preserved" "$expected" "$out"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

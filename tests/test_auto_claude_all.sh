#!/bin/bash
# test_auto_claude_all.sh — Run all auto_claude test suites

PASS=0
FAIL=0

for t in ~/bin/test_auto_claude_*.sh; do
  [[ "$t" == *"test_auto_claude_all.sh" ]] && continue
  echo "━━━ $(basename $t) ━━━"
  if bash "$t"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
  echo ""
done

echo "━━━ Overall: ${PASS} suites passed, ${FAIL} suites failed ━━━"
[ $FAIL -gt 0 ] && exit 1 || exit 0

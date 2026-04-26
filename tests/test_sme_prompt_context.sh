#!/bin/bash
# test_sme_prompt_context.sh — Tests for sme-prompt-context slicer.
#
# Usage: bash test_sme_prompt_context.sh

set -euo pipefail

PASS=0
FAIL=0
TEST_TMPDIR=""
SCRIPT_DIR="$(cd "$(dirname "$0")/../bin" && pwd)"
SME_INIT="$SCRIPT_DIR/sme-init"
SME_CTX="$SCRIPT_DIR/sme-prompt-context"

_setup() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/sme_ctx_test.XXXXXX")
  export HOME="$TEST_TMPDIR/home"
  mkdir -p "$HOME"
}
_teardown() { [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"; TEST_TMPDIR=""; }
_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "        $2"; }

_assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  echo "$haystack" | grep -qF "$needle" \
    && _pass "$label" \
    || _fail "$label" "needle not found: $needle"
}
_assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  echo "$haystack" | grep -qF "$needle" \
    && _fail "$label" "unexpected: $needle" \
    || _pass "$label"
}

# Build a fake repo with realistic recovery shape
_make_repo_with_recovery() {
  local path="$1"
  mkdir -p "$path/.recovery_artifacts" "$path/.phase_handoffs"
  cat > "$path/.recovery_artifacts/invariants.json" <<'EOF'
{
  "invariants": [
    {
      "invariant_id": "inv-application-unique",
      "description": "A candidate can have at most one application per role",
      "confidence": 0.98,
      "related_subjects": ["application", "candidate", "role"],
      "evidence": [{"source": "lib/applications/application.ex", "excerpt": "unique_constraint"}]
    },
    {
      "invariant_id": "inv-cohort-cap",
      "description": "Cohort enrolment cannot exceed configured cap",
      "confidence": 0.85,
      "related_subjects": ["cohort", "enrolment"],
      "evidence": [{"source": "lib/cohorts/cohort.ex"}]
    },
    {
      "invariant_id": "inv-billing-monthly",
      "description": "Billing runs once per month per company",
      "confidence": 0.9,
      "related_subjects": ["billing", "company"],
      "evidence": [{"source": "lib/billing/cycle.ex"}]
    }
  ]
}
EOF
  cat > "$path/.recovery_artifacts/policies.json" <<'EOF'
{
  "policies": [
    {
      "id": "pol-role-access",
      "name": "Role-based route access",
      "rule": "Routes require role intersection",
      "applies_to": ["application", "candidate-signup"],
      "evidence": [{"source": "lib/auth/plug.ex"}]
    },
    {
      "id": "pol-pagination",
      "name": "Cursor pagination",
      "rule": "Lists use cursor pagination",
      "applies_to": ["search", "feed"],
      "evidence": [{"source": "lib/pagination.ex"}]
    }
  ]
}
EOF
  cat > "$path/.recovery_artifacts/intent_envelopes.json" <<'EOF'
{
  "intent_envelopes": [
    {
      "subject": "application",
      "canonical_intent": "Candidate submits an application for a role",
      "user_expression": "applies for a role"
    },
    {
      "subject": "billing",
      "canonical_intent": "Company pays monthly subscription",
      "user_expression": "pays bill"
    }
  ]
}
EOF
  git -C "$path" init -q 2>/dev/null
  git -C "$path" remote add origin "git@github.com:acme/widget.git" 2>/dev/null || true
}

echo "=== sme-prompt-context ==="

# 1. Spec mentioning 'application' returns matching invariants/policies/intents
_setup
REPO="$TEST_TMPDIR/widget"
_make_repo_with_recovery "$REPO"
"$SME_INIT" "$REPO" >/dev/null
SPEC="$TEST_TMPDIR/spec.md"
cat > "$SPEC" <<'EOF'
# Application uniqueness change

We need to update lib/applications/application.ex to add a new constraint
on the application table. The candidate uniqueness invariant must be
preserved across the migration.
EOF
out=$("$SME_CTX" --repo-id "acme__widget" --spec "$SPEC")
_assert_contains "header present"        "$out" "## SME priming (verify before relying)"
_assert_contains "matches inv-application-unique" "$out" "inv-application-unique"
_assert_contains "matches pol-role-access (applies_to: application)" "$out" "pol-role-access"
_assert_contains "matches intent application" "$out" "application"
_assert_not_contains "billing-only invariant excluded" "$out" "inv-billing-monthly"
_assert_not_contains "pagination policy excluded" "$out" "pol-pagination"
_teardown

# 2. Spec with no recognisable terms returns digest fallback
_setup
REPO="$TEST_TMPDIR/widget"
_make_repo_with_recovery "$REPO"
"$SME_INIT" "$REPO" >/dev/null
SPEC="$TEST_TMPDIR/spec.md"
echo "do the do" > "$SPEC"
out=$("$SME_CTX" --repo-id "acme__widget" --spec "$SPEC")
_assert_contains "header present even on fallback" "$out" "## SME priming"
_teardown

# 3. --max-tokens caps output
_setup
REPO="$TEST_TMPDIR/widget"
_make_repo_with_recovery "$REPO"
"$SME_INIT" "$REPO" >/dev/null
SPEC="$TEST_TMPDIR/spec.md"
cat > "$SPEC" <<'EOF'
application candidate role billing cohort enrolment company auth
EOF
short=$("$SME_CTX" --repo-id "acme__widget" --spec "$SPEC" --max-tokens 100)
long=$("$SME_CTX" --repo-id "acme__widget" --spec "$SPEC" --max-tokens 5000)
[ "${#short}" -lt "${#long}" ] && _pass "max-tokens caps output ($(echo $short | wc -c) < $(echo $long | wc -c))" \
  || _fail "max-tokens caps output" "short=${#short} long=${#long}"
_teardown

# 4. Missing repo_id sme dir errors out
_setup
SPEC="$TEST_TMPDIR/spec.md"
echo "anything" > "$SPEC"
if "$SME_CTX" --repo-id "nonexistent__nope" --spec "$SPEC" 2>/tmp/sme_ctx_err.log; then
  _fail "exits non-zero on missing SME"
else
  _pass "exits non-zero on missing SME"
  grep -q "sme-init" /tmp/sme_ctx_err.log \
    && _pass "error message points at sme-init" \
    || _fail "error message points at sme-init" "got: $(cat /tmp/sme_ctx_err.log)"
fi
rm -f /tmp/sme_ctx_err.log
_teardown

# 5. Output is well-formed markdown (starts with header, no parse errors)
_setup
REPO="$TEST_TMPDIR/widget"
_make_repo_with_recovery "$REPO"
"$SME_INIT" "$REPO" >/dev/null
SPEC="$TEST_TMPDIR/spec.md"
echo "application change in lib/applications/application.ex" > "$SPEC"
out=$("$SME_CTX" --repo-id "acme__widget" --spec "$SPEC")
first_line=$(echo "$out" | head -n1)
[ "$first_line" = "## SME priming (verify before relying)" ] \
  && _pass "first line is the priming header" \
  || _fail "first line is the priming header" "got: $first_line"
_teardown

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

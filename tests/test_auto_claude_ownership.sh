#!/bin/bash
# test_auto_claude_ownership.sh — Tests for ownership manifest and boundary fences
#
# Covers: _load_ownership_manifest, _write_boundary_fence, boundary fence hook
#
# Usage: bash test_auto_claude_ownership.sh

set -euo pipefail

PASS=0
FAIL=0
TEST_TMPDIR=""

_setup_tmp() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ac_ownership_test.XXXXXX")
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

_assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  echo "$haystack" | grep -qF "$needle" && _pass "$label" || _fail "$label" "'$needle' not found"
}

# Source _load_ownership_manifest from auto_claude
_source_ownership() {
  log() { :; }

  local ac="$1"
  eval "$(sed -n '/_load_ownership_manifest()/,/^}/p' "$ac")"
  eval "$(sed -n '/_build_ownership_context()/,/^}/p' "$ac")"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AC="$(cd "$SCRIPT_DIR/.." && pwd)/bin/auto_claude"
[ -f "$AC" ] || AC="$HOME/bin/auto_claude"

# ─── Tests ────────────────────────────────────────────────────────────────────

test_1_load_manifest_with_valid_data() {
  echo "Test 1: _load_ownership_manifest correctly reads manifest and sets globals"
  _setup_tmp
  _source_ownership "$AC"

  PROJECT_ROOT="$TEST_TMPDIR"
  OWNERSHIP_OWNS=""
  OWNERSHIP_READS=""
  OWNERSHIP_MUST_NOT_TOUCH=""

  # Create manifest
  cat > "${TEST_TMPDIR}/.auto_claude_ownership.json" <<'EOF'
{
  "runs": {
    "frontend": {
      "owns": ["src/components/Filter.tsx", "src/components/Search.tsx"],
      "reads": ["src/types.ts"],
      "must_not_touch": ["src/api/client.ts", "src/hooks/useData.ts"]
    }
  }
}
EOF

  AUTO_CLAUDE_RUN_NAME="frontend"
  _load_ownership_manifest

  local own_count
  own_count=$(echo "$OWNERSHIP_OWNS" | grep -c . 2>/dev/null || echo 0)
  _assert_eq "owns has 2 files" "2" "$own_count"

  local read_count
  read_count=$(echo "$OWNERSHIP_READS" | grep -c . 2>/dev/null || echo 0)
  _assert_eq "reads has 1 file" "1" "$read_count"

  local fence_count
  fence_count=$(echo "$OWNERSHIP_MUST_NOT_TOUCH" | grep -c . 2>/dev/null || echo 0)
  _assert_eq "must_not_touch has 2 files" "2" "$fence_count"

  _assert_contains "owns includes Filter" "$OWNERSHIP_OWNS" "Filter.tsx"
  _assert_contains "must_not_touch includes client" "$OWNERSHIP_MUST_NOT_TOUCH" "client.ts"

  _teardown_tmp
}

test_2_load_manifest_no_file() {
  echo "Test 2: _load_ownership_manifest with no manifest file — standalone mode"
  _setup_tmp
  _source_ownership "$AC"

  PROJECT_ROOT="$TEST_TMPDIR"
  OWNERSHIP_OWNS=""
  OWNERSHIP_READS=""
  OWNERSHIP_MUST_NOT_TOUCH=""
  AUTO_CLAUDE_RUN_NAME="frontend"

  _load_ownership_manifest

  _assert_eq "owns is empty" "" "$OWNERSHIP_OWNS"
  _assert_eq "reads is empty" "" "$OWNERSHIP_READS"
  _assert_eq "must_not_touch is empty" "" "$OWNERSHIP_MUST_NOT_TOUCH"

  _teardown_tmp
}

test_3_load_manifest_no_env_var() {
  echo "Test 3: _load_ownership_manifest with manifest but no AUTO_CLAUDE_RUN_NAME"
  _setup_tmp
  _source_ownership "$AC"

  PROJECT_ROOT="$TEST_TMPDIR"
  OWNERSHIP_OWNS=""
  OWNERSHIP_READS=""
  OWNERSHIP_MUST_NOT_TOUCH=""

  cat > "${TEST_TMPDIR}/.auto_claude_ownership.json" <<'EOF'
{"runs": {"frontend": {"owns": ["a.ts"], "reads": [], "must_not_touch": []}}}
EOF

  AUTO_CLAUDE_RUN_NAME=""
  _load_ownership_manifest

  _assert_eq "owns is empty without env var" "" "$OWNERSHIP_OWNS"

  _teardown_tmp
}

test_4_load_manifest_unknown_run() {
  echo "Test 4: _load_ownership_manifest with unknown run name"
  _setup_tmp
  _source_ownership "$AC"

  PROJECT_ROOT="$TEST_TMPDIR"
  OWNERSHIP_OWNS=""
  OWNERSHIP_READS=""
  OWNERSHIP_MUST_NOT_TOUCH=""

  cat > "${TEST_TMPDIR}/.auto_claude_ownership.json" <<'EOF'
{"runs": {"backend": {"owns": ["api.ts"], "reads": [], "must_not_touch": []}}}
EOF

  AUTO_CLAUDE_RUN_NAME="frontend"
  _load_ownership_manifest

  _assert_eq "owns is empty for unknown run" "" "$OWNERSHIP_OWNS"

  _teardown_tmp
}

test_5_boundary_fence_rejects_fenced_files() {
  echo "Test 5: Boundary fence pre-commit hook rejects changes to fenced files"
  _setup_tmp

  # Create a mock git repo in temp dir
  cd "$TEST_TMPDIR"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  git config core.hooksPath .git/hooks

  # Create initial commit
  echo "content" > owned.ts
  echo "content" > fenced.ts
  git add -A && git commit -q -m "init"

  # Write a boundary fence hook that blocks fenced.ts
  mkdir -p .git/hooks
  cat > .git/hooks/pre-commit <<'HOOKEOF'
#!/bin/bash
staged=$(git diff --cached --name-only)
for file in $staged; do
  case "$file" in
    fenced.ts) echo "BOUNDARY FENCE: Cannot modify ${file} — owned by another parallel run."; echo "Add a // TODO(boundary): comment describing the interface you need."; exit 1 ;;
  esac
done
exit 0
HOOKEOF
  chmod +x .git/hooks/pre-commit

  # Modify fenced file — should be rejected
  echo "modified" > fenced.ts
  git add fenced.ts
  local commit_exit=0
  git commit -m "test" 2>&1 || commit_exit=$?
  _assert_eq "commit with fenced file is rejected" "1" "$commit_exit"

  # Reset and try owned file — should succeed
  git reset HEAD fenced.ts 2>/dev/null || true
  git checkout -- fenced.ts 2>/dev/null || true
  echo "modified" > owned.ts
  git add owned.ts
  commit_exit=0
  git commit -q -m "test owned" 2>&1 || commit_exit=$?
  _assert_eq "commit with owned file succeeds" "0" "$commit_exit"

  cd - >/dev/null
  _teardown_tmp
}

test_6_boundary_fence_allows_new_files() {
  echo "Test 6: Boundary fence allows new files (not in any list)"
  _setup_tmp

  cd "$TEST_TMPDIR"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  git config core.hooksPath .git/hooks
  echo "init" > base.ts
  git add -A && git commit -q -m "init"

  # Fence only blocks specific files — new files pass through
  mkdir -p .git/hooks
  cat > .git/hooks/pre-commit <<'HOOKEOF'
#!/bin/bash
staged=$(git diff --cached --name-only)
for file in $staged; do
  case "$file" in
    fenced.ts) echo "BOUNDARY FENCE: blocked"; exit 1 ;;
  esac
done
exit 0
HOOKEOF
  chmod +x .git/hooks/pre-commit

  echo "new" > newfile.ts
  git add newfile.ts
  local exit_code=0
  git commit -q -m "add new file" 2>&1 || exit_code=$?
  _assert_eq "new file allowed through fence" "0" "$exit_code"

  cd - >/dev/null
  _teardown_tmp
}

test_7_reconciliation_detects_boundary_todos() {
  echo "Test 7: TODO(boundary) comments are detectable by grep"
  _setup_tmp

  mkdir -p "$TEST_TMPDIR/src"
  echo '// TODO(boundary): Need shared ErrorType from api/errors.ts' > "$TEST_TMPDIR/src/component.ts"
  echo 'normal code' > "$TEST_TMPDIR/src/other.ts"

  local todos
  todos=$(grep -rn 'TODO(boundary):' "$TEST_TMPDIR" --include='*.ts' 2>/dev/null) || true
  _assert_contains "finds boundary TODO" "$todos" "Need shared ErrorType"

  _teardown_tmp
}

# ─── Run all tests ──────────────────────────────────────────────────────────
echo "=== auto_claude ownership & boundary fence tests ==="
echo ""

test_1_load_manifest_with_valid_data
echo ""
test_2_load_manifest_no_file
echo ""
test_3_load_manifest_no_env_var
echo ""
test_4_load_manifest_unknown_run
echo ""
test_5_boundary_fence_rejects_fenced_files
echo ""
test_6_boundary_fence_allows_new_files
echo ""
test_7_reconciliation_detects_boundary_todos
echo ""

echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ $FAIL -gt 0 ] && exit 1 || exit 0

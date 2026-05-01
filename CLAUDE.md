# CLAUDE.md — claude-autonomous-pipeline

## Architecture

Two bash scripts that form a reusable autonomous pipeline engine:

- `bin/auto_claude` (~4500 lines) — single-project pipeline: plan → decisions → test_intent → vacuousness_pass_1 → pattern_baseline → implement → test_fix → vacuousness_pass_2_semantic → vacuousness_pass_2_coverage → ci_checks → impact → skill_chain → loc_enforcement → fresh_review → doc_update → final
- `bin/worktree_auto_claude` (~1300 lines) — parallel orchestrator: forks git worktrees, runs independent auto_claude instances, cherry-picks results back

Project-specific configuration lives in `.auto_claude.conf` files (see `conf/` for examples).

### File Structure

```
bin/
├── auto_claude               # Main pipeline engine
├── auto_claude_original      # Pre-explainability snapshot (reference only)
└── worktree_auto_claude      # Parallel worktree orchestrator
conf/
├── aurora.auto_claude.conf   # Example: Aurora project config
├── platform.auto_claude.conf # Example: NICE platform config
└── user_home.auto_claude.conf # Example: user home directory config
skills/
└── check-vacuousness/SKILL.md # Ad-hoc invocation of the vacuousness gate (CAP-VG-001)
tests/
├── test_auto_claude_all.sh       # Runner: executes all test suites
├── test_auto_claude_state.sh     # State file, context packs, test results
├── test_auto_claude_pipeline.sh  # Suite discovery, _run_all_suites, changed files
├── test_auto_claude_ci_checks.sh # CI check discovery, auto-fix, Claude-fix
├── test_auto_claude_phase_final.sh # Final phase, auto-commit logic
├── test_auto_claude_escalation.sh  # Escalation strategy and boundary violations
├── test_auto_claude_ownership.sh   # Ownership manifest loading and context building
├── test_vacuousness_pass_1.sh      # Gate 1: TDD-ordering check, auto-rewrite loop
├── test_vacuousness_pass_2_semantic.sh  # Gate 2: semantic mutation apply/restore, kill/survive
├── test_vacuousness_pass_2_coverage.sh  # Gate 3: coverage-driven mutation, weakly-covered lines
├── test_vacuousness_phase_integration.sh # Dispatcher policy, frontmatter parse, fresh_review pack
├── test_vacuousness_skill.sh           # Skill invocation contract, --vacuousness-only JSON output
└── test_vacuousness_taxonomy.sh        # Taxonomy load/cache, fallback when missing
docs/
├── auto_claude.md                    # Pipeline architecture documentation
├── auto-claude-explainability-sketch.md # Explainability design notes
└── vacuousness_taxonomy.md           # Mutation taxonomy + JSON schema (loaded as prompt fragment)
specs/                                # Feature specs (auto_claude format)
```

## Conventions

### Bash
- **Bash 3.2 compatible** (macOS default). No associative arrays in auto_claude (use flat strings + temp files). No `${var,,}` lowercase syntax.
- `set -Eeuo pipefail` at top. ERR trap for error reporting.
- All state mutations go through `_jq_update` (atomic read-modify-write via tmp + mv).
- State reads go through `_state_get` (thin jq wrapper).
- Config variables have defaults in the "Configuration Defaults" section (line ~48) and are overridable in `.auto_claude.conf`.

### Pipeline Architecture
- **Authoring block** (plan through ci_checks): single Claude conversation via `--continue`. Full context.
- **Quality block** (impact through final): each phase gets a fresh session with a context pack built from structured state.
- **Seam**: `_extract_authoring_summary` runs once after `SEAM_AFTER` phase, populating `.semantic` in the state file.
- New phases: add a `phase_<name>` function, add the name to the `PHASES` array. The main loop at the bottom dispatches `phase_${phase_name}` automatically.

### Tests
- Tests source individual functions from `bin/auto_claude` via `sed -n` or `awk` extraction — they don't run the full pipeline.
- Test scripts use a common pattern: `_setup_tmp` / `_teardown_tmp`, `_pass` / `_fail`, `_assert_eq` / `_assert_contains`.
- Tests look for auto_claude at `$HOME/bin/auto_claude` first, then fall back to the repo's `bin/auto_claude`. When working in this repo, tests should use the repo copy.

## Commands

```bash
# Run all tests
bash tests/test_auto_claude_all.sh

# Run individual test suites
bash tests/test_auto_claude_state.sh
bash tests/test_auto_claude_pipeline.sh
bash tests/test_auto_claude_ci_checks.sh

# Syntax check
bash -n bin/auto_claude && bash -n bin/worktree_auto_claude

# Shellcheck (if installed)
shellcheck -x -s bash bin/auto_claude bin/worktree_auto_claude
```

## Constraints

- Files can exceed 300 LOC — auto_claude is a single large script by design (MAX_LOC=400 in conf)
- No external dependencies beyond bash, jq, git, and claude CLI
- worktree_auto_claude uses associative arrays (bash 4+) — this is acceptable because it only runs on the developer's machine where brew bash is available
- auto_claude must NOT use associative arrays — it runs in worktrees where the shell may be macOS default bash 3.2

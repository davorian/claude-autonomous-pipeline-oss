# auto_claude

A reusable autonomous feature pipeline that executes specs end-to-end — from planning through implementation, testing, code review, and documentation — using Claude as the engine. Project-specific configuration lives in `.auto_claude.conf`; the pipeline infrastructure lives in `~/bin/auto_claude`.

---

## Usage

```bash
auto_claude [--opinionated] [--rigorous] [--skip-vacuousness-gate]
            [--auto-rewrite-vacuous] [--vacuousness-format json|human]
            [--vacuousness-only [--files <list> | --diff <ref>]]
            [--skip <phase>]... [--only <phase>]
            <path-to-spec.md>
```

The spec is a markdown file following the format defined in `CLAUDE.md`. It describes what to build, not how to build it — the pipeline works that out.

A spec can also opt into the full vacuousness gate via frontmatter — `rigorous: true` between leading `---` markers is treated as `--rigorous`.

---

## Architecture

The pipeline splits into two blocks at a configurable **seam** (`SEAM_AFTER`, default: `ci_checks`).

```
Authoring block                            Quality block
─────────────────────────────────────      ──────────────────────────────────────────
plan                                       impact
  ↓                                          ↓
decisions                                  skill_chain (incl. pattern conformance)
  ↓                                          ↓
test_intent  [TDD_ENABLED]                 loc_enforcement
  ↓                                          ↓
vacuousness_pass_1  (Gate 1, always on)    fresh_review
  ↓                                          ↓
pattern_baseline [PATTERN_CONFORMANCE]     doc_update
  ↓                                          ↓
implement                                  final
  ↓
test_fix
  ↓
vacuousness_pass_2_semantic   [RIGOROUS]
  ↓
vacuousness_pass_2_coverage   [RIGOROUS]
  ↓
ci_checks  ── seam ──▶
```

### Authoring block
Single Claude conversation via `--continue`. Full shared context across all authoring phases — Claude holds the plan, implementation decisions, and test failures in one session. CI checks run here because type errors are best fixed while Claude still has full implementation context.

### Quality block
Each phase starts a **fresh Claude session** with a tailored context pack assembled from `.auto_claude_state.json`. No conversation bleed between phases — each reviewer comes in cold. The seam triggers a one-time extraction call that summarises the authoring work into structured JSON, funding all subsequent fresh sessions with bounded, relevant context.

### Ports and adapters
The conf is an adapter layer. The pipeline core knows only the port conventions:

| Port | Convention | Adapter source |
|------|-----------|----------------|
| Test suites | `test_suite_*()` functions | `.auto_claude.conf` |
| CI checks | `ci_check_*()` functions | `.auto_claude.conf` or auto-discovered from `package.json` |
| CI auto-fix | `ci_fix_*()` functions | `.auto_claude.conf` or synthesised by `_auto_discover_ci_checks` |

The engine never hard-codes test commands or CI tools — it discovers what's available through the port.

---

## Phases

### `plan`
Reads the spec and produces a numbered implementation checklist. Uses `PLAN_CONTEXT` for project-specific framing. In opinionated mode, architectural standards are prepended here. When an ownership manifest is present (worktree mode), ownership context is injected to constrain planning to owned boundaries.

### `decisions`
Writes an explainability manifest to `.auto_claude_explain/decisions.json` capturing key decisions made during planning — what was chosen, what alternatives were considered, and why. Controlled by `EXPLAIN_PHASES` (default: true). Skipped when explainability is disabled.

### `test_intent`
TDD test-first phase. Controlled by `TDD_ENABLED` (default: true). Reads the spec and plan, then asks Claude to write test stubs and skeleton assertions that express the spec's requirements — before any implementation exists. Verifies that a test run produces red (failing) results, confirming the tests are meaningful. The intent map is stored in state at `.semantic.test_intent_map` for use by `phase_implement`. Also persists the new test files' paths to `.deterministic.test_intent.files_added` so the vacuousness gate can scope itself to just the new tests.

### `vacuousness_pass_1` (Gate 1 — TDD-ordering)
Cheap TDD-ordering check. Always on (gated by `SKIP_VACUOUSNESS_GATE`). Re-runs the suite with the new test files in place but BEFORE `implement` has produced its diff. If every suite passes, the new tests assert on behaviour that is already true → vacuous. Hard-fails the pipeline; with `AUTO_REWRITE_VACUOUS=1` (or `--auto-rewrite-vacuous`) it asks Claude to rewrite the offending tests to assert on observable side-effects of the not-yet-written implementation, looping up to `VACUOUSNESS_RETRY_LIMIT` times. Findings persist to `.auto_claude_explain/vacuousness_pass_1.json` and `.semantic.vacuousness.pass_1`. See `docs/vacuousness_taxonomy.md`.

### `pattern_baseline`
Catalogues existing coding patterns in the areas about to be changed. Controlled by `PATTERN_CONFORMANCE` (default: true). Claude reads files adjacent to the planned changes and records naming conventions, error handling patterns, import styles, and structural patterns. The baseline is stored in state at `.semantic.pattern_baseline` and used later by `skill_chain` for conformance checking.

### `implement`
Executes the plan. Writes code and tests. No commits. When `TDD_ENABLED` is true and a test intent map exists in state, implementation is guided by the intent map — Claude is instructed to make the red tests pass rather than writing tests from scratch.

### `test_fix`
Runs all `test_suite_*()` functions. On failure, sends output to Claude for fixes. Loops up to `MAX_TEST_ITERATIONS` (default: 5).

### `vacuousness_pass_2_semantic` (Gate 2 — semantic mutation)
Opt-in via `--rigorous` or `RIGOROUS=1`. Runs after `test_fix` (impl + tests are green). Loads the mutation taxonomy from `docs/vacuousness_taxonomy.md` (overridable via `VACUOUSNESS_TAXONOMY_PATH`) and asks Claude to enumerate every applicable semantic mutant across the changed impl files (no_op_body, drop_side_effect, drop_filter, swap_query_subject, swap_column, invert_boolean, skip_iteration, constant_return). For each mutant, applies it via `_vacuous_apply_mutant` (atomic save → swap → run suite → restore), classifies as **killed** (tests fail) or **survived** (tests still pass), and surfaces survivors as vacuous coverage. `SYNTAX_CHECK_COMMAND` filters out unparseable mutants. `EXPECTED_SURVIVORS` (newline-separated `file:line:category`) suppresses known-equivalent mutants. Findings persist to `.auto_claude_explain/vacuousness_pass_2_semantic.json` and `.semantic.vacuousness.pass_2_semantic`.

### `vacuousness_pass_2_coverage` (Gate 3 — coverage-driven mutation)
Opt-in via `--rigorous`. Reads `coverage_map.json` (auto-runs `COVERAGE_COMMAND` or auto-detects `mix test --cover` / `npm test -- --coverage` / `pytest --cov` if missing), surfaces uncovered lines, and runs targeted line-level mutations at covered-but-suspect lines. Surviving targeted mutants → weakly-covered lines (the high-coverage-low-confidence shape). For each survivor, asks Claude for a one-paragraph assertion shape that would kill the mutant. Findings persist to `.auto_claude_explain/vacuousness_pass_2_coverage.json` and `.semantic.vacuousness.pass_2_coverage`. `fresh_review` reads all three vacuousness artefacts into its context pack so the cold reviewer can challenge anything auto-rewrite did not resolve.

### `ci_checks`
Runs all `ci_check_*()` functions. Two-track fix strategy:
- **Auto-fixable** (`ci_fix_*` exists) — runs the fix command, re-checks, promotes to Claude if still failing
- **Claude-fixable** (no `ci_fix_*`) — sends error output directly to Claude

After any fixes, re-runs tests to confirm nothing regressed. Loops up to `MAX_CI_ITERATIONS` (default: 3).

### `skill_chain`
Fresh session. Sequential passes on the changed files: code review → pattern conformance (if `PATTERN_CONFORMANCE` is true) → security audit → simplification. Pattern conformance compares the implementation against the baseline captured in `phase_pattern_baseline`, reverting unjustified deviations and documenting intentional ones. Uses `REVIEW_EXTRAS` and `SECURITY_EXTRAS` for project-specific criteria. Extracts structured findings (including `pattern_conformance` with `deviations_reverted` and `deviations_kept`) into state on completion.

### `loc_enforcement`
Fresh session. Finds files exceeding `MAX_LOC` (default: 300) that were changed during this pipeline run. Asks Claude to split them. Stale-detection prevents infinite loops when a file genuinely cannot be split further.

### `fresh_review`
Fresh session. Deliberately excludes `plan_intent` from the context pack to avoid anchoring bias — the reviewer evaluates the code cold. Uses `FRESH_REVIEW_PREAMBLE` and `FRESH_REVIEW_EXTRAS`. Extracts findings into state.

### `doc_update`
Fresh session. Updates documentation to reflect changed files. Uses `DOC_UPDATE_CONTEXT` for project-specific doc locations and rules.

### `final`
Fresh session. Produces a human-readable summary of what was built, how to test it manually, and known limitations. Then auto-commits all session-changed files if tests passed.

---

## Configuration

All configuration lives in `.auto_claude.conf` in the project root. The file is sourced after defaults are set, so any variable can be overridden.

### Required

```bash
# At least one test suite function
test_suite_jest() {
  cd "$PROJECT_ROOT" && npm test 2>&1
  return ${PIPESTATUS[0]}
}
```

### Optional — pipeline tuning

```bash
MAX_TEST_ITERATIONS=5       # How many test-fix loops before giving up
MAX_CI_ITERATIONS=3         # How many CI fix loops before giving up
MAX_REFACTOR_ROUNDS=10      # How many LOC refactor rounds before giving up
MAX_LOC=300                 # Line count threshold for loc_enforcement
SEAM_AFTER="ci_checks"      # Last phase of the authoring block
OPINIONATED=false           # See Opinionated Mode below
TDD_ENABLED=true            # Enable test_intent phase and TDD-aware implement
PATTERN_CONFORMANCE=true    # Enable pattern_baseline phase and conformance in skill_chain
```

### Optional — vacuousness gate (CAP-VG-001)

```bash
RIGOROUS=0                       # opt-in to Gates 2 + 3 (mutation testing)
SKIP_VACUOUSNESS_GATE=0          # bypass all three vacuousness phases
AUTO_REWRITE_VACUOUS=0           # rewrite-on-failure inside the gate
VACUOUSNESS_FORMAT="human"       # "human" or "json" (JSON for CI / skill)
VACUOUSNESS_RETRY_LIMIT=2        # auto-rewrite retry cap (Pass 1)
VACUOUSNESS_TAXONOMY_PATH=""     # override docs/vacuousness_taxonomy.md path
EXPECTED_SURVIVORS=""            # newline-separated file:line:category
                                 # list of known-equivalent mutants
COVERAGE_COMMAND=""              # fallback coverage command (auto-detected if empty)
SYNTAX_CHECK_COMMAND=""          # parse check for mutants (e.g. "mix compile --no-deps-check")
```

CLI flags `--rigorous`, `--skip-vacuousness-gate`, `--auto-rewrite-vacuous`, and `--vacuousness-format` override these. A spec frontmatter `rigorous: true` between leading `---` markers is equivalent to `--rigorous`. `--vacuousness-only [--files <list> | --diff <ref>]` runs the gate as a standalone tool against the supplied files (used by the `check-vacuousness` skill).

### Optional — prompt fragments

These are injected into phase prompts. Prepend project-specific context without replacing the generic prompts.

```bash
PLAN_CONTEXT=""             # Injected into plan phase
REVIEW_EXTRAS=""            # Injected into skill_chain code review
SECURITY_EXTRAS=""          # Injected into skill_chain security pass
FRESH_REVIEW_PREAMBLE=""    # Prepended to fresh_review prompt
FRESH_REVIEW_EXTRAS=""      # Appended to fresh_review criteria
DOC_UPDATE_CONTEXT=""       # Replaces default doc update instruction
```

### Optional — CI checks

If not defined in conf, auto-discovered from `package.json` scripts:

```bash
# Manual definition
ci_check_format() { cd "$PROJECT_ROOT" && npm run prettier-check 2>&1; }
ci_fix_format()   { cd "$PROJECT_ROOT" && npm run prettier-fix 2>&1; }

ci_check_types()  { cd "$PROJECT_ROOT" && npm run typecheck 2>&1; }
# No ci_fix_types — type errors go to Claude
```

Auto-discovery maps these `package.json` scripts to check/fix functions:

| Script | Maps to |
|--------|---------|
| `prettier-check` / `format:check` | `ci_check_format` + `ci_fix_format` |
| `lint` | `ci_check_lint` + `ci_fix_lint` |
| `typecheck` / `type-check` / `tsc` | `ci_check_types` (no fix — Claude-fixable) |
| `typescript` in `devDependencies` | `ci_check_types` via `npx tsc --noEmit` |

---

## Opinionated Mode

Controls whether architectural standards are enforced or advisory during review phases.

```bash
# Per-run (CLI flag takes precedence over conf)
auto_claude --opinionated specs/my_feature.md

# Per-project (in .auto_claude.conf)
OPINIONATED=true
```

### OFF (default)
Standards are injected into `REVIEW_EXTRAS` and `FRESH_REVIEW_PREAMBLE` as **advisory observations**. Claude surfaces what it would have applied and why — labelled as non-blocking — so you can see the delta without being forced into it. Not injected into `PLAN_CONTEXT`, so implementation is not second-guessed mid-plan.

### ON
Standards are injected into `PLAN_CONTEXT`, `REVIEW_EXTRAS`, and `FRESH_REVIEW_PREAMBLE` as **enforced requirements**. Claude defers to existing codebase patterns first, but where they conflict with the standards, applies the standards and notes the departure.

### The four standards

1. **Discriminated unions over optional fields** — when a type has distinct states, use tagged unions so each variant carries exactly the fields it needs. Make impossible states impossible at compile time.

2. **Ports and adapters at natural seams** — where the code crosses a boundary (external service, CLI tool, config system), define a port and keep adapters separate. The core should not know which adapter is wired in.

3. **Prefer simpler by default** — when two approaches are valid, default to the less complex one. Add abstraction only when the simpler option demonstrably cannot serve the need.

4. **Defer to existing patterns** — examine the codebase first. Follow existing patterns unless the requirement genuinely cannot be served by them.

---

## State File

`.auto_claude_state.json` is written after every phase and is the single source of truth for pipeline state. Two sections:

- **`deterministic`** — populated by the engine from git and test runners. Always accurate. Contains changed files, test results, CI check results, LOC violations.
- **`semantic`** — populated by Claude via extraction calls at the seam and after each quality phase. Richer but lossy. Contains plan intent, implementation summary, key decisions, review findings.

Inspect at any time:
```bash
jq . .auto_claude_state.json
```

Resume after a crash — the pipeline detects an interrupted run on next invocation and resumes from the last completed phase.

---

## Runtime Files

| File | Purpose |
|------|---------|
| `.auto_claude_state.json` | Structured pipeline state (phases, test results, semantic summaries) |
| `.auto_claude_<timestamp>.log` | Full timestamped log of every phase |
| `.auto_claude_baseline` | Snapshot of untracked files at pipeline start (deleted on completion) |
| `.auto_claude.lock/` | Concurrency guard — prevents two instances running on the same project |
| `.auto_claude_ownership.json` | Boundary manifest — written by `worktree_auto_claude`, read by `_load_ownership_manifest` to constrain each instance to its owned files |
| `.auto_claude_explain/` | Explainability artifacts — `decisions.json`, `assumptions.json`, `coverage_map.json`, `impact_assessment.md`, `vacuousness_pass_1.json`, `vacuousness_pass_2_semantic.json`, `vacuousness_pass_2_coverage.json` |

---

## Dependencies

| Tool | Required | Purpose |
|------|----------|---------|
| `claude` CLI | Yes | Claude invocation |
| `jq` | Yes | JSON parsing of state file and Claude output |
| `git` | Recommended | Changed file detection, auto-commit |

---

## Tests

The test suite mirrors the structure of the pipeline — one test file per functional area.

| File | Covers |
|------|--------|
| `test_auto_claude_ci_checks.sh` | CI check discovery, classification, auto-discovery from `package.json` |
| `test_auto_claude_phase_final.sh` | Git staging loop — `git check-ignore` exit code handling, artifact filtering |
| `test_auto_claude_escalation.sh` | Escalation strategy and boundary violation handling |
| `test_auto_claude_ownership.sh` | Ownership manifest loading and context building |
| `test_vacuousness_pass_1.sh` | Gate 1: TDD-ordering check, auto-rewrite loop, retry-limit hard-fail |
| `test_vacuousness_pass_2_semantic.sh` | Gate 2: mutant apply/restore, kill/survive classification, syntax-check + EXPECTED_SURVIVORS filters |
| `test_vacuousness_pass_2_coverage.sh` | Gate 3: coverage-map parse, weakly-covered-line surfacing, fallback coverage command |
| `test_vacuousness_phase_integration.sh` | Dispatcher policy (skip / rigorous / vacuousness-only), spec frontmatter parse, fresh_review context pack injection |
| `test_vacuousness_skill.sh` | `skills/check-vacuousness/SKILL.md` invocation contract, `--vacuousness-only` JSON output shape |
| `test_vacuousness_taxonomy.sh` | `docs/vacuousness_taxonomy.md` cache, fallback when missing, schema doc completeness |

Run all tests:
```bash
bash ~/bin/test_auto_claude_ci_checks.sh
bash ~/bin/test_auto_claude_phase_final.sh
```

### Known regression: line 1431 (`phase_final` crash on ignored paths)

`git check-ignore` exits with three distinct codes: `0` (ignored), `1` (not ignored), `128` (error — path untracked and not in `.gitignore`). The original staging loop used `! git check-ignore ...` which let exit `128` escape the negation and fire the `ERR` trap, crashing the pipeline at `phase_final`. Fixed by capturing the exit code explicitly and only staging on exit `1`. Covered by `test_auto_claude_phase_final.sh` test 3.

---

## Gotchas

**`.idea` and `specs/` showing git hints on stderr** — these are advisory messages from git, not errors. Suppress globally with:
```bash
git config --global advice.addIgnoredFile false
```

**`vitest` entering watch mode** — the pipeline exports `CI=true` to force non-interactive mode. If your test runner still hangs, ensure it respects the `CI` environment variable.

**Concurrency** — only one auto_claude instance may run per project. A second invocation will detect the lock and exit with the PID of the running instance. Remove a stale lock with `rm -rf .auto_claude.lock`.

**Non-git projects** — supported. Project root is detected by walking up from `pwd` looking for `.auto_claude.conf`. Changed file detection and auto-commit are skipped.

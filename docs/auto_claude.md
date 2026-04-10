# auto_claude

A reusable autonomous feature pipeline that executes specs end-to-end — from planning through implementation, testing, code review, and documentation — using Claude as the engine. Project-specific configuration lives in `.auto_claude.conf`; the pipeline infrastructure lives in `~/bin/auto_claude`.

---

## Usage

```bash
auto_claude [--opinionated] <path-to-spec.md>
```

The spec is a markdown file following the format defined in `CLAUDE.md`. It describes what to build, not how to build it — the pipeline works that out.

---

## Architecture

The pipeline splits into two blocks at a configurable **seam** (`SEAM_AFTER`, default: `ci_checks`).

```
Authoring block          Quality block
─────────────────────    ──────────────────────────────────────────
plan                     skill_chain
  ↓                        ↓
implement                loc_enforcement
  ↓                        ↓
test_fix                 fresh_review
  ↓                        ↓
ci_checks  ── seam ──▶  doc_update
                           ↓
                         final
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
Reads the spec and produces a numbered implementation checklist. Uses `PLAN_CONTEXT` for project-specific framing. In opinionated mode, architectural standards are prepended here.

### `implement`
Executes the plan. Writes code and tests. No commits.

### `test_fix`
Runs all `test_suite_*()` functions. On failure, sends output to Claude for fixes. Loops up to `MAX_TEST_ITERATIONS` (default: 5).

### `ci_checks`
Runs all `ci_check_*()` functions. Two-track fix strategy:
- **Auto-fixable** (`ci_fix_*` exists) — runs the fix command, re-checks, promotes to Claude if still failing
- **Claude-fixable** (no `ci_fix_*`) — sends error output directly to Claude

After any fixes, re-runs tests to confirm nothing regressed. Loops up to `MAX_CI_ITERATIONS` (default: 3).

### `skill_chain`
Fresh session. Three sequential passes on the changed files: code review → security audit → simplification. Uses `REVIEW_EXTRAS` and `SECURITY_EXTRAS` for project-specific criteria. Extracts structured findings into state on completion.

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
```

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

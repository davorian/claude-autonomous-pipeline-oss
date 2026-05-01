# CAP-VG-001: Vacuousness Gate for Claude Autonomous Pipeline (and as a global skill)

## Context

A vacuous test is one that passes regardless of whether the implementation actually does anything meaningful. Common shapes:

- Tests that match `{:ok, _}` without checking what's in the wildcard
- Tests where the fixture seeds the asserted end-state itself (the function-under-test doesn't have to do anything)
- Tests that exercise reused upstream code only — the new module/function-under-test is never directly observed
- "No mutation" claims without before/after row counts
- `Mimic.stub` calls without `verify_on_exit!` (stubbed external call could go un-invoked silently)

Auto_claude's `impact_assessment` step has been catching these post-hoc on a per-PR basis (e.g. "the bare-user happy path is vacuous"). That's good as a forensic tool but late — the test has already been generated and committed by the time the assessment runs. We want the same check earlier in the pipeline so vacuous tests are detected and rewritten before they ship.

We also want this capability **as a standalone skill** so engineers can run it ad-hoc in any conversation against existing code, not just within an autonomous pipeline run.

This spec is designed to run via `~/bin/auto_claude`.

### Three gates, two passes

The vacuousness check is split into **two passes** that run at different points in the pipeline. Together they evaluate **three gates**.

**Pass 1 — Intent level (cheap, default-on)**
Runs after `test_intent`, before `implementation`. One gate:

- **Gate 1 — TDD-ordering gate** (D2). New tests must FAIL before the implementation phase has produced its diff. If a test passes pre-impl, it asserts something already true → vacuous.

**Pass 2 — Coverage / post-impl level (rigorous, opt-in via `--rigorous`)**
Runs after `implementation`, before `validation`. Two gates that work in concert:

- **Gate 2 — Semantic-mutation gate** (D3). Generate meaningful mutants from the taxonomy (D1) — the kinds of mistakes a real engineer or LLM would make. Each mutant must be killed by ≥1 test. Survivors → vacuous coverage of that mutation site.
- **Gate 3 — Coverage-driven mutation surfacing** (D4). Use the test suite's coverage report to identify lines that are *touched* by tests but where mutating the line doesn't fail any test. This is the subtle case Gate 2 alone misses: a test runs through the line (so coverage is "100%") but doesn't actually assert on the line's effect, so any change to it slips through. Coverage data is what lets us target mutation effort precisely at suspicious-coverage hotspots rather than mutating everything blindly.

Why split into two passes? Pass 1 is fast and catches ~80% of vacuous tests for free; running it before implementation also lets the pipeline halt early without wasting an impl-generation budget. Pass 2 is order-of-magnitude more expensive (mutation testing is O(mutants × test-suite)) so it sits behind a `--rigorous` flag — appropriate for high-stakes specs (deletion scripts, payment paths, security-sensitive code) but skipped for routine refactors.

### What this spec does NOT do

- Does NOT replace the existing `impact_assessment` step — that remains for broader downstream/blast-radius analysis. The vacuousness gate is a focused subset that runs earlier.
- Does NOT replace integration / e2e / property-based testing — those have different jobs.
- Does NOT do random/operator-level byte-mutation (Stryker-style). The whole point is that mutations must be **semantically meaningful** — the kinds of mistakes a human or LLM would actually make. Random mutants produce too much equivalent-mutant noise.
- Does NOT auto-merge fixes. When a vacuous test is flagged, the gate either hard-fails or proposes a stronger assertion for human review (configurable).
- Does NOT change the autonomous-pipeline's existing phase contract. New phases slot in between existing ones; existing artefacts stay.

### Dependencies (all met)

- [x] Claude Autonomous Pipeline already has a phased pipeline shape (spec → intent_map → test_intent → coverage_map → implementation → validation → impact_assessment) with each phase emitting a JSON/MD artefact.
- [x] The pipeline can run shell commands inside the project (e.g. `mix test --only`).
- [x] The pipeline has access to an LLM call for code generation (used for impl + tests already; we reuse it for mutation generation).
- [x] Skill mechanism exists in Claude Code for invoking project-scoped or global skills via the `Skill` tool.
- [ ] **Implementer**: claude-autonomous-pipeline maintainer needs to slot in the two new phases + the skill. Estimated: 1–2 days.

---

## Deliverable 1: Define the meaningful-mutation taxonomy

**File:** `lib/cap/vacuousness/mutation_taxonomy.ex` (or equivalent in the pipeline's host language) — create

### Why

A formal list of mutation strategies that are **semantically meaningful** for typical code. Each strategy must answer: "Would a real engineer plausibly make this mistake?" If no, it goes in the random-mutant pile and is excluded.

### Mutation taxonomy

Eight categories, each with concrete examples:

| Category | Mutation | Example (Elixir) |
|---|---|---|
| **No-op body** | Replace function body with the simplest valid return | `def x(_), do: {:ok, %{}}` |
| **Drop side-effect** | Remove the data-mutation call but keep the surrounding control flow | Remove `Repo.delete_all(query)`; keep the count return as `0` |
| **Drop filter** | Remove a `where:` / `WHERE` / `if` guard so the function operates on too much/too little data | `from(t in T, where: t.user_id == ^id)` → `from(t in T)` |
| **Swap query subject** | Change the table/source the query targets to a sibling-but-wrong one | `from(u in "users", ...)` → `from(u in "users_including_deactivated", ...)` (or vice versa — exactly the H2 bug shape) |
| **Swap column** | Replace a column reference with a similarly-named sibling | `where: t.user_id == ^id` → `where: t.id == ^id` |
| **Invert boolean** | Flip an `if condition do X else Y end` so the branches swap | `if dry_run do report else execute end` → `if dry_run do execute else report end` |
| **Skip iteration** | In a `Enum.reduce/3`, return the accumulator unchanged | `Enum.reduce(items, acc, fn x, acc -> handle(x, acc) end)` → `Enum.reduce(items, acc, fn _, acc -> acc end)` |
| **Constant return** | Replace a count/aggregate with a constant zero or one | `Repo.aggregate(query, :count)` → `0` |

These cover ~95% of the real-world bugs we've seen in SEA-1246. They generalise across language stacks (TypeScript jest mocks, Python unittest patches, Ruby RSpec doubles).

### Out of taxonomy

- Operator-level byte mutation (`+` → `-`, `<` → `>`)
- Whitespace / comment changes
- Random argument shuffling

These produce too many equivalent mutants and waste compute.

### Changes

- Define a `Mutation.t()` struct (or equivalent typed record): `%{category: atom, file: String.t, line: integer, original: String.t, mutated: String.t}`.
- Provide a `mutate/2` function: takes the impl module + mutation strategy → returns a list of mutants (one per applicable site).
- Each mutant carries provenance: which strategy generated it, which line/column, what the original was.

### Tests

1. [ ] `mutate/2` with `:no_op_body` on a 3-function module returns 3 mutants
2. [ ] `mutate/2` with `:drop_filter` on a query with 2 `where:` clauses returns 2 mutants (one per dropped clause)
3. [ ] `mutate/2` with `:swap_table` on `Repo.delete_all(from(t in "x", ...))` proposes at least one swap to a sibling table name
4. [ ] Each mutant includes `:original` and `:mutated` source snippets for the report
5. [ ] Mutants don't apply to test files (only to lib/ code)

### Existing Test Impact

- **No change needed**: new module, isolated.

---

## Deliverable 2: TDD-ordering gate (Pass 1 — intent level, cheap)

**File:** `lib/cap/vacuousness/tdd_gate.ex` — create

### Why

Cheapest vacuousness check. Invariant: in a TDD-shape pipeline, **tests written in the `test_intent` phase must fail when run against the codebase before the `implementation` phase has produced its diff**. If they pass, the tests are asserting something that's already true — so they don't actually test the new behaviour.

This catches ~80% of vacuous-test cases at the cost of one extra `mix test` run.

### Interface

```elixir
defmodule CAP.Vacuousness.TDDGate do
  @doc """
  Run the new test files (those touched by the test_intent phase)
  against the codebase BEFORE the implementation phase has merged in.

  Returns:
    :ok                                    — all new tests fail (as expected)
    {:vacuous, [test_module: [test_name]]} — listed tests passed unexpectedly
  """
  @spec check(test_files :: [String.t], project_root :: String.t) ::
          :ok | {:vacuous, [{module(), [String.t]}]}
end
```

### Changes

- Identify the test files added/modified in the current `test_intent` artefact.
- Stash the impl-phase changes (or run before they're applied — the pipeline's exact ordering depends on how it stages diffs).
- Run `mix test <test files>` (or language-equivalent).
- Parse output: tests that pass at this stage are vacuous.
- Return structured list of vacuous tests with file path + test name.

### Tests

1. [ ] Given a new module that doesn't exist yet, all tests against it fail → check returns `:ok`
2. [ ] Given a test that asserts `assert true` (trivially passing), check returns `{:vacuous, ...}` with that test listed
3. [ ] Given a test that exercises an existing pre-impl-phase function (so it passes), check returns `{:vacuous, ...}`
4. [ ] When 0 new test files exist (no test_intent diff), check returns `:ok` immediately without running tests

### Existing Test Impact

- **No change needed**: new module, isolated.

---

## Deliverable 3: Semantic-mutation gate (Pass 2a — post-impl, rigorous opt-in)

**File:** `lib/cap/vacuousness/mutation_gate.ex` — create

### Why

Catches the ~15% of vacuous tests that survive the TDD gate (tests that DO fail without the impl, but only by accident — they assert on something narrower than what the impl actually does, so the impl can be subtly wrong and the tests still pass).

Method: after `implementation` phase, generate semantic mutants per the taxonomy from D1, run the test suite against each, and report mutants that no test catches ("survivors").

### Interface

```elixir
defmodule CAP.Vacuousness.MutationGate do
  @doc """
  Generate meaningful mutants per the taxonomy and verify each is killed
  by at least one test.

  Returns:
    :ok                              — every mutant killed by ≥1 test
    {:survivors, [Mutation.t()]}     — listed mutations that no test catches
  """
  @spec check(impl_files :: [String.t], test_files :: [String.t]) ::
          :ok | {:survivors, [Mutation.t()]}
end
```

### Changes

For each function in the impl-phase diff:
1. Generate mutants using the D1 taxonomy
2. For each mutant: apply it, run the relevant test files, capture pass/fail
3. Categorise: killed (≥1 test fails) vs. survived (all tests pass)
4. Return list of survivors with `original` + `mutated` snippets so the gate's report shows exactly what mutation went uncaught

**Performance:** N mutants × M test runs is O(N×M). For typical functions: ~5 mutants per function, ~10 functions per PR, test suite runs in <30s — total ~25 min worst case. Sequential per impl-file is the default; parallel-per-mutant is a stretch goal.

**Equivalent-mutant filter:** some mutations are functionally equivalent to the original (e.g. dropping a `where:` clause that's always true). The gate can't distinguish; it'll flag them as survivors. Add a `:expected_survivors` opt-in list per project for known-equivalent cases.

### LLM-generated mutations (optional)

In addition to the taxonomy, allow an LLM-call to propose mutations specific to the function being tested. Prompt: "Here's the function {body}. List 3 plausible mistakes a junior engineer might make in this function." The LLM produces context-aware mutations (e.g. "swap `user_id` with `id`" specifically tied to the function's domain). Run those alongside taxonomy-derived mutants.

### Tests

1. [ ] Given a function `f(_), do: 1` and a test `assert f(:x) == 1`, the `:no_op_body` mutant survives → check returns `{:survivors, ...}`
2. [ ] Given the same function with test `assert f(:x) > 0`, survival is also reported (still vacuous because the no-op return `0` would also be > 0... wait, that's not vacuous, the test would catch `0`). Refine: given a test on a function that returns a Map and the test only checks `is_map/1`, the no-op mutant `%{}` survives → reported.
3. [ ] LLM-proposed mutations run alongside taxonomy mutations
4. [ ] The `:expected_survivors` config opts-out a known-equivalent mutant from the survivors list

### Existing Test Impact

- **No change needed**: new module, isolated.

---

## Deliverable 4: Coverage-driven mutation surfacing (Pass 2b — post-impl, rigorous opt-in)

**File:** `lib/cap/vacuousness/coverage_gate.ex` — create

### Why

Gate 2 (D3) generates the same taxonomy of mutants for every impl file regardless of how the test suite actually exercises it. That's wasteful at one end (mutating lines no test ever touches will always survive — uninformative) and *blind* at the other end (mutating lines tests touch but don't assert on is exactly the case Gate 2 misses if the mutation happens to produce equivalent output).

This gate sharpens Gate 2 by **using the test suite's coverage report to target mutation effort**:

- Lines with **zero coverage** → flag as untested. No need to mutate; the absence of coverage is itself a vacuousness indicator.
- Lines with **non-zero coverage** → run mutants targeted at those specific lines. If any mutant survives despite coverage, the test is "running through" the line without asserting on it — the classic high-coverage-low-confidence failure mode.

Distinct from Gate 2 because:
- Gate 2 = "are these meaningful mutations all caught?" (asks for kill-rate)
- Gate 3 = "where is coverage misleading us?" (asks for high-coverage-low-kill-rate hotspots)

A function can pass Gate 2 (all *generated* mutants killed) and still fail Gate 3 (coverage shows lines that no targeted mutation kills, indicating the test is observing the function's output too coarsely).

### Interface

```elixir
defmodule CAP.Vacuousness.CoverageGate do
  @doc """
  Cross-reference the test suite's coverage report with the impl files
  and surface lines where coverage > 0 but no mutation at that line is
  killed by any test.

  Returns:
    :ok                                          — every covered line is mutation-sensitive
    {:weakly_covered, [%{file:, line:, coverage_pct:, surviving_mutants: [...]}]}
  """
  @spec check(impl_files :: [String.t], test_files :: [String.t], coverage_report :: map) ::
          :ok | {:weakly_covered, [map]}
end
```

### Changes

- Read the coverage report from the upstream `coverage_map` phase artefact (already produced by the existing pipeline) — see "Reuse coverage_map" below.
- For each impl file in the diff:
  1. Identify lines with `coverage_count > 0` (i.e. tests do execute these lines)
  2. For each such line, run a targeted mutation per the D1 taxonomy at that line only (single-line mutation, not whole-function)
  3. Run the test suite against the mutated code; if it still passes, record `{file, line, coverage_pct, surviving_mutation}`
- Return list of weakly-covered lines

### Reuse coverage_map

The pipeline already produces a `coverage_map` artefact upstream. This gate reads it directly rather than re-running coverage from scratch — saves a full test-suite run.

If `coverage_map` doesn't exist (e.g. the pipeline was started post-`coverage_map`), the gate produces a warning and falls back to running its own coverage pass.

### Suggested-test output

When a weakly-covered line is reported, include a recommended assertion shape:

```
lib/platform/customer_exit/restrict_pre_clean.ex:88
  Coverage: 100% (line executed in 3 tests)
  Surviving mutation: drop_filter — `where: t.user_id == ^id` → `where: true`
  Suggested assertion: assert that pre_clean_user_id only deletes rows
                       where user_id = supplied id, not all rows.
                       Add a sibling-user fixture and assert intactness.
```

This is the same auto-rewrite hook D5 (was D4) uses.

### Tests

1. [ ] Given an impl file with 100% line coverage but 0% mutation kill-rate, the gate returns `{:weakly_covered, ...}` listing every line
2. [ ] Given an impl file where coverage_map shows uncovered lines, those uncovered lines appear in the report tagged as "no coverage" (without running mutations)
3. [ ] When the upstream `coverage_map` artefact is missing, the gate logs a fallback warning and runs its own coverage pass
4. [ ] The gate's output integrates with auto-rewrite (D5) — surviving-mutation snippets feed directly into the LLM prompt for test rewriting
5. [ ] When all covered lines are mutation-sensitive (no survivors), gate returns `:ok`

### Existing Test Impact

- **No change needed**: new module, isolated. Reads existing `coverage_map` artefact format.

---

## Deliverable 5: Phase integration into Claude Autonomous Pipeline

**File:** `lib/cap/phases/vacuousness_phase.ex` — create
**File:** `lib/cap/orchestrator.ex` — modify

### Why

Slot the three gates into the existing phase ordering so they run automatically on every autonomous run, with a `--rigorous` flag toggling Pass 2.

### New phase ordering

```
Existing:                              New:
spec                                   spec
intent_map                             intent_map
test_intent                            test_intent
                                       vacuousness_pass_1        ← NEW (Gate 1 / D2)
                                         └─ tdd_ordering_gate
coverage_map                           coverage_map
implementation                         implementation
                                       vacuousness_pass_2        ← NEW, --rigorous only
                                         ├─ semantic_mutation    (Gate 2 / D3)
                                         └─ coverage_mutation    (Gate 3 / D4)
validation                             validation
impact_assessment                      impact_assessment
```

### Pass semantics

**Pass 1 — `vacuousness_pass_1`** runs after `test_intent`, before `coverage_map`. Always-on (default). Cheap.
- Runs Gate 1 (TDD-ordering, D2)
- Emits `vacuousness_pass_1.json` — `{vacuous_tests: []}`
- If vacuous tests detected: hard-fail (default) or auto-rewrite (if `--auto-rewrite-vacuous` flag set)

**Pass 2 — `vacuousness_pass_2`** runs after `implementation`, before `validation`. **Opt-in via `--rigorous` flag**.
- Runs Gate 2 (semantic-mutation, D3)
- Runs Gate 3 (coverage-driven mutation surfacing, D4) — reuses `coverage_map` artefact
- Emits `vacuousness_pass_2.json` — `{semantic_survivors: [...], weakly_covered_lines: [...]}`
- If either gate reports issues: hard-fail (default) or auto-rewrite

### Flag semantics

| Flag | Default | Effect |
|---|---|---|
| `--rigorous` | off | Enables Pass 2 (Gates 2 + 3). Pass 1 always runs. |
| `--skip-vacuousness-gate` | off | Skips both passes entirely. For trivial PRs / hotfixes. |
| `--auto-rewrite-vacuous` | off | When a gate fails, call LLM to rewrite the test with stronger assertions. Cap retries at 2. |
| `--vacuousness-format json` | off | Machine-readable artefact format (for CI). Default: human-readable + JSON twins. |

A high-stakes spec (deletion scripts, payment paths, anything touching prod data) should set `--rigorous` in its frontmatter so the pipeline auto-applies it. Routine refactors run with default flags.

### Auto-rewrite semantics (opt-in)

When a vacuous test or surviving mutant is detected, the pipeline can call back to the LLM with: "This test passed even when the impl was a no-op (or this mutation survived: {original} → {mutated}). Rewrite the test with stronger observable-side-effect assertions. Specifically: assert on row counts, the exact value returned, or external-call invocations."

The rewritten test is re-run through the gate that flagged it. Up to 2 retries before hard-fail (configurable).

### Changes

- Add `vacuousness_pass_1` phase after `test_intent` in `orchestrator.ex` (always-on)
- Add `vacuousness_pass_2` phase after `implementation` (gated on `--rigorous`)
- Wire flags: `--rigorous`, `--skip-vacuousness-gate`, `--auto-rewrite-vacuous`, `--vacuousness-format`
- Each pass emits its artefact to `.auto_claude_explain/` for human review

### Tests

1. [ ] On a run where test_intent produces a vacuous test, the pipeline halts at `vacuousness_pass_1` and emits the report
2. [ ] On a `--rigorous` run where implementation introduces a function with weakly-covered lines, the pipeline halts at `vacuousness_pass_2` with both `semantic_survivors` and `weakly_covered_lines` populated
3. [ ] On a default (non-rigorous) run, `vacuousness_pass_2` does not execute; pipeline proceeds straight to `validation`
4. [ ] `--skip-vacuousness-gate` bypasses both passes
5. [ ] `--auto-rewrite-vacuous` retries up to N times before hard-fail
6. [ ] On a clean rigorous run (no vacuous tests, all mutants killed, no weakly-covered lines), both passes emit empty reports and pipeline continues
7. [ ] A spec frontmatter `rigorous: true` is honored equivalently to the CLI `--rigorous` flag

### Existing Test Impact

- **Update to new context**: any existing pipeline integration test that asserted on phase count needs updating for two new phases.
- **No change needed**: existing phases' artefacts are unchanged. `coverage_map` is reused, not modified.

---

## Deliverable 6: Global skill `check-vacuousness` for ad-hoc use

**File:** `~/.claude/skills/check-vacuousness/skill.md` — create
**File:** `~/.claude/skills/check-vacuousness/runner.exs` — create (or `.py` / `.ts` matching the host project's language; the skill detects)

### Why

Engineers often want to check vacuousness on existing tests — not in the middle of an autonomous run. Examples:

- "I'm reviewing a PR; are these tests robust?"
- "I just wrote a test; is it actually testing my code?"
- "We've had a regression slip through; were the tests covering that path vacuous?"

A global skill makes this a one-command operation: `/check-vacuousness <test-file-or-module>`.

### Interface

The skill is invocable from any conversation:

```
/check-vacuousness test/platform/customer_exit/restrict_pre_clean_test.exs
/check-vacuousness Platform.CustomerExit.RestrictPreClean
/check-vacuousness --diff main..HEAD
/check-vacuousness <args> --rigorous     # also run Pass 2 (Gates 2 + 3)
/check-vacuousness <args> --auto-rewrite # propose stronger test variants
```

### Skill behaviour

By default the skill runs **Gate 1 only** (Pass 1, TDD-ordering check) — same default as the autonomous pipeline. The `--rigorous` flag enables Gates 2 + 3 (Pass 2). This mirrors the pipeline's flag semantics so the skill and the in-pipeline gate produce identical reports for the same input.

1. Resolve the input → set of `(impl_file, test_file)` pairs
2. Run **Gate 1 — TDD-ordering** (if a "before" state is reachable, e.g. via a diff or git ref; otherwise skip with a note)
3. If `--rigorous`:
   - Run **Gate 2 — semantic-mutation**
   - Run **Gate 3 — coverage-driven mutation surfacing** (uses local coverage report; runs `mix test --cover` if missing)
4. Print structured report:
   ```
   Vacuousness Report — Platform.CustomerExit.RestrictPreClean
   
   PASS 1 (intent level)
   ✓ Gate 1 — TDD-ordering: passed (5 of 5 new tests fail without impl)
   
   PASS 2 (post-impl — --rigorous)
   ✗ Gate 2 — Semantic mutation: 2 survivors
   
       1. lib/platform/customer_exit/restrict_pre_clean.ex:88
          Strategy: drop_filter
          Original: where: t.user_id == ^user_id
          Mutated:  (filter removed)
          Suggested test: assert that pre_clean_user_id/1 only deletes the supplied user_id's rows, leaving siblings intact (you have this for member_details — extend to seed_login_descriptions, seed_login_tags)
   
       2. lib/platform/customer_exit/restrict_pre_clean.ex:104
          Strategy: swap_column
          Original: field(t, ^column) == ^user_id
          Mutated:  field(t, ^column) == ^column  (column literal, not user_id)
          Suggested test: ...
   
   ✗ Gate 3 — Coverage-driven mutation: 1 weakly-covered line
   
       lib/platform/customer_exit/restrict_pre_clean.ex:142
          Coverage: 100% (line executed in 4 tests)
          Surviving mutation: skip_iteration on Enum.reduce/3
          Diagnosis: the Enum.reduce body is exercised by tests but no test
                     asserts on the accumulated count — replacing the body
                     with the identity reducer slips through.
          Suggested test: assert the returned counts map's :logs key equals
                          the actual deleted-row count (not just non-zero).
   
   Run the skill in --auto-rewrite mode to have the suggested tests applied automatically:
       /check-vacuousness <args> --rigorous --auto-rewrite
   ```

### Reuse from auto_claude

The skill internally calls the same modules from D2 + D3. The autonomous pipeline shells out to it (or imports the modules directly). Both surfaces share the implementation; one runs interactively (skill), the other runs in-pipeline (D4).

### Tests

1. [ ] `/check-vacuousness <test_file>` produces a structured report
2. [ ] `/check-vacuousness <module>` resolves to its test file via convention (module path → test path) and produces a report
3. [ ] `/check-vacuousness --diff main..HEAD` resolves to the set of files changed in the diff
4. [ ] The skill produces no false positives on a known-clean test file (manually-verified suite)
5. [ ] When run on the SEA-1246 candidates suite (which has known vacuous-ish patterns flagged in the conversation), the skill flags at least the `{:error, _}`-pattern tests + the impact_assessment-flagged "bare-user happy path" pattern

### Existing Test Impact

- **No change needed**: new skill, isolated. Doesn't modify existing skills.

---

## Constraints

- Mutation tests must be **deterministic** for a given impl + test set. No random seed. Reproducibility for CI is non-negotiable.
- Performance ceiling: total wall-time for both gates on a typical 5-file PR diff < 5 minutes. If the function-under-test has expensive setup (DB, RabbitMQ), use `mix test --partitions` or equivalent parallelism.
- Mutants that fail to compile must NOT be counted as survivors. Compile-failure = mutant invalid; skip it.
- Skill output must work in both interactive (terminal) and CI (machine-readable) modes. Provide a `--format json` flag.
- No language-bound implementation. The pipeline + skill should work for Elixir, TypeScript, Python projects in the same conceptual shape (the per-language mutation library can be a separate adapter).

## File Summary

| # | File | Action | Deliverable |
|---|------|--------|-------------|
| 1 | `lib/cap/vacuousness/mutation_taxonomy.ex` | create | D1 |
| 2 | `test/cap/vacuousness/mutation_taxonomy_test.exs` | create | D1 |
| 3 | `lib/cap/vacuousness/tdd_gate.ex` | create | D2 (Gate 1) |
| 4 | `test/cap/vacuousness/tdd_gate_test.exs` | create | D2 |
| 5 | `lib/cap/vacuousness/mutation_gate.ex` | create | D3 (Gate 2) |
| 6 | `test/cap/vacuousness/mutation_gate_test.exs` | create | D3 |
| 7 | `lib/cap/vacuousness/coverage_gate.ex` | create | D4 (Gate 3) |
| 8 | `test/cap/vacuousness/coverage_gate_test.exs` | create | D4 |
| 9 | `lib/cap/phases/vacuousness_phase.ex` | create | D5 |
| 10 | `lib/cap/orchestrator.ex` | modify | D5 |
| 11 | `test/cap/phases/vacuousness_phase_test.exs` | create | D5 |
| 12 | `~/.claude/skills/check-vacuousness/skill.md` | create | D6 |
| 13 | `~/.claude/skills/check-vacuousness/runner.exs` | create | D6 |
| 14 | `test/skills/check_vacuousness_test.exs` | create | D6 |

## Execution Order

```
D1 (taxonomy)         → mix test test/cap/vacuousness/mutation_taxonomy_test.exs
D2 (Gate 1 / TDD)     → mix test test/cap/vacuousness/tdd_gate_test.exs
D3 (Gate 2 / mutation)→ mix test test/cap/vacuousness/mutation_gate_test.exs   [depends on D1]
D4 (Gate 3 / coverage)→ mix test test/cap/vacuousness/coverage_gate_test.exs   [depends on D1, D3]
D5 (phase integration)→ mix test test/cap/phases/vacuousness_phase_test.exs    [depends on D2, D3, D4]
D6 (skill)            → /check-vacuousness <known-test-file>                   [depends on D1, D2, D3, D4]
```

D1 is the foundation — taxonomy must be defined first. D2 forms Pass 1 (intent-level gate). D3 + D4 form Pass 2 (post-impl gates). D5 wires both passes into the autonomous pipeline behind the `--rigorous` flag. D6 exposes the same machinery as a global skill for ad-hoc use.

## Verification

```bash
# Smoke test: skill against a known-clean test (default = Pass 1 only)
/check-vacuousness test/known_clean_module_test.exs
# Expected: ✓ Gate 1 passed

# Smoke test: rigorous mode against a known-clean test
/check-vacuousness test/known_clean_module_test.exs --rigorous
# Expected: ✓ Gate 1, ✓ Gate 2, ✓ Gate 3 — no survivors, no weakly-covered lines

# Smoke test: rigorous against a deliberately-vacuous test
/check-vacuousness test/known_vacuous_module_test.exs --rigorous
# Expected: ✗ at least one of the three gates fires; specific gate depends on the
#           vacuousness shape (TDD-pre-pass vs. blanket-mutation-survivor vs.
#           coverage-blind-line)

# Pipeline test: default run (Pass 1 only)
~/bin/claude-autonomous-pipeline run a-spec-that-produces-vacuous-tests.md
# Expected: halts at vacuousness_pass_1; Pass 2 never runs

# Pipeline test: rigorous run
~/bin/claude-autonomous-pipeline run --rigorous a-spec.md
# Expected: both passes execute; halts at the first failing gate

# Pipeline test: --skip-vacuousness-gate flag
~/bin/claude-autonomous-pipeline run --skip-vacuousness-gate a-spec.md
# Expected: both passes skipped; pipeline continues
```

## Open questions

- **Equivalent-mutant noise**: how aggressive should the LLM-generated mutation step be at filtering equivalent mutants? Current spec offers `:expected_survivors` config; could also add a "second-LLM-pass to evaluate equivalence" step.
- **Cross-language adapter shape**: how to factor the mutation taxonomy so adding a TypeScript or Python adapter is clean? Suggest a behaviour interface (`@callback mutate/2`) per language with a shared report format.
- **Auto-rewrite quality**: when the gate proposes a test rewrite, how does it ensure the rewrite is meaningful (not vacuous itself)? Suggest re-running the gate on the rewritten test and capping retries at 2.
- **Performance on full-suite runs**: mutation testing is inherently O(mutants × suite). For very large suites, support `--scope-tests` to run only tests covering the impl file (using existing coverage-map artefact from the upstream phase).

---

## Why these specific mutations beat random byte-mutation

Industry-standard mutation testing (Stryker, PIT, mutmut) uses syntactic operator-level mutations: flip `+` to `-`, `<` to `>`, etc. These produce ~20-50 mutants per function, of which 30-60% are "equivalent mutants" (functionally identical to the original — e.g. `i++` vs `++i` in a loop). Engineers triaging the report waste time on the equivalents; signal-to-noise is poor.

The taxonomy in D1 is tighter: each mutation maps to a real bug pattern observed in production code reviews (the "drop_filter" bug = SEA-1246's H2 view-vs-table; the "swap_column" bug = SEA-1246's M-severity UUID-case finding; the "no_op_body" bug = the "bare-user happy path is vacuous" auto_claude flag).

Tighter taxonomy → fewer equivalent mutants → engineers actually act on the reported survivors.

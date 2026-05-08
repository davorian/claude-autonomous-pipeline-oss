---
name: check-vacuousness
description: Run the auto_claude vacuousness gate ad-hoc against a test file, module, or git diff. Default = Gate 1 (TDD-ordering, cheap). Pass --rigorous to also run Gates 2 + 3 (semantic + coverage-driven mutation). Use for "are these tests robust?" reviews on PRs, individual tests you've just written, or post-mortem regression triage.
---

# check-vacuousness

A vacuous test passes regardless of whether the implementation does anything
meaningful. This skill finds them.

## When to invoke

- "I'm reviewing a PR; are these tests robust?"
- "I just wrote a test; is it actually testing my code?"
- "We've had a regression slip through; were the tests covering that path
  vacuous?"

## Invocation shapes

```
/check-vacuousness <test-file>
/check-vacuousness <ModuleName>
/check-vacuousness --diff main..HEAD
/check-vacuousness <args> --rigorous       # also run Gates 2 + 3
/check-vacuousness <args> --auto-rewrite   # propose stronger test variants
```

## Behaviour

By default the skill runs **Gate 1** only (Pass 1, TDD-ordering check) — the
same default as the autonomous pipeline. The `--rigorous` flag enables
**Gates 2 + 3** (Pass 2 — semantic mutation + coverage-driven mutation).
This mirrors the pipeline's flag semantics so the skill and the in-pipeline
gate produce identical reports for the same input.

The skill is a thin invocation layer over `auto_claude`:

```sh
auto_claude --vacuousness-only --files "<resolved file list>" \
            [--rigorous] [--auto-rewrite-vacuous] \
            --vacuousness-format json
```

`auto_claude` is the single source of truth for the gate logic. The skill
parses the JSON report and renders it for the user.

## How to run

1. Resolve the input to a set of `(impl_file, test_file)` pairs:
   - `<test-file>` → the file directly.
   - `<ModuleName>` → convention-based test path
     (e.g. `Foo.Bar.Baz` → `test/foo/bar/baz_test.exs`).
   - `--diff <ref>` → `git diff --name-only <ref>` and filter to test/source
     files.
2. Run `auto_claude --vacuousness-only --files "<list>" --vacuousness-format json`
   (add `--rigorous` if requested, `--auto-rewrite-vacuous` if requested).
3. Parse the emitted JSON document with keys `pass_1`, `pass_2_semantic`,
   `pass_2_coverage`.
4. Print the report in the structured shape:

   ```
   Vacuousness Report — <subject>

   PASS 1 (intent level)
   {✓|✗} Gate 1 — TDD-ordering: <summary>

   PASS 2 (post-impl — --rigorous)
   {✓|✗} Gate 2 — Semantic mutation: <count> survivors
       <per-survivor block with category, file:line, original, mutated,
        and suggested test text from the JSON>

   {✓|✗} Gate 3 — Coverage-driven mutation: <count> weakly-covered lines
       <per-line block with file:line, coverage_pct, surviving_mutation,
        suggested_assertion>
   ```

5. If any gate fired and `--auto-rewrite` was NOT passed, end the report
   with:

   > Run again with `--auto-rewrite` to apply suggested test rewrites.

## Constraints

- Output must work in both interactive (terminal) and CI (machine-readable)
  modes. Pass `--vacuousness-format json` when CI is detected (env
  `CI=true`).
- Mutation work is delegated to `auto_claude`, not implemented in the skill.
- Do not modify test expectations — only the impl-driving assertions in
  test files when `--auto-rewrite` is set.

## Install

This skill ships in-repo at `skills/check-vacuousness/SKILL.md`. To install:

```sh
mkdir -p ~/.claude/skills/check-vacuousness
cp skills/check-vacuousness/SKILL.md ~/.claude/skills/check-vacuousness/
```

Or symlink for live edits while iterating:

```sh
mkdir -p ~/.claude/skills
ln -s "$(pwd)/skills/check-vacuousness" ~/.claude/skills/check-vacuousness
```

## See also

- `docs/vacuousness_taxonomy.md` — the eight categories of mutations the
  gate considers semantically meaningful.
- `bin/auto_claude` phases `phase_vacuousness_pass_1`,
  `phase_vacuousness_pass_2_semantic`, `phase_vacuousness_pass_2_coverage`
  — the in-pipeline implementation.

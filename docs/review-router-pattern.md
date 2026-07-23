# Review router pattern

`phase_fresh_review` routes each review to the lenses that are load-bearing for *this*
diff, instead of applying one fixed checklist to every change. Routing is mechanical —
driven by the changed files and their content — so which lenses fire is decided by the
diff, not by reviewer intuition (which tends to rate what is cheap to check over what
actually breaks systems).

## Two layered mechanisms

Both are assembled into the cold-review prompt by `phase_fresh_review`, alongside the
empirical-finding gate (`docs/empirical_finding_gate.md`).

### 1. Repo review rules — `_load_repo_review_rules`

Loads a project's own rules and filters them against the diff:

- `.cursor/BUGBOT.md` — always applied (repo-wide).
- `.cursor/rules/**/*.mdc` — each fires if **any** of:
  - `alwaysApply: true` in its frontmatter, OR
  - `globs:` matches a changed path (`_files_match_glob`), OR
  - `contentPatterns:` matches the content of a changed file (`_content_matches_any`,
    case-insensitive regex). Content routing catches a concern wherever it lives — a raw
    SQL migration, an event-schema change — regardless of the path it sits at.

`.mdc` is the Cursor rule format; `contentPatterns` is an additive frontmatter field
Cursor ignores, so rules stay compatible both ways.

### 2. Review lenses — `_load_review_lenses`

Markdown questionnaires with YAML frontmatter, loaded from two places:

- `docs/review-experts/` — the shipped, tech-agnostic cross-cutting lenses (below).
- `<project>/.auto_claude/review-experts/` — optional project-specific lenses.

Each lens declares a firing predicate (OR-combined; `always` wins):

```yaml
---
id: sql-migrations
label: "Migration safety — locking, ordering, reversibility"
when_content: ["CREATE TABLE", "ALTER TABLE", "CREATE INDEX"]   # regex, case-insensitive
# or: when_paths: ["**/*.sql", "migrations/**"]
# or: when: always
---
<questionnaire body — the questions this lens asks of the diff>
```

Fired lenses' bodies are injected into the prompt under a **FIRED / NOT-FIRED** summary,
so the reviewer knows which lenses are load-bearing. A fired lens must be applied; if the
reviewer judges one a false positive for this diff, it says so explicitly in the review
body (name + reason) — it does not silently skip. Silent skipping is the pre-judgement
failure mode the router exists to prevent.

## Shipped cross-cutting lenses (always-on)

- **absence-lens** — what is *missing* that the diff implies (a schema/code mismatch, a
  new entity without its index/test/audit, a renamed export with un-updated callers).
- **failure-mode-blast-radius** — per High finding: what breaks, who notices (silent?),
  and the blast radius; auto-promotes silent-failure / data-corruption findings to High.
- **historical-precedent** — match the diff against the project's known-findings
  catalogue before deriving a bug from scratch.

## Adding or tuning a lens

- **Add a project lens:** drop a `.md` with the frontmatter above into
  `<project>/.auto_claude/review-experts/`.
- **Add a shipped lens:** add a `.md` to `docs/review-experts/` (keep it tech-agnostic —
  anything project-specific belongs in the project dir).
- **Tune firing:** widen/narrow `when_paths` / `when_content`.

## Backtest procedure

When a bug slips through a review:

1. Re-run the review and check which lenses fired.
2. If the lens whose questionnaire would have caught it did **not** fire → routing gap;
   widen its `when_paths` / `when_content` so it fires next time.
3. If it fired but its questionnaire lacked the relevant question → lens gap; add the
   question.
4. If no lens covers the class → add a lens.

## Relationship to the `auto_claude-review` skill

The `auto_claude-review` skill applies this same routing to an already-open GitHub PR
(reviewing the PR diff cold), lifted out of the pipeline. The lens catalogue and the
firing predicates are shared vocabulary between the two.

# claude-autonomous-pipeline

Reusable autonomous feature pipeline using Claude as engine.

## Pipeline

13-phase pipeline split into two blocks at a configurable seam:

**Authoring block** (single Claude conversation):
`plan` → `decisions` → `test_intent` → `pattern_baseline` → `implement` → `test_fix` → `ci_checks`

**Quality block** (fresh sessions per phase):
`impact` → `skill_chain` → `loc_enforcement` → `fresh_review` → `doc_update` → `final`

Key features:
- **TDD flow** — `test_intent` writes failing tests before implementation; `implement` makes them pass (`TDD_ENABLED=true`)
- **Pattern conformance** — `pattern_baseline` catalogues existing patterns; `skill_chain` enforces conformance (`PATTERN_CONFORMANCE=true`)
- **Ownership boundaries** — `worktree_auto_claude` writes `.auto_claude_ownership.json` to constrain each parallel instance to its owned files
- **Explainability** — `decisions` phase emits decision manifests to `.auto_claude_explain/`

## Structure

```
bin/
  auto_claude              # Main pipeline script (~4000 lines)
  worktree_auto_claude     # Git worktree wrapper for isolated parallel runs
  auto_claude_original     # Pre-refactor backup
conf/
  platform.auto_claude.conf    # Multiverse platform config
  aurora.auto_claude.conf      # Multiverse aurora config
  user_home.auto_claude.conf   # Multiverse user_home config
docs/
  auto_claude.md                       # Pipeline documentation
  auto-claude-explainability-sketch.md # Explainability proposal
tests/
  test_auto_claude_*.sh    # Pipeline test scripts
```

## Usage

```bash
# Direct run
~/bin/auto_claude path/to/spec.md

# Isolated worktree run
~/bin/worktree_auto_claude path/to/spec.md
```

Requires `.auto_claude.conf` in the project root. See `conf/` for examples and `docs/auto_claude.md` for full documentation.

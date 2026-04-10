# claude-autonomous-pipeline

Reusable autonomous feature pipeline using Claude as engine.

## Structure

```
bin/
  auto_claude              # Main pipeline script
  worktree_auto_claude     # Git worktree wrapper for isolated runs
  auto_claude_original     # Pre-refactor backup
conf/
  platform.auto_claude.conf    # Multiverse platform config
  aurora.auto_claude.conf      # Multiverse aurora config
  user_home.auto_claude.conf   # Multiverse user_home config
docs/
  auto_claude.md                       # Pipeline documentation
  auto-claude-explainability-sketch.md # Explainability proposal (4 phases)
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

Requires `.auto_claude.conf` in the project root. See `conf/` for examples.

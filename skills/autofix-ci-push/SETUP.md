# autofix-ci-push — setup

This skill is three cooperating pieces: a **skill** (the playbook Claude runs),
two **hooks** (that schedule and surface a check after you push), and an optional
**background watcher**. The skill lives in the repo; the hooks are Claude Code
user-config and live under `~/.claude/`.

## What each file is

| File | Role |
|---|---|
| `SKILL.md` | The playbook. Categorise CI + bot findings → auto-fix the mechanical ones in one commit → surface the rest. |
| `watch-pr.sh` | Background watcher. Polls a PR and exits when CI resolves / a new bot thread appears / the review decision changes. Optional — invoked from the skill. |
| `hooks/autofix-ci-push-trigger.sh` | **PostToolUse(Bash)** hook. On a successful `git push` to a feature branch, drops a marker under `~/.claude/autofix-queue/` with a `due_at` ~10 minutes out. |
| `hooks/autofix-ci-push-surface.sh` | **UserPromptSubmit** hook. Ripens due markers and emits an `AUTOFIX-CI-PUSH ready…` `<system-reminder>` that invokes the skill. |

The hooks are how "push → (10 min later, on your next prompt) Claude checks the
PR" happens with **no background daemon** — macOS lacks `setsid`, so ripeness is
computed inline from `due_at` on each user prompt. The watcher is the alternative
for when you want to act the *moment* CI resolves rather than on your next prompt.

## Prerequisites

- **GitHub CLI** authenticated: `gh auth login` (the skill reads PRs and review threads via `gh`).
- **`jq`** on `PATH` (the trigger hook parses the tool-call payload with it).
- Bash 3.2+ (macOS default is fine) — the scripts are POSIX-ish bash.

## Install

### 1. Skill

Copy this whole directory into your Claude Code skills dir:

```sh
mkdir -p ~/.claude/skills
cp -R skills/autofix-ci-push ~/.claude/skills/autofix-ci-push
chmod +x ~/.claude/skills/autofix-ci-push/watch-pr.sh
```

### 2. Hooks

```sh
mkdir -p ~/.claude/hooks
cp skills/autofix-ci-push/hooks/autofix-ci-push-trigger.sh  ~/.claude/hooks/
cp skills/autofix-ci-push/hooks/autofix-ci-push-surface.sh  ~/.claude/hooks/
chmod +x ~/.claude/hooks/autofix-ci-push-*.sh
```

### 3. Register the hooks in `~/.claude/settings.json`

Merge these two entries into the `hooks` object (create `hooks` if it's not there).
`$HOME` is expanded by the hook runner, so this is portable across machines.

```jsonc
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/autofix-ci-push-trigger.sh",
            "timeout": 10,
            "async": true
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/autofix-ci-push-surface.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

If you already have `PostToolUse` / `UserPromptSubmit` arrays, append these
entries to them rather than replacing — both events allow multiple registrations.

## Verify it's wired

1. `gh auth status` → logged in.
2. Push a commit to a **feature** branch (not `main`/`master`/`prod` — those are
   intentionally excluded). You should see, on stderr:
   `[autofix-ci-push-trigger] queued CI/bot check for '<branch>' (ripens in 10 min)`
3. Within ~10 minutes, on your next prompt, an `AUTOFIX-CI-PUSH ready…`
   `<system-reminder>` should appear and the skill should run.
4. Inspect the queue any time: `ls ~/.claude/autofix-queue/` (pending markers) and
   `~/.claude/autofix-queue/processed/` (handled).

To trigger the skill manually any time: `/autofix-ci-push [pr-number]`.

## Adapt to your stack

`SKILL.md` names the toolchain generically (*formatter*, *linter*, *type-checker*,
*security scanner*, *test runner*). The only edits you may want:

- In **Step 6 → Make edits + verify**, swap the example commands for your real
  ones (`prettier`/`eslint`, `gofmt`/`go vet`, `black`/`ruff`/`mypy`, `mix
  format`/`mix credo`, …).
- In **Step 5**, add any project-specific auto-fixable patterns your linter
  emits — but keep the bias: when unsure, **surface, don't auto-fix**.

The hooks and the watcher are stack-agnostic — no changes needed there.

## Tuning

- **Ripen delay** — `autofix-ci-push-trigger.sh`, the `due_at` line: `$((TS + 600))`
  is 10 minutes. Lower it if your CI is fast.
- **Excluded branches** — same file, the `case "$BRANCH" in … ) exit 0` line lists
  branches that never schedule a check (`main`, `master`, `production`, `prod`,
  `HEAD`). Add your trunk's name if it differs.
- **Watcher cadence / ceiling** — `watch-pr.sh <pr> <owner/repo> [poll_seconds] [max_polls]`
  default to 60s polls, 40 polls (~40 min).

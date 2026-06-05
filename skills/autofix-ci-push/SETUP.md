# autofix-ci-push — setup

This skill is three cooperating pieces: a **skill** (the playbook Claude runs), a
**background watcher**, and two **hooks** (that arm the watcher after you push).
The skill + watcher live in the repo; the hooks are Claude Code user-config and
live under `~/.claude/`.

## What each file is

| File | Role |
|---|---|
| `SKILL.md` | The playbook. Probe four axes (CI / merge-state / threads / reviews) → auto-fix the mechanical bot+CI findings in one commit → surface the rest. Silent when all four are clean. |
| `watch-pr.sh` | Background watcher. Polls a PR and exits the instant something is actionable: CI resolves, a new (bot or human) thread appears, the review decision changes, or the merge-state becomes actionable. Invoked from the skill in watch mode. |
| `hooks/autofix-ci-push-trigger.sh` | **Synchronous PostToolUse(Bash)** hook. On a successful `git push` to a feature branch, resolves the branch's PR + `owner/repo` and injects an `additionalContext` instruction telling Claude to arm the watcher now. Also writes a marker under `~/.claude/autofix-queue/` as the fallback record. |
| `hooks/autofix-ci-push-surface.sh` | **UserPromptSubmit** hook. The fallback: if a push marker is still `pending` (watcher never armed) past its ~5-min window, reminds Claude once, then moves it to `processed/`. |

**Why the trigger is synchronous (no `async`):** an async PostToolUse hook has its
stdout **ignored** — `additionalContext` only reaches the model from a *synchronous*
hook. Register the trigger without `async` (see below), or the arming instruction
never fires. The hook still exits in microseconds for non-push Bash calls, so the
`gh` latency is only paid on an actual `git push`.

## Prerequisites

- **GitHub CLI** authenticated: `gh auth login` (the skill reads PRs and review threads via `gh`).
- **`jq`** on `PATH` (the trigger hook parses the tool-call payload and builds its JSON output with it).
- Bash 3.2+ (macOS default is fine) — the scripts are POSIX-ish bash.

## Install

### 1. Skill + watcher

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

Merge these into the `hooks` object (create it if absent). `$HOME` is expanded by
the hook runner, so this is portable across machines. **Note the trigger has no
`async`** — it must run synchronously (see "Why the trigger is synchronous" above).

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
            "timeout": 15
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
entries rather than replacing — both events allow multiple registrations.

## Verify it's wired

1. `gh auth status` → logged in.
2. Open a PR on a **feature** branch (not `main`/`master`/`prod`/`HEAD` — those are
   intentionally excluded), and push a commit to it.
3. On that push, the trigger resolves the PR and injects an instruction; Claude
   should **arm the watcher** (a `watch-pr.sh <pr> <owner/repo>` background call)
   and then carry on. If there's no open PR yet, nothing is armed — the surface
   fallback reminds you on your next prompt.
4. Inspect the queue any time: `ls ~/.claude/autofix-queue/` (pending markers) and
   `~/.claude/autofix-queue/processed/` (handled).

To trigger the skill manually any time: `/autofix-ci-push [pr-number]`.

## Adapt to your stack

`SKILL.md` names the toolchain generically (*formatter*, *linter*, *type-checker*,
*security scanner*, *test runner*). The edits you may want:

- In **Step 6 → Edit + verify**, swap the example commands for your real ones
  (`prettier`/`eslint`, `gofmt`/`go vet`, `black`/`ruff`/`mypy`, `mix format`/`mix credo`, …).
- In **Step 5**, add any project-specific auto-fixable patterns your linter emits —
  but keep the bias: when unsure, **surface, don't auto-fix**.

The hooks and the watcher are stack-agnostic — no changes needed there. Auto-fix
only runs when the skill can detect your toolchain; otherwise it's surface-only.

## Tuning

- **Fallback window** — `autofix-ci-push-trigger.sh`, the `due_at` line: `$((TS + 300))`
  is 5 minutes (how long before the surface hook reminds you that the watcher was
  never armed). The primary path is the synchronous arm on push, so this only
  matters as a safety net.
- **Excluded branches** — same file, the `case "$BRANCH" in … ) exit 0` line lists
  branches that never arm (`main`, `master`, `production`, `prod`, `HEAD`). Add your
  trunk's name if it differs.
- **Watcher cadence / ceiling** — `watch-pr.sh <pr> <owner/repo> [poll_seconds] [max_polls]`
  default to 60s polls, 40 polls (~40 min).

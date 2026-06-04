---
name: autofix-ci-push
description: After a git push, sweep a PR's CI checks + bot review findings. Auto-fix the mechanical ones (formatting, unused imports, lint nits, verified false positives) in a single commit; surface everything that needs a human decision (test failures, real security findings, design concerns) to chat. Silent when the PR is all green. Stack-neutral — adapt the toolchain commands to your project.
---

# autofix-ci-push

Sweep CI + bot findings on a freshly-pushed PR. Auto-fix the obvious; surface the rest.

> **Stack-neutral.** The auto-fix actions below name a *formatter*, *linter*,
> *type-checker*, *security scanner* and *test runner* generically. Substitute
> your project's real commands — e.g. `prettier --write` / `eslint`, `gofmt` /
> `go vet`, `black` / `ruff` / `mypy`, `mix format` / `mix credo`. The skill's
> logic (categorise → fix-the-mechanical → surface-the-rest) is the same on any
> stack; only the commands change.

## Hard rules — read first

1. **SILENT WHEN GREEN.** If `gh pr checks <pr>` is all green AND there are no actionable bot findings since the most recent push, output exactly one line: `autofix-ci-push: PR #<n> all green, no findings.` No headings, no tables, no narration of the checks you ran. End of skill.
2. **Don't post PR reviews.** Findings go to chat. Only resolve a bot thread when you've actually fixed the underlying issue or verified it's a false positive — then reply inline and resolve the thread.
3. **No AI attribution.** Commits carry no `Co-Authored-By: Claude`, no "Generated with…", no AI mention.
4. **Bundle auto-fixes into ONE commit per session.** Don't push a separate fix-commit per finding — that's reviewer-noise.
5. **Never `--no-verify`** on commit or push. **Never request `@copilot`** as a reviewer.

## When to invoke (matches `description`)

- User types `/autofix-ci-push [pr-number]`
- A `<system-reminder>` appears in conversation: `AUTOFIX-CI-PUSH ready: a push to branch '<branch>' completed…` (emitted by the surface hook — see Related)
- User asks any natural variant: "check my last push", "is CI green on #X", "what's the bot saying", "anything red on my open PRs"

## Step 1 — Access preflight

Before checking anything, validate that you have the access you need. If any of these fail, **stop and prompt the user** in plain language; do not silently proceed with partial access.

| Need | How to check | If missing → prompt |
|---|---|---|
| GitHub CLI authenticated | `gh auth status` exit 0 and shows `Logged in to github.com` | "GitHub CLI not authenticated — run `gh auth login` and re-invoke." |
| PR API readable | `gh pr view <pr> --json number` returns the number | "Can't read PR #<n> via gh — check repo permissions / `gh auth refresh -s repo`." |
| Ticket system (OPTIONAL — skip if absent) | however your project links a branch to a ticket (Linear/Jira/GitHub Issues) | If unavailable, **continue without ticket context**. Only prompt if the user explicitly asked for ticket cross-reference. |

## Step 2 — Resolve target PR

Pick PR number from, in order:
1. Explicit arg to the skill invocation
2. `<system-reminder>` payload (parse the branch name, then `gh pr list --head <branch> --json number --state open --jq '.[0].number'`)
3. Current branch — `git rev-parse --abbrev-ref HEAD` then same lookup
4. Most recent open PR by user — `gh pr list --author @me --state open --json number,headRefName --limit 5` — present choices if more than one

If no PR found, say so plainly and stop.

## Step 3 — Check CI

```
gh pr checks <pr> --json name,state,conclusion
```

Categorise:
- **all green** (state=COMPLETED, conclusion=SUCCESS for every required check; SKIPPED is fine) → continue to Step 4
- **any in-progress** (state=IN_PROGRESS, QUEUED, PENDING) → output `autofix-ci-push: PR #<n> CI still running — re-check in a few minutes.` and stop. Do not wait. (To wait *without* blocking, arm the background watcher — see "Background watch mode".)
- **any failed** (conclusion=FAILURE / CANCELLED / TIMED_OUT) → record the failing check names with `details_url`; categorise per the auto-fixable table below

## Step 4 — Fetch bot findings

```
gh api repos/<owner>/<repo>/pulls/<pr>/reviews --paginate
gh api repos/<owner>/<repo>/pulls/<pr>/comments --paginate
```

Filter to:
- Reviews+comments authored by bot accounts (`*[bot]` login pattern — notably `cursor[bot]` (Cursor Bugbot), plus known names: `github-actions`, `coderabbitai`, `codeql`, `copilot-pull-request-reviewer`, `snyk-bot`, `dependabot`)
- Newer than the most recent commit on the PR head (`gh pr view <pr> --json commits --jq '.commits[-1].committedDate'`) OR not yet marked resolved
- Exclude any thread whose `isResolved == true` (read via the GraphQL `reviewThreads` query — see Step 6)

## Step 5 — Categorise each finding

Walk through each finding once. Tag with:

### Auto-fixable (do them — bundle into one commit)

| Pattern | Action |
|---|---|
| Formatting flagged by a `--check`/CI formatting gate (spacing, trailing whitespace, missing final newline, quote/import style) | Run your formatter over the affected files (e.g. `prettier --write <files>`, `gofmt -w`, `black`, `mix format`). |
| Unused import / variable / binding flagged by the compiler or linter | Edit the file per the warning — remove the unused import, or rename an unused var to the language's throwaway form (`_`, `_unused`). Re-run the linter / a warnings-as-errors build to confirm. |
| Unambiguous linter readability nit the tool names exactly (import ordering, redundant blank lines, redundant qualifier) | Apply exactly the change the linter names. Even when the linter can't auto-fix, these edits are mechanical. |
| **Verified false positive** — e.g. a SAST warning on a query that's actually parameterized, or a complexity warning on intentional code | **Do NOT edit code.** In Step 6, mark the thread resolved with a reply explaining why it's a false positive. |
| CI gate that requires a docs/changelog update and names the exact file | Make the minimal update the gate specifies. If the required content isn't obvious, **surface instead** — don't guess at docs. |

### Needs-decision (surface, don't fix)

| Pattern | Action |
|---|---|
| Failing tests (unit/integration) | List the failing test names + 1-line cause from the log. Do NOT auto-edit tests or implementation to make them pass. |
| Compile errors, or type-checker / typespec warnings | Surface; fixing types blind is a footgun. |
| SAST / CodeQL **real positive** — SQL injection via raw query, missing auth/tenant scoping (if your app is multi-tenant), hard-coded secret, XSS, CSRF, mass-assignment | Surface with severity + line ref. Never auto-fix security. |
| Design / architecture concerns from review bots (Cursor Bugbot etc.) | Surface as a discussion item. |
| Anything not in the auto-fixable table above | Default to surface. |

If you're not sure whether a finding is in the auto-fixable column, **surface, don't fix**. The cost of asking is small; the cost of a wrong auto-edit is high.

## Step 6 — Apply auto-fixes + mark threads resolved

### Confirm the working tree

Work in-place in the PR's checkout. Confirm:
- the repo is on the PR's head branch (`git rev-parse --abbrev-ref HEAD`), and
- the working tree is clean (`git status --porcelain` is empty).

If either fails — wrong branch, or uncommitted local changes — **abort the auto-fix and surface**. Don't switch branches or stash without asking. (If your workflow runs many PRs in parallel, do the fixes in a `git worktree` so you never disturb the user's current checkout — see "Background watch mode".)

### Make edits + verify

For each auto-fixable finding, edit the file. After all edits, verify with your project's commands — at minimum: formatter, linter, and the tests covering the changed files. For example:

```
<formatter> <changed files>          # e.g. prettier --write … / gofmt -w … / mix format …
<linter>                             # e.g. eslint . / go vet ./... / mix credo
<test runner> <relevant test files>  # e.g. jest path/… / go test ./pkg/… / mix test test/…
```

If tests need services/env (a database, a broker) and they aren't up, either bring them up or skip the local test run and rely on CI — but say which you did. If format + lint + the relevant tests pass, continue. If a test breaks in a way clearly caused by your edit (e.g. you removed an import that was actually used), revert that edit and surface to the user.

### Commit + push (one commit only)

```
git commit -m "$(cat <<'EOF'
<TICKET-or-headline>: Resolve CI bot findings (<bot names>)

- <finding 1 short description>
- <finding 2 short description>
EOF
)"
git push
```

- Prefix the message with the branch's ticket id if your project uses one; otherwise a plain descriptive subject.
- No AI attribution (hard rule 3). No `--no-verify` (hard rule 5).

### Resolve bot threads via GraphQL

For each bot finding you fixed (or verified false positive), resolve its thread:

1. Query thread IDs:

```
gh api graphql -f query='
{
  repository(owner: "<owner>", name: "<repo>") {
    pullRequest(number: <pr>) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          comments(first: 1) { nodes { path, line, body } }
        }
      }
    }
  }
}'
```

2. Match each finding to its thread (by path + line). Skip already-resolved threads.

3. For each match, resolve:

```
gh api graphql -f query='
mutation Resolve($id: ID!) {
  resolveReviewThread(input: { threadId: $id }) {
    thread { isResolved }
  }
}' -F id=<thread-id>
```

4. For verified false positives, post a single explanatory reply on the thread BEFORE resolving:

```
gh api repos/<owner>/<repo>/pulls/<pr>/comments/<comment_id>/replies \
  -f body="False positive — <one-sentence reason>. Resolving."
```

## Step 7 — Surface non-trivial findings

For each Needs-decision finding, produce a concise inline summary in chat:

```
PR #<n> findings (not auto-fixed):

- {file}:{line} — {bot} — {short description}. {why this isn't auto-fixable}.
- ...
```

Don't headings-and-tables this — bullets are fine. Group by severity if more than 3 items.

## Step 8 — Mark queue marker processed

If invoked from a `<system-reminder>` (queue ripening), the surface hook has already moved the marker to `~/.claude/autofix-queue/processed/`. Nothing to do. If invoked manually, skip this step.

## Background watch mode

The skill above runs once, now. If CI is still in-progress and you want to act the moment it resolves *without* polling by hand, arm the background watcher `watch-pr.sh` (next to this file).

**Arm it** with `run_in_background` after a push or when CI is pending:

```
skills/autofix-ci-push/watch-pr.sh <pr> <owner/repo>
```

It polls (default 60s, ~40 min ceiling) and exits — printing what changed to stderr — as soon as any of these becomes true:
- **CI resolves** — every check goes terminal (all pass, or at least one fails),
- **a NEW unresolved review/bot thread appears** (a Bugbot finding, a human comment),
- **the review decision changes** (APPROVED / CHANGES_REQUESTED).

It's check-name **agnostic** (aggregates every check's `bucket`), so it works on any CI provider and survives checks being renamed.

**On wake** (the background task exits → the harness re-invokes you): run this skill's categorise → fix → surface → reply/resolve flow on whatever changed, then **re-arm** the watcher if the PR isn't yet green+approved. Stop re-arming once the PR is green and approved, or the user says stop, or the ceiling is hit.

**Parallel safety:** if you're watching several PRs or the user is mid-edit on the head branch, do the auto-fixes in a dedicated `git worktree` (a separate checkout of the same repo on the PR's branch) so the fix/commit never disturbs the user's working tree. Spawn the fix as a sub-agent scoped to that worktree, then clean it up.

## Output shape examples

**All green:**
```
autofix-ci-push: PR #329 all green, no findings.
```

**Only false positives, all resolved:**
```
autofix-ci-push: PR #329 — 1 bot finding resolved as false positive (src/db/query.go:73 — SAST raw-SQL warning, query is parameterized). No code changes. CI green.
```

**Mix: auto-fixed + surfaced:**
```
autofix-ci-push: PR #329

Auto-fixed in commit abc1234:
- src/auth/user.go:64 — removed unused import `fmt` (linter); ran the formatter on 2 files

Surfaced (your call):
- test/enrolment_test.go:42 — tests failing on a date assertion unrelated to this PR. Investigate before merge.
```

**Access missing:**
```
autofix-ci-push: GitHub CLI not authenticated — run `gh auth login` and re-invoke.
```

## Related

- `hooks/autofix-ci-push-trigger.sh` — PostToolUse hook on Bash; on a successful `git push` it queues a check marker under `~/.claude/autofix-queue/` with a `due_at` ~10 min out.
- `hooks/autofix-ci-push-surface.sh` — UserPromptSubmit hook; ripens due markers and emits the `AUTOFIX-CI-PUSH ready…` `<system-reminder>` that invokes this skill.
- `watch-pr.sh` — the background watcher described under "Background watch mode".
- `SETUP.md` — where each file goes under `~/.claude/`, and the `settings.json` hook-registration snippet.

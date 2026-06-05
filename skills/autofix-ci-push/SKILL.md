---
name: autofix-ci-push
description: After a git push, watch the corresponding GitHub PR to merge-readiness. Checks FOUR axes — CI, merge-state (conflicts / behind-base / blocked), review threads (bot AND human), and review decision — auto-fixes the safely-mechanical bot/CI findings in-place, and surfaces everything else. SILENT WHEN GREEN (all four axes clean). Auto-armed on push via a synchronous PostToolUse hook; also runs on `/autofix-ci-push [pr]`, on an autofix-ci-push `<system-reminder>`, or when the user asks "is CI green / is #N ready / what's the bot saying / watch this PR". Stack-neutral — adapt the toolchain commands to your project.
---

# autofix-ci-push

Watch a freshly-pushed PR all the way to *ship-ready*. Auto-fix the safely-mechanical; surface everything else; stay silent when there's genuinely nothing to do.

> **Stack-neutral.** The auto-fix actions name a *formatter*, *linter*,
> *type-checker*, *security scanner* and *test runner* generically. Substitute
> your project's real commands — e.g. `prettier --write` / `eslint`, `gofmt` /
> `go vet`, `black` / `ruff` / `mypy`, `mix format` / `mix credo`. The logic
> (probe four axes → fix-the-mechanical → surface-the-rest) is identical on any
> stack; only the commands change. **Auto-fixes run only when you can detect the
> repo's toolchain** (a known formatter / linter / test runner); for any repo
> whose toolchain is unknown, do the read-only merge-readiness probe and
> **surface** findings — never auto-edit blind.

## Hard rules — read first

1. **SILENT WHEN GREEN = all four axes clean.** Output exactly one line — `autofix-ci-push: PR #<n> all green, no findings.` — only when **CI** is green for the pushed SHA, **merge-state** is `MERGEABLE/CLEAN`, **zero unresolved threads** (bot or human), and **review decision** is not `CHANGES_REQUESTED`. (Awaiting-review — `REVIEW_REQUIRED` with no changes requested — is *healthy*, so it stays silent too.) No headings, no narration of the checks you ran. End of skill.
2. **Bots: reply + resolve. Humans: reply, NEVER resolve.** Resolve a *bot* thread only once you've fixed it or verified it's a false positive (reply inline, then resolve). For a *human* thread, when a push addresses it, post "Addressed in `<sha>`: …" and leave it **OPEN** for the reviewer to close. Never auto-edit to satisfy human feedback without surfacing it first.
3. **No AI attribution.** Commits carry no `Co-Authored-By`, no "Generated with…", no AI mention.
4. **One commit per fix batch; retry budget = 3.** Bundle a session's auto-fixes into ONE commit. Cap the fix→push→re-check loop at **3 attempts per PR per session**; after the 3rd that doesn't clear the finding, STOP auto-fixing and surface it. Prevents an infinite loop on something the auto-fix can't satisfy.
5. **Never `--no-verify`** on commit or push. **Never request `@copilot`** as a reviewer.

## When to invoke (matches `description`)

- **Auto-armed on push** — the synchronous trigger hook injects `additionalContext` after a `git push`, telling you to arm watch mode for the branch's PR. Do it (it's one non-blocking background call).
- A `<system-reminder>` appears: `AUTOFIX-CI-PUSH ready/fallback: … branch '<branch>' …`
- User types `/autofix-ci-push [pr-number]` (one-shot) or asks to **watch / monitor** a PR → watch mode.
- User asks any natural variant: "is CI green on #X", "is #N ready to merge", "what's the bot saying", "any conflicts / am I behind main", "anything red on my open PRs", "tidy the stale / already-fixed bot threads on #N".

## Step 1 — Access preflight

If any of these fail, **stop and prompt the user**; don't proceed with partial access.

| Need | How to check | If missing → prompt |
|---|---|---|
| GitHub CLI authenticated | `gh auth status` exit 0, shows `Logged in to github.com` | "GitHub CLI not authenticated — run `gh auth login` and re-invoke." |
| PR API readable | `gh pr view <pr> --repo <owner/repo> --json number` returns the number | "Can't read PR #<n> via gh — check repo permissions / `gh auth refresh -s repo`." |
| Ticket system (OPTIONAL) | however your project links a branch to a ticket (Linear / Jira / GitHub Issues) | If unavailable, **continue without ticket context**. |

## Step 2 — Resolve target PR + repo

PR number, in order: (1) explicit arg / reminder payload; (2) current branch — `gh pr list --head "$(git rev-parse --abbrev-ref HEAD)" --state open --json number --jq '.[0].number'`; (3) most recent open PR by you — `gh pr list --author @me --state open --json number,headRefName --limit 5` (present choices if >1). Resolve `<owner/repo>` with `gh repo view --json nameWithOwner --jq .nameWithOwner`. If no PR found, say so plainly and stop.

**Toolchain gate:** auto-fix is enabled only if you can identify the repo's formatter / linter / test commands (from project config — `package.json`, `go.mod`, `pyproject.toml`, `mix.exs`, a Makefile, etc.). Otherwise this run is **surface-only** (probe + report, no edits).

## Step 2.5 — Merge-readiness probe (the four axes)

One read of the PR's gate state, plus checks pinned to the pushed commit:

```
gh pr view <pr> --repo <owner/repo> --json \
  mergeable,mergeStateStatus,reviewDecision,reviewRequests,isDraft,state,headRefOid
gh pr checks <pr> --repo <owner/repo>   # check runs for the head commit
```

Build the four axes:

1. **CI** — pin to the pushed SHA. `gh pr checks` reads the head commit's runs, but right after a push the new commit's checks may not exist yet — you'd see the *prior* commit's green, or an empty set. If the required checks haven't all reported for `headRefOid`, treat CI as **PENDING** (not green) and let the watcher catch completion.
2. **Merge-state** — `mergeable` + `mergeStateStatus`. **`mergeable` is computed asynchronously**: right after a push it reads `UNKNOWN` until GitHub recomputes. If either is `UNKNOWN`, do NOT conclude "no conflicts" — re-poll a few seconds apart (≤5 tries), or defer to the watcher. Once known: `CLEAN` = good; `DIRTY`/`CONFLICTING` = merge conflicts; `BEHIND` = behind base (needs sync); `BLOCKED` = branch protection not satisfied (required reviews / checks / code-owners / conversation-resolution); `UNSTABLE` = a non-required check is red; `DRAFT` = draft PR.
3. **Threads** — unresolved review threads via GraphQL (Step 6 query). Count **bot and human**; outdated threads don't count as blocking.
4. **Reviews** — `reviewDecision`: `APPROVED` / `CHANGES_REQUESTED` / `REVIEW_REQUIRED` (or null = none required).

→ If all four are clean per Hard Rule 1, you're done (silent line). Otherwise continue.

## Step 3 — Triage CI

- **green** for the pushed SHA → fine.
- **in-progress** → don't block on it here; the watcher fires when it resolves. (One-shot mode: report "CI still running" and stop.)
- **failed** → record failing check names + `details_url`; categorise per the tables below.

## Step 4 — Fetch findings (split: bots vs humans)

```
gh api repos/<owner>/<repo>/pulls/<pr>/reviews --paginate
gh api repos/<owner>/<repo>/pulls/<pr>/comments --paginate
```

- **4a — Bots.** `*[bot]` logins — notably `cursor[bot]` (Cursor Bugbot), plus `github-actions`, `coderabbitai`, `codeql`, `copilot-pull-request-reviewer`, `snyk-bot`, `dependabot`. → run through auto-fix categorisation (Step 5).
- **4b — Humans.** Every other reviewer. → **always route to surface** (Step 7). When a push you make plausibly addresses one, reply on the thread; **never resolve it**.

Scope to threads newer than the last head commit OR still unresolved; skip `isResolved == true`.

## Step 5 — Categorise each BOT/CI finding

### Auto-fixable (toolchain-known repo only — bundle into one commit)

| Pattern | Action |
|---|---|
| Formatting (a `--check` formatter gate or a format CI check) | Run your formatter over the affected files (`prettier --write`, `gofmt -w`, `black`, `mix format`, …). |
| Unused import / variable / binding (compiler or linter warning) | Remove the unused import, or rename an unused var to the language's throwaway form (`_`). Confirm with a warnings-as-errors build / the linter. |
| Unambiguous linter readability nit the tool names exactly (import ordering, redundant blank lines, redundant qualifier) | Apply exactly the change the linter names — mechanical even when the linter can't auto-fix it. |
| CI gate that requires a file update and names the exact file (changelog, a generated manifest, a registration list) | Make the minimal update the gate specifies. If the required content isn't obvious, **surface instead** — don't guess. |
| **Verified false positive** — e.g. a SAST warning on a query that's actually parameterized | **Do NOT edit code.** In Step 6, reply explaining why, then resolve the (bot) thread. |

### Needs-decision (surface, never auto-fix)

| Pattern | Action |
|---|---|
| Failing tests | List failing test names + 1-line cause. Never auto-edit tests/impl to force a pass. |
| Compile errors, type-checker / typespec warnings | Surface; blind type-fixing is a footgun. |
| SAST / CodeQL **real positive** — SQL injection via raw query, missing auth / tenant scoping (if your app is multi-tenant), hard-coded secret, XSS, CSRF, mass-assignment | Surface with severity + line. Never auto-fix security. |
| Any **human** comment (4b), or design / architecture concern from a bot | Surface. Humans never get auto-resolved. |
| Anything not in the auto-fixable table | Default to surface. |

If unsure → **surface, don't fix**.

## Step 6 — Apply auto-fixes + resolve / reconcile BOT threads

> Only the **edit + commit** parts below need a known toolchain. The **thread resolution and the stale-clean sweep are read-only + GraphQL — they run in *any* repo** (including surface-only ones), since they never touch code.

**Confirm the working tree.** On the PR's head branch (`git rev-parse --abbrev-ref HEAD`) and clean (`git status --porcelain` empty)? If not — wrong branch or dirty tree — **abort the auto-fix and surface**; don't switch/stash without asking. (If you can't safely use the main tree — e.g. you're watching several PRs at once — run the fix in a dedicated `git worktree` via a sub-agent.)

**Edit + verify.** For each auto-fixable finding, edit the file. After all edits, run your project's verify commands — at minimum formatter, linter, and the tests covering the changed files:

```
<formatter> <changed files>          # e.g. prettier --write … / gofmt -w … / mix format …
<linter>                             # e.g. eslint . / go vet ./... / mix credo
<test runner> <relevant test files>  # e.g. jest path/… / go test ./pkg/… / mix test test/…
```

If tests need services/env (a database, a broker) and they aren't up, either bring them up or skip the local run and rely on CI — but **say which you did**. If a test breaks from your edit, revert that edit and surface.

**Commit + push (one commit; respect the retry budget):**

```
git commit -m "$(cat <<'EOF'
<ticket-or-headline>: Resolve CI bot findings (<bots>)

- <finding 1>
- <finding 2>
EOF
)"
git push
```

Prefix with the branch's ticket id if your project uses one. No AI attribution; no `--no-verify`. Your push re-arms the trigger → the watcher re-baselines automatically.

**Resolve threads (BOTS only):**

```
gh api graphql -f query='{ repository(owner:"<owner>",name:"<repo>"){ pullRequest(number:<pr>){
  reviewThreads(first:100){ nodes{ id isResolved isOutdated comments(first:1){ nodes{ path line body author{login} } } } } } } }'
```
Match each fixed bot finding to its thread (path+line), skip resolved, then:
```
gh api graphql -f query='mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' -F id=<thread-id>
```
For a verified false positive, reply first: `gh api repos/<owner>/<repo>/pulls/<pr>/comments/<comment_id>/replies -f body="False positive — <reason>. Resolving."`
For a **human** thread you addressed: reply `"Addressed in <sha>: <what changed>."` and **stop — leave it open.**

### Reconcile stale-clean bot threads (sweep)

Some **bot** threads are unresolved only because the issue was already addressed — a prior commit, a teammate, an earlier session — and nobody clicked resolve. This sweep tidies those. It runs **even when this session made zero auto-fixes, and in surface-only repos** — it's read-only + GraphQL and never edits code.

Reuse the `reviewThreads` query above (note the `isOutdated` field). For each thread where `isResolved == false`, the comment's `author.login` matches `*[bot]`, and it wasn't just resolved by the fix step:

1. **Re-read current HEAD** at the thread's `path:line` (widen to the enclosing function if `isOutdated == true` — the anchor may have shifted).
2. Classify against the bot's original concern:
   - **Demonstrably addressed** (flagged construct gone/changed, or the suggested fix is now present) → reply, then resolve:
     ```
     gh api repos/<owner>/<repo>/pulls/<pr>/comments/<comment_id>/replies -f body="Resolved in <sha> — <what now stands at path:line>."
     gh api graphql -f query='mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' -F id=<thread-id>
     ```
   - **Still live** (concern still applies) → hand to Step 5 → fix-or-surface like any other finding.
   - **Ambiguous / can't confirm** → leave OPEN and surface it: `stale? <path:line> — <bot> — <concern>; verify before resolving.`

**Guardrails:** bots only (humans are never swept). High-confidence resolves only — **default to surface**. `isOutdated` is a hint, not proof (a moved line ≠ an addressed concern). Always cite the `<sha>` + what now stands in the reply so the resolution is auditable.

## Step 7 — Surface + ship-readiness footer

List needs-decision items (bullets, group by severity if >3):

```
PR #<n> findings (not auto-fixed):
- {file}:{line} — {who} — {desc}. {why not auto-fixable}.
```

Then **always** end a non-silent report with a one-line readiness footer covering all four axes, e.g.:

```
Not ship-ready: behind base by 3 commits; 2 unresolved threads (alice #12, cursor[bot] #14); CI green; reviewDecision: CHANGES_REQUESTED.
```

When the user explicitly asks "is #N ready/mergeable", give the **ship-ready verdict** (merge bar = CI green ∧ MERGEABLE/CLEAN ∧ zero unresolved threads ∧ reviewDecision APPROVED):

```
Ship-ready ✅ PR #329 — CI green · no conflicts · in sync with base · 0 unresolved · APPROVED.
```

## Step 8 — Marker housekeeping

On arming the watcher (or finishing a one-shot triggered by a push), move the branch's marker from `~/.claude/autofix-queue/*.pending` to `processed/` so the surface fallback doesn't re-fire.

## Watch mode — autonomous poll → fix → re-arm

The trigger hook *arms* you; `watch-pr.sh` does the actual continuous monitoring on a background thread and pulls you back the moment something is actionable. A background bash task can only **observe** — it can't edit/commit — so: **watch-pr.sh watches; you fix on wake.**

### Arming

First run **Steps 2.5–7 once** so the watcher's baseline is an already-triaged snapshot (else it won't fire on findings that already exist). Then, via Bash with `run_in_background: true`:

```
~/.claude/skills/autofix-ci-push/watch-pr.sh <pr> <owner/repo>
```

It polls every 60s and exits (re-invoking you) the instant, vs its launch baseline:
- **CI** resolves (pending → pass/fail, aggregated across all checks),
- a **new** unresolved thread appears (bot or human),
- the **review decision** changes,
- the **merge-state** becomes actionable (`DIRTY`/`CONFLICTING`, `BEHIND`, `BLOCKED`, `UNSTABLE`) or recovers to `CLEAN` (UNKNOWN is ignored — async, not yet computed).

Otherwise silent; self-expires after ~40 min (`WATCH-PR IDLE`).

### On wake

Read the `<task-notification>`'s output file, then run **Steps 2.5–7** on what it flagged — CI red → fix auto-fixable, surface rest; new bot thread → categorise → fix-or-surface → reply+resolve; new human thread / `CHANGES_REQUESTED` → surface; `BEHIND` → sync the base branch in (merge, don't rebase, unless your project says otherwise) and surface only if it conflicts; `DIRTY` → surface the conflicting files (don't auto-resolve). Then **re-arm** watch-pr.sh.

### If you're mid-task when woken — worktree sub-agent

A wake queues (won't clobber in-flight work). If you're deep in unrelated work, hand Steps 2.5–7 to a **worktree-isolated** sub-agent (NOT a bash thread — bash can't edit/commit):

```
Run the autofix-ci-push flow for PR #<pr> (<owner/repo>) on what watch-pr.sh flagged: <reason>.
Auto-fix only the mechanical findings (formatter / linter / unused import / a named-file CI gate)
AND only if the repo's toolchain is known; else surface. Verify (formatter + relevant tests + linter),
commit with NO AI attribution, push with `git push origin HEAD:<branch>` (HEAD: form avoids clashing
with the main tree's checkout). Reply+resolve bot threads you fix; reply-only on human threads.
Respect a 3-attempt cap. Return: what you fixed, the commit SHA, and anything needing surfacing.
```

Relay its summary, surface needs-decision items, **re-arm**. When free at wake time, just handle inline.

### When to STOP re-arming

Stop (say so in one line) when any holds:
- PR **merged or closed** (`gh pr view <pr> --json state,merged`).
- **Ship-ready** — APPROVED + CI green + `MERGEABLE/CLEAN` + zero unresolved threads. Terminal-good.
- `WATCH-PR IDLE` twice running with the PR stable → pause: "watch paused — push or ping me to resume" (a new push re-arms via the hook).
- Retry budget (3) exhausted on a finding the auto-fix can't clear → surface and stop.

All hard rules hold in watch mode — especially **SILENT WHEN GREEN** and **one commit per fix batch**.

## Output examples

**All green:** `autofix-ci-push: PR #329 all green, no findings.`

**Toolchain-known: auto-fixed + surfaced + footer:**
```
autofix-ci-push: PR #329
Auto-fixed in commit abc1234:
- src/auth/user.go:64 — removed unused import `fmt` (linter); ran the formatter on 2 files
Surfaced (your call):
- test/enrolment_test.go:42 — tests failing on a date assertion. Investigate before merge.
Not ship-ready: CI red (1 check); behind base by 2; reviewDecision: REVIEW_REQUIRED.
```

**Surface-only repo (toolchain unknown):**
```
autofix-ci-push: PR #41 — surface-only (toolchain not detected).
- CONFLICTING/DIRTY: merge conflicts vs base — resolve locally.
- cursor[bot] flagged 1 issue (src/auth.ts:88). Your call.
```

## Related
- `hooks/autofix-ci-push-trigger.sh` — **synchronous** PostToolUse(Bash) hook; on a successful `git push` it resolves the PR and injects an `additionalContext` instruction to arm the watcher (and writes a queue marker as the fallback record).
- `hooks/autofix-ci-push-surface.sh` — UserPromptSubmit hook; the fallback reminder if the watcher was never armed.
- `watch-pr.sh` — the background watcher described under "Watch mode".
- `SETUP.md` — where each file goes under `~/.claude/`, and the `settings.json` hook-registration snippet.

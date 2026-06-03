---
name: new-gate
description: Scaffold a Claude Code memory+skill+hook trio for a new behavioural rule. Interactive — walks through the rule, the gated tools, the motivation, then runs `bin/new-claude-gate` to generate the four artefacts. Use when adopting the gate pattern in a new repo, onboarding a new client, or adding a new rule alongside existing ones.
---

# /new-gate

Scaffold a new memory + skill + hook trio for Claude Code, following the
[claude-gates-pattern](../../docs/claude-gates-pattern.md) (single-flag handoff
between skill and hook, single-use flag, MCP+Bash matchers).

This skill is the interactive front-end for `bin/new-claude-gate`. Use it when:

- adopting the gate pattern in a brand-new repo or client environment
- adding a new rule alongside the ones already wired (e.g. `short`, `claim-verification`, `link-presence`)
- demonstrating the pattern to a teammate

For repeat / scripted use, call `bin/new-claude-gate` directly with flags.

## Invocation

```
/new-gate
/new-gate --dry-run         # show what would be generated, write nothing
/new-gate --target /tmp/x   # generate into a sandbox dir (for testing)
```

## Walkthrough

Conduct a 4-question interview to fill in the required fields:

### 1. Rule name (kebab-case)

> Examples: `short-drafts`, `pii-redact`, `claim-verification`, `link-presence`, `pr-resolve-before-merge`.

Constraints: lowercase letters, digits, hyphens only; starts with a letter.

### 2. One-line description (for the skill frontmatter)

> Examples:
> - "Paraphrase outbound messages into a long+short pair before sending."
> - "Redact PII (emails, SSNs, phone numbers) from outbound messages."
> - "Verify every factual claim is cited or hedged before publishing."

Used in `description:` of the generated skill's frontmatter. Should make the
skill discoverable to future-Claude searching for relevance.

### 3. The "why"

> Examples:
> - "Aude flagged on PR #1293 that messages are too verbose."
> - "Customer 2026-04-22 incident: PII leaked in a Slack DM during PR walkthrough."
> - "Reviewer kept asking for a TL;DR; we now require one upfront."

The motivation — ideally quoting the incident, person, or feedback that
prompted the rule. Goes into the memory file's **Why** section. Without it
the agent has no anchor for edge cases.

### 4. Gated tools

Comma-separated. Each entry is either:

- A full MCP tool name, e.g. `mcp__slack-multiverse__slack_send_message`
- `Bash:<regex>` for shell commands, e.g. `Bash:gh pr comment` or `Bash:gh api[^|;&]*-X[[:space:]]+POST[^|;&]*/comments`

Tip: list the tools that would actually trigger the rule. Don't gate `Read` /
`Edit` / draft-create tools — those aren't the moment the rule applies. Gate
the *send* / *publish* / *commit* / *deploy* moments.

Common destinations and their tool names:

| Channel | Tool name |
|---|---|
| Slack send | `mcp__slack-multiverse__slack_send_message` |
| Slack scheduled send | `mcp__slack-multiverse__slack_schedule_message` |
| Slack draft (NOT gated by default) | `mcp__slack-multiverse__slack_send_message_draft` |
| GitHub PR comment | `Bash:gh pr comment` |
| GitHub PR review (any) | `Bash:gh pr review` |
| GitHub issue comment | `Bash:gh issue comment` |
| GitHub API POST (PR/issue comments/reviews) | `Bash:gh api[^\|;&]*-X[[:space:]]+POST[^\|;&]*/(issues\|pulls)/[0-9]+/(comments\|reviews)` |
| Linear comment | `mcp__linear-server__save_comment` |
| Coda comment | `mcp__Coda__comment_add` |
| Jira comment | `mcp__atlassian__addCommentToJiraIssue` |
| Confluence comment | `mcp__atlassian__createConfluenceFooterComment` |

## After collecting answers

Run the CLI:

```bash
~/projects/claude-autonomous-pipeline/bin/new-claude-gate \
  --name "<answer-1>" \
  --desc "<answer-2>" \
  --why "<answer-3>" \
  --gated "<answer-4>" \
  ${DRY_RUN:+--dry-run}
```

The CLI generates:
- `~/.claude/memory/feedback_<name>.md` — memory rule
- `~/.claude/skills/<name>/SKILL.md` — skill (placeholder content, customise after)
- `~/.claude/hooks/<name>-gate.sh` — hook (executable, syntax-checked)
- patches `~/.claude/settings.json` — wires the hook (with `.bak.<ts>` backup)
- appends to `~/.claude/memory/MEMORY.md` — index entry

## After the CLI runs

Show the user:
1. The four file paths created.
2. The matcher pipe-list (so they see what's gated).
3. The flag path (`/tmp/claude-<name>.flag`).
4. **Next steps**:
   - Open the skill file and fill in the placeholder sections (what to produce, modes, post-send cleanup).
   - Expand the memory file's scope/exclusions sections.
   - Restart Claude Code so the new hook + skill are picked up.

## Smoke test (offer to run)

After the CLI returns, offer:

> Want me to smoke-test the hook? I'll trigger one of the gated tools without setting the flag (should block) and then with the flag (should pass + consume).

If yes:
```bash
echo '{"tool_name":"<one-of-the-gated-mcp-tools>","tool_input":{}}' \
  | bash ~/.claude/hooks/<name>-gate.sh
# expect: exit 2, "GATE blocked" message on stderr

touch /tmp/claude-<name>.flag
echo '{"tool_name":"<same>","tool_input":{}}' \
  | bash ~/.claude/hooks/<name>-gate.sh
# expect: exit 0, flag consumed
```

## What this skill does NOT do

- Customise the generated skill body — that's still on the user. The CLI
  fills in the structural sections (frontmatter, flag-handoff, destinations
  table) but leaves the "What to produce" section as a placeholder
  because the actual workflow is rule-specific.
- Validate that the rule is well-scoped. If the user gates too broadly (e.g.
  `Bash` with no pattern), the hook will fire on every Bash command.
  Surface this risk during the interview.
- Generate Linear / Coda / Jira drafts for *what* the skill should do. That
  remains the human's design call.

## Related

- `bin/new-claude-gate` — the underlying CLI scaffold.
- `docs/claude-gates-pattern.md` — the pattern doc this skill implements.
- `~/.claude/skills/short/PATTERN.md` — the canonical pattern reference.
- Existing gates that follow this pattern: `short-draft-gate`, `claim-verification-gate`, `link-presence-gate` (all in `~/.claude/hooks/`).

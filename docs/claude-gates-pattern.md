# Pattern: Memory + Skill + Hook (with single-use flag handoff)

A reusable design pattern for enforcing a behavioural rule on Claude Code that the agent **can't reliably remember on its own**. Worked example: forcing every outbound human-facing message through a `/short` paraphrase step.

This doc is the reference for the **`bin/new-claude-gate`** CLI and the **`/new-gate`** interactive skill in this repo. Both generate the same four artefacts; the CLI is faster for repeat use, the skill is friendlier for the first time.

```bash
# Repeat / scripted use
bin/new-claude-gate --name <slug> --gated <list> --why "<text>" --desc "<text>"

# First-time / interactive
# (from a Claude Code session)
/new-gate
```

---

## When to use this pattern

Reach for this trio when the rule meets all three:

1. **Behavioural, not mechanical.** The rule is "always X before Y" — not a code refactor.
2. **High cost of a single miss.** A reviewer / customer / production system bears the cost when the rule is skipped.
3. **The agent has *some* control over compliance**, i.e. it's the agent's tool call that triggers Y. (If Y happens outside the agent's tool surface, a hook can't see it.)

Counter-examples:
- *"Use camelCase for new variable names."* → pure memory rule, no hook needed (the cost of a miss is trivial and humans review code anyway).
- *"Don't ever commit to main."* → branch protection on GitHub is better than a Claude hook.
- *"Translate every doc to French before publish."* → if "publish" is outside Claude's tool surface, no hook can gate it.

---

## The three components and what each one does

```
┌────────────────────────────────────────────────────────────────────────────┐
│  MEMORY rule (markdown, loaded into context)                               │
│  "Before doing X, invoke /skill-name first."                               │
│  ↓ shapes intent — agent reads it every session                            │
├────────────────────────────────────────────────────────────────────────────┤
│  SKILL (markdown prompt, user-invocable)                                   │
│  Does the actual work — produces artefacts, sets the gate flag, runs send  │
│  ↓ encapsulates the workflow — easy to edit, easy to call                  │
├────────────────────────────────────────────────────────────────────────────┤
│  HOOK (shell script, PreToolUse)                                           │
│  Checks for the flag on the gated tool call — blocks if missing, consumes  │
│  ↓ enforces compliance — agent cannot skip without explicit bypass         │
└────────────────────────────────────────────────────────────────────────────┘
        │
        └── single-use flag at /tmp/<rule>-<verb>.flag glues skill → hook
```

| Layer | What it can do | What it can't do |
|---|---|---|
| **Memory** | Shape intent, communicate why, reference related rules. Survives session restarts (loaded fresh). | Force compliance. Survive a careless skip. Trigger reliably under compaction. |
| **Skill** | Encapsulate a multi-step workflow as one invocation. Take args. Reference patterns. Easy to iterate. | Fire automatically — only runs when invoked. |
| **Hook** | Block tool calls. Inject remediation text. Read tool arguments. Fire deterministically. | Generate content. Reason about intent. Survive being commented out (it's just a script). |

**The flag is the glue.** It's the only way the skill tells the hook "this send has been blessed". Without it, the three components are independent: memory hopes the skill is called, the skill is voluntary, the hook gates blindly. With it, you have a real workflow.

---

## Why the flag is single-use

Two reasons:

1. **One send per blessing.** If the skill blesses one send and the flag persisted, a second unrelated send 30 turns later would inherit the blessing. Single-use closes that.
2. **Auditable.** Each send carries one explicit "skill ran for this send" decision. No quiet drift where the agent learns to set the flag once at session start and forget about it.

Pattern: hook consumes (`rm -f`) the flag on the matched call. Skill touches it immediately before the next send tool call, in a separate tool invocation (so the touch isn't part of the gated command's arg string).

---

## Reference implementation

### 1. Memory rule — `~/.claude/memory/feedback_<rule-name>.md`

```markdown
---
name: <rule-slug>
description: <one-line summary of when to invoke /skill>
metadata:
  type: feedback
---

Before doing <X>, invoke `/skill-name` first.

**Why:** <the incident or preference that motivated this rule — link to a PR comment, Slack message, etc.>

**How to apply:**
1. <step 1>
2. <step 2 — invoke /skill-name>
3. <step 3 — the skill sets /tmp/<rule>-<verb>.flag and triggers the send>
4. <hook verifies the flag>

**Scope:** <where this fires — tools, channels, contexts>

**Where this rule does NOT fire:** <exclusions — internal tools, drafts, edits, etc.>

**Don't game the rule:** <anti-pattern to call out — the obvious "I'll just skip the skill if X" excuse>

Related: [[other-rule]]
```

Then add a one-line entry to `~/.claude/memory/MEMORY.md`:

```markdown
- [<title>](feedback_<rule-name>.md) — <one-line hook>
```

### 2. Skill — `~/.claude/skills/<skill-name>/SKILL.md`

```markdown
---
description: <one-line — used when the agent decides relevance>
argument-hint: "[--flags]"
---

# /<skill-name> — <one-line headline>

## Pre-condition
<what must exist before this skill runs — usually a tempfile with input>

## What to produce
<artefacts: side-by-side drafts, a structured report, etc.>

## Modes (flag arguments)
<no flag / --auto / --collapsed / ...>

## The flag handoff (CRITICAL)
Immediately before the send tool call, run:
\`\`\`bash
touch /tmp/<rule>-<verb>.flag
\`\`\`
The PreToolUse hook consumes this flag on the next gated send. Single-use.

## Destination → send-tool reference
<table mapping channels to MCP/Bash tools>

## After sending
<cleanup>

## Edge cases
<known awkward situations and how to handle them>
```

### 3. Hook — `~/.claude/hooks/<rule>-gate.sh`

```bash
#!/usr/bin/env bash
# <one-line purpose>
#
# Wiring: ~/.claude/settings.json PreToolUse, matcher includes the gated tool list.
# Skill: ~/.claude/skills/<skill-name>/SKILL.md
# Memory: ~/.claude/memory/feedback_<rule>.md

set -uo pipefail

FLAG=/tmp/<rule>-<verb>.flag

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

# --- allowlist: which tool calls require the flag ---
GATED=false
case "$TOOL" in
  mcp__<server>__<tool1>|mcp__<server>__<tool2>)
    GATED=true
    ;;
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
    if printf '%s' "$CMD" | grep -qE '<bash-command-regex>'; then
      GATED=true
    fi
    ;;
esac

if ! $GATED; then exit 0; fi

# --- flag check ---
if [[ -f "$FLAG" ]]; then
  rm -f "$FLAG"   # single-use; consume
  exit 0
fi

# --- blocked: emit remediation ---
cat >&2 <<EOF
<RULE-NAME> GATE blocked this publish.

<one-line why this gate exists>

Before re-issuing this tool call:
  1. <prep step — usually write something to a tempfile>
  2. Invoke /<skill-name>
  3. The skill produces <artefacts>, touches \$FLAG, then calls this send tool.

Bypass (only for legitimately exempt cases):
  Run Bash: touch \$FLAG
The flag is single-use; this hook deletes it on consume.
EOF
exit 2
```

Make it executable: `chmod +x ~/.claude/hooks/<rule>-gate.sh`

### 4. Wire it — `~/.claude/settings.json`

Add a new entry to `.hooks.PreToolUse` array. Mirror the matcher pattern of existing hooks:

```json
{
  "matcher": "mcp__<server>__<tool1>|mcp__<server>__<tool2>|Bash",
  "hooks": [
    {
      "type": "command",
      "command": "/Users/<you>/.claude/hooks/<rule>-gate.sh",
      "timeout": 10
    }
  ]
}
```

The `matcher` is a `|`-separated regex of tool names. Order doesn't matter; they're independent matches. Include `Bash` if any of your gated calls go through it (e.g. `gh pr comment`); the hook itself inspects `tool_input.command` to narrow Bash matches.

---

## How to port this to another client repo

The pattern is portable; the **content** is per-client. Recipe:

1. **Identify the rule.** What behavioural thing keeps slipping? Get specific — "verbose Slack messages" isn't actionable; "Slack DMs to reviewers exceed 200 chars and they've complained twice" is.
2. **Identify the trigger.** Which tool calls happen at the moment of compliance/violation? Slack send, gh comment, an MCP tool, a Bash command? List them.
3. **Author the memory rule.** Markdown, ~30–50 lines. Include the why (reference the incident), how, and don't-game-it section.
4. **Author the skill.** Markdown, ~100–200 lines. Heading sections: Pre-condition, What to produce, Modes/Flags, Flag handoff (CRITICAL), Destination → tool reference, After sending, Edge cases.
5. **Author the hook.** Bash, ~50–100 lines. Match the tool name set from step 2; check `Bash.command` for any shell-tool patterns.
6. **Wire the hook** in `~/.claude/settings.json` PreToolUse.
7. **Test it** — try to violate the rule. The hook should block. Invoke the skill. The send should go through.

Total time to adopt: roughly 60–90 minutes once you've done it once.

---

## Anti-patterns

- **Memory rule without a hook.** Drifts in a couple weeks. The whole point of the hook is to be the discipline you can't sustain.
- **Hook without a skill.** Hook blocks with a generic "do X" message, agent struggles to remediate inline, the loop is awkward. The skill is the *named workflow* the hook points at.
- **Multi-use flag.** Once the flag persists across sends, you've lost the audit trail. Make it single-use.
- **Flag in the same Bash command as the send.** `touch flag && gh pr comment ...` — the hook reads the command string and gates before the touch fires. Use separate Bash tool calls.
- **Generic remediation text.** "This tool call was blocked." doesn't help the agent recover. Tell it exactly which skill to invoke and where the tempfile lives.
- **Hook that generates content.** Hooks are pre-tool guards, not content producers. If you find yourself shelling out to an LLM inside the hook, you've conflated layers. Move the content work to the skill.
- **Skipping the memory rule because "the hook will catch it anyway".** The memory rule is what gets the skill invoked in the *first* place; the hook is the backstop. Without memory, the agent will sit forever waiting for permission instead of just running `/skill`.

---

## Versioning / maintenance

- Treat the skill as the canonical workflow doc. Edit it freely; iteration is cheap.
- Treat the memory rule as the canonical "why we do this" doc. Edit it when the underlying concern shifts.
- Treat the hook as **infrastructure** — edit carefully, test the matcher patterns. A broken hook either blocks everything (annoying) or gates nothing (silent regression).
- Run the matcher-regex through a quick sanity check after edits: `bash -n ~/.claude/hooks/<rule>-gate.sh` for syntax, and one mock invocation through `echo '{"tool_name":"...","tool_input":{...}}' | bash ~/.claude/hooks/<rule>-gate.sh` to confirm the gate triggers.

---

## Examples in this repo

- **`/short` skill** (this file's sibling) — paraphrase before sending. Worked example.
- **`claim-verification-gate.sh`** — claims must be cited or marked hedged before publish.
- **`link-presence-gate.sh`** — every #NNNN / TICKET-NNNN reference in outbound text must carry its URL.

All three share the flag-handoff shape; only the content differs.

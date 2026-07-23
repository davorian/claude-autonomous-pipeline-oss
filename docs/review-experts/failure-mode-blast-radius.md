---
id: failure-mode-blast-radius
label: "Failure mode + blast radius — per finding, what breaks and who notices"
when: always
blast_radius: n/a
reversibility: n/a
---

# Expert: failure-mode-blast-radius (meta-lens, always-on)

Applies to every High finding — and every merge-blocking Medium — that any other lens
surfaces. It is what forces a finding to be load-bearing rather than surface-level.

## The core prompt

For each such finding, answer three questions *in the finding body*:

1. **What breaks?** — the concrete failure mode. Not "this could fail" but "if X, then
   Y silently returns the wrong value" or "then the write rolls back and the caller sees
   a 500".
2. **Who notices?** — a log line? a user-visible error? a CI check? Or does it fail
   silently (the worst case)? If silent, name the observability gap as its own
   sub-finding.
3. **Blast radius** — one row, one user, one tenant, or everyone? Reversible via retry /
   follow-up fix, or does it corrupt data that needs a manual backfill?

## Weighting rule

Any finding where the answer to (2) is "no one notices" OR (3) is "corrupts data that
needs a backfill" is automatically **High** — regardless of how the surfacing lens
graded it.

## Confidence marker

Tag each High finding with confidence:

- `[conf: high]` — reproduced, or the mechanism is fully understood.
- `[conf: medium]` — read the code, mechanism is plausible but not reproduced.
- `[conf: low]` — a smell worth investigating; may be a false positive.

Confidence gates the remediation verb: `high` → "must fix"; `medium` → "please confirm";
`low` → "consider / flag for the author".

## Failure-mode patterns worth grepping for (tech-agnostic)

- Silent truncation or rounding that loses data.
- Catch-all handlers that swallow and continue (`catch {}`, `rescue nil`,
  `EXCEPTION WHEN OTHERS`).
- A guard or validation predicated on a value that can be null.
- A bulk UPDATE / DELETE with no WHERE clause.
- A fetch loop firing N queries per parent row (N+1).

## Falsifiability

This lens exists to force testability. If you can't answer (1) / (2) / (3) concretely,
the finding is a taste preference — downgrade or drop it. Pairs with the
empirical-finding gate.

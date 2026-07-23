---
id: historical-precedent
label: "Historical precedent — match the diff against the project's known-findings catalogue"
when: always
blast_radius: n/a
reversibility: n/a
---

# Expert: historical-precedent (cross-cutting, always-on)

Before deriving a bug from scratch, check whether its *class* is already documented for
this project. Recurring mistakes tend to have a known signature and a known fix.

## Procedure

1. Identify the project's known-findings catalogue, if it has one — e.g.
   `docs/common-review-findings.md`, a `.cursor/BUGBOT.md`, a `REVIEW*.md` log, or the
   repo review rules already loaded into this prompt.
2. Skim the diff for keywords that match catalogue entries (framework foot-guns, query
   patterns, migration hazards, the project's recurring mistakes).
3. If the diff reproduces a documented class, cite the entry ("see `<catalogue>#<slug>`
   — the standard fix is X") instead of re-deriving the finding from scratch.
4. If the diff *avoids* a documented pitfall by using the standard pattern, note it under
   Strengths — it reinforces the pattern.
5. If the diff exposes a class **not** in the catalogue, flag it under a "Catalogue
   candidate" bullet so the catalogue grows.

## Why

Avoids re-work (the fix is often already written down), prevents re-inventing
terminology for the same issue, and feeds the catalogue forward so the next review is
cheaper.

## Falsifiability

Cite the catalogue entry. If there is no matching entry, say so explicitly ("no matching
entry — candidate for addition").

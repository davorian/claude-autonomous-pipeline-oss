---
id: absence-lens
label: "Absence lens — what's missing that the diff implies"
when: always
blast_radius: high
reversibility: varies
---

# Expert: absence-lens (cross-cutting, always-on)

Every other lens asks *"is what's in the diff correct?"* This one asks *"what's NOT
in the diff that should be?"* Absence bugs slip through review because they don't
exist on the page to be read.

## Questions

1. **Schema ↔ code coherence** — does the code reference a table / column / field /
   RPC the migration doesn't add? Or the reverse: a migration adds a column no code
   reads?
2. **New-entity completeness** — a new table / model / endpoint / resource without the
   project's "done" checklist: access control or authorization, an index on every
   foreign key, a matching generated type, audit / logging where siblings have it?
3. **Test coverage** — a behavioural change with no matching test? Especially a new
   module / hook / handler / trigger without a test beside it.
4. **Docs / comments** — a new user-visible feature or changed contract without the
   doc / README / changelog update its siblings receive?
5. **Cross-caller sweep** — a renamed or re-signatured export: did *every* caller
   update? Grep it.
6. **Type / contract drift** — a changed return shape the type system should catch,
   but the diff never regenerates the types?
7. **Null-safety** — a new nullable field a downstream reader assumes is non-null?
8. **Config / seed references** — a new template / flag / setting referenced but not
   registered in the place its peers are registered?

## How to use

Read the diff twice. First pass: "is this right?" Second pass: "if I were writing this
from scratch, what would I have added that isn't here?" The second read is the one that
catches absences.

## Falsifiability

For each absence claim, cite the two artifacts that should agree but don't — e.g.
"migration adds column X but grep finds no consumer of it".

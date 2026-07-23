# Empirical Finding Gate (CAP-EFG-001)

A discipline applied to **High-severity** review findings, and to **Medium-severity** findings that make falsifiable claims about runtime behaviour.

Doubles as a prompt fragment. `phase_fresh_review` in `bin/auto_claude` reads this file and injects it into the cold-review prompt; the user-invocable `auto_claude-review` skill references the same file. Single source of truth — the gate evolves in one place.

---

## Test before claim — empirical-finding discipline

**For every High-severity finding (and every Medium that makes a falsifiable claim about runtime behaviour), apply this gate before posting:**

1. **Is this finding a testable claim or an opinion?**
   - *Testable claim* — *"Sequelize upsert with omitted `archivedAt` overwrites the existing value to NULL"*, *"this loop is O(N²) under K elements"*, *"this query missed the tenant filter"*.
   - *Opinion / heuristic* — *"this is harder to read than the alternative"*, *"this convention drifts from the rest of the codebase"*, *"this comment doesn't add value"*. Opinions get posted as opinions.
2. **If testable: will testing it make the finding clearer?**
   - Almost always yes. The gap between *"I believe this is a bug"* and *"I have run this and it produces X"* is the difference between a confident-sounding-but-wrong comment and a definitive one.
3. **If yes: how can we test it now?**
   - Read the source (cheapest — for library-behaviour claims, the relevant source file is usually grep-distance away).
   - Write a self-contained script (10–30 LOC against the actual installed dependency version) that exercises the exact call shape and observes the result.
   - Add a regression test in the project's existing test file (most rigorous; locks the behaviour for future regressions regardless of outcome).
4. **Run the test before posting.** If running it is genuinely impossible in the current session (no local environment, no test framework, no compatible dependencies), then **downgrade the claim to a question**: *"Worth verifying — does Sequelize's upsert with omitted fields preserve them or overwrite to NULL? If overwrite, this is a bug."* Don't post the testable claim as a finding.

The hedge wording (*"Verification ask, not a definitive bug claim"*) is **not** a substitute for testing. The body of the comment will read as a confident bug-claim regardless of the hedge — readers anchor on the substance, not the qualifier.

**Why:** A confidently-worded testable finding that turns out to be wrong is worse than no finding at all. It costs the author their time pushing back, costs the reviewer credibility on the rest of the review, and dilutes the signal of the *real* findings. *"I would have caught this if I'd just spent 5 minutes running it"* is a recurring failure mode for AI-generated reviews specifically — the cost of reading the source / writing a quick script is small, the cost of a wrong claim is large, and the asymmetry justifies the gate.

**Caught on:** aurora#1166 (2026-05-07) — H1 claimed Sequelize v6 upsert clobbered omitted fields. Aude pushed back asking if it had been tested locally. Empirical test (a 50-line standalone Node script against Sequelize 6.37.3 + Postgres 16, the exact aurora versions) showed `archivedAt` preserved. Source-code verification (`node_modules/sequelize/lib/model.js:1486-1542`) confirmed the test result. H1 was retracted. The finding could have been verified in 5 minutes before posting; the cost of getting it wrong was a back-and-forth on the PR and a credibility hit on the rest of the review.

---

## Decision tree (one-paragraph form for prompt injection)

For each finding you're about to post:

- If H-severity → gate applies.
- If M-severity AND finding makes a falsifiable claim about runtime behaviour → gate applies.
- Otherwise → no gate.

If gate applies:

- Classify as testable claim vs opinion.
- If testable: try to test (read source / write script / add regression test).
- If tested: post with the test result inline (*"verified by running X, observed Y"*).
- If not testable in this session: post as a question, not a claim.

The cost of testing is ~5 minutes. The cost of a confidently-wrong claim is ~30 minutes of back-and-forth + reviewer credibility. The asymmetry is the gate's whole reason for existing.

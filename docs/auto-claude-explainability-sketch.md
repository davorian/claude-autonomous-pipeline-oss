# auto_claude Explainability — Design Sketch

Four phases of explainability, each adding a layer of traceability to auto_claude's pipeline. All outputs go to `.auto_claude_explain/` in the project root, alongside the existing `.auto_claude_state.json`.

---

## Graceful Degradation — Artifacts Are Optional

auto_claude is a generic pipeline. Recovery artifacts (`.recovery_artifacts/`) are project-specific and may not exist. All four phases **must work without artifacts** — they just work *better* with them.

### Design principle

Every phase has two modes:

| Mode | When | Behaviour |
|---|---|---|
| **LLM-only** | No artifacts directory found | Claude reasons from spec + code only. Decisions, coverage, assumptions, and impact are all LLM-generated. Still valuable — just not grounded in structural data. |
| **Artifact-enriched** | `$ARTIFACTS_DIR` exists and contains valid JSON | Deterministic artifact data is injected into prompts and used for graph traversal. LLM output is grounded in structural facts. |

### Implementation

A single detection function at pipeline startup:

```bash
# ─── Artifact Detection ──────────────────────────────────────────────────
# Recovery artifacts enrich explainability but are never required.
# ARTIFACTS_DIR can be set in .auto_claude.conf to override auto-detection.

_detect_artifacts() {
  # Explicit config takes precedence
  if [ -n "${ARTIFACTS_DIR:-}" ] && [ -d "$ARTIFACTS_DIR" ]; then
    HAS_ARTIFACTS=true
    log INFO "Artifacts directory: $ARTIFACTS_DIR"
    return
  fi

  # Auto-detect: check project root, then parent directory (monorepo layout)
  for candidate in \
    "$PROJECT_ROOT/.recovery_artifacts" \
    "$(dirname "$PROJECT_ROOT")/.recovery_artifacts"; do
    if [ -d "$candidate" ] && [ -f "$candidate/system_graph.json" ]; then
      ARTIFACTS_DIR="$candidate"
      HAS_ARTIFACTS=true
      log INFO "Auto-detected artifacts: $ARTIFACTS_DIR"
      return
    fi
  done

  HAS_ARTIFACTS=false
  ARTIFACTS_DIR=""
  log INFO "No recovery artifacts found — explainability phases will use LLM-only mode"
}
```

Each phase then branches on `$HAS_ARTIFACTS`:

```bash
# Pattern used in every phase that can leverage artifacts
if [ "$HAS_ARTIFACTS" = true ]; then
  artifact_context=$(_filter_artifacts_for_spec)
  # Inject into prompt
else
  artifact_context=""
  # Phase still runs, just without structural grounding
fi
```

### What changes per phase without artifacts

| Phase | With artifacts | Without artifacts |
|---|---|---|
| **1: Decisions** | Prompt includes data_ownership excerpts (view/table info, readers/writers), invariants for relevant entities, event contracts. Claude makes decisions grounded in structural facts. | Claude makes decisions based on spec + code exploration only. Still emits the manifest — just without structural grounding. Assumptions are more likely to be wrong, but at least they're *stated*. |
| **2: Coverage Map** | Cross-references failure_topology for known failure modes. Highlights untested failure paths from the artifact data. | Claude assesses coverage from spec requirements only. Still identifies `uncovered` and `implicit_scenarios` — just can't cross-reference known failure modes. |
| **3: Assumptions** | Validates assumptions against invariants.json and concurrency_invariants.json. Auto-escalates contradictions. | Assumptions are still extracted and carried forward. No automated validation against invariants — the fresh_review phase is the only check. |
| **4: Blast Radius** | Full deterministic graph traversal → classification → LLM narrative for boundary/core. | **Classification defaults to `leaf`** — no graph data means no way to determine downstream impact. Phase emits a warning: "No recovery artifacts available — blast radius analysis skipped. Consider running recovery analysis for this project." The `fresh_review` phase proceeds without impact context. |

### Artifact validation

Individual artifact files may be missing or malformed even when the directory exists. Each artifact access is guarded:

```bash
_read_artifact() {
  local name="$1"  # e.g., "data_ownership"
  local file="$ARTIFACTS_DIR/${name}.json"
  
  if [ ! -f "$file" ]; then
    log DEBUG "Artifact not found: $name (skipping)"
    echo ""
    return
  fi
  
  # Validate it's parseable JSON
  if ! jq '.' "$file" >/dev/null 2>&1; then
    log WARN "Artifact malformed: $name (skipping)"
    echo ""
    return
  fi
  
  cat "$file"
}
```

So even in a project that has *some* artifacts but not all, the pipeline uses what's available and skips what isn't.

### Config surface

```bash
# .auto_claude.conf additions
ARTIFACTS_DIR=""              # Override auto-detection. Empty = auto-detect.
DECISIONS_REVIEW=false        # Pause after decisions manifest for human review
COVERAGE_GATE=false           # Pause if high-severity coverage gaps found
EXPLAIN_PHASES=true           # Master switch — set false to disable all explainability
```

`EXPLAIN_PHASES=false` disables all four phases entirely for projects that don't want the overhead.

---

## Phase 1: Decisions Manifest

**Where in pipeline:** Between `phase_plan` and `phase_implement` (new phase: `phase_decisions`)

**Problem:** auto_claude interprets spec requirements and makes implicit choices — which table to query, which module to alias, which pattern to follow. These choices are invisible in the final diff. When a choice is wrong (e.g., querying a view instead of a table), it's only caught downstream by review.

**How it works:**

1. After `phase_plan` completes, a new `phase_decisions` phase runs in the same conversation (still in the authoring block, before the seam).

2. Claude is prompted to emit a structured decisions manifest *before writing any code*:

```
Before implementing, analyse each deliverable and emit a decisions manifest.
For each deliverable, identify the key technical choices you'll make.

Output ONLY valid JSON:
{
  "deliverables": [
    {
      "id": "D1",
      "title": "...",
      "decisions": [
        {
          "id": "D1-001",
          "category": "data_source|pattern|module|dependency|api",
          "choice": "What you chose to do",
          "rationale": "Why you chose it",
          "assumption": "What must be true for this choice to be correct",
          "alternatives_considered": ["Other approach you rejected and why"],
          "risk": "What could go wrong if the assumption is wrong"
        }
      ]
    }
  ]
}
```

3. The manifest is saved to `.auto_claude_explain/decisions.json` and also injected into `_extract_authoring_summary` so downstream quality phases can reference it.

4. **Optional gate:** If `DECISIONS_REVIEW=true` in `.auto_claude.conf`, the pipeline pauses after emitting the manifest and waits for the user to press Enter (or Ctrl+C to abort). This lets a human scan assumptions before code is written — the cheapest possible intervention point.

**What this catches (using our SEA-1161 bug as an example):**

```json
{
  "id": "D1-003",
  "category": "data_source",
  "choice": "Query employer_candidates table for pre-flight check",
  "rationale": "Matches the entity name in the spec",
  "assumption": "employer_candidates returns all non-deleted, non-complete candidates",
  "alternatives_considered": [
    "employer_candidates_including_deleted with is_nil(deleted_at) — would be needed if employer_candidates is a view that filters rows"
  ],
  "risk": "If employer_candidates is a view with implicit filters, soft-deleted records from SEA-1162 may still appear"
}
```

A human or downstream reviewer seeing that assumption can immediately check whether it's a table or view.

**Changes to auto_claude:**

- Add `phase_decisions` to `PHASES` array, between `plan` and `implement`
- Add it to the authoring block (before the seam)
- Parse and save the JSON to state, same pattern as `_extract_authoring_summary`
- Add `DECISIONS_REVIEW` config option for optional human gate

---

## Phase 2: Verification Coverage Map

**Where in pipeline:** End of `phase_test_fix`, after all tests pass

**Problem:** Tests passing is binary — there's no record of which requirements are covered and which aren't. The soft-delete scenario in SEA-1161 had no test, and nothing in the pipeline flagged this gap.

**How it works:**

1. After `phase_test_fix` succeeds, a new extraction step (`_extract_coverage_map`) runs in the same conversation.

2. Claude is prompted with both the original spec and the test files it wrote:

```
All tests pass. Now assess test coverage against the spec requirements.

For each requirement or acceptance criterion in the spec, identify:
- Whether a test exists that covers it
- Which test (file:line) covers it
- Any requirement that has NO test

Also identify scenarios that are implied by the requirements but not
explicitly stated — edge cases, interaction effects, error paths that
a careful reader would expect to be tested.

Output ONLY valid JSON:
{
  "covered": [
    {
      "requirement": "Closes open cohorts for a programme",
      "test": "test/platform/prod_scripts/batch_close_cohorts_test.exs:49",
      "confidence": "direct"
    }
  ],
  "uncovered": [
    {
      "requirement": "Soft-deleted candidates (from SEA-1162) should not block the script",
      "source": "implied by pre-flight check + SEA-1162 dependency",
      "severity": "high",
      "reason": "Pre-flight queries employer_candidates — if this is a view that doesn't filter deleted_at, soft-deleted records will still count"
    }
  ],
  "implicit_scenarios": [
    {
      "scenario": "Running after SEA-1162 soft-delete",
      "description": "The spec says SEA-1162 must run first. The test should verify that soft-deleted candidates don't trip the pre-flight check.",
      "severity": "high"
    }
  ]
}
```

3. The coverage map is saved to `.auto_claude_explain/coverage_map.json`.

4. **Auto-escalation:** If any `uncovered` item has `severity: "high"`, the pipeline logs a warning and (if `COVERAGE_GATE=true`) pauses for human review before proceeding to CI checks. In non-gated mode, the uncovered items are injected into the `skill_chain` context pack so the skill review phase can address them.

**What this catches:**

The soft-delete gap. Claude, when prompted to think about coverage *against the spec* (not just "do tests pass"), would identify that the spec says "SEA-1162 must run first" but no test verifies the interaction. The `implied_scenarios` section catches cross-cutting concerns that fall between deliverables.

**Changes to auto_claude:**

- Add `_extract_coverage_map` function, called at end of `phase_test_fix` (after tests pass, before the `phase_ci_checks`)
- Save to `.auto_claude_explain/coverage_map.json` and to state
- Inject `uncovered` items into `_build_context_pack("skill_chain")` so the skill review can address gaps
- Add `COVERAGE_GATE` config option

---

## Phase 3: Assumptions Carried Forward (Phase Handoffs)

**Where in pipeline:** At the authoring/quality seam (augmenting `_extract_authoring_summary`)

**Problem:** When D1 makes an assumption (e.g., "employer_candidates is a table, not a view"), D2 inherits that assumption silently. If D2 depends on D1's data model choices, it can't validate them because the assumption was never made explicit. The existing `.phase_handoffs/` structure captures *what was done* but not *what was assumed*.

**How it works:**

1. Augment `_extract_authoring_summary` to also extract assumptions:

```
Additionally, list all assumptions your implementation depends on that
are NOT verified by the tests you wrote. Focus on:

- Data model assumptions (table vs view, column semantics, implicit filters)
- Ordering assumptions (this script runs after X, Y must have happened first)
- Environment assumptions (config values, feature flags, external service state)
- Concurrency assumptions (no other process modifies this data concurrently)

Output in this format within the existing JSON:
"assumptions_carried_forward": [
  {
    "id": "A001",
    "assumption": "employer_candidates returns only non-deactivated users",
    "depends_on": "D1-003",  // links to decisions manifest
    "verified_by": null,     // null = unverified, or test file:line
    "impact_if_wrong": "Pre-flight check counts wrong records, blocking the script permanently",
    "suggested_verification": "Check whether employer_candidates is a table or view; if view, check its WHERE clause"
  }
]
```

2. These assumptions are:
   - Saved to `.auto_claude_explain/assumptions.json`
   - Injected into `_build_context_pack` for ALL quality phases
   - Specifically highlighted in `fresh_review` context so the cold reviewer can challenge them

3. **Cross-deliverable linking:** When a multi-deliverable spec runs, assumptions from D1 are available during D2's planning. The `phase_decisions` prompt for D2 includes:

```
The following assumptions were made in earlier deliverables.
If your implementation depends on any of these, validate or challenge them:

[assumptions from D1]
```

This creates a chain: D1 states assumption → D2 either validates it (by checking) or inherits it (explicitly). Either way, it's traceable.

**What this catches:**

The `employer_candidates` view assumption. If D1 (batch close cohorts) logged "employer_candidates returns only non-deactivated users" as an unverified assumption, then D2 (deactivate programmes) would see it and could either verify it or flag the same risk. The fresh review phase would also see it and could challenge it.

**Changes to auto_claude:**

- Augment the `_extract_authoring_summary` prompt to include `assumptions_carried_forward`
- Save separately to `.auto_claude_explain/assumptions.json`
- Inject into `_build_context_pack` for `skill_chain`, `fresh_review`, and `final`
- For multi-deliverable specs, pipe previous deliverable assumptions into next deliverable's `phase_decisions`

---

## Phase 4: Change Impact Assessment (Blast Radius)

**Where in pipeline:** New phase `phase_impact` between `phase_ci_checks` and `phase_skill_chain` (first phase in the quality block, fresh session)

**Problem:** For changes to core modules (as opposed to isolated scripts), the blast radius extends beyond the changed files. A change to a shared table, an event contract, or a core module can affect services, views, consumers, and workflows that the implementer never looked at. The recovery artifacts contain exactly the graph data needed to compute this automatically.

**How it works:**

1. A new `phase_impact` runs as the first quality-block phase (fresh session). It does NOT use Claude for the core analysis — it uses deterministic graph traversal of the recovery artifacts, with Claude only for narrative synthesis.

2. **Step A — Deterministic blast radius computation (no LLM):**

   A helper script (`_compute_blast_radius`) reads the changed files from state, then queries the recovery artifacts:

   ```bash
   _compute_blast_radius() {
     local changed_files
     changed_files=$(jq -r '.deterministic.files_changed[]' "$STATE_FILE")
     
     # For each changed file, find which system_graph node it belongs to
     # Then find all edges FROM that node (downstream dependents)
     # Then find all edges TO that node (upstream callers)
     
     python3 "$SCRIPT_DIR/blast_radius.py" \
       --changed-files <(echo "$changed_files") \
       --system-graph "$ARTIFACTS_DIR/system_graph.json" \
       --behaviour-graph "$ARTIFACTS_DIR/behaviour_graph.json" \
       --data-ownership "$ARTIFACTS_DIR/data_ownership.json" \
       --event-contracts "$ARTIFACTS_DIR/event_contracts.json" \
       --failure-topology "$ARTIFACTS_DIR/failure_topology.json" \
       --invariants "$ARTIFACTS_DIR/invariants.json" \
       --test-coverage "$ARTIFACTS_DIR/test_coverage_topology.json" \
       --output "$EXPLAIN_DIR/blast_radius.json"
   }
   ```

3. **What `blast_radius.py` computes:**

   For each changed file, it traverses the artifact graphs to find:

   ```json
   {
     "changed_file": "lib/platform/prod_scripts/batch_close_cohorts_for_programmes.ex",
     "system_node": "prod_scripts",
     "classification": "new_file|core_module|leaf_module",
     
     "tables_touched": [
       {
         "table": "employer_candidates",
         "operation": "read",
         "is_view": true,
         "view_source": "employer_candidates_including_deleted",
         "view_filters": ["users_including_deactivated.deactivated = false"],
         "note": "VIEW — does NOT filter on deleted_at. Soft-deleted records will be visible.",
         "owner_service": "platform",
         "other_readers": ["goals_service", "aurora"],
         "data_ownership_ref": "data_ownership.json#entities[employer_candidates]"
       },
       {
         "table": "cohorts",
         "operation": "write (update)",
         "is_view": false,
         "owner_service": "platform",
         "other_readers": ["goals_service"]
       }
     ],

     "downstream_services": [
       {
         "service": "goals_service",
         "mechanism": "reads cohorts table",
         "impact": "Closing cohorts may affect goals service queries that filter on open_to_applications",
         "evidence": "system_graph.json edge: platform -> goals_service"
       }
     ],

     "event_contracts_affected": [
       {
         "event": "cohort.updated",
         "impact": "If cohort update triggers an event, consumers will see open_to_applications change",
         "consumers": ["goals_service", "aurora"],
         "ref": "event_contracts.json#cohort.updated"
       }
     ],

     "invariants_at_risk": [
       {
         "invariant": "Cohorts with active employer candidates must remain open",
         "status": "RELEVANT — this script closes cohorts; pre-flight check enforces this invariant",
         "ref": "invariants.json#inv-042"
       }
     ],

     "failure_modes": [
       {
         "id": "fm-employer-candidate-view-filter",
         "description": "employer_candidates view filters on user.deactivated but not deleted_at",
         "relevance": "Pre-flight check queries this view; soft-deleted records may be counted",
         "severity": "high",
         "ref": "failure_topology.json#fm-xxx"
       }
     ],

     "test_coverage_gaps": [
       {
         "item": "No test verifies behaviour after SEA-1162 soft-delete",
         "ref": "test_coverage_topology.json#untested_items[...]"
       }
     ]
   }
   ```

4. **Step B — Classification gate (deterministic, no LLM):**

   The script classifies the change:

   | Classification | Criteria | Action |
   |---|---|---|
   | `leaf` | New file, no downstream edges, no shared tables written | Skip impact narrative (prod scripts, migrations) |
   | `boundary` | Touches a table read by other services, or publishes events | Generate impact narrative |
   | `core` | Modifies a file in the system_graph with >3 downstream edges | Generate impact narrative + require human review |

   For our SEA-1161 case: it's a new file (leaf), BUT it reads `employer_candidates` (a view) and writes `cohorts` (read by other services) → classified as `boundary`.

5. **Step C — Narrative synthesis (LLM, only for boundary/core):**

   For `boundary` and `core` changes, the blast radius JSON is passed to Claude in a fresh session:

   ```
   You are reviewing the blast radius of a code change.
   The following impact data was computed by analysing the codebase's
   dependency graphs, data ownership, event contracts, and invariants.

   [blast_radius.json content]

   Write a concise impact assessment:
   1. Which downstream systems or workflows could be affected?
   2. Are there any invariants this change could violate?
   3. Are there view/table assumptions that need verification?
   4. What specific tests or manual checks should be added?

   Keep it under 500 words. Be specific — cite the evidence from the
   blast radius data.
   ```

   The narrative is saved to `.auto_claude_explain/impact_assessment.md` and injected into the `fresh_review` context pack.

6. **Recovery artifacts used and why:**

   | Artifact | Used for |
   |---|---|
   | `system_graph.json` | Map changed files → nodes → downstream edges (service dependencies) |
   | `behaviour_graph.json` | Identify workflows that pass through the changed code |
   | `data_ownership.json` | Find who else reads/writes the tables this code touches |
   | `event_contracts.json` | Check if table changes trigger events with downstream consumers |
   | `failure_topology.json` | Surface known failure modes related to the changed area |
   | `invariants.json` | Identify business rules that the change could violate |
   | `test_coverage_topology.json` | Find gaps in test coverage for the affected area |
   | `layer_map.json` | Classify the change (interaction/application/implementation layer) |
   | `concurrency_invariants.json` | Flag if the change touches data with concurrency constraints |
   | `config_surface.json` | Check if the change depends on config values or feature flags |

**What this catches (using our SEA-1161 bug as an example):**

The `data_ownership.json` artifact knows that `employer_candidates` is a view backed by `employer_candidates_including_deleted`. The `system_graph.json` knows that `cohorts` is read by `goals_service`. The graph traversal would surface both facts deterministically — no LLM hallucination risk for the structural analysis. Claude only writes the human-readable summary.

**Without artifacts:**

Phase 4 degrades the most because the deterministic graph traversal is the whole point. Without artifacts:

- `_compute_blast_radius` is skipped entirely
- Classification defaults to `leaf` (safe default — no blocking)
- Claude is instead given a simpler prompt: "List the tables/entities this code reads and writes. For each, consider whether other parts of the system depend on them." This is LLM-only and less reliable, but better than nothing.
- A log message notes: "No recovery artifacts — blast radius analysis is LLM-only. Run recovery analysis for deterministic impact assessment."

**Changes to auto_claude:**

- New `blast_radius.py` script in `~/bin/` (or `$SCRIPT_DIR`)
- New `phase_impact` added to `PHASES` array, first in the quality block
- New `_compute_blast_radius` function called before the LLM narrative step (guarded by `$HAS_ARTIFACTS`)
- `ARTIFACTS_DIR` detected by `_detect_artifacts` at startup, overridable in `.auto_claude.conf`
- Classification gate determines whether to skip (leaf), generate narrative (boundary), or gate (core)
- Inject impact assessment into `_build_context_pack("fresh_review")`

---

## Cross-cutting: Artifact Use Across All Phases

The recovery artifacts can strengthen all four phases — but every phase works without them. When `HAS_ARTIFACTS=false`, each phase falls back to LLM-only reasoning. When `HAS_ARTIFACTS=true`, the following enrichments apply:

### Phase 1 (Decisions Manifest) + Artifacts

Inject relevant artifact excerpts into the `phase_decisions` prompt:

- **`data_ownership.json`**: For any table/entity mentioned in the spec, include its ownership info (is it a view? who else reads it?). This directly prevents the SEA-1161 bug — Claude would see "employer_candidates is a VIEW" before making its data source choice.
- **`invariants.json`**: Include invariants related to the entities being modified. Claude can then check its planned approach against known business rules.
- **`event_contracts.json`**: If the spec involves modifying data that triggers events, include the consumer list so Claude knows the downstream impact.

The prompt addition:

```
Before making decisions, review these structural facts about the entities
you'll be working with:

[filtered excerpt from data_ownership.json for relevant tables]
[filtered excerpt from invariants.json for relevant entities]
[filtered excerpt from event_contracts.json for relevant events]

Factor these into your decisions. If your planned approach conflicts with
any structural fact, flag it as a risk.
```

### Phase 2 (Coverage Map) + Artifacts

- **`failure_topology.json`**: Include known failure modes for the changed area. Claude can check whether any of them have test coverage. If a known failure mode has no test, it goes in `uncovered` with severity from the failure topology.
- **`test_coverage_topology.json`**: Cross-reference Claude's coverage assessment against the existing coverage topology to avoid duplicate analysis and surface pre-existing gaps.

### Phase 3 (Assumptions) + Artifacts

- **`invariants.json`**: Each assumption can be cross-checked against known invariants. If an assumption contradicts an invariant, auto-escalate.
- **`concurrency_invariants.json`**: If the change assumes single-writer semantics on a table that has concurrency constraints, flag it.

### How to filter artifacts for relevance

Not all 67 entities and 90 invariants should be injected — that's noise. The filter (only runs when `HAS_ARTIFACTS=true`):

1. Parse the spec for entity/table names (deterministic regex)
2. Parse the plan output for file paths
3. Use `system_graph.json` to find which nodes those files belong to
4. Use `data_ownership.json` to find which entities those nodes touch
5. Return only the relevant subset of artifacts

This filtering is deterministic (no LLM), runs in <1 second, and is implemented in `_filter_artifacts_for_spec`. When `HAS_ARTIFACTS=false`, this function returns an empty string and the prompt proceeds without structural context.

---

## Output Structure

```
.auto_claude_explain/
  decisions.json          # Phase 1: choices made and why
  coverage_map.json       # Phase 2: requirement → test mapping + gaps
  assumptions.json        # Phase 3: unverified assumptions carried forward
  blast_radius.json       # Phase 4: deterministic graph traversal output
  impact_assessment.md    # Phase 4: LLM narrative (boundary/core only)
```

All files are gitignored (like `.auto_claude_state.json`). They persist across runs for the same spec but are regenerated on each new run.

---

## Implementation Priority

| Phase | Effort | Value | Catches bugs like... |
|---|---|---|---|
| 1 (Decisions) | Small — prompt addition + JSON extraction | High | employer_candidates view vs table |
| 4 (Blast Radius) | Medium — needs blast_radius.py + artifact integration | High | cross-service impact, view semantics |
| 2 (Coverage Map) | Small — prompt addition at end of test_fix | Medium | missing soft-delete test scenario |
| 3 (Assumptions) | Small — augment existing extraction | Medium | cross-deliverable assumption inheritance |

Phases 1 and 4 together would have caught both bugs in our SEA-1161/1163 work. Phase 2 would have flagged the missing test. Phase 3 would have propagated the assumption to the 1163 review.

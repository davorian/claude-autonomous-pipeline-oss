# Meaningful-Mutation Taxonomy

This document defines the eight categories of **semantically meaningful**
mutations the vacuousness gate (CAP-VG-001) generates. Each category answers
the same test: *"Would a real engineer plausibly make this mistake?"*

If a mutation does not match a real-world bug pattern, it does not belong
here — it belongs in the random-byte-mutation pile and is excluded.

The pipeline's bash phases (`phase_vacuousness_pass_2_semantic`,
`phase_vacuousness_pass_2_coverage`) load this file verbatim into prompts
and ask Claude to enumerate applicable mutants per category. The schema
section below is consumed both by Claude (to format output) and by the
gate (to parse it).

---

## Categories (in scope)

| ID                  | Category               | What it does                                                            |
|---------------------|------------------------|-------------------------------------------------------------------------|
| `no_op_body`        | No-op body             | Replace function body with the simplest valid return.                   |
| `drop_side_effect`  | Drop side-effect       | Remove the data-mutation call but keep the surrounding control flow.    |
| `drop_filter`       | Drop filter            | Remove a `where:` / `WHERE` / `if` guard so the function processes too much/too little data. |
| `swap_query_subject`| Swap query subject     | Change the table/source the query targets to a sibling-but-wrong one.   |
| `swap_column`       | Swap column            | Replace a column reference with a similarly-named sibling.              |
| `invert_boolean`    | Invert boolean         | Flip an `if cond do A else B end` so the branches swap.                 |
| `skip_iteration`    | Skip iteration         | In an `Enum.reduce/3` (or equivalent), return the accumulator unchanged. |
| `constant_return`   | Constant return        | Replace a count/aggregate with a constant zero or one.                  |

### Worked examples

#### `no_op_body` (Elixir)

```elixir
# original
def pre_clean_user_id(user_id) do
  # ... real work ...
  {:ok, %{logs: deleted_count}}
end

# mutated
def pre_clean_user_id(_), do: {:ok, %{}}
```

A test that only asserts `is_map/1` on the result will fail to kill this mutant.

#### `drop_side_effect` (Elixir)

```elixir
# original
{count, _} = Repo.delete_all(query)
count

# mutated — query never runs, but a count is still returned
0
```

#### `drop_filter` (Ecto)

```elixir
# original
from(t in T, where: t.user_id == ^user_id)

# mutated — operates on every row, regardless of user
from(t in T)
```

This is the SEA-1246 H2 bug shape. A test that doesn't seed sibling-user
fixtures and assert their intactness will not catch it.

#### `swap_query_subject` (Ecto)

```elixir
# original
from(u in "users", ...)

# mutated — sibling table, semantically different
from(u in "users_including_deactivated", ...)
```

#### `swap_column` (Ecto)

```elixir
# original
where: t.user_id == ^id

# mutated
where: t.id == ^id
```

#### `invert_boolean` (any language)

```elixir
# original
if dry_run, do: report(), else: execute()

# mutated — branches swapped
if dry_run, do: execute(), else: report()
```

#### `skip_iteration` (Elixir / functional)

```elixir
# original
Enum.reduce(items, acc, fn item, acc -> handle(item, acc) end)

# mutated — identity reducer; nothing happens
Enum.reduce(items, acc, fn _, acc -> acc end)
```

#### `constant_return` (any language)

```elixir
# original
Repo.aggregate(query, :count)

# mutated
0
```

---

## Out of taxonomy

These produce too many equivalent mutants and waste compute. They are
explicitly **excluded** from this gate.

- **Operator-level byte mutation** — flipping `+` to `-`, `<` to `>`, etc.
  (Stryker / PIT / mutmut style.)
- **Whitespace / comment changes.**
- **Random argument shuffling.**
- **Constant tweaking** that is not "0 or 1" (e.g. flipping `7` to `8` —
  rarely produces a meaningful bug shape).

If you are tempted to extend this list, ask: *"Have I seen a real engineer
make this mistake in code review?"* If not, it does not belong here.

---

## JSON output schema

Claude must emit mutants as a JSON array sorted by `file` then `line`.
Each record must conform to:

```json
[
  {
    "category": "drop_filter",
    "file": "lib/platform/customer_exit/restrict_pre_clean.ex",
    "line": 88,
    "original": "where: t.user_id == ^user_id",
    "mutated": "(filter removed)",
    "provenance": "taxonomy",
    "applies_to_lang": "elixir"
  },
  {
    "category": "swap_column",
    "file": "lib/platform/customer_exit/restrict_pre_clean.ex",
    "line": 104,
    "original": "field(t, ^column) == ^user_id",
    "mutated": "field(t, ^column) == ^column",
    "provenance": "taxonomy",
    "applies_to_lang": "elixir"
  }
]
```

### Field semantics

- **`category`** — one of the eight identifiers in the table above.
- **`file`** — repository-relative path of the source file the mutation applies to.
- **`line`** — 1-based line number of the start of the mutated region.
- **`original`** — the exact source snippet being replaced, single-line
  or multi-line (for prompts, keep it short — a code excerpt, not the
  whole function).
- **`mutated`** — the replacement snippet, in the same shape as `original`.
  Empty string is permitted (e.g. for `drop_filter` where the clause is
  removed entirely).
- **`provenance`** — `"taxonomy"` for taxonomy-derived mutants;
  `"llm"` for LLM-proposed mutants specific to the function under test.
- **`applies_to_lang`** — language hint (`"elixir"`, `"typescript"`,
  `"python"`, `"ruby"`, etc.) so cross-language adapters can filter to
  applicable mutations.

### Determinism contract

- Output **must** be sorted by (`file`, `line`) ascending.
- For two mutants at the same `(file, line)`, sort by `category` ascending.
- No timestamps, no random IDs, no machine-specific data — the same input
  must produce byte-identical output across runs.

---

## Why these specific categories beat random byte-mutation

Industry-standard mutation testing (Stryker, PIT, mutmut) uses syntactic
operator-level mutations. They produce 20-50 mutants per function, of
which 30-60% are *equivalent mutants* (functionally identical to the
original). Engineers triaging the report waste time on the equivalents;
signal-to-noise is poor.

The taxonomy above is tighter: each mutation maps to a real bug pattern
observed in production code reviews. Tighter taxonomy → fewer equivalent
mutants → engineers actually act on the reported survivors.

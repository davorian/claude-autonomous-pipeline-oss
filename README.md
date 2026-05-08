# claude-autonomous-pipeline

Reusable autonomous feature pipeline using Claude as engine.

## Pipeline

16-phase pipeline split into two blocks at a configurable seam:

**Authoring block** (single Claude conversation):
`plan` → `decisions` → `test_intent` → `vacuousness_pass_1` → `pattern_baseline` → `implement` → `test_fix` → `vacuousness_pass_2_semantic` → `vacuousness_pass_2_coverage` → `ci_checks`

**Quality block** (fresh sessions per phase):
`impact` → `skill_chain` → `loc_enforcement` → `fresh_review` → `doc_update` → `final`

Key features:
- **TDD flow** — `test_intent` writes failing tests before implementation; `implement` makes them pass (`TDD_ENABLED=true`)
- **Vacuousness gate** (CAP-VG-001) — Gate 1 verifies the new tests are TDD-red before `implement` runs; Gates 2 + 3 (opt-in via `--rigorous`) generate semantic + coverage-driven mutants and require each to be killed by ≥1 test. See `docs/vacuousness_taxonomy.md` and `skills/check-vacuousness/SKILL.md`.
- **Pattern conformance** — `pattern_baseline` catalogues existing patterns; `skill_chain` enforces conformance (`PATTERN_CONFORMANCE=true`)
- **Ownership boundaries** — `worktree_auto_claude` writes `.auto_claude_ownership.json` to constrain each parallel instance to its owned files
- **Explainability** — `decisions` phase emits decision manifests to `.auto_claude_explain/`

## Structure

```
bin/
  auto_claude              # Main pipeline script (~4000 lines)
  worktree_auto_claude     # Git worktree wrapper for isolated parallel runs
  auto_claude_original     # Pre-refactor backup
conf/
  platform.auto_claude.conf    # Multiverse platform config
  aurora.auto_claude.conf      # Multiverse aurora config
  user_home.auto_claude.conf   # Multiverse user_home config
docs/
  auto_claude.md                       # Pipeline documentation
  auto-claude-explainability-sketch.md # Explainability proposal
tests/
  test_auto_claude_*.sh    # Pipeline test scripts
```

## Usage

```bash
# Direct run
~/bin/auto_claude path/to/spec.md

# Isolated worktree run
~/bin/worktree_auto_claude path/to/spec.md

# Run with full vacuousness gate (Gates 1 + 2 + 3)
~/bin/auto_claude --rigorous path/to/spec.md

# Ad-hoc vacuousness check on existing files (no spec / no implementation)
~/bin/auto_claude --vacuousness-only --files path/to/test.ex,path/to/other_test.ex
~/bin/auto_claude --vacuousness-only --diff main..HEAD --vacuousness-format json
```

Requires `.auto_claude.conf` in the project root. See `conf/` for examples and `docs/auto_claude.md` for full documentation.

## Install `ac-helper` (optional but recommended)

`ac-helper` is a small Go binary that handles the parsing surface of
`auto_claude` (JSON extraction from Claude responses, response-field
parsing). It kills a class of recurring bash bugs. The bash script works
without it — it detects the binary on `PATH` and falls back to hardened
bash if absent — but having it on is strictly better.

### Prerequisites

This repo is **private**, so the installers below use the GitHub CLI
(`gh`) for authenticated downloads rather than anonymous `curl`. One-time
setup:

```sh
# macOS
brew install gh

# Linux — see https://github.com/cli/cli#installation

# Then, once:
gh auth login
```

### Seamless install (one-liner)

Fetches `install.sh` from the private repo via the authenticated `gh`
token, runs it, auto-detects your OS + arch, and drops the binary at
`~/bin/ac-helper`. On macOS it also strips Gatekeeper quarantine.

```sh
gh api /repos/davorian/claude-autonomous-pipeline/contents/install.sh --jq .content | base64 -d | sh
```

Pin a specific version (same flow):

```sh
gh api /repos/davorian/claude-autonomous-pipeline/contents/install.sh --jq .content | base64 -d | VERSION=v0.1.0 sh
```

Change install root:

```sh
gh api /repos/davorian/claude-autonomous-pipeline/contents/install.sh --jq .content | base64 -d | PREFIX=/usr/local sh
```

### Per-platform manual install

One-liners per machine type if you'd rather skip `install.sh`. Replace
`latest` resolution is automatic when no tag is specified; add
`v0.1.0` positionally after `download` to pin.

**macOS — Apple Silicon (M1/M2/M3/M4):**

```sh
gh release download --repo davorian/claude-autonomous-pipeline \
  --pattern 'ac-helper-darwin-arm64' --output ~/bin/ac-helper --clobber
chmod +x ~/bin/ac-helper
xattr -d com.apple.quarantine ~/bin/ac-helper 2>/dev/null || true
```

**macOS — Intel:**

```sh
gh release download --repo davorian/claude-autonomous-pipeline \
  --pattern 'ac-helper-darwin-amd64' --output ~/bin/ac-helper --clobber
chmod +x ~/bin/ac-helper
xattr -d com.apple.quarantine ~/bin/ac-helper 2>/dev/null || true
```

**Linux — x86_64 (Intel/AMD servers, most CI runners):**

```sh
gh release download --repo davorian/claude-autonomous-pipeline \
  --pattern 'ac-helper-linux-amd64' --output ~/bin/ac-helper --clobber
chmod +x ~/bin/ac-helper
```

**Linux — arm64 (Graviton, Raspberry Pi 4/5, arm64 CI):**

```sh
gh release download --repo davorian/claude-autonomous-pipeline \
  --pattern 'ac-helper-linux-arm64' --output ~/bin/ac-helper --clobber
chmod +x ~/bin/ac-helper
```

### Build from source

Requires Go 1.22+.

```sh
git clone https://github.com/davorian/claude-autonomous-pipeline.git
cd claude-autonomous-pipeline
make install          # → $HOME/bin/ac-helper
# or:
PREFIX=/usr/local make install   # → /usr/local/bin/ac-helper
```

Cross-compile all targets at once (outputs into `dist/`):

```sh
make build-all
```

### Verify

```sh
ac-helper --version
echo '{"a":1}' | ac-helper extract-json    # → {"a":1}
```

Next `auto_claude` run will detect and use it automatically. No config flag.

### Uninstall

```sh
rm ~/bin/ac-helper    # reverts to bash fallback on next auto_claude run
```

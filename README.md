# claude-autonomous-pipeline

Reusable autonomous feature pipeline using Claude as engine.

## Pipeline

13-phase pipeline split into two blocks at a configurable seam:

**Authoring block** (single Claude conversation):
`plan` → `decisions` → `test_intent` → `pattern_baseline` → `implement` → `test_fix` → `ci_checks`

**Quality block** (fresh sessions per phase):
`impact` → `skill_chain` → `loc_enforcement` → `fresh_review` → `doc_update` → `final`

Key features:
- **TDD flow** — `test_intent` writes failing tests before implementation; `implement` makes them pass (`TDD_ENABLED=true`)
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
```

Requires `.auto_claude.conf` in the project root. See `conf/` for examples and `docs/auto_claude.md` for full documentation.

## Install `ac-helper` (optional but recommended)

`ac-helper` is a small Go binary that handles the parsing surface of
`auto_claude` (JSON extraction from Claude responses, response-field
parsing). It kills a class of recurring bash bugs. The bash script works
without it — it detects the binary on `PATH` and falls back to hardened
bash if absent — but having it on is strictly better.

### Seamless install (one-liner)

Installs to `~/bin/ac-helper` (change with `PREFIX=/usr/local`, etc.). The
script detects OS + architecture, downloads the right binary, and strips
macOS Gatekeeper quarantine automatically.

```sh
curl -fsSL https://raw.githubusercontent.com/davorian/claude-autonomous-pipeline/main/install.sh | sh
```

Pin a specific version:

```sh
curl -fsSL https://raw.githubusercontent.com/davorian/claude-autonomous-pipeline/main/install.sh | VERSION=v0.1.0 sh
```

### Per-platform manual install

If you'd rather pull the binary yourself. Replace `latest` with a version
tag (`v0.1.0`) to pin.

**macOS — Apple Silicon (M1/M2/M3/M4):**

```sh
curl -L https://github.com/davorian/claude-autonomous-pipeline/releases/latest/download/ac-helper-darwin-arm64 -o ~/bin/ac-helper
chmod +x ~/bin/ac-helper
xattr -d com.apple.quarantine ~/bin/ac-helper 2>/dev/null || true
```

**macOS — Intel:**

```sh
curl -L https://github.com/davorian/claude-autonomous-pipeline/releases/latest/download/ac-helper-darwin-amd64 -o ~/bin/ac-helper
chmod +x ~/bin/ac-helper
xattr -d com.apple.quarantine ~/bin/ac-helper 2>/dev/null || true
```

**Linux — x86_64 (Intel/AMD servers, most CI runners):**

```sh
curl -L https://github.com/davorian/claude-autonomous-pipeline/releases/latest/download/ac-helper-linux-amd64 -o ~/bin/ac-helper
chmod +x ~/bin/ac-helper
```

**Linux — arm64 (Graviton, Raspberry Pi 4/5, arm64 CI):**

```sh
curl -L https://github.com/davorian/claude-autonomous-pipeline/releases/latest/download/ac-helper-linux-arm64 -o ~/bin/ac-helper
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

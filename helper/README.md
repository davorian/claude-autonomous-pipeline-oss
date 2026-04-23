# ac-helper

A small Go binary that handles the string / JSON parsing surface of
`auto_claude`. Extracted from bash because this is the category of
operation where bash is weakest:

- parsing JSON out of arbitrary Claude response text (with prose,
  fences, or raw payload);
- parsing `claude --output-format json` output into discrete fields
  without letting parser failures propagate to the global `ERR` trap.

The bash script keeps orchestrating everything else (git, CI tools,
phase dispatch, locks, spinners). `ac-helper` is invoked at a handful
of hot spots and falls back to a hardened bash implementation when the
binary isn't on `PATH`, so existing installs continue to work unchanged.

## Install

```sh
make install              # → $(HOME)/bin/ac-helper
# or PREFIX=/usr/local make install
```

## Subcommands

```sh
ac-helper extract-json            < some-response.txt
ac-helper parse-claude-response --field=session_id < claude-output.json
ac-helper parse-claude-response --field=result     < claude-output.json
```

Both commands read from stdin and write to stdout. `extract-json`
exits 1 on failure (empty stdout); `parse-claude-response` never exits
non-zero — that's the whole point.

## Cross-compile

```sh
make build-all            # → dist/ac-helper-{darwin,linux}-{amd64,arm64}
```

CI (`.github/workflows/helper.yml`) runs `make check` on macOS +
Ubuntu and uploads all four cross-compiled binaries on each push.

## Tests

```sh
make test                 # go test ./helper/...
```

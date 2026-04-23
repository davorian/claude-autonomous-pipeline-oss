package main

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

// runParseClaudeResponse replaces:
//
//     session_id=$(jq -r '.session_id // empty' <<< "$raw" 2>/dev/null) || true
//     response_text=$(jq -r '.result // empty' <<< "$raw" 2>/dev/null) || true
//
// The contract: NEVER return a non-zero exit. If the input isn't JSON or
// the requested field is missing, stdout is empty and exit is 0. That
// prevents the ERR trap from firing — which is the whole point of the
// rewrite.
func runParseClaudeResponse(args []string, stdin io.Reader, stdout io.Writer) int {
	field, err := parseFieldFlag(args)
	if err != nil {
		fmt.Fprintln(stdout) // still silent-success; bash reads empty
		return 0
	}

	raw, err := io.ReadAll(stdin)
	if err != nil {
		return 0
	}

	var payload map[string]any
	if err := json.Unmarshal(raw, &payload); err != nil {
		return 0
	}

	val, ok := payload[field]
	if !ok || val == nil {
		return 0
	}

	switch v := val.(type) {
	case string:
		_, _ = io.WriteString(stdout, v)
	default:
		// For non-string fields, emit compact JSON. Keeps the tool
		// useful beyond just session_id/result without changing the
		// happy-path contract.
		if out, err := json.Marshal(v); err == nil {
			_, _ = stdout.Write(out)
		}
	}
	return 0
}

// parseFieldFlag accepts either `--field=X` or `--field X` and returns X.
func parseFieldFlag(args []string) (string, error) {
	for i, a := range args {
		if strings.HasPrefix(a, "--field=") {
			f := strings.TrimPrefix(a, "--field=")
			if f == "" {
				return "", fmt.Errorf("empty --field")
			}
			return f, nil
		}
		if a == "--field" && i+1 < len(args) {
			return args[i+1], nil
		}
	}
	return "", fmt.Errorf("missing --field")
}

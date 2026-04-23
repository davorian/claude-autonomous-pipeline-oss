package main

import (
	"bytes"
	"encoding/json"
	"io"
	"regexp"
	"strings"
)

// runExtractJSON replaces bash's _extract_json_from_response (tiers 1–3).
// Reads the full body from stdin and writes a compact JSON payload to stdout.
// Returns the process exit code (0 on success, 1 on failure — empty stdout).
func runExtractJSON(stdin io.Reader, stdout io.Writer) int {
	raw, err := io.ReadAll(stdin)
	if err != nil {
		return 1
	}
	parsed, ok := ExtractJSON(raw)
	if !ok {
		return 1
	}
	if _, err := stdout.Write(parsed); err != nil {
		return 1
	}
	return 0
}

// ExtractJSON tries three strategies in order:
//
//  1. The whole input is JSON.
//  2. A ```json ... ``` or ``` ... ``` fenced block contains JSON.
//  3. The slice from the first `{` to the last `}` parses as JSON
//     (handles prose before/after, as in "Here's the manifest: {...}").
//
// Returns the compacted JSON payload and true on success; nil/false otherwise.
// Matches the contract of the bash function it replaces: best-effort, never
// panics, silent failure.
func ExtractJSON(input []byte) ([]byte, bool) {
	trimmed := bytes.TrimSpace(input)
	if len(trimmed) == 0 {
		return nil, false
	}

	// Tier 1: raw parse
	if out, ok := compactIfValid(trimmed); ok {
		return out, true
	}

	// Tier 2: fenced block (```json ... ``` or ``` ... ```)
	if body, ok := extractFenced(trimmed); ok {
		if out, ok := compactIfValid(body); ok {
			return out, true
		}
	}

	// Tier 3: first { to last }
	first := bytes.IndexByte(trimmed, '{')
	last := bytes.LastIndexByte(trimmed, '}')
	if first >= 0 && last > first {
		if out, ok := compactIfValid(trimmed[first : last+1]); ok {
			return out, true
		}
	}

	// Also try first [ to last ] for JSON arrays.
	first = bytes.IndexByte(trimmed, '[')
	last = bytes.LastIndexByte(trimmed, ']')
	if first >= 0 && last > first {
		if out, ok := compactIfValid(trimmed[first : last+1]); ok {
			return out, true
		}
	}

	return nil, false
}

// compactIfValid returns compact JSON bytes if input parses as JSON.
// The compact form (no incidental whitespace) keeps downstream bash
// comparisons stable.
func compactIfValid(b []byte) ([]byte, bool) {
	var buf bytes.Buffer
	if err := json.Compact(&buf, b); err != nil {
		return nil, false
	}
	return buf.Bytes(), true
}

// fencedRE matches ```json\n...\n``` or ```\n...\n``` fenced blocks.
// Non-greedy body; (?s) so `.` matches newlines.
var fencedRE = regexp.MustCompile("(?s)```(?:json)?\\s*\\n(.*?)```")

func extractFenced(input []byte) ([]byte, bool) {
	m := fencedRE.FindSubmatch(input)
	if m == nil {
		return nil, false
	}
	return bytes.TrimSpace(m[1]), true
}

// Unused helper kept for potential future prose-JSON extraction without
// a closing fence (e.g. truncated response). Marked here so strings pkg
// import isn't removed by goimports if future edits need it.
var _ = strings.Contains

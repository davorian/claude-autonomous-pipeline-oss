package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestExtractJSON(t *testing.T) {
	cases := []struct {
		name   string
		input  string
		want   string
		wantOk bool
	}{
		{
			name:   "tier1_raw_object",
			input:  `{"a":1,"b":"two"}`,
			want:   `{"a":1,"b":"two"}`,
			wantOk: true,
		},
		{
			name:   "tier1_raw_array",
			input:  `[1,2,3]`,
			want:   `[1,2,3]`,
			wantOk: true,
		},
		{
			name:   "tier1_whitespace_only",
			input:  "   \n\t ",
			wantOk: false,
		},
		{
			name:   "tier1_pretty_printed",
			input:  "{\n  \"a\": 1\n}",
			want:   `{"a":1}`,
			wantOk: true,
		},
		{
			name: "tier2_json_fence",
			input: "Here's the result:\n\n" +
				"```json\n" +
				`{"a":1}` + "\n" +
				"```\n\nHope this helps.",
			want:   `{"a":1}`,
			wantOk: true,
		},
		{
			name: "tier2_bare_fence",
			input: "```\n" +
				`{"a":1}` + "\n" +
				"```",
			want:   `{"a":1}`,
			wantOk: true,
		},
		{
			name:   "tier3_prose_around_object",
			input:  `Here is the manifest: {"a":1,"nested":{"x":true}} — done.`,
			want:   `{"a":1,"nested":{"x":true}}`,
			wantOk: true,
		},
		{
			name:   "tier3_multiline_prose",
			input:  "Sure, here is your JSON:\n\n{\n  \"a\": 1\n}\n\nLet me know if you need changes.",
			want:   `{"a":1}`,
			wantOk: true,
		},
		{
			name: "tier3_array_after_prose",
			input: "The items are:\n" +
				`[{"id":1},{"id":2}]` + "\nThanks.",
			want:   `[{"id":1},{"id":2}]`,
			wantOk: true,
		},
		{
			name:   "invalid_not_json",
			input:  "Hello, world. No JSON here.",
			wantOk: false,
		},
		{
			name:   "invalid_unclosed_brace",
			input:  `{"a": 1`,
			wantOk: false,
		},
		{
			name:   "edge_empty",
			input:  "",
			wantOk: false,
		},
		{
			// The exact case that bit us in bash: multi-line with a `1\n`
			// leaking into the numeric test. Go handles it natively.
			name:   "regression_multiline_newlines_leaking",
			input:  "1\n{\"status\":\"ok\"}\nend",
			want:   `{"status":"ok"}`,
			wantOk: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := ExtractJSON([]byte(tc.input))
			if ok != tc.wantOk {
				t.Fatalf("ok = %v, want %v (got=%q)", ok, tc.wantOk, got)
			}
			if ok && string(got) != tc.want {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestRunExtractJSON(t *testing.T) {
	var out bytes.Buffer
	rc := runExtractJSON(strings.NewReader(`{"a":1}`), &out)
	if rc != 0 {
		t.Fatalf("exit %d, want 0", rc)
	}
	if out.String() != `{"a":1}` {
		t.Fatalf("stdout = %q", out.String())
	}

	out.Reset()
	rc = runExtractJSON(strings.NewReader("no json"), &out)
	if rc != 1 {
		t.Fatalf("exit %d, want 1", rc)
	}
	if out.Len() != 0 {
		t.Fatalf("stdout = %q, want empty", out.String())
	}
}

package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRunParseClaudeResponse(t *testing.T) {
	const jsonInput = `{"session_id":"abc123","result":"Hello, world.","exit_code":0}`

	cases := []struct {
		name    string
		args    []string
		input   string
		want    string
		wantRC  int // contract: always 0
	}{
		{
			name:  "extract_session_id",
			args:  []string{"--field=session_id"},
			input: jsonInput,
			want:  "abc123",
		},
		{
			name:  "extract_result",
			args:  []string{"--field=result"},
			input: jsonInput,
			want:  "Hello, world.",
		},
		{
			name:  "extract_result_multiline",
			args:  []string{"--field=result"},
			input: `{"session_id":"x","result":"line 1\nline 2\nline 3"}`,
			want:  "line 1\nline 2\nline 3",
		},
		{
			name:  "extract_non_string_as_compact_json",
			args:  []string{"--field=exit_code"},
			input: jsonInput,
			want:  "0",
		},
		{
			name:  "missing_field_returns_empty",
			args:  []string{"--field=does_not_exist"},
			input: jsonInput,
			want:  "",
		},
		{
			name:  "null_field_returns_empty",
			args:  []string{"--field=result"},
			input: `{"session_id":"x","result":null}`,
			want:  "",
		},
		{
			name:  "invalid_json_returns_empty",
			args:  []string{"--field=session_id"},
			input: "not json at all",
			want:  "",
		},
		{
			name:  "empty_input_returns_empty",
			args:  []string{"--field=session_id"},
			input: "",
			want:  "",
		},
		{
			name:  "missing_flag_returns_empty",
			args:  []string{},
			input: jsonInput,
			want:  "", // writes a newline-only response; normalized below
		},
		{
			name:  "field_flag_space_separated",
			args:  []string{"--field", "session_id"},
			input: jsonInput,
			want:  "abc123",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var out bytes.Buffer
			rc := runParseClaudeResponse(tc.args, strings.NewReader(tc.input), &out)
			if rc != 0 {
				t.Fatalf("exit %d, want 0 (contract: never fail)", rc)
			}
			got := strings.TrimRight(out.String(), "\n") // missing-flag path emits a bare newline
			if got != tc.want {
				t.Fatalf("stdout = %q, want %q", got, tc.want)
			}
		})
	}
}

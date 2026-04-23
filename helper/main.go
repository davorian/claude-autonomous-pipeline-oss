// ac-helper: parsing helpers for auto_claude.
//
// Two subcommands replace bug-prone bash string/JSON manipulation:
//
//   extract-json          Read arbitrary text from stdin, return the JSON
//                         payload embedded in it. Handles raw JSON, JSON
//                         wrapped in ```json ... ``` fences, and JSON
//                         embedded in prose. Stdout = parsed JSON (compact),
//                         exit 0 on success. Exit 1 with empty stdout on
//                         failure — matching the bash contract.
//
//   parse-claude-response Read `claude --output-format json` stdout from
//                         stdin and return a named field. Flag:
//                             --field={session_id|result}
//                         Never exits non-zero: if the input isn't valid
//                         JSON or the field is missing, stdout is empty
//                         and exit is 0. This replaces the jq + `|| true`
//                         dance that leaked ERR-trap noise.
package main

import (
	"fmt"
	"io"
	"os"
)

const version = "0.1.0"

func main() {
	if len(os.Args) < 2 {
		usage(os.Stderr)
		os.Exit(2)
	}

	switch os.Args[1] {
	case "extract-json":
		os.Exit(runExtractJSON(os.Stdin, os.Stdout))
	case "parse-claude-response":
		os.Exit(runParseClaudeResponse(os.Args[2:], os.Stdin, os.Stdout))
	case "-h", "--help", "help":
		usage(os.Stdout)
		os.Exit(0)
	case "-v", "--version", "version":
		fmt.Fprintln(os.Stdout, version)
		os.Exit(0)
	default:
		fmt.Fprintf(os.Stderr, "ac-helper: unknown subcommand %q\n\n", os.Args[1])
		usage(os.Stderr)
		os.Exit(2)
	}
}

func usage(w io.Writer) {
	fmt.Fprintln(w, "ac-helper — parsing helpers for auto_claude")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "USAGE:")
	fmt.Fprintln(w, "  ac-helper extract-json            < input")
	fmt.Fprintln(w, "  ac-helper parse-claude-response --field=FIELD < input")
	fmt.Fprintln(w, "  ac-helper --version")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "FIELDS:")
	fmt.Fprintln(w, "  session_id  — .session_id from claude --output-format json")
	fmt.Fprintln(w, "  result      — .result from claude --output-format json")
}

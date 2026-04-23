#!/bin/sh
# ac-helper installer — downloads the right prebuilt binary for your OS/arch
# from the latest GitHub Release and drops it into $PREFIX/bin/ac-helper.
#
# The repo is private, so this uses `gh release download` (authenticated)
# rather than anonymous curl. Install `gh` and run `gh auth login` first.
#
# Usage:
#   ./install.sh
#   PREFIX=/usr/local ./install.sh
#   VERSION=v0.1.0 ./install.sh
#
# Or, pulled from the private repo in one shot:
#   gh api /repos/davorian/claude-autonomous-pipeline/contents/install.sh \
#     --jq .content | base64 -d | sh
#
# Environment:
#   PREFIX   install root (default: $HOME) — binary lands in $PREFIX/bin/ac-helper
#   VERSION  release tag to pin (default: latest)
#
# POSIX sh — runs on any Mac/Linux with `gh` installed and authenticated.

set -eu

REPO="davorian/claude-autonomous-pipeline"
BIN_NAME="ac-helper"
PREFIX="${PREFIX:-$HOME}"
VERSION="${VERSION:-}"

BINDIR="$PREFIX/bin"
TARGET="$BINDIR/$BIN_NAME"

die() { printf 'install: %s\n' "$*" >&2; exit 1; }
info() { printf '→ %s\n' "$*"; }

# --- Prereq: gh CLI + auth ----------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
  die "\`gh\` is not installed. Install it first:
    macOS:  brew install gh
    Linux:  see https://github.com/cli/cli#installation"
fi

if ! gh auth status >/dev/null 2>&1; then
  die "\`gh\` is not authenticated. Run \`gh auth login\` first."
fi

# --- OS / arch detection ------------------------------------------------------
os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
  darwin|linux) ;;
  *) die "unsupported OS: $os (only darwin and linux are supported)" ;;
esac

raw_arch=$(uname -m)
case "$raw_arch" in
  x86_64|amd64)  arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) die "unsupported architecture: $raw_arch (only amd64 and arm64 are supported)" ;;
esac

asset="$BIN_NAME-$os-$arch"

# --- Download via gh ----------------------------------------------------------
info "platform: $os/$arch"
info "version:  ${VERSION:-latest}"
info "target:   $TARGET"

mkdir -p "$BINDIR"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

dl_args="--repo $REPO --pattern $asset --output $tmp --clobber"
# If VERSION is set, pass it as a positional tag; otherwise gh resolves
# the latest release automatically.
if [ -n "$VERSION" ]; then
  # shellcheck disable=SC2086
  gh release download "$VERSION" $dl_args || die "download failed — check that $VERSION exists on $REPO"
else
  # shellcheck disable=SC2086
  gh release download $dl_args || die "download failed — no release on $REPO?"
fi

# Basic sanity: non-empty binary
size=$(wc -c < "$tmp" | tr -d ' ')
if [ "$size" -lt 100000 ]; then
  die "downloaded file is only $size bytes — likely a redirect page, not a binary"
fi

# --- Install ------------------------------------------------------------------
install -m 0755 "$tmp" "$TARGET"

# Strip macOS Gatekeeper quarantine so the binary runs without the
# "cannot be opened because the developer cannot be verified" prompt.
if [ "$os" = "darwin" ]; then
  xattr -d com.apple.quarantine "$TARGET" 2>/dev/null || true
fi

# --- Verify -------------------------------------------------------------------
if ! "$TARGET" --version >/dev/null 2>&1; then
  die "installed binary at $TARGET does not run — check arch or try VERSION=<tag>"
fi

info "installed $("$TARGET" --version) at $TARGET"

# Warn if PREFIX/bin is not on PATH
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) printf '\nNote: %s is not on your PATH. Add this to your shell rc:\n  export PATH="%s:$PATH"\n' "$BINDIR" "$BINDIR" ;;
esac

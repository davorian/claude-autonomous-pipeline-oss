#!/bin/sh
# ac-helper installer — downloads the right prebuilt binary for your OS/arch
# from the latest GitHub Release and drops it into $PREFIX/bin/ac-helper.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/davorian/claude-autonomous-pipeline/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/davorian/claude-autonomous-pipeline/main/install.sh | PREFIX=/usr/local sh
#   curl -fsSL https://raw.githubusercontent.com/davorian/claude-autonomous-pipeline/main/install.sh | VERSION=v0.1.0 sh
#
# Environment:
#   PREFIX   install root (default: $HOME) — binary lands in $PREFIX/bin/ac-helper
#   VERSION  release tag to pin (default: latest)
#
# POSIX sh — runs on any Mac/Linux with curl.

set -eu

REPO="davorian/claude-autonomous-pipeline"
BIN_NAME="ac-helper"
PREFIX="${PREFIX:-$HOME}"
VERSION="${VERSION:-latest}"

BINDIR="$PREFIX/bin"
TARGET="$BINDIR/$BIN_NAME"

die() { printf 'install: %s\n' "$*" >&2; exit 1; }
info() { printf '→ %s\n' "$*"; }

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

# --- URL resolution -----------------------------------------------------------
if [ "$VERSION" = "latest" ]; then
  url="https://github.com/$REPO/releases/latest/download/$asset"
else
  url="https://github.com/$REPO/releases/download/$VERSION/$asset"
fi

# --- Download -----------------------------------------------------------------
info "platform: $os/$arch"
info "version:  $VERSION"
info "source:   $url"
info "target:   $TARGET"

mkdir -p "$BINDIR"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

if ! curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$tmp"; then
  die "download failed — check that release $VERSION exists and asset $asset is attached"
fi

# Basic sanity: non-empty file, not an HTML 404
size=$(wc -c < "$tmp" | tr -d ' ')
if [ "$size" -lt 100000 ]; then
  die "downloaded file is only $size bytes — likely a 404/redirect page, not a binary"
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

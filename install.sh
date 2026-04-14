#!/usr/bin/env sh
# slipway installer — downloads the CLI + commands library into ${PREFIX:-$HOME/.local}.
# Usage:  curl -sSL https://raw.githubusercontent.com/primestageprime/slipway/main/install.sh | sh
#         PREFIX=/usr/local curl -sSL ... | sudo sh
set -eu

PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="$PREFIX/bin"
LIBDIR="$PREFIX/lib/slipway"
REF="${SLIPWAY_REF:-main}"
BASE="https://raw.githubusercontent.com/primestageprime/slipway/${REF}"

command -v jq >/dev/null 2>&1 || { echo "slipway install: missing dependency 'jq'" >&2; exit 1; }

if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -qO- "$1"; }
else
  echo "slipway install: need curl or wget" >&2
  exit 1
fi

mkdir -p "$BINDIR" "$LIBDIR"

tmp_bin=$(mktemp)
tmp_lib=$(mktemp)
trap 'rm -f "$tmp_bin" "$tmp_lib"' EXIT

fetch "$BASE/bin/slipway"                 > "$tmp_bin"
fetch "$BASE/lib/slipway/commands.sh"     > "$tmp_lib"

chmod 0755 "$tmp_bin"
chmod 0644 "$tmp_lib"
mv "$tmp_bin" "$BINDIR/slipway"
mv "$tmp_lib" "$LIBDIR/commands.sh"

echo "installed: $BINDIR/slipway + $LIBDIR/commands.sh (from $REF)"
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo "note: $BINDIR is not on your PATH — add it to your shell rc." ;;
esac

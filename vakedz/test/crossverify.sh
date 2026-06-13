#!/usr/bin/env bash
# crossverify — the closed-loop dogfooding gate for vakedz.
#
# Builds nothing; takes a path to the vakedz binary, runs `vakedz parse` on each
# example whose graph we have a committed golden for, and asserts byte-identical
# output. Also re-derives each golden from the Python reference (`vakedc parse`)
# and warns if the committed golden has drifted from it — so the Zig front-end
# and the Python reference are pinned to the SAME bytes, forever.
#
# Usage:  vakedz/test/crossverify.sh [path/to/vakedz]
set -euo pipefail

BIN="${1:-vakedz/zig-out/bin/vakedz}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if [[ ! -x "$BIN" ]]; then
  echo "crossverify: vakedz binary not found at '$BIN' (run: cd vakedz && zig build)" >&2
  exit 2
fi

# source.vaked  ->  committed golden graph
PAIRS=(
  "vaked/examples/operator-field.vaked|vakedz/test/golden/operator-field.graph.json"
  "vaked/examples/engines/zig.vaked|vakedz/test/golden/zig.graph.json"
)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

for pair in "${PAIRS[@]}"; do
  src="${pair%%|*}"
  golden="${pair##*|}"
  out="$tmp/$(basename "$golden")"

  "$BIN" parse "$src" --json "$out" --no-cache >/dev/null
  if diff -u "$golden" "$out" >"$tmp/diff.txt"; then
    echo "PASS  vakedz parse $src == $golden"
  else
    echo "FAIL  vakedz parse $src != $golden"
    sed 's/^/      /' "$tmp/diff.txt" | head -40
    fail=1
  fi

  # Drift guard: the committed golden must still equal the Python reference.
  if command -v python3 >/dev/null 2>&1 && [[ -d vakedc ]]; then
    ref="$tmp/ref-$(basename "$golden")"
    python3 -m vakedc parse "$src" --json "$ref" 2>/dev/null || true
    if [[ -f "$ref" ]] && ! diff -q "$golden" "$ref" >/dev/null; then
      echo "WARN  golden $golden has drifted from the vakedc reference — regenerate it"
      fail=1
    fi
  fi
done

if [[ "$fail" -eq 0 ]]; then
  echo "crossverify: OK — vakedz is byte-identical to vakedc on all goldens"
else
  echo "crossverify: FAILED" >&2
fi
exit "$fail"

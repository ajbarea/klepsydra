#!/usr/bin/env bash
# Builds the Linux .deb in place; unlike Windows there is no filesystem to
# cross, so no staging copy.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

# The Windows build excludes this harness input when staging; here the bundle
# would embed src/ as-is, so refuse rather than ship it.
if [[ -e src/dev-fixture.json ]]; then
  echo "src/dev-fixture.json is harness input; delete it before building" >&2
  exit 1
fi

echo "==> installing frontend tooling"
npm install --no-fund --no-audit --no-package-lock 2>&1 | tail -5

# Only a .deb newer than this counts: a stale one from an earlier build would
# otherwise report success for a build that produced nothing.
stamp=$(mktemp)
trap 'rm -f "$stamp"' EXIT

echo "==> cargo tauri build"
npx --yes tauri build --bundles deb 2>&1 | tail -30

deb=$(find src-tauri/target/release/bundle/deb -maxdepth 1 -name '*.deb' -newer "$stamp" 2>/dev/null | head -1 || true)
if [[ -z "$deb" ]]; then
  echo "build did not produce a .deb" >&2
  exit 1
fi
echo
echo "built: $deb"
echo "install: sudo apt install ./$deb"

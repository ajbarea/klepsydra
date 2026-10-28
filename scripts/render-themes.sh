#!/usr/bin/env bash
# Renders the Professions and DiceBear themes' faces into src/fleet/faces,
# each with its LICENSES.json entry: Lucide glyphs on accent discs and
# DiceBear Lorelei faces, from the packages scripts/render-themes/ pins
# (package-lock.json), installed into a temp dir. Run once and commit the results; the app loads no library and calls no
# avatar service at run time.
# Usage: bash scripts/render-themes.sh
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp:?}"' EXIT

echo "==> pinned packages into $tmp"
# Every package, transitive ones included, at the version and hash
# scripts/render-themes/package-lock.json records.
cp "$repo/scripts/render-themes/package.json" "$repo/scripts/render-themes/package-lock.json" "$tmp/"
npm ci --prefix "$tmp" --no-fund --no-audit --ignore-scripts >/dev/null
mkdir -p "$tmp/svg"
node "$repo/scripts/render-themes.mjs" "$tmp" "$tmp/svg"

echo "==> WebP into src/fleet/faces"
uv run -q --no-project --with playwright --with pillow==13.0.0 \
  python -I "$repo/scripts/render-themes.py" "$tmp/svg" "$repo/src/fleet/faces"

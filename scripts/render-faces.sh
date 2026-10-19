#!/usr/bin/env bash
# Regenerates every face under src/fleet/faces: the ten kourai-khryseai
# portraits and the DiceBear Lorelei faces, each with its LICENSES.json entry.
# Run once and commit the results; the app loads no library at run time.
# Usage: bash scripts/render-faces.sh [path/to/kourai-khryseai]
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
kourai=${1:-$HOME/ajsoftworks/kourai-khryseai}
faces="$repo/src/fleet/faces"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "==> DiceBear 9.4.2 into $tmp"
npm install --prefix "$tmp" --no-save --no-fund --no-audit --ignore-scripts \
  @dicebear/core@9.4.2 @dicebear/lorelei@9.4.2 >/dev/null
node "$repo/scripts/render-lorelei.mjs" "$tmp" "$faces"

echo "==> kourai portraits from $kourai"
uv run --no-project --with pillow==13.0.0 python -I "$repo/scripts/cut-portraits.py" "$kourai" "$faces"

#!/usr/bin/env bash
# Builds the Windows binary. Source of truth stays in the WSL repo; Cargo runs
# against a native NTFS staging copy, because building on a \\wsl$ UNC path is
# slow and prone to link failures. The staging target/ dir persists, so repeat
# builds are incremental.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
stage_win="C:\\Users\\$USER\\klepsydra-build"
stage="/mnt/c/Users/$USER/klepsydra-build"

mkdir -p "$stage"
# Everything except build output and VCS; target/ and node_modules/ stay put.
rsync -a --delete \
  --exclude 'src-tauri/target/' --exclude 'node_modules/' --exclude '.git/' \
  --exclude 'src/dev-fixture.json' \
  "$repo"/ "$stage"/

# WSL builds its Windows PATH at startup, so tools installed since then are
# missing from any powershell.exe we spawn. Put them back explicitly.
# shellcheck disable=SC2016  # PowerShell source: $env: must reach pwsh unexpanded.
tools='$env:Path = "C:\\Program Files\\nodejs;$env:USERPROFILE\\.cargo\\bin;" + $env:Path'

echo "==> installing frontend tooling"
powershell.exe -NoProfile -Command "$tools; cd '$stage_win'; npm install --no-fund --no-audit" 2>&1 | tail -5

echo "==> cargo tauri build"
powershell.exe -NoProfile -Command "$tools; cd '$stage_win'; npx --yes tauri build" 2>&1 | tail -60

exe="$stage/src-tauri/target/release/klepsydra.exe"
if [[ -f "$exe" ]]; then
  echo
  printf 'built: %s\\src-tauri\\target\\release\\klepsydra.exe\n' "$stage_win"
  ls -la "$exe"
else
  echo "build did not produce klepsydra.exe" >&2
  exit 1
fi

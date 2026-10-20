#!/usr/bin/env bash
# Builds the Windows binary. Source of truth stays in the WSL repo; Cargo runs
# against a native NTFS staging copy, because building on a \\wsl$ UNC path is
# slow and prone to link failures. The staging target/ dir persists, so repeat
# builds are incremental. KLEPSYDRA_STAGE names the staging folder (default
# klepsydra-build), so a branch can build in a folder of its own. With --check
# it runs clippy and the tests there instead, for the code that compiles only
# on Windows.
set -euo pipefail

# Refuses a stage name or folder that rsync --delete must never touch.
check_stage() {
  local name=$1 dir=$2
  if [[ ! $name =~ ^klepsydra-build(-[A-Za-z0-9._]+)?$ ]]; then
    echo "KLEPSYDRA_STAGE must be klepsydra-build or klepsydra-build-<name>: $name" >&2
    return 2
  fi
  if [[ -d $dir && -n $(ls -A "$dir") && ! -f $dir/src-tauri/Cargo.toml ]]; then
    echo "$dir is not empty and is not a klepsydra stage; refusing to mirror into it." >&2
    return 2
  fi
}

# Sourced by scripts/test_build_windows.sh for the check alone.
[[ ${BASH_SOURCE[0]} != "$0" ]] && return 0

repo=$(cd "$(dirname "$0")/.." && pwd)
stage_name=${KLEPSYDRA_STAGE:-klepsydra-build}
stage_win="C:\\Users\\$USER\\$stage_name"
stage="/mnt/c/Users/$USER/$stage_name"
check_stage "$stage_name" "$stage" || exit 2

mkdir -p "$stage"
# Everything except build output and VCS; target/ and node_modules/ stay put.
rsync -a --delete \
  --exclude 'src-tauri/target/' --exclude 'node_modules/' --exclude '.git/' \
  --exclude 'src/dev-fixture.json' --exclude 'src/dev-fleet.json' \
  "$repo"/ "$stage"/

# WSL builds its Windows PATH at startup, so tools installed since then are
# missing from any powershell.exe we spawn. Put them back explicitly.
# shellcheck disable=SC2016  # PowerShell source: $env: must reach pwsh unexpanded.
tools='$env:Path = "C:\\Program Files\\nodejs;$env:USERPROFILE\\.cargo\\bin;" + $env:Path'

if [[ ${1:-} == --check ]]; then
  echo "==> cargo clippy and cargo test, on Windows"
  powershell.exe -NoProfile -Command "$tools; cd '$stage_win\\src-tauri'; cargo clippy --workspace --all-targets -- -D warnings; if (\$LASTEXITCODE) { exit \$LASTEXITCODE }; cargo test --workspace; exit \$LASTEXITCODE"
  exit $?
fi

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

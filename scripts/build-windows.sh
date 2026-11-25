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

# Stops any Windows process whose command line contains the stage folder name.
stop_windows_stage_processes() {
  local name=$1
  if [[ ! $name =~ ^klepsydra-build(-[A-Za-z0-9._]+)?$ ]]; then
    return 0
  fi
  # shellcheck disable=SC2016 # PowerShell source: $ variables reach pwsh unexpanded.
  timeout 15s powershell.exe -NoProfile -Command \
    "Get-CimInstance Win32_Process | Where-Object { \$_.ProcessId -ne \$PID -and \$_.CommandLine -like '*$name*' } | Stop-Process -Force -ErrorAction SilentlyContinue" 2>/dev/null || true
}

# Runs powershell under a time limit, stopping stage processes on timeout.
run_powershell() {
  local timeout_s=${FLEET_WINBUILD_TIMEOUT_S:-1800}
  local min=$(( (timeout_s + 59) / 60 ))
  local stage=${stage_name:-${KLEPSYDRA_STAGE:-klepsydra-build}}
  local timer_flag; timer_flag=$(mktemp -u /tmp/winbuild_timeout.XXXXXX)

  powershell.exe "$@" &
  local pwsh_pid=$!

  (
    sleep "$timeout_s" &
    wait $!
    touch "$timer_flag"
    kill -TERM "$pwsh_pid" 2>/dev/null
    pkill -P "$pwsh_pid" 2>/dev/null || true
  ) &
  local timer_pid=$!

  local rc=0
  wait "$pwsh_pid" 2>/dev/null || rc=$?

  pkill -P "$timer_pid" 2>/dev/null || true
  kill -9 "$timer_pid" 2>/dev/null || true
  wait "$timer_pid" 2>/dev/null || true

  if [[ -f "$timer_flag" ]]; then
    rm -f "$timer_flag"
    kill -KILL "$pwsh_pid" 2>/dev/null || true
    pkill -9 -P "$pwsh_pid" 2>/dev/null || true
    cleaned_up=1
    stop_windows_stage_processes "$stage"
    echo "build-windows: hung: no compiler running after $min min; skip the local Windows check, CI windows-latest covers it" >&2
    return 1
  fi

  return "$rc"
}

# Sourced by scripts/test_build_windows.sh for the check alone.
[[ ${BASH_SOURCE[0]} != "$0" ]] && return 0

repo=$(cd "$(dirname "$0")/.." && pwd)
stage_name=${KLEPSYDRA_STAGE:-klepsydra-build}
stage_root=${KLEPSYDRA_STAGE_ROOT:-/mnt/c/Users/$USER}
stage_win="C:\\Users\\$USER\\$stage_name"
stage="$stage_root/$stage_name"
check_stage "$stage_name" "$stage" || exit 2

cleaned_up=0
cleanup() {
  local rc=$?
  if (( rc != 0 && cleaned_up == 0 )); then
    cleaned_up=1
    stop_windows_stage_processes "$stage_name"
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$stage"
# Everything except build output and VCS; target/ and node_modules/ stay put.
rsync -a --delete \
  --exclude 'src-tauri/target/' --exclude 'node_modules/' --exclude '.git/' \
  --exclude 'src/dev-fixture.json' --exclude 'src/dev-fleet.json' --exclude '.claude/' \
  "$repo"/ "$stage"/

# WSL builds its Windows PATH at startup, so tools installed since then are
# missing from any powershell.exe we spawn. Put them back explicitly.
# shellcheck disable=SC2016  # PowerShell source: $env: must reach pwsh unexpanded.
tools='$env:Path = "C:\\Program Files\\nodejs;$env:USERPROFILE\\.cargo\\bin;" + $env:Path'

if [[ ${1:-} == --check ]]; then
  echo "==> cargo clippy and cargo test, on Windows"
  run_powershell -NoProfile -Command "$tools; cd '$stage_win\\src-tauri'; cargo clippy --workspace --all-targets -- -D warnings; if (\$LASTEXITCODE) { exit \$LASTEXITCODE }; cargo test --workspace; exit \$LASTEXITCODE"
  exit $?
fi

echo "==> installing frontend tooling"
run_powershell -NoProfile -Command "$tools; cd '$stage_win'; npm install --no-fund --no-audit" 2>&1 | tail -5

echo "==> cargo tauri build"
run_powershell -NoProfile -Command "$tools; cd '$stage_win'; npx --yes tauri build" 2>&1 | tail -60

exe="$stage/src-tauri/target/release/klepsydra.exe"
if [[ -f "$exe" ]]; then
  echo
  printf 'built: %s\\src-tauri\\target\\release\\klepsydra.exe\n' "$stage_win"
  ls -la "$exe"
else
  echo "build did not produce klepsydra.exe" >&2
  exit 1
fi

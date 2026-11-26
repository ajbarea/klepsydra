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

# Returns the anchored PowerShell filter matching this stage folder on command lines.
stage_filter() {
  local stage_target=$1
  cat <<END
\$_.CommandLine -match ('(?i)' + [regex]::Escape('$stage_target') + '(?=[\\\\/"''\\s]|$)')
END
}

# Stops any Windows process whose command line targets this stage folder.
stop_windows_stage_processes() {
  local name=$1
  local stage_target=${2:-C:\\Users\\$USER\\$name}
  if [[ ! $name =~ ^klepsydra-build(-[A-Za-z0-9._]+)?$ ]]; then
    return 0
  fi
  timeout 15s powershell.exe -NoProfile -Command \
    "$(stop_script 'Get-CimInstance Win32_Process' "$stage_target")" 2>/dev/null || true
}

# Prints the PowerShell that stops each process from source $1 whose command
# line targets stage $2. Stop by -Id: piped whole, a Win32_Process binds its
# Name ("cargo.exe") to -Name, which matches no process, so nothing stops.
stop_script() {
  # shellcheck disable=SC2016 # PowerShell source: $ variables reach pwsh unexpanded.
  printf '%s | Where-Object { $_.ProcessId -ne $PID -and %s } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }\n' \
    "$1" "$(stage_filter "$2")"
}

# Runs powershell under a time limit, stopping stage processes on timeout.
run_powershell() {
  local timeout_s=${FLEET_WINBUILD_TIMEOUT_S:-1800}
  if [[ ! $timeout_s =~ ^[0-9]+$ ]] || (( timeout_s <= 0 )); then
    timeout_s=1800
  fi
  local min=$(( (timeout_s + 59) / 60 ))
  local stage=${stage_name:-${KLEPSYDRA_STAGE:-klepsydra-build}}
  local win=${stage_win:-C:\\Users\\$USER\\$stage}

  local rc=0
  timeout --foreground -k 10s "${timeout_s}s" powershell.exe "$@" || rc=$?

  if (( rc == 124 || rc == 137 )); then
    cleaned_up=1
    stop_windows_stage_processes "$stage" "$win"
    if [[ ${check_mode:-0} == 1 || ${*:-} =~ --check|cargo\ (clippy|test) ]]; then
      echo "build-windows: hung after $min min; skip the local Windows check, CI windows-latest covers it" >&2
    else
      echo "build-windows: hung after $min min" >&2
    fi
    return 1
  fi

  return "$rc"
}

# Sourced by scripts/test_build_windows.sh for the check alone.
[[ ${BASH_SOURCE[0]} != "$0" ]] && return 0

repo=$(cd "$(dirname "$0")/.." && pwd)
stage_name=${KLEPSYDRA_STAGE:-klepsydra-build}
stage_root=${KLEPSYDRA_STAGE_ROOT:-/mnt/c/Users/$USER}
stage="$stage_root/$stage_name"
check_stage "$stage_name" "$stage" || exit 2

if [[ -n ${KLEPSYDRA_STAGE_WIN:-} ]]; then
  stage_win=$KLEPSYDRA_STAGE_WIN
elif [[ -n ${KLEPSYDRA_STAGE_ROOT:-} ]]; then
  stage_win=$(wslpath -w "$stage" 2>/dev/null || printf 'C:\\Users\\%s\\%s\n' "$USER" "$stage_name")
else
  stage_win="C:\\Users\\$USER\\$stage_name"
fi

cleaned_up=0
build_log=""

on_signal() {
  local sig=$1
  if (( cleaned_up == 0 )); then
    cleaned_up=1
    stop_windows_stage_processes "$stage_name" "$stage_win"
  fi
  [[ -n ${build_log:-} && -f $build_log ]] && rm -f "$build_log"
  exit "$sig"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap '[[ -n ${build_log:-} && -f $build_log ]] && rm -f "$build_log"' EXIT

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
  check_mode=1
  echo "==> cargo clippy and cargo test, on Windows"
  run_powershell -NoProfile -Command "$tools; cd '$stage_win\\src-tauri'; cargo clippy --workspace --all-targets -- -D warnings; if (\$LASTEXITCODE) { exit \$LASTEXITCODE }; cargo test --workspace; exit \$LASTEXITCODE"
  exit $?
fi

check_mode=0
echo "==> installing frontend tooling"
build_log=$(mktemp)
run_powershell -NoProfile -Command "$tools; cd '$stage_win'; npm install --no-fund --no-audit" >"$build_log" 2>&1 || {
  rc=$?
  tail -5 "$build_log"
  rm -f "$build_log"
  exit "$rc"
}
tail -5 "$build_log"
rm -f "$build_log"

echo "==> cargo tauri build"
build_log=$(mktemp)
run_powershell -NoProfile -Command "$tools; cd '$stage_win'; npx --yes tauri build" >"$build_log" 2>&1 || {
  rc=$?
  tail -60 "$build_log"
  rm -f "$build_log"
  exit "$rc"
}
tail -60 "$build_log"
rm -f "$build_log"

exe="$stage/src-tauri/target/release/klepsydra.exe"
if [[ -f "$exe" ]]; then
  echo
  printf 'built: %s\\src-tauri\\target\\release\\klepsydra.exe\n' "$stage_win"
  ls -la "$exe"
else
  echo "build did not produce klepsydra.exe" >&2
  exit 1
fi

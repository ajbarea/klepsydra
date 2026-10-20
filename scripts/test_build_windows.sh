#!/usr/bin/env bash
# Tests for the Windows build's stage check. Run: bash scripts/test_build_windows.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck source=scripts/build-windows.sh
source "$here/build-windows.sh"
pass=0 fail=0

check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
  fi
}

verdict() { check_stage "$1" "${2:-$work/none}" >/dev/null 2>&1; echo $?; }

for bad in . .. Documents "a'b" klepsydra-buildx "" "klepsydra-build-a b" "klepsydra-build-a;b"; do
  check "refuses '$bad'" "$(verdict "$bad")" 2
done
for good in klepsydra-build klepsydra-build-launch klepsydra-build-v1.2_x; do
  check "accepts $good" "$(verdict "$good")" 0
done

mkdir -p "$work/other" "$work/stage/src-tauri" "$work/empty"
touch "$work/other/file" "$work/stage/src-tauri/Cargo.toml"
check "refuses a non-empty foreign folder" "$(verdict klepsydra-build "$work/other")" 2
check "accepts an existing stage" "$(verdict klepsydra-build "$work/stage")" 0
check "accepts an empty folder" "$(verdict klepsydra-build "$work/empty")" 0

printf '%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))

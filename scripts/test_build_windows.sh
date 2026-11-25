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

# The stage copy must skip agent worktrees: 11-24 it copied 455 MB of them and failed.
# shellcheck disable=SC2016 # $repo is the literal text in build-windows.sh, not a variable here
excludes=$(sed -n '/^rsync -a --delete/,/"\$repo"/p' "$(dirname "$0")/build-windows.sh")
for path in .claude/ .git/ node_modules/ src-tauri/target/; do
  check "stage copy excludes $path" "$(grep -cF -- "--exclude '$path'" <<<"$excludes")" 1
done

# Timeout and cleanup tests with a fake powershell.exe (#560).
mkdir -p "$work/bin"
cat <<'EOF' > "$work/bin/powershell.exe"
#!/usr/bin/env bash
if [[ "$*" =~ Stop-Process ]]; then
  echo "stopped" >> "${PWSH_LOG:-/dev/null}"
  exit 0
fi
if [[ -n "${PWSH_SLEEP:-}" ]]; then
  exec sleep "$PWSH_SLEEP"
fi
EOF
chmod +x "$work/bin/powershell.exe"

# A hung powershell is stopped at the time limit and reports the skip line.
pwsh_hung_log="$work/pwsh_hung.log"
rc_hung=0
out_hung=$(
  PATH="$work/bin:$PATH" \
  FLEET_WINBUILD_TIMEOUT_S=1 \
  PWSH_SLEEP=9999 \
  PWSH_LOG="$pwsh_hung_log" \
  KLEPSYDRA_STAGE_ROOT="$work/stage_root" \
  KLEPSYDRA_STAGE="klepsydra-build-test_hung" \
  timeout 10s bash "$here/build-windows.sh" --check 2>&1
) || rc_hung=$?

check "hung run exits non-zero" "$rc_hung" 1
check "hung run prints skip line" "$(grep -cF 'build-windows: hung: no compiler running after 1 min; skip the local Windows check, CI windows-latest covers it' <<<"$out_hung")" 1
check "hung run stops Windows processes" "$(grep -cF 'stopped' "$pwsh_hung_log" 2>/dev/null || echo 0)" 1

# A normal powershell run finishes cleanly and does not print the hung error.
pwsh_normal_log="$work/pwsh_normal.log"
rc_normal=0
out_normal=$(
  PATH="$work/bin:$PATH" \
  PWSH_SLEEP="" \
  PWSH_LOG="$pwsh_normal_log" \
  KLEPSYDRA_STAGE_ROOT="$work/stage_root" \
  KLEPSYDRA_STAGE="klepsydra-build-test_normal" \
  timeout 10s bash "$here/build-windows.sh" --check 2>&1
) || rc_normal=$?

check "normal run exits zero" "$rc_normal" 0
check "normal run prints no hung warning" "$(grep -cF 'build-windows: hung:' <<<"$out_normal")" 0
check "normal run does not stop processes" "$(grep -cF 'stopped' "$pwsh_normal_log" 2>/dev/null || echo 0)" 0

printf '%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))

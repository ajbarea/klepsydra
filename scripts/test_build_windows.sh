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

# Filter expression test: anchored case-insensitive match on Windows stage path.
expected_filter=$(cat <<'END'
$_.CommandLine -match ('(?i)' + [regex]::Escape('C:\Users\x\klepsydra-build') + '(?=[\\/"''\s]|$)')
END
)
check "stage_filter produces expected expression" "$(stage_filter 'C:\Users\x\klepsydra-build')" "$expected_filter"

if command -v pwsh >/dev/null 2>&1; then
  # shellcheck disable=SC2016 # PowerShell source: $ expressions reach pwsh unexpanded
  pwsh_res=$(pwsh -NoProfile -Command '
    $pattern = "(?i)" + [regex]::Escape("C:\Users\x\klepsydra-build") + "(?=[\\/\"'\''\s]|$)"
    $cases = @(
      @{ cmd = "cargo.exe run in C:\Users\x\klepsydra-build\src-tauri"; want = $true },
      @{ cmd = "c:\users\X\klepsydra-build\target\release.exe"; want = $true },
      @{ cmd = "cargo.exe in C:\Users\x\klepsydra-build-foo\a"; want = $false },
      @{ cmd = "Code.exe C:\Users\x\klepsydra-build"; want = $true },
      @{ cmd = "powershell.exe C:\Users\x\klepsydra-build.bak"; want = $false },
      @{ cmd = "cargo.exe D:\Users\x\klepsydra-build\src"; want = $false }
    )
    $all_ok = $true
    foreach ($c in $cases) {
      if (($c.cmd -match $pattern) -ne $c.want) { $all_ok = $false }
    }
    if ($all_ok) { "pass" } else { "fail" }
  ')
  check "pwsh table test matches filter cases" "$pwsh_res" "pass"
fi

# Timeout and cleanup tests with a fake powershell.exe (#560).
mkdir -p "$work/bin"
cat <<'EOF' > "$work/bin/powershell.exe"
#!/usr/bin/env bash
if [[ "$*" =~ Stop-Process ]]; then
  echo "$*" >> "${PWSH_LOG:-/dev/null}"
  exit 0
fi
if [[ -n "${PWSH_EXIT:-}" ]]; then
  exit "$PWSH_EXIT"
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
  KLEPSYDRA_STAGE_WIN='C:\Users\testuser\klepsydra-build-test_hung' \
  timeout 10s bash "$here/build-windows.sh" --check 2>&1
) || rc_hung=$?

check "hung run exits non-zero" "$rc_hung" 1
check "hung run prints skip line" "$(grep -cF 'build-windows: hung after 1 min; skip the local Windows check, CI windows-latest covers it' <<<"$out_hung")" 1
hung_filter=$(stage_filter 'C:\Users\testuser\klepsydra-build-test_hung')
check "hung run stops Windows processes with anchored filter" "$(grep -cF -- "$hung_filter" "$pwsh_hung_log" 2>/dev/null || echo 0)" 1

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
check "normal run prints no hung warning" "$(grep -cF 'build-windows: hung' <<<"$out_normal")" 0
check "normal run does not stop processes" "$(grep -cF 'Stop-Process' "$pwsh_normal_log" 2>/dev/null || echo 0)" 0

# An ordinary clippy failure (exit 101) does not run process cleanup.
pwsh_clippy_log="$work/pwsh_clippy.log"
rc_clippy=0
PATH="$work/bin:$PATH" \
PWSH_EXIT=101 \
PWSH_LOG="$pwsh_clippy_log" \
KLEPSYDRA_STAGE_ROOT="$work/stage_root" \
KLEPSYDRA_STAGE="klepsydra-build-test_clippy" \
timeout 10s bash "$here/build-windows.sh" --check >/dev/null 2>&1 || rc_clippy=$?

check "clippy error exits with powershell exit code" "$rc_clippy" 101
check "clippy error does not run cleanup" "$(grep -cF 'Stop-Process' "$pwsh_clippy_log" 2>/dev/null || echo 0)" 0

# Signal handling: SIGTERM cleans up and exits 143.
pwsh_sig_log="$work/pwsh_sig.log"
PATH="$work/bin:$PATH" \
PWSH_SLEEP=9999 \
PWSH_LOG="$pwsh_sig_log" \
KLEPSYDRA_STAGE_ROOT="$work/stage_root" \
KLEPSYDRA_STAGE="klepsydra-build-test_sig" \
timeout 10s bash "$here/build-windows.sh" --check >/dev/null 2>&1 &
build_pid=$!
sleep 0.5
kill -TERM "$build_pid" 2>/dev/null || true
rc_sig=0
wait "$build_pid" 2>/dev/null || rc_sig=$?

check "SIGTERM exits 143" "$rc_sig" 143
check "SIGTERM stops Windows processes" "$(grep -cF 'Stop-Process' "$pwsh_sig_log" 2>/dev/null || echo 0)" 1

# Release build timeout prints general hung message without check-specific advice.
pwsh_build_log="$work/pwsh_build.log"
rc_build=0
out_build=$(
  PATH="$work/bin:$PATH" \
  FLEET_WINBUILD_TIMEOUT_S=1 \
  PWSH_SLEEP=9999 \
  PWSH_LOG="$pwsh_build_log" \
  KLEPSYDRA_STAGE_ROOT="$work/stage_root" \
  KLEPSYDRA_STAGE="klepsydra-build-test_bld" \
  timeout 10s bash "$here/build-windows.sh" 2>&1
) || rc_build=$?

check "build timeout exits non-zero" "$rc_build" 1
check "build timeout prints build hung notice" "$(grep -cF 'build-windows: hung after 1 min' <<<"$out_build")" 1
check "build timeout does not print check-only advice" "$(grep -cF 'skip the local Windows check' <<<"$out_build")" 0
check "build timeout stops Windows processes" "$(grep -cF 'Stop-Process' "$pwsh_build_log" 2>/dev/null || echo 0)" 1

# Negative timeout value is sanitized to default and does not abort normal run.
pwsh_neg_log="$work/pwsh_neg.log"
rc_neg=0
PATH="$work/bin:$PATH" \
FLEET_WINBUILD_TIMEOUT_S=-5 \
PWSH_SLEEP="" \
PWSH_LOG="$pwsh_neg_log" \
KLEPSYDRA_STAGE_ROOT="$work/stage_root" \
KLEPSYDRA_STAGE="klepsydra-build-test_neg" \
timeout 10s bash "$here/build-windows.sh" --check >/dev/null 2>&1 || rc_neg=$?

check "negative timeout sanitized, normal run exits zero" "$rc_neg" 0

printf '%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))

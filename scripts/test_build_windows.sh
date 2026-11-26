#!/usr/bin/env bash
# Tests for the Windows build's stage check. Run: bash scripts/test_build_windows.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
finished=0
# An exit before the summary names the command that failed, so CI never ends
# on a bare exit code (the build script it sources runs under set -e).
on_exit() {
  local rc=$?
  rm -rf -- "${work:?}"
  if ((finished == 0)); then
    printf 'FAIL test_build_windows.sh ended before the summary (exit %s) at line %s: %s\n' "$rc" "$err_line" "$err_cmd" >&2
    printf '::error file=scripts/test_build_windows.sh,line=%s::ended before the summary (exit %s): %s\n' "$err_line" "$rc" "$err_cmd"
    ((rc != 0)) || rc=1
  fi
  exit "$rc"
}
err_line='?' err_cmd='?'
trap 'err_line=$LINENO err_cmd=$BASH_COMMAND' ERR
trap on_exit EXIT
# shellcheck source=scripts/build-windows.sh
source "$here/build-windows.sh"
# The build script runs under set -e; the checks below must not inherit it.
set +e -uo pipefail
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

# Runs stage_filter's own output in PowerShell over a table of command lines
# (one "want<TAB>command line" per stdin line); prints each mismatch, or
# "pass". The filter reaches pwsh in a file, never through shell quoting.
# shellcheck disable=SC2016 # PowerShell source: $ expressions reach pwsh unexpanded
filter_table() {
  local stage=$1 want cmd
  {
    echo '$cases = @('
    while IFS=$'\t' read -r want cmd; do
      printf "  [pscustomobject]@{ CommandLine = '%s'; want = \$%s }\n" "${cmd//\'/\'\'}" "$want"
    done
    echo ')'
    printf '$bad = $cases | Where-Object { (%s) -ne $_.want }\n' "$(stage_filter "$stage")"
    echo 'if ($bad) { $bad | ForEach-Object { "mismatch: " + $_.CommandLine } } else { "pass" }'
  } >"$work/filter.ps1"
  pwsh -NoProfile -NonInteractive -File "$work/filter.ps1" 2>&1
}

if command -v pwsh >/dev/null 2>&1; then
  check "stage_filter in pwsh matches its own stage only" "$(filter_table 'C:\Users\x\klepsydra-build' <<'END'
true	cargo.exe run in C:\Users\x\klepsydra-build\src-tauri
true	c:\users\X\klepsydra-build\target\release.exe
true	Code.exe C:\Users\x\klepsydra-build
true	node.exe "C:\Users\x\klepsydra-build" x
true	node.exe 'C:\Users\x\klepsydra-build' x
true	cargo.exe C:\Users\x\klepsydra-build/src-tauri
false	cargo.exe in C:\Users\x\klepsydra-build-foo\a
false	powershell.exe C:\Users\x\klepsydra-build.bak
false	cargo.exe D:\Users\x\klepsydra-build\src
false	cargo.exe C:\Users\y\klepsydra-build\src
END
)" pass
  check "a branch stage's filter skips a longer branch name" "$(filter_table 'C:\Users\x\klepsydra-build-agy_5' <<'END'
true	cargo.exe C:\Users\x\klepsydra-build-agy_5\src-tauri
false	cargo.exe C:\Users\x\klepsydra-build-agy_533\src-tauri
false	cargo.exe C:\Users\x\klepsydra-build\src-tauri
END
)" pass
  # stop_script's own text, fed process objects shaped like Win32_Process
  # (Name carries ".exe"), stops the stage's process and only that one.
  gone() { # true once pid $1 has exited (zombie or reaped), within 5 s
    local i state
    for ((i = 0; i < 50; i++)); do
      state=$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)
      [[ -z $state || $state == Z ]] && return 0
      sleep 0.1
    done
    return 1
  }
  sleep 300 & victim=$!
  sleep 300 & bystander=$!
  stop_script "@(
    [pscustomobject]@{ ProcessId = $victim; Name = 'cargo.exe'; CommandLine = 'cargo.exe C:\Users\x\klepsydra-build\src-tauri' },
    [pscustomobject]@{ ProcessId = $bystander; Name = 'cargo.exe'; CommandLine = 'cargo.exe C:\Users\x\klepsydra-build-foo\src-tauri' })" \
    'C:\Users\x\klepsydra-build' >"$work/stop.ps1"
  pwsh -NoProfile -NonInteractive -File "$work/stop.ps1" >/dev/null 2>&1
  check "stop_script stops the stage's process" "$(gone "$victim" && echo stopped || echo running)" stopped
  check "stop_script leaves another stage's process" "$(gone "$bystander" && echo stopped || echo running)" running
  kill "$victim" "$bystander" 2>/dev/null
  { wait "$victim" "$bystander"; } 2>/dev/null
else
  echo "  skip stage_filter and stop_script in pwsh (no pwsh on PATH)"
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
finished=1
((fail == 0))

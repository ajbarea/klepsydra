#!/usr/bin/env bash
# Tests for scripts/shellcheck.sh, make shellcheck's runner (#503), with a stub
# in place of ShellCheck and a fake cgroup tree: no tmux, no real ShellCheck run.
set -uo pipefail
unset CI GITHUB_ACTIONS FLEET_SHELLCHECK_ALL # the cases set what they need

here=$(cd "$(dirname "$0")" && pwd)
runner="$here/shellcheck.sh"
work=$(mktemp -d)
trap 'rm -rf -- "${work:?}"' EXIT

pass=0 fail=0
check() { # NAME GOT WANT
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$3" "$2"
  fi
}

# The stub prints its arguments; a file named *bad* makes it fail, as a finding would.
# shellcheck disable=SC2016 # the stub's own $a and $@
printf '%s\n' '#!/usr/bin/env bash' 'printf "checked:"; printf " %s" "$@"; echo' \
  'for a; do [[ $a == *bad* ]] && exit 1; done; exit 0' >"$work/fake-shellcheck"
chmod +x "$work/fake-shellcheck"
small="$work/small.sh" big="$work/big.sh"
printf 'echo hi\n' >"$small"
seq 1 3500 | sed 's/^/: /' >"$big"

# A cgroup tree as WSL has it: the scope allows 5 GiB, the slice above it 3.6 GiB
# of which 3 GiB is in use, so 556 MiB is really left.
cg="$work/cg" scope=user.slice/fleet.slice/fleet-workers.slice/w.scope
mkdir -p "$cg/$scope" "$work/proc/self"
echo "0::/$scope" >"$work/proc/self/cgroup"
echo 5368709120 >"$cg/$scope/memory.max"; echo 104857600 >"$cg/$scope/memory.current"
echo 3804233728 >"$cg/user.slice/fleet.slice/fleet-workers.slice/memory.max"
echo 3221225472 >"$cg/user.slice/fleet.slice/fleet-workers.slice/memory.current"
echo max >"$cg/user.slice/fleet.slice/memory.max"
printf 'MemTotal: 16000000 kB\nMemAvailable: 9000000 kB\n' >"$work/meminfo-roomy"
printf 'MemTotal: 16000000 kB\nMemAvailable: 2000000 kB\n' >"$work/meminfo-low"
run() { # [VAR=VALUE...] -- ARGS...: the runner's output (stdout and stderr), then rc=N
  local -a env=()
  while [[ $1 != -- ]]; do env+=("$1"); shift; done
  shift
  env SHELLCHECK_BIN="$work/fake-shellcheck" FLEET_PROC="$work/proc" FLEET_CGROUP_ROOT="$cg" \
    FLEET_MEMINFO="$work/meminfo-roomy" "${env[@]}" bash "$runner" "$@" 2>&1
  echo "rc=$?"
}
R='--extended-analysis=false --exclude=SC2086' # a reduced run's flags
open="$work/open" # a cgroup tree with no limit anywhere
mkdir -p "$open/$scope"; echo max >"$open/$scope/memory.max"

check "small files are checked together, in full, when the room covers their need" \
  "$(run FLEET_SHELLCHECK_SMALL_NEED_MIB=500 -- -x "$small" "$small")" "checked: -x -- $small $small
rc=0"
out=$(run FLEET_SHELLCHECK_SMALL_NEED_MIB=1000 -- -x "$small" "$small" "$small" "$small")
check "small files over the room are checked without dataflow too, and the note counts them" \
  "$(grep -c "^checked: $R -x -- " <<<"$out") $(grep -c '^note: 4 files checked without dataflow analysis or SC2086: 556 MiB of room, under the 1000 MiB it needs' <<<"$out")" "1 1"
check "a big file with room is checked in full" "$(run FLEET_CGROUP_ROOT="$open" -- -x "$big")" "checked: -x -- $big
rc=0"
out=$(run -- -x "$big")
check "the slice above the scope sets the room: a big file is checked without dataflow, not skipped" \
  "$(grep -c "^checked: $R -x -- .*big.sh\$" <<<"$out") $(tail -1 <<<"$out")" "1 rc=0"
check "and a note says so, with the room it found and how to run it all" \
  "$(grep -c '^note: .*big.sh checked without dataflow analysis or SC2086: 556 MiB of room, under the 4000 MiB it needs; CI runs the full check (FLEET_SHELLCHECK_ALL=1 runs it here)$' <<<"$out")" "1"
out=$(run FLEET_CGROUP_ROOT="$open" FLEET_MEMINFO="$work/meminfo-low" -- -x "$big")
check "with no cgroup limit, a machine short of memory does the same" \
  "$(grep -c 'extended-analysis=false' <<<"$out") $(grep -c '1953 MiB of room' <<<"$out")" "1 1"
check "FLEET_SHELLCHECK_ALL=1 runs it in full regardless" "$(run FLEET_SHELLCHECK_ALL=1 -- -x "$big")" "checked: -x -- $big
rc=0"
check "so does CI" "$(run CI=true -- -x "$big")" "checked: -x -- $big
rc=0"
check "small and big files each go to their own run" "$(run -- -x "$small" "$big" | grep -c '^checked:')" "2"
cp "$small" "$work/bad.sh"
check "a finding fails the run, whichever file has it" "$(run -- -x "$work/bad.sh" "$big" | tail -1)" "rc=1"
seq 1 3500 | sed 's/^/: /' >"$work/bad-big.sh"
check "including a big file checked without dataflow" "$(run -- -x "$small" "$work/bad-big.sh" | tail -1)" "rc=1"

check "a run without dataflow leaves out SC2086, which reads values through it" \
  "$(run -- -x "$big" | grep -c "^checked: $R -x -- ")" "1"
check "an option's value word stays with it, not read as a file" \
  "$(run FLEET_CGROUP_ROOT="$open" -- -x -s bash -e SC2034 "$big")" "checked: -x -s bash -e SC2034 -- $big
rc=0"
odd="$work/odd" # a limit partway up that cannot be read as a number
mkdir -p "$odd/$scope"; echo max >"$odd/$scope/memory.max"; echo '?' >"$odd/user.slice/memory.max"
out=$(run FLEET_CGROUP_ROOT="$odd" FLEET_SHELLCHECK_SMALL_NEED_MIB=1 -- -x "$small")
check "an unreadable limit is unknown room: checked without dataflow, not in full" \
  "$(grep -c 'extended-analysis=false' <<<"$out") $(grep -c 'room unknown, under' <<<"$out")" "1 1"
check "a grouped short option takes its value word too (-xs bash)" \
  "$(run FLEET_CGROUP_ROOT="$open" -- -xs bash "$big")" "checked: -xs bash -- $big
rc=0"
check "a long option's value word stays with it (--rcfile)" \
  "$(run FLEET_CGROUP_ROOT="$open" -- --rcfile my.rc "$big")" "checked: --rcfile my.rc -- $big
rc=0"
check "after --, every word is a file, and the reduced flags stay before it" \
  "$(run -- -x -- "$big" | grep -c "^checked: $R -x -- $big\$")" "1"
check "no file at all goes to shellcheck, which reports it" "$(run -- -x)" "checked: -x
rc=0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))

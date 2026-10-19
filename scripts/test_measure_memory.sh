#!/usr/bin/env bash
# Tests for the release memory check. Run: bash scripts/test_measure_memory.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0 fail=0

check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
  fi
}

log() { printf '%s\t%s\t%s\n' "$@" >"$work/log"; }
verdict() { bash "$here/measure-memory.sh" check "$work/log" >/dev/null 2>&1; echo $?; }
span=28500

echo "memory check"
log 1000 120.0 7 $((1000 + span)) 131.9 7
check "9.9% growth passes" "$(verdict)" "0"
log 1000 120.0 7 $((1000 + span)) 132.1 7
check "10.1% growth blocks the release" "$(verdict)" "1"
log 1000 120.0 7 $((1000 + span)) 90.0 7
check "shrinking passes" "$(verdict)" "0"
log 1000 120.0 7 $((1000 + 3600)) 121.0 7
check "an hour apart cannot answer" "$(verdict)" "2"
printf '1000\t120.0\t7\n' >"$work/log"
check "one reading cannot answer" "$(verdict)" "2"
log 1000 "" 7 $((1000 + span)) 120.0 7
check "an empty first reading cannot answer" "$(verdict)" "2"
log 1000 120.0 7 $((1000 + span)) "" 7
check "an empty last reading cannot answer" "$(verdict)" "2"
log 1000 120.0 7 $((1000 + span)) Error 7
check "a non-numeric reading cannot answer" "$(verdict)" "2"
log 1000 120.0 7 $((1000 + span)) 0 7
check "a zero reading cannot answer" "$(verdict)" "2"
log 1000 0 7 $((1000 + span)) 120.0 7
check "a zero first reading cannot answer" "$(verdict)" "2"
log 1000 120.0 7 $((1000 + span)) 120.0 8
check "a restart between readings cannot answer" "$(verdict)" "2"
check "the restart message" "$(bash "$here/measure-memory.sh" check "$work/log")" "klepsydra restarted; measure again"
printf '1000\t120.0\n%s\t120.0\n' $((1000 + span)) >"$work/log"
check "readings without a start time cannot answer" "$(verdict)" "2"
check "the verdict line" "$(bash "$here/measure-memory.sh" check <(printf '0\t100.0\t5\n28800\t104.0\t5\n'))" \
  "100.0 MiB -> 104.0 MiB over 8.0 h: +4.0% (limit 10%)"

echo "sample"
fake() { # exit code, stdout
  printf '#!/usr/bin/env bash\nprintf "%%b" %q\nexit %s\n' "$2" "$1" >"$work/ps"
  chmod +x "$work/ps"
}
sample() { MEASURE_POWERSHELL="$work/ps" bash "$here/measure-memory.sh" sample 2>"$work/err"; }
fake 0 '241.5\t638000000\r\n'
out=$(sample); rc=$?
check "a reading is recorded with the start time" "${out#*$'\t'}" $'241.5\t638000000'
check "a good reading exits 0" "$rc" "0"
fake 0 '\r\n'
sample >/dev/null; check "an empty reading is refused" "$?" "5"
fake 0 'Error\t5\r\n'
sample >/dev/null; check "a non-numeric reading is refused" "$?" "5"
fake 0 '0\t5\r\n'
sample >/dev/null; check "a zero reading is refused" "$?" "5"
fake 0 '12.0\r\n'
sample >/dev/null; check "a reading without a start time is refused" "$?" "5"
fake 3 ''
sample >/dev/null; check "klepsydra not running exits 3" "$?" "3"
fake 4 ''
sample >/dev/null; check "two klepsydra.exe are refused" "$?" "4"
check "and say so" "$(cat "$work/err")" "more than one klepsydra.exe is running; stop the extra one"
fake 1 ''
sample >/dev/null; check "a PowerShell failure is refused" "$?" "5"

echo "usage"
usage=$(bash "$here/measure-memory.sh" 2>&1)
check "usage exits 2" "$(bash "$here/measure-memory.sh" >/dev/null 2>&1; echo $?)" "2"
check "usage starts at the description" "$(head -n 1 <<<"$usage")" \
  "klepsydra's memory on Windows: the working set (MiB) of klepsydra.exe and"
check "usage ends at the last command line" "$(tail -n 1 <<<"$usage" | tr -s ' ')" " 5 min and 8 h, then check"
check "usage leaves out the code" "$(grep -c -e 'set -euo' -e FIRST_AT <<<"$usage")" "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]

#!/usr/bin/env bash
# The screen helpers read a capture with one process (#492): screen_parse runs
# one awk per distinct capture and every helper asks its result.
#   1. Differential: each helper agrees with the sed/awk/grep pipelines it
#      replaced (copied below as old_*, the oracle) on every screen of a corpus:
#      hooks/fixtures/pane-*.txt, screens built here to reach each branch, and
#      any *.txt in $SCREEN_CORPUS (live captures, kept out of the repo).
#      Run once per awk found (awk, mawk, gawk): CI's default is mawk.
#   2. Fork budget (strace): all helpers on one capture cost one process.
# Run: bash fleet/test_forks_screen.sh (no tmux server, no lock)
# set -u only, as the fleet scripts that use these helpers run: under pipefail
# the old limit_line pipeline could fail even when it printed a line.
set -u

root=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "${work:?}"' EXIT

pass=0 fail=0
check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %q\n       got:  %q\n' "$name" "$want" "$got"
  fi
}

# --- the oracle: the helpers as they were before #492 ---
old_plain() { sed -E $'s/\e\\][^\a\e]*(\a|\e\\\\)//g; s/\e\\[[0-9;?]*[A-Za-z]//g'; }
old_input_text() {
  sed -E $'s/\e\\[2m[^\e]*//g' <<<"$1" | old_plain | awk '
    index($0, "────") == 1 { r[++n] = NR }
    { line[NR] = $0 }
    END {
      if (n < 2 || r[n] - r[n - 1] < 2) exit
      first = line[r[n - 1] + 1]
      if (index(first, "❯") != 1) exit
      sub(/^❯(\xc2\xa0| )?/, "", first)
      out = first
      for (i = r[n - 1] + 2; i < r[n]; i++) { l = line[i]; sub(/^  /, "", l); out = out " " l }
      gsub(/\xc2\xa0/, " ", out); sub(/[ \n]+$/, "", out); sub(/^ +/, "", out)
      printf "%s", out
    }'
}
old_has_input_box() {
  old_plain <<<"$1" | awk 'index($0, "────") == 1 { r[++n] = NR } { line[NR] = $0 }
    END { exit !(n >= 2 && r[n] - r[n - 1] >= 2 && index(line[r[n - 1] + 1], "❯") == 1) }'
}
old_split_screen() {
  local p
  p=$(old_plain <<<"$1")
  OLD_ABOVE=$(awk 'index($0, "────") == 1 { r[++n] = NR } { line[NR] = $0 }
    END { last = (n >= 2) ? r[n - 1] - 1 : NR; for (i = 1; i <= last; i++) print line[i] }' <<<"$p")
  OLD_BELOW=$(awk 'index($0, "────") == 1 { r[++n] = NR } { line[NR] = $0 }
    END { if (n < 2) exit; for (i = r[n] + 1; i <= NR; i++) print line[i] }' <<<"$p")
}
old_near() { grep -v '^[[:space:]]*$' <<<"$OLD_ABOVE" | tail -"${1:-6}"; }
old_busy() { old_split_screen "$1"; old_near 4 | grep -Eq '… \(|esc to interrupt'; }
old_limit_line() {
  old_split_screen "$1"
  { old_near 6 | awk -v re="$LIMIT_RE" '
      /hit your fast limit/ { next }
      $0 ~ re { l = $0; next }
      /^❯ / && !/^❯ \// { l = "" }
      END { if (l != "") print l }'
    printf '%s\n' "$OLD_BELOW" | grep -E "$LIMIT_RE"; } | tail -1 | grep .
}
old_limit_menu() {
  local tail
  old_has_input_box "$1" && return 1
  tail=$(old_plain <<<"$1" | grep -v '^[[:space:]]*$' | tail -8)
  grep -q 'Stop and wait for limit to reset' <<<"$tail" && grep -q 'Enter to confirm' <<<"$tail"
}
old_armed() {
  old_split_screen "$1"
  printf '%s\n' "$OLD_BELOW" | grep -o 'Continuing automatically at [^·]*' | tail -1 | sed 's/^Continuing automatically at //; s/ *$//'
}
old_idle_empty() { old_has_input_box "$1" && [[ -z $(old_input_text "$1") ]] && ! old_busy "$1"; }
old_box_empty() { old_has_input_box "$1" && [[ -z $(old_input_text "$1") ]]; }
old_holds_input() { [[ -n $(old_input_text "$1") ]]; }
old_rc_settled() {
  local p
  p=$(old_plain <<<"$1")
  grep -q 'Enter to select · Esc to continue' <<<"$p" && return 0
  old_split_screen "$1"
  old_near 4 | grep -q '/remote-control is active' && old_idle_empty "$1"
}
# --- end oracle ---

# The corpus: the fixtures, then screens built to reach each branch.
E=$'\e' RULE='────────────────────────────────────────' NB=$' '
corpus=()
for f in "$root"/hooks/fixtures/pane-*.txt "${SCREEN_CORPUS:-/nonexistent}"/*.txt; do
  [[ -f $f ]] && corpus+=("$(<"$f")")
done
aboves=(
  "● Done the thing."
  "● Working${NB}
${E}[2m✻ Pondering… (12s · ↓ 300 tokens · esc to interrupt)${E}[0m"
  "· Thinking… (3s)

"
  "  ⎿  You've hit your 5-hour limit · resets 4:10am (America/New_York)
     /rate-limit-options"
  "You've hit your weekly limit · resets Nov 21, 1pm
❯ continue"
  "You've hit your fast limit · resets 3pm"
  "You've hit your org's monthly spend limit
❯ /usage"
  "${E}]8;;https://example.com${E}\\link text${E}]8;;${E}\\ and ${E}]8;;x${E}\\more${E}]8;;${E}\\"
  "/remote-control is active · connect at claude.ai/code"
  "  done 3:40 PM
  still running: 1 shell"
  ""
)
boxes=(
  "$RULE
❯${NB}
$RULE"
  "$RULE
❯ ${E}[2mTry \"fix the bug\"${E}[22m
$RULE"
  "$RULE
${E}[1m❯${E}[0m hello${NB}world and a long line
  that wraps here
$RULE"
  "$RULE
❯
$RULE"
  "$RULE
$RULE"
  "$RULE
 ❯ 1. Yes
   2. No
$RULE"
  " Stop and wait for limit to reset
 Enter to confirm · Esc to cancel"
  " Enter to select · Esc to continue"
  ""
)
belows=(
  "  ${E}[2m⏵⏵ bypass permissions on${E}[0m"
  "  Usage limit reached · resets 5pm"
  "  Continuing automatically at 4:10 AM ·  Continuing automatically at 5:20 PM
  Usage limit reached"
  ""
)
for a in "${aboves[@]}"; do
  for b in "${boxes[@]}"; do
    for c in "${belows[@]}"; do corpus+=("$a
$b
$c"); done
  done
done
# Long screens that differ only below the box, so the cache is asked to
# tell captures apart by their ends.
long=$(printf 'scrollback line %d\n' {1..300})
corpus+=("$long
✻ Pondering… (3s · esc to interrupt)
$RULE
❯${NB}
$RULE
  status" "$long
✻ Pondering… (3s · esc to interrupt)
$RULE
❯ typed
$RULE
  Usage limit reached")
corpus+=("$RULE" "x" "$RULE
❯ a
$RULE
mid
$RULE
❯ b
$RULE")

# shellcheck source=fleet/lib.sh
. "$root/fleet/lib.sh"
# shellcheck source=/dev/null
. <(sed -n '/^armed_at() {/,/^}/p' "$root/fleet/resume-at-reset.sh")
declare -F armed_at >/dev/null || { echo "FAIL: armed_at not found in fleet/resume-at-reset.sh"; exit 1; }

# Each screen straight after the one before it: the cache must notice even
# a change at the very end (no unset between screens). Pass 2 runs backwards.
differential() { # AWK-NAME [reverse]
  local s i=0 got want n k order=()
  for ((k = 0; k < ${#corpus[@]}; k++)); do order+=("$k"); done
  if [[ ${2:-} == reverse ]]; then
    for ((k = ${#corpus[@]} - 1; k >= 0; k--)); do order[${#corpus[@]} - 1 - k]=$k; done
  fi
  for k in "${order[@]}"; do
    s=${corpus[k]}
    i=$((k + 1))
    screen_parse "$s"
    check "$1 #$i plain" "$SCR_PLAIN" "$(old_plain <<<"$s")"
    old_split_screen "$s"
    check "$1 #$i above" "$ABOVE" "$OLD_ABOVE"
    check "$1 #$i below" "$BELOW" "$OLD_BELOW"
    for n in 4 6; do check "$1 #$i near $n" "$(near "$n")" "$(old_near "$n")"; done
    has_input_box "$s"; got=$?; old_has_input_box "$s"; want=$?
    check "$1 #$i has_input_box" "$got" "$want"
    check "$1 #$i input_text" "$(input_text "$s")" "$(old_input_text "$s")"
    busy "$s"; got=$?; old_busy "$s"; want=$?
    check "$1 #$i busy" "$got" "$want"
    check "$1 #$i limit_line" "$(limit_line "$s"; echo "rc=$?")" "$(old_limit_line "$s"; echo "rc=$?")"
    limit_menu "$s"; got=$?; old_limit_menu "$s"; want=$?
    check "$1 #$i limit_menu" "$got" "$want"
    armed_at "$s"
    check "$1 #$i armed" "$ARMED" "$(old_armed "$s")"
    # Each with another screen cached first, so a helper that reads the cache
    # before parsing its own screen is caught.
    for n in idle_empty box_empty holds_input rc_settled; do
      screen_parse "${corpus[(k + 1) % ${#corpus[@]}]}"
      "$n" "$s"; got=$?; "old_$n" "$s"; want=$?
      check "$1 #$i $n" "$got" "$want"
    done
    screen_parse "${corpus[(k + 1) % ${#corpus[@]}]}"
    armed_at "$s"
    check "$1 #$i armed_at" "$ARMED" "$(old_armed "$s")"
  done
}

awks=()
for a in awk mawk gawk; do
  p=$(command -v "$a") && p=$(readlink -f "$p") && [[ " ${awks[*]} " != *" $p "* ]] && awks+=("$p")
done
for a in "${awks[@]}"; do
  mkdir -p "$work/bin-${a##*/}"
  ln -sf "$a" "$work/bin-${a##*/}/awk"
  PATH=$work/bin-${a##*/}:$PATH differential "${a##*/}"
  PATH=$work/bin-${a##*/}:$PATH differential "${a##*/}" reverse
done
printf '  %s screens x %s awks: %s\n' "${#corpus[@]}" "${#awks[@]}" "${awks[*]}"
if [[ -n ${CI:-} && " ${awks[*]} " != *mawk* ]]; then check "CI has mawk to test against" no yes; fi

# stopped_at: its "done H:MM AM" read with printf's clock, as date read it,
# on ordinary days and across both DST changes, in two zones.
old_stopped_at() { # PANE PLAIN
  local at day now d c k best="" stopped
  at=$(grep -o 'done [0-9]\{1,2\}:[0-9][0-9] [AP]M' <<<"$2" | tail -1 | cut -c6-)
  at=${at#0}
  now=$(clock)
  if [[ -n $at ]] && day=$(date -d "@$now" +%F); then
    for d in -1 0 1; do
      c=$(date -d "$(date -d "$day 12:00 PM $d day" +%F) $at" +%s 2>/dev/null) || continue
      for k in -7200 -3600 -1800 0 1800 3600 7200; do
        (( c + k <= now + 900 && c + k > ${best:-0} )) || continue
        [[ $(LC_ALL=C date -d "@$((c + k))" '+%-I:%M %p') == "$at" ]] && best=$((c + k))
      done
    done
  fi
  if [[ -n $best ]]; then stopped=$((best + 59)); else stopped=$NOW; fi
  printf '%s' "$stopped"
}
# shellcheck source=/dev/null
. <(sed -n '/^clock() {/p; /^stopped_at() { # PANE PLAIN/,/^}/p' "$root/fleet/resume-at-reset.sh")
t() { return 1; } # no tmux: an unread time falls back to NOW in both
NOW=1
for zone in America/New_York Europe/Berlin; do
  for now in 1795120858 1772951400 1772955000 1772974800 1793511000 1793514600 1793538000 1774744200 1774747800 1792888200 1792891800 1792915200; do
    for done_at in "done 1:30 AM" "done 2:30 AM" "done 12:05 PM" "done 11:59 PM" "done 3:40 PM" "nothing"; do
      check "stopped_at $zone $now $done_at" "$(TZ=$zone FLEET_NOW=$now stopped_at %1 "x $done_at y")" \
        "$(TZ=$zone FLEET_NOW=$now old_stopped_at %1 "x $done_at y")"
    done
  done
done

# A failed awk is never kept as the screen's answer: the next call reads again.
mkdir -p "$work/bin-fail"
printf '#!/bin/sh\nexit 1\n' >"$work/bin-fail/awk"
chmod +x "$work/bin-fail/awk"
unset SCR_RAW
PATH=$work/bin-fail:$PATH screen_parse "${corpus[0]}"
check "cache: a failed parse is not kept" "${SCR_RAW+set}" ""
screen_parse "${corpus[0]}"
check "cache: the next call reads the screen" "$SCR_PLAIN" "$(old_plain <<<"${corpus[0]}")"

# Fork budget: every helper on one capture, one process (strace).
STRACE=${STRACE:-strace}
if command -v "$STRACE" >/dev/null; then
  forks_of() {
    "$STRACE" -f -qq -e trace=clone,clone3,fork,vfork -e signal=none -o "$work/trace" "$@" >/dev/null 2>&1 </dev/null
    grep -cE ' (clone|clone3|fork|vfork)\(' "$work/trace"
  }
  printf '%s' "${corpus[2]}" >"$work/screen"
  armed_src=$(sed -n '/^armed_at() {/,/^}/p' "$root/fleet/resume-at-reset.sh")
  # shellcheck disable=SC2016  # the child bash expands $1, $2 and $3, its positional args.
  load=$(forks_of env -u FLEET_RUN_ID bash -c '. "$1/fleet/lib.sh"; eval "$3"; s=$(<"$2")' _ "$root" "$work/screen" "$armed_src")
  # shellcheck disable=SC2016  # the child bash expands $1, $2, $3 and $s.
  all=$(forks_of env -u FLEET_RUN_ID bash -c '. "$1/fleet/lib.sh"; eval "$3"; s=$(<"$2")
    busy "$s"; has_input_box "$s"; idle_empty "$s"; limit_line "$s" >/dev/null; limit_menu "$s"
    split_screen "$s"; near 6 >/dev/null; holds_input "$s"; box_empty "$s"; rc_settled "$s"
    armed_at "$s"; : "$(input_text "$s")"' _ "$root" "$work/screen" "$armed_src")
  # input_text prints, so its $(...) is one fork of the caller's: two in all.
  check "every screen helper on one capture: one parse" "$((all - load))" 2
  # The watch loop, one tick at a time, against a stub tmux (no server): one
  # busy pane and one idle pane that says "done". Processes between one tick's
  # sleep and the next; the first tick also loads the state, so it is left out.
  mkdir -p "$work/stub" "$work/wstate" "$work/wk/fleet"
  printf '%s\n' "● Working" "✻ Pondering… (12s · esc to interrupt)" "$RULE" "❯ " "$RULE" >"$work/pane-busy"
  printf '%s\n' "● Done." "  done 3:40 PM" "$RULE" "❯ " "$RULE" "  ⏵⏵ bypass permissions on" >"$work/pane-done"
  cat >"$work/stub/tmux" <<STUB
#!/bin/sh
case "\$*" in
  *list-panes*) printf '%s\\n' %1 %2 ;;
  *capture-pane*%1*) cat "$work/pane-busy" ;;
  *capture-pane*%2*) cat "$work/pane-done" ;;
esac
STUB
  chmod +x "$work/stub/tmux"
  PATH=$work/stub:$PATH FLEET_STATE=$work/wstate KLEPSYDRA_DIR=$work/wk WATCH_TICK=0.2 IDLE_S=99999 \
    "$STRACE" -f -qq -e trace=clone,clone3,fork,vfork,execve -e signal=none -o "$work/wtrace" \
    timeout 6 bash "$root/fleet/watch-panes.sh" %1 %2 >/dev/null 2>&1 </dev/null
  ticks=$(awk '/ (clone|clone3|fork|vfork)\(/ && !/resumed/ { n++ } / execve\("[^"]*\/sleep"/ { if (seen) print n; seen = 1; n = 0 }' "$work/wtrace")
  most=$(sort -n <<<"$ticks" | tail -1)
  check "the watch loop ran ticks to count" "$(($(grep -c . <<<"$ticks") >= 2))" 1
  # Counted with the stub's own processes. 23 on every tick here; 82 before
  # #492's slice 4. A later slice that lowers it lowers WATCH_TICK_BUDGET.
  check "one watch tick, 2 panes: at most ${WATCH_TICK_BUDGET:-23} processes (most was ${most:-none})" \
    "$((${most:-999} <= ${WATCH_TICK_BUDGET:-23}))" 1
elif [[ -n ${CI:-} ]]; then
  check "strace present in CI" no yes
else
  printf '\n  WARNING: NO FORK BUDGET RAN: strace is missing (sudo apt-get install strace, or STRACE=path).\n  CI fails without it; this local run checked behaviour only.\n\n' >&2
fi

echo "screen parse: $pass passed, $fail failed"
((fail == 0))

#!/usr/bin/env bash
# Tests for the fleet scripts against a private tmux server and fake Claude
# Code panes (tests/fake_pane.py), with no real Claude. Run: make test-fleet (it takes the heavy lock)
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
fake="$here/tests/fake_pane.py"
work=$(mktemp -d)
export TZ=America/New_York # the fixtures' times are AJ's
export FLEET_SOCK="fleet-test-$$" FLEET_STATE="$work/state" FLEET_SESSION=fleet
export FLEET_HOOK_DIR="$work/claude" # never the real ~/.claude
# Never AJ's keryx: the resume service skips voices, and voices.sh finds no keryx
# and reads a private keryx config, unless a case hands it a stub (#273).
export FLEET_LIVE_CONF=0 FLEET_VOICES=0 FLEET_KERYX="$work/no-keryx" XDG_CONFIG_HOME="$work/xdg"
real_keryx_config=${HOME}/.config/keryx/config.json
real_keryx_sum=$(sha256sum "$real_keryx_config" 2>/dev/null | cut -d' ' -f1)
export KLEPSYDRA_DIR="$work/klepsydra" FLEET_TICK=0.1 FLEET_START_WAIT=4 FLEET_TURN_WAIT=6 FLEET_RC_WAIT=12
mkdir -p "$FLEET_STATE" "$KLEPSYDRA_DIR/accounts/a" "$KLEPSYDRA_DIR/accounts/b"
# Two config folders, logged out until a case logs one in (accounts a and b).
export FLEET_DEFAULT_CONFIG="$work/cfg-a" FLEET_DEFAULT_JSON="$work/cfg-a.json" FLEET_ACCOUNTS="$work/cfg-a $work/cfg-b"
unset CLAUDE_CONFIG_DIR KLEPSYDRA_BACKGROUND
# Never AJ's user manager (#265 review): a case that wants systemctl passes its
# own stub; a bare `systemctl` lands on a guard that records the call.
export FLEET_SYSTEMCTL="$work/no-systemctl"
# The memory slices are sized from a fixed MemTotal (#353), never the runner's.
printf 'MemTotal:       10186856 kB\nMemAvailable:    5151140 kB\n' >"$work/meminfo"
export FLEET_MEMINFO="$work/meminfo"
# and earlyoom's line, as AJ's PC sets it, never the runner's (none on CI).
printf 'EARLYOOM_ARGS="-m 5 -s 100,100 -r 3600"\n' >"$work/earlyoom"
export FLEET_EARLYOOM_CONF="$work/earlyoom"
# Never the host's WSL: the doctor reads AJ's .wslconfig only on WSL (#292 review 3).
unset WSL_DISTRO_NAME FLEET_WSLCONFIG
mkdir -p "$work/guard"
printf '#!/usr/bin/env bash\necho "$*" >>%q\nexit 1\n' "$work/guard.calls" >"$work/guard/systemctl"
chmod +x "$work/guard/systemctl"
export PATH="$work/guard:$PATH"
login() { # a|b
  local d=$work/cfg-$1 j=$work/cfg-$1/.claude.json
  [[ $1 == a ]] && j=$FLEET_DEFAULT_JSON
  mkdir -p "$d"; : >"$d/.credentials.json"
  jq -n --arg u "$1" '{oauthAccount: {accountUuid: $u}}' >"$j"
}
logout() { rm -f -- "$work/cfg-${1:?}/.credentials.json"; }
cleanup() {
  tmux -L "$FLEET_SOCK" kill-server 2>/dev/null
  chmod -R u+w -- "${work:?}" 2>/dev/null
  rm -rf -- "${work:?}"
}
trap cleanup EXIT
# A signal ends the run through exit, so the EXIT trap still stops the server (#239).
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
# No inherited descriptor past stderr: a tmux server started here would keep a
# caller's lock, such as flock's /tmp/fleet-heavy.lock, after the run (#193).
for fd in "/proc/$$/fd"/*; do n=${fd##*/}; (( n > 2 && n < 255 )) && eval "exec $n>&-"; done

pass=0 fail=0
check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
    # On GitHub Actions, an annotation names the failing case on the run's page.
    if [[ -n ${GITHUB_ACTIONS:-} ]]; then
      local msg=${name//%/%25}
      msg=${msg//$'\r'/%0D}
      printf '::error file=fleet/test_fleet.sh,line=%s,title=fleet test failed::%s\n' "${BASH_LINENO[0]}" "${msg//$'\n'/%0A}"
    fi
  fi
}
has() { grep -qF -- "$2" <<<"$1" && echo yes || echo no; } # TEXT NEEDLE

# shellcheck source=fleet/lib.sh
. "$here/lib.sh"

t new-session -d -s fleet -x 200 -y 50 "sleep 100000"
t set -g default-size 200x50

# A fake pane started with STATE (JSON); prints its pane id. Its log is $work/<name>.log.
pane() { # NAME STATE-JSON
  printf '%s' "$2" >"$work/$1.json"
  : >"$work/$1.log"
  t new-window -d -P -F '#{pane_id}' -t fleet: "python3 -I $fake $work/$1.json $work/$1.log"
}
state() { printf '%s' "$2" >"$work/$1.json"; sleep 0.4; } # NAME STATE-JSON
events() { cat "$work/$1.log"; }
settle() { sleep 0.6; }
reading() { # DIR LABEL FIVE_HOUR_PCT MTIME: a usage reading for account DIR
  # A case that sets an account's reading starts with no limit seen on it (#319).
  rm -f -- "$FLEET_STATE/limited/${1:?}".five "$FLEET_STATE/limited/${1:?}".seven
  jq -n --arg l "$2" --argjson u "$3" --argjson r "$(( $(date +%s) + 3600 ))" \
    '{label: $l, windows: {five_hour: {used_percentage: $u, resets_at: $r}}}' >"$KLEPSYDRA_DIR/accounts/$1/s.json"
  touch -d "@$4" "$KLEPSYDRA_DIR/accounts/$1/s.json"
}
resume() { FLEET_NOW=$1 bash "$here/resume-at-reset.sh" --once 2>/dev/null; } # NOW
# A registered session, live in pane $1 by klepsydra's fleet file.
SID=11111111-2222-4333-8444-555555555555
mkdir -p "$KLEPSYDRA_DIR/fleet"
live() { jq -n --arg p "$1" '{session_id: "x", ended: null, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/${2:-$SID}.json"; }
logged() { jq -r --arg m "$1" 'select(.message | contains($m)) | .pane' "$FLEET_LOG" 2>/dev/null | tr '\n' ' '; }

echo "reset times"
now=$(TZ=America/New_York date -d '2026-10-28 22:00' +%s)
at() { TZ=America/New_York date -d "@$(reset_epoch "$1" "$now")" '+%F %H:%M'; }
check "time only, past: tomorrow" "$(at 'You'"'"'ve hit your session limit · resets 1:10pm (America/New_York)')" "2026-10-29 13:10"
check "status line, no zone" "$(TZ=America/New_York at '⚠ Usage limit reached · limit resets 4:10am')" "2026-10-29 04:10"
check "time only, ahead: today" "$(TZ=America/New_York at 'resets 11:30pm')" "2026-10-28 23:30"
check "dated weekly banner (10-28 bug: read as Thu 00:00)" "$(at 'You'"'"'ve hit your weekly limit · resets Nov 2, 1pm (America/New_York)')" "2026-11-02 13:00"
check "dated with minutes" "$(at 'resets Nov 2, 1:30pm (America/New_York)')" "2026-11-02 13:30"
check "another zone (London is GMT again on Nov 2; New York is EST)" "$(at 'resets Nov 2, 1pm (Europe/London)')" "2026-11-02 08:00"
now=$(TZ=America/New_York date -d '2026-12-30 10:00' +%s)
check "a date past the new year" "$(at 'resets Jan 3, 9am (America/New_York)')" "2027-01-03 09:00"
check "no reset named" "$(reset_epoch 'nothing here' "$now" || echo none)" "none"
now=$(TZ=America/New_York date -d '2027-01-01 00:30' +%s)
check "#265 review: a dated reset just before the new year, read after it, is last year's" "$(at 'resets Dec 31, 11pm (America/New_York)')" "2026-12-31 23:00"
now=$(TZ=America/New_York date -d '2026-10-31 22:00' +%s)
check "#265 review: tomorrow across the clock change keeps the wall-clock time" "$(TZ=America/New_York at 'resets 2am')" "2026-11-01 02:00"
now=$(TZ=America/New_York date -d '2026-11-03 01:00' +%s)
check "#265 review 2: a time-only reset up to a day ahead stays ahead (a weekly one is dated only past 24 h)" "$(TZ=America/New_York at 'resets 11pm')" "2026-11-03 23:00"
now=$(TZ=America/New_York date -d '2026-03-07 21:00' +%s)
check "#265 review 3: tomorrow's 2:30am, which the spring-forward skips, fails rather than reading as now" \
  "$(TZ=America/New_York reset_epoch 'resets 2:30am' "$now"; echo "rc=$?")" "rc=1"
check "#265 review 4: a dated reset at a skipped time fails too" \
  "$(TZ=America/New_York reset_epoch 'resets Mar 8, 2:30am (America/New_York)' "$now"; echo "rc=$?")" "rc=1"
now=$(TZ=America/New_York date -d '2026-03-08 00:30' +%s)
check "#265 review 4: and so does today's, read before the clock change" \
  "$(TZ=America/New_York reset_epoch 'resets 2am' "$now"; echo "rc=$?")" "rc=1"
now=$(TZ=America/New_York date -d '2026-11-02 18:50' +%s)
check "#265 review: with a 19 h roll (the doctor's), a reset 6 h past is today's" \
  "$(TZ=America/New_York date -d "@$(reset_epoch 'resets 12:40pm' "$now" 68400)" '+%F %H:%M')" "2026-11-02 12:40"
now=$(TZ=America/New_York date -d '2026-12-30 10:00' +%s)
check "the last reset on screen wins" "$(TZ=America/New_York date -d "@$(reset_epoch $'resets 1pm\nresets 3pm' "$now")" +%H:%M)" "15:00"

echo "reading the screen"
p=$(pane read '{"above":["hello"]}'); settle
s=$(screen "$p")
check "an empty prompt reads empty (the dim placeholder is not text)" "[$(input_text "$s")]" "[]"
check "and idle" "$(idle_empty "$s" && echo yes)" "yes"
t send-keys -t "$p" -l "a note from AJ"; settle
check "a typed line" "$(input_text "$(screen "$p")")" "a note from AJ"
t send-keys -t "$p" C-u
printf 'one\ntwo\nthree\n' >"$work/three.txt"; t load-buffer -b x "$work/three.txt"; t paste-buffer -p -d -b x -t "$p"; settle
check "a pasted block shows as its marker" "$(input_text "$(screen "$p")")" "[Pasted text #1 +3 lines]"
t send-keys -t "$p" C-u
state read '{"above":["x"],"busy":true}'
check "the spinner is a running turn" "$(busy "$(screen "$p")" && echo yes)" "yes"
state read '{"above":["⏺ Done. The spinner showed esc to interrupt while it ran."]}'
check "#307: an idle pane whose last reply quotes the esc hint is not busy" "$(busy "$(screen "$p")" && echo yes || echo no)" "no"
state read '{"above":["  ⎿  You'"'"'ve hit your session limit · resets 1:10pm (America/New_York)","",""]}'
check "the limit as the last thing printed" "$(limit_line "$(screen "$p")")" "  ⎿  You've hit your session limit · resets 1:10pm (America/New_York)"
state read '{"above":["  ⎿  You'"'"'ve hit your session limit · resets 1:10pm","a","b","c","d","e","f","g"]}'
check "an old limit far above the prompt is not one" "$(limit_line "$(screen "$p")" || echo none)" "none"
state read '{"above":["x"],"below":["  ⚠ Usage limit reached · limit resets 4:10am"]}'
check "the status line banner" "$(limit_line "$(screen "$p")")" "  ⚠ Usage limit reached · limit resets 4:10am"
# Claude Code 2.1.316 names the window (#263): each name in its label map, and near misses.
for w in "5-hour limit" "weekly limit" "Opus limit" "Sonnet limit" "Fable limit" "usage credit limit" "limit"; do
  state read "{\"above\":[\"  ⎿  You've hit your $w · resets 12:40pm\",\"\",\"\"]}"
  check "#263: \"You've hit your $w\" is a limit" "$(limit_line "$(screen "$p")" | grep -c "hit your $w")" "1"
done
state read '{"above":["  ⎿  You'"'"'ve hit your 5-hour limit · resets 12:40pm","❯ The usage limit has reset. Please continue.","● Queue is empty"]}'
check "#265 review: a limit followed by a prompt sent after it is past" "$(limit_line "$(screen "$p")" || echo none)" "none"
state read '{"above":["❯ a note","  ⎿  You'"'"'ve hit your 5-hour limit · resets 12:40pm"]}'
check "#265 review: a limit that answered the last prompt is current" "$(limit_line "$(screen "$p")" | grep -c '5-hour limit')" "1"
state read '{"above":["  ⎿  You'"'"'ve hit your session limit · resets 1:10pm (America/New_York)","❯ /rate-limit-options","  ⎿  Claude Code will continue automatically at 1:10pm"]}'
check "#265 review 2: Claude Code's own /rate-limit-options after the limit leaves it current" "$(limit_line "$(screen "$p")" | grep -c 'session limit')" "1"
state read '{"above":["  ⎿  You'"'"'ve hit your fast limit · resets in 3m","",""]}'
check "#265 review: the /fast dialog's limit is no usage limit" "$(limit_line "$(screen "$p")" || echo none)" "none"
state read '{"above":["  ⎿  You'"'"'ve hit your org'"'"'s monthly spend limit · your 5-hour limit resets 1pm","",""]}'
check "#265 review: a three-word name with an apostrophe is a limit" "$(limit_line "$(screen "$p")" | grep -c 'spend limit')" "1"
check "#265 review: LIMIT_RE has no {m,n} interval (mawk ignores one)" "$(grep -c '[{][0-9]' <<<"$LIMIT_RE")" "0"
for w in "I think you hit your stride on the limits" "You've hit your limits page" "Then you've hit your weekly limits"; do
  state read "{\"above\":[\"$w\",\"\",\"\"]}"
  check "#263: \"$w\" is no limit" "$(limit_line "$(screen "$p")" || echo none)" "none"
done
state read '{"above":["x"],"menu":"limit"}'
check "a menu hides the input box" "$(has_input_box "$(screen "$p")" && echo box || echo none)" "none"
t kill-window -t "$p"

echo "limits from events (#311)"
# A session the fleet hook recorded at STATE (default: a StopFailure rate_limit), in pane PANE.
stop_file() { # SID PANE STATE_AT ACCOUNT MESSAGE [STATE REASON]
  jq -n --arg p "$2" --argjson at "$3" --arg a "$4" --arg m "$5" --arg st "${6:-error}" --arg r "${7:-rate limit}" \
    '{session_id: "x", ended: null, tmux: {pane: $p}, state: $st, reason: $r, state_at: $at, error: $m}
     + (if $a == "" then {} else {account: {id: $a, label: "Ev"}} end)' >"$KLEPSYDRA_DIR/fleet/$1.json"
}
# A usage reading for account ID: each window's percentage used and reset.
win() { # ID FIVE_PCT FIVE_RESET [SEVEN_PCT SEVEN_RESET]
  mkdir -p "$KLEPSYDRA_DIR/accounts/$1"
  jq -n --argjson fp "$2" --argjson fr "$3" --arg sp "${4:-}" --arg sr "${5:-}" \
    '{label: "Ev", windows: ({five_hour: {used_percentage: $fp, resets_at: $fr}}
      + (if $sp == "" then {} else {seven_day: {used_percentage: ($sp | tonumber), resets_at: ($sr | tonumber)}} end))}' \
    >"$KLEPSYDRA_DIR/accounts/$1/ev.json"
}
evn=$(TZ=America/New_York date -d '2026-10-28 12:00' +%s)
E1=aaaaaaaa-0000-4000-8000-000000000311
L5='  ⎿  You'"'"'ve hit your 5-hour limit · resets 1:10pm (America/New_York)'
LW='  ⎿  You'"'"'ve hit your weekly limit · resets Nov 2, 1pm (America/New_York)'
ev() { limit_event %9001 || echo none; }
stop_file "$E1" %9001 "$evn" ev1 "$L5"; win ev1 100 $((evn + 4000))
check "a spent window's resets_at dates the stop, not the message's text" "$(ev)" "$((evn + 4000))"$'\t'"$L5"
win ev1 60 $((evn + 4000))
check "a window not yet shown spent: the one the message names" "$(ev)" "$((evn + 4000))"$'\t'"$L5"
stop_file "$E1" %9001 "$evn" ev1 "$LW"; win ev1 30 $((evn + 4000)) 100 $((evn + 200000))
check "a weekly stop: the weekly window's reset" "$(ev | cut -f1)" "$((evn + 200000))"
win ev1 100 $((evn + 4000)) 100 $((evn + 200000))
check "both spent: the later reset" "$(ev | cut -f1)" "$((evn + 200000))"
stop_file "$E1" %9001 "$evn" ev1 "API Error: Rate limit reached"; win ev1 60 $((evn + 4000))
check "a passing API rate limit with room left parks nothing" "$(ev)" "none"
win ev1 100 $((evn + 4000))
check "the same error with the window spent is a limit" "$(ev | cut -f1)" "$((evn + 4000))"
old=$((evn - 3 * 86400))
stop_file "$E1" %9001 "$old" ev1 "$L5"
check "a stop older than the account's window: its own text, read from the stop's day" \
  "$(TZ=America/New_York date -d "@$(ev | cut -f1)" '+%F %H:%M')" "2026-10-25 13:10"
stop_file "$E1" %9001 "$evn" ev1 '  ⎿  You'"'"'ve hit your fast limit · resets in 3m'
check "the /fast limit is no usage limit" "$(ev)" "none"
stop_file "$E1" %9001 "$evn" ev1 "$L5" working null
check "a prompt since (working) clears it" "$(ev)" "none"
eve=$(TZ=America/New_York date -d '2026-10-28 19:00' +%s)
stop_file "$E1" %9001 "$eve" ev-none '  ⎿  You'"'"'ve hit your weekly limit · resets 3pm (America/New_York)'
check "a time-only reset 20 h after the stop is the next day's, never before the stop" \
  "$(TZ=America/New_York date -d "@$(ev | cut -f1)" '+%F %H:%M')" "2026-10-29 15:00"
login a; printf '{"oauthAccount":{"accountUuid":"ev-new"}}\n' >"$FLEET_DEFAULT_JSON"
stop_file "$E1" %9001 "$evn" ev1 "$L5"; win ev1 100 $((evn + 4000))
check "a /login in the pane's folder since: the old account's readings date nothing, the text does" "$(ev | cut -f1)" "$((evn + 4200))"
printf '{"oauthAccount":{"accountUuid":"ev1"}}\n' >"$FLEET_DEFAULT_JSON"
check "the same account still logged in: its reading dates it" "$(ev | cut -f1)" "$((evn + 4000))"
logout a; rm -f -- "${FLEET_DEFAULT_JSON:?}" # as before this case: never logged in
# #313 review 2: a model's own weekly limit dates itself; the all-models week, not spent, is another window.
stop_file "$E1" %9001 "$evn" ev1 '  ⎿  You'"'"'ve hit your Opus weekly limit · resets Oct 30, 1pm (America/New_York)'
win ev1 30 $((evn + 4000)) 61 $((evn + 200000))
check "#313 review 2: a weekly window that disagrees with the stop's own dated reset does not date it" \
  "$(TZ=America/New_York date -d "@$(ev | cut -f1)" '+%F %H:%M')" "2026-10-30 13:00"
stop_file "$E1" %9001 "$evn" ev1 '  ⎿  You'"'"'ve hit your Opus weekly limit · resets Nov 2, 1pm (America/New_York)'
win ev1 30 $((evn + 4000)) 61 $((evn + 172800))
check "#313 review 3: nor one that ends days before it" "$(TZ=America/New_York date -d "@$(ev | cut -f1)" '+%F %H:%M')" "2026-11-02 13:00"
# #313 review 2: Heph's pane is no row; its folder is his own (orchestrator.config), not the default.
had_b=0; [[ -d $work/cfg-b ]] && had_b=1
login a; login b; printf '{"oauthAccount":{"accountUuid":"ev1"}}\n' >"$work/cfg-b/.claude.json"
printf '%%9001\n' >"$FLEET_STATE/orchestrator.pane"; printf '%s\n' "$work/cfg-b" >"$FLEET_STATE/orchestrator.config"
stop_file "$E1" %9001 "$evn" ev1 "$L5"; win ev1 100 $((evn + 4000))
check "#313 review 2: Heph's stop is dated by the account on his own folder" "$(ev | cut -f1)" "$((evn + 4000))"
logout a; logout b; rm -f -- "${FLEET_DEFAULT_JSON:?}" "$work/cfg-b/.claude.json" "$FLEET_STATE/orchestrator.pane" "$FLEET_STATE/orchestrator.config"
# The second folder as it was: a folder login made would be one the doctor checks.
(( had_b )) || rm -rf -- "${work:?}/cfg-b"
stop_file "$E1" %9001 "$evn" ev-none "$L5"
check "no reading: the message's reset" "$(ev | cut -f1)" "$((evn + 4200))"
stop_file "$E1" %90010 "$evn" ev1 "$L5"
check "a file naming pane %90010 is no session of pane %9001" "$(ev)" "none"
stop_file "$E1" %9001 "$evn" ev1 "$L5"
ln -s "$KLEPSYDRA_DIR/fleet/$E1.json" "$KLEPSYDRA_DIR/fleet/link.json"
check "a link to a session file is no second session" "$(ev | cut -f1)" "$((evn + 4000))"
cp "$KLEPSYDRA_DIR/fleet/$E1.json" "$KLEPSYDRA_DIR/fleet/copy.json"
check "two live files naming the pane are no answer" "$(ev)" "none"
rm -f -- "$KLEPSYDRA_DIR/fleet/link.json" "$KLEPSYDRA_DIR/fleet/copy.json" "$KLEPSYDRA_DIR/fleet/${E1:?}.json"

: >"$FLEET_LOG"
p=$(pane evlim '{"above":["work"],"on_submit":"busy"}'); settle
stop_file "$E1" "$p" "$evn" ev1 "$L5"; win ev1 100 $((evn + 4000))
resume "$evn"
check "a limit the screen no longer shows is seen from the hook's record, dated by resets_at" \
  "$(jq -r 'select(.message == "limit seen") | [.pane, .from, .resets] | join(" ")' "$FLEET_LOG")" \
  "$p event $(date -d "@$((evn + 4000))" '+%a %F %H:%M')"
check "nothing is typed before that reset" "$(events evlim)" ""
resume "$((evn + 4000 + 130))"
check "and it resumes at the reading's reset, before the message's 1:10pm" "$(has "$(events evlim)" "SUBMIT The usage limit has reset.")" "yes"
t kill-window -t "$p"
rm -f -- "$KLEPSYDRA_DIR/fleet/${E1:?}.json"
rm -rf -- "${KLEPSYDRA_DIR:?}/accounts/ev1"
: >"$FLEET_LOG"

echo "resume: limits, resets and accounts"
reading a Personal 40 1000
LIMIT='  ⎿  You'"'"'ve hit your session limit · resets 1:10pm (America/New_York)'
p=$(pane lim "{\"above\":[\"work\",\"$LIMIT\"],\"on_submit\":\"busy\"}"); settle
noon=$(TZ=America/New_York date -d '2026-10-28 12:00' +%s)
resume "$noon"
check "a limit is seen and logged with its pane, account and reset" \
  "$(jq -r 'select(.message == "limit seen") | [.pane, .account, .resets] | join(" ")' "$FLEET_LOG")" "$p Personal Wed 2026-10-28 13:10"
check "#319: a folder with no known login marks no account" "$(ls "$FLEET_STATE/limited" 2>/dev/null)" ""
p2=$(pane unreg "{\"above\":[\"work\",\"$LIMIT\"]}"); settle; login a
resume "$noon"
check "#319: nor does a pane no row names (its folder is a guess)" "$(ls "$FLEET_STATE/limited" 2>/dev/null)" ""
check "#322 review 3: and its limit-seen line names no mark" \
  "$(jq -r --arg p "$p2" 'select(.message == "limit seen" and .pane == $p) | .marked' "$FLEET_LOG")" "none"
logout a; rm -f -- "${FLEET_DEFAULT_JSON:?}"; t kill-window -t "$p2"
check "nothing is typed before the reset" "$(events lim)" ""
resume "$(( noon + 3600 + 600 + 130 ))"
check "after the reset, the continue message goes in and starts a turn" "$(has "$(events lim)" "SUBMIT The usage limit has reset.")" "yes"
check "logged as resumed, with the turn started" "$(jq -r 'select(.message == "resumed with the continue message") | .started' "$FLEET_LOG")" "yes"
t kill-window -t "$p"
: >"$FLEET_LOG"
LIMIT5='  ⎿  You'"'"'ve hit your 5-hour limit · resets 1:10pm (America/New_York)'
p=$(pane lim5 "{\"above\":[\"work\",\"$LIMIT5\"],\"on_submit\":\"busy\"}"); settle
resume "$noon"
check "#263: the 2.1.316 wording is seen as a limit, with its reset" \
  "$(jq -r 'select(.message == "limit seen") | [.pane, .resets] | join(" ")' "$FLEET_LOG")" "$p Wed 2026-10-28 13:10"
check "#263: each pass says what it saw, in resume.beat for the doctor" "$(sed 's/ at=.*//' "$FLEET_STATE/resume.beat")" "panes=2 limited=1 limited_panes=$p"
check "#263: and logs it when it changes" "$(jq -r 'select(.message == "pass") | [.limited_count, .limited] | join(" ")' "$FLEET_LOG" | tail -1)" "1 $p"
resume "$noon"
check "#263: an unchanged pass is not logged again" "$(jq -c 'select(.message == "pass")' "$FLEET_LOG" | wc -l)" "1"
resume "$(( noon + 3600 + 600 + 130 ))"
check "#263: and it is resumed after the reset" "$(has "$(events lim5)" "SUBMIT The usage limit has reset.")" "yes"
t kill-window -t "$p"

: >"$FLEET_LOG"
p=$(pane banner '{"above":["work"],"below":["  ⚠ Usage limit reached · limit resets 4:10am"]}'); settle
early=$(TZ=America/New_York date -d '2026-10-29 03:00' +%s)
resume "$early"
state banner '{"above":["work"],"below":["  ⏵⏵ bypass permissions on"]}'
resume "$(( early + 3600 + 600 + 130 ))"
check "10-28: a pane seen limited whose banner cleared at the reset still resumes" "$(has "$(events banner)" "SUBMIT The usage limit has reset.")" "yes"
t kill-window -t "$p"

: >"$FLEET_LOG"
p=$(pane switch "{\"above\":[\"work\",\"$LIMIT\"]}"); settle
resume "$noon"
check "no resume while the limited account is still active" "$(events switch)" ""
reading b RIT 10 2000
resume "$(( noon + 60 ))"
check "after AJ switches to an account with room, it resumes at once" "$(has "$(events switch)" "SUBMIT The usage limit has reset.")" "yes"
check "logged as a switch" "$(jq -r 'select(.message == "resumed with the continue message") | [.account, .switched] | join(" ")' "$FLEET_LOG")" "RIT 1"
t kill-window -t "$p"
reading b RIT 100 2000
p=$(pane full "{\"above\":[\"work\",\"$LIMIT\"]}"); settle
reading a Personal 40 1000; reading b RIT 100 500
resume "$noon"
reading b RIT 100 3000
resume "$(( noon + 60 ))"
check "a switch to an account that is itself at 100% brings nothing" "$(events full)" ""
t kill-window -t "$p"
reading a Personal 40 1000; rm -f "$KLEPSYDRA_DIR/accounts/b/s.json"

echo "resume: what AJ typed is never lost"
: >"$FLEET_LOG"
p=$(pane typed "{\"above\":[\"work\",\"$LIMIT\"]}"); settle
t send-keys -t "$p" -l "AJ: also fix the footer"; settle
resume "$noon"
check "the typed line is logged while the pane waits" "$(jq -r 'select(.message | startswith("AJ typed")) | .text' "$FLEET_LOG")" "AJ: also fix the footer"
resume "$(( noon + 4330 ))"
check "at the reset it is sent as AJ typed it, with nothing typed over it" "$(events typed)" "SUBMIT AJ: also fix the footer"
t kill-window -t "$p"

: >"$FLEET_LOG"
p=$(pane vanish "{\"above\":[\"work\",\"$LIMIT\"]}"); settle
t send-keys -t "$p" -l "AJ: the note that vanished on 10-28"; settle
resume "$noon"
state vanish "{\"above\":[\"work\",\"$LIMIT\"],\"clear\":true}"   # a /login redraw empties the prompt
reading b RIT 10 2000
resume "$(( noon + 60 ))"
check "10-28: a line that left the prompt unsent is typed again, not replaced by the continue message" \
  "$(events vanish)" $'PASTE 35\nSUBMIT AJ: the note that vanished on 10-28'
check "and logged as such" "$(logged "had left the prompt unsent")" "$p "
t kill-window -t "$p"
reading a Personal 40 1000; rm -f "$KLEPSYDRA_DIR/accounts/b/s.json"

: >"$FLEET_LOG"
p=$(pane sent "{\"above\":[\"work\",\"$LIMIT\"]}"); settle
t send-keys -t "$p" -l "AJ: sent while limited"; settle
resume "$noon"
state sent "{\"above\":[\"work\",\"❯ AJ: sent while limited\",\"$LIMIT\"],\"clear\":true}"  # AJ pressed Enter himself
resume "$(( noon + 4330 ))"
check "a line AJ already sent is not sent twice; the continue message follows it" "$(has "$(events sent)" "SUBMIT The usage limit has reset.") $(grep -c 'AJ: sent' "$work/sent.log")" "yes 0"
t kill-window -t "$p"

echo "resume: review round 1 (S1, S2, S5, S6)"
: >"$FLEET_LOG"
p=$(pane menutext "{\"above\":[\"agent: the menu says Stop and wait for limit to reset · Enter to confirm\",\"x\",\"y\"]}"); settle
t send-keys -t "$p" -l "AJ half-typed thou"; settle
resume "$noon"
check "S1: the limit menu's words in a transcript are not the menu; AJ's half line is left alone" "$(events menutext)" ""
t kill-window -t "$p"

p=$(pane short "{\"above\":[\"Build ok\",\"$LIMIT\"]}"); settle
t send-keys -t "$p" -l "ok"; settle
resume "$noon"
state short "{\"above\":[\"Build ok\",\"$LIMIT\"],\"clear\":true}"
reading b RIT 10 2000
resume "$(( noon + 60 ))"
check "S2: a short line that the transcript happens to contain is still typed again" "$(grep -c '^SUBMIT ok$' "$work/short.log")" "1"
t kill-window -t "$p"; reading a Personal 40 1000; rm -f "$KLEPSYDRA_DIR/accounts/b/s.json"

p=$(pane racer '{"above":["idle"],"input":"AJ!"}'); settle
type_exactly "$p" "/remote-control"; rc=$?
settle
check "S5: typed into a box AJ was typing in, the script backs out its own characters and submits nothing" \
  "$rc [$(input_text "$(screen "$p")")] $(grep -c '^SUBMIT\|RC REQUESTED' "$work/racer.log")" "1 [AJ!] 0"
t kill-window -t "$p"

: >"$FLEET_LOG"
p=$(pane keep "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tkeeper\t%s\t%s\t/w\n' "$p" "$work/brief.src" "$SID" >"$REGISTRY"
printf '#!/usr/bin/env bash\necho "HOLD: only 1 MiB available"\nexit 2\n' >"$work/launch-fails.sh"
resume "$(TZ=America/New_York date -d '2026-10-28 09:00' +%s)"
LAUNCH="$work/launch-fails.sh" FLEET_NOW=$(( noon + 4330 )) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "S6: when the fresh launch fails, the old pane is kept and resumed" \
  "$(fleet_panes | grep -cx "$p") $(grep -c 'SUBMIT /exit' "$work/keep.log") $(has "$(events keep)" "SUBMIT The usage limit has reset.")" "1 0 yes"
check "and the failed launch is an error in the log" "$(jq -r 'select(.level == "ERROR") | .message' "$FLEET_LOG")" "fresh session not started; the old pane is kept"
t kill-window -t "$p"; : >"$REGISTRY"

echo "resume: review round 2 (B-1, B-2)"
cat >"$work/launcher-bg.sh" <<EOF
#!/usr/bin/env bash
# The launcher's "new", plus a long-lived child, as a tmux server it starts would be.
sleep 300 >/dev/null 2>&1 &
echo \$! >"$work/bg.pid"
tmux -L "\$KLEPSYDRA_TMUX_SOCKET" new-window -d -t fleet: -c "\$3" "\$KLEPSYDRA_CLAUDE"
EOF
printf '%s' '{"above":["Claude Code"]}' >"$work/bgl.json"; : >"$work/bgl.log"
printf 'A brief.\n' >"$work/bgl.src"
( exec 7>>"$FLEET_STATE/.fresh.lock"; FLEET_SCOPE=0 FLEET_MIN_AVAIL_MB=0 FLEET_LAUNCHER="$work/launcher-bg.sh" FLEET_DIR="$work" \
  FLEET_CLAUDE="python3 -I $fake $work/bgl.json $work/bgl.log" bash "$here/launch.sh" bgl "$work/bgl.src" >"$work/bgl.out" 2>&1 )
bg=$(cat "$work/bg.pid" 2>/dev/null)
if [[ -n $bg && -d /proc/$bg ]]; then ran=yes; else ran=$(tail -3 "$work/bgl.out"); fi
check "B-1: the launcher really ran (its child is alive)" "$ran" "yes"
check "B-1: a long-lived child of the launcher holds neither lock" \
  "$(find "/proc/$bg/fd" -lname '*.launch.lock' -o -lname '*.fresh.lock' 2>/dev/null | wc -l) $(flock -n "$FLEET_STATE/.launch.lock" true && echo free)" "0 free"
kill "$bg" 2>/dev/null

: >"$FLEET_LOG"
p=$(pane changed "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tchanger\t%s\t%s\t/w\n' "$p" "$work/brief.src" "$SID" >"$REGISTRY"
cat >"$work/launch-slow.sh" <<EOF
#!/usr/bin/env bash
# A launch during which AJ types into the old pane; it repoints the row as launch.sh does.
tmux -L "$FLEET_SOCK" send-keys -t "$p" -l "AJ: wait, one more thing"
sleep 1
sed -i "s|^$p\t|%998\t|" "$REGISTRY"
echo "pane=%998 session=x account=x avail=1MiB brief=started"
EOF
resume "$(TZ=America/New_York date -d '2026-10-28 09:00' +%s)"
LAUNCH="$work/launch-slow.sh" FLEET_NOW=$(( noon + 4330 )) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "B-2: AJ typed during the launch: the old pane stays, with his text, and nothing exits it" \
  "$(fleet_panes | grep -cx "$p") $(grep -c 'SUBMIT /exit' "$work/changed.log") [$(input_text "$(screen "$p")")]" "1 0 [AJ: wait, one more thing]"
check "and the registry points at it again" "$(cut -f1,4 "$REGISTRY")" "$p	$SID"
check "round 3: nothing is typed into the pane AJ took back" "$(grep -c '^SUBMIT' "$work/changed.log")" "0"
check "logged as an error" "$(jq -r 'select(.level == "ERROR") | .message' "$FLEET_LOG" | grep -c 'the old pane changed while its fresh session launched')" "1"
t kill-window -t "$p"; : >"$REGISTRY"

# #261 review 10: the new session's /exit runs the fleet hook's SessionEnd,
# which records a finish for the row naming that session. The rollback points
# the row back first, so the agent itself is never recorded finished.
: >"$FLEET_LOG"; rm -f -- "$FLEET_STATE/finished.tsv"
p=$(pane rolled "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\trolled\t%s\t%s\t/w\n' "$p" "$work/brief.src" "$SID" >"$REGISTRY"
NSID=bbbbbbbb-0000-4000-8000-0000000000e1
cat >"$work/launch-undelivered.sh" <<EOF
#!/usr/bin/env bash
# A launch whose brief never starts a turn: a new pane, the row repointed at it
# and its session as launch.sh does, then NOT-DELIVERED.
printf '%s' '{"exit_on_exit": true, "on_exit": "bash $here/registry-event.sh SessionEnd $NSID prompt_input_exit"}' >"$work/rolled-new.json"
: >"$work/rolled-new.log"
n=\$(tmux -L "$FLEET_SOCK" new-window -d -P -F '#{pane_id}' -t fleet: "python3 -I $fake $work/rolled-new.json $work/rolled-new.log")
sleep 0.6
sed -i "s|^$p\t\([^\t]*\)\t\([^\t]*\)\t$SID|\$n\t\1\t\2\t$NSID|" "$REGISTRY"
echo "pane=\$n session=$NSID account=x avail=1MiB brief=NOT-DELIVERED"
EOF
resume "$(TZ=America/New_York date -d '2026-10-28 09:00' +%s)"
LAUNCH="$work/launch-undelivered.sh" FLEET_NOW=$(( noon + 4330 )) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "#261 review 10: an undelivered brief's rollback: the new pane got /exit, and its end ran the hook" \
  "$(grep -c 'SUBMIT /exit' "$work/rolled-new.log") $(jq -r 'select(.message == "fresh session'"'"'s brief did not start; the old pane stays and the new one goes") | .name' "$FLEET_LOG")" "1 rolled"
check "#261 review 10: the row names the old pane and session again, and no finish is recorded" \
  "$(cut -f1,4 "$REGISTRY") | $(cat "$FLEET_STATE/finished.tsv" 2>/dev/null | grep -c .) | $(session_finished "$SID" && echo finished || echo not-finished)" "$p	$SID | 0 | not-finished"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"; rm -f -- "$FLEET_STATE/finished.tsv"
# A launch that started its session but never repointed the row (it could not
# take the registry lock): the old session must not be retired, or its own
# /exit would record the agent finished.
: >"$FLEET_LOG"
p=$(pane unpointed "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"],\"exit_on_exit\":true,\"on_exit\":\"bash $here/registry-event.sh SessionEnd $SID prompt_input_exit\"}"); settle
live "$p"
printf '%s\tunpointed\t%s\t%s\t/w\n' "$p" "$work/brief.src" "$SID" >"$REGISTRY"
cat >"$work/launch-unpointed.sh" <<EOF
#!/usr/bin/env bash
: >"$work/unpointed-new.log"
n=\$(tmux -L "$FLEET_SOCK" new-window -d -P -F '#{pane_id}' -t fleet: "python3 -I $fake $work/rolled-new.json $work/unpointed-new.log")
sleep 0.6
echo "pane=\$n session=$NSID account=x avail=1MiB brief=started"
EOF
resume "$(TZ=America/New_York date -d '2026-10-28 09:00' +%s)"
LAUNCH="$work/launch-unpointed.sh" FLEET_NOW=$(( noon + 4330 )) bash "$here/resume-at-reset.sh" --once 2>/dev/null
new_unp=$(jq -r 'select(.message | startswith("the launch left its row unregistered")) | .new_pane' "$FLEET_LOG")
check "#261 review 10: a row the launch never repointed: fresh repoints it to the new session, then retires the old, and no finish is recorded" \
  "$(grep -c 'SUBMIT /exit' "$work/unpointed.log") $(grep -c 'SUBMIT /exit' "$work/unpointed-new.log") | $(cut -f1,4 "$REGISTRY") | $(cat "$FLEET_STATE/finished.tsv" 2>/dev/null | grep -c .)" \
  "1 0 | $new_unp	$NSID | 0"
check "#261 review 10: logged as a warning" "$(jq -r 'select(.level == "WARN") | .message' "$FLEET_LOG" | grep -c "the launch left its row unregistered")" "1"
t kill-window -t "$new_unp" 2>/dev/null
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"; rm -f -- "$FLEET_STATE/finished.tsv"
# #261 review 12: the same, with a stale row of another agent on the new pane id
# (a past server's): only a row of this agent's name counts as registered.
: >"$FLEET_LOG"
p=$(pane unstale "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"],\"exit_on_exit\":true,\"on_exit\":\"bash $here/registry-event.sh SessionEnd $SID prompt_input_exit\"}"); settle
live "$p"
printf '%s\tunstale\t%s\t%s\t/w\n' "$p" "$work/brief.src" "$SID" >"$REGISTRY"
cat >"$work/launch-unstale.sh" <<EOF
#!/usr/bin/env bash
: >"$work/unstale-new.log"
n=\$(tmux -L "$FLEET_SOCK" new-window -d -P -F '#{pane_id}' -t fleet: "python3 -I $fake $work/rolled-new.json $work/unstale-new.log")
printf '%s\tother\t/b\tOTHERSID\t/w\n' "\$n" >>"$REGISTRY"
sleep 0.6
echo "pane=\$n session=$NSID account=x avail=1MiB brief=started"
EOF
resume "$(TZ=America/New_York date -d '2026-10-28 09:00' +%s)"
LAUNCH="$work/launch-unstale.sh" FLEET_NOW=$(( noon + 4330 )) bash "$here/resume-at-reset.sh" --once 2>/dev/null
new_unp=$(jq -r 'select(.message | startswith("the launch left its row unregistered")) | .new_pane' "$FLEET_LOG")
check "#261 review 12: a stale row on the new pane id is not this agent's: its row is still repointed, and no finish is recorded" \
  "$(cut -f1,2,4 "$REGISTRY" | tr '\t\n' ' |') $(cat "$FLEET_STATE/finished.tsv" 2>/dev/null | grep -c .)" \
  "${new_unp:-none} unstale $NSID|${new_unp:-none} other OTHERSID| 0"
[[ -n $new_unp ]] && t kill-window -t "$new_unp" 2>/dev/null
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"; rm -f -- "$FLEET_STATE/finished.tsv"
# The other rollback, AJ typing into the old pane during the launch, in the same order.
: >"$FLEET_LOG"
p=$(pane typedin "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\ttypedin\t%s\t%s\t/w\n' "$p" "$work/brief.src" "$SID" >"$REGISTRY"
cat >"$work/launch-typedin.sh" <<EOF
#!/usr/bin/env bash
: >"$work/typedin-new.log"
n=\$(tmux -L "$FLEET_SOCK" new-window -d -P -F '#{pane_id}' -t fleet: "python3 -I $fake $work/rolled-new.json $work/typedin-new.log")
tmux -L "$FLEET_SOCK" send-keys -t "$p" -l "AJ: hold on"
sleep 1
sed -i "s|^$p\t\([^\t]*\)\t\([^\t]*\)\t$SID|\$n\t\1\t\2\t$NSID|" "$REGISTRY"
echo "pane=\$n session=$NSID account=x avail=1MiB brief=started"
EOF
resume "$(TZ=America/New_York date -d '2026-10-28 09:00' +%s)"
LAUNCH="$work/launch-typedin.sh" FLEET_NOW=$(( noon + 4330 )) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "#261 review 10: AJ typed during the launch: the new session's end leaves the restored row alone" \
  "$(grep -c 'SUBMIT /exit' "$work/typedin-new.log") | $(cut -f1,4 "$REGISTRY") | $(cat "$FLEET_STATE/finished.tsv" 2>/dev/null | grep -c .)" "1 | $p	$SID | 0"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"; rm -f -- "$FLEET_STATE/finished.tsv"

echo "round 4: AJ resumed the old pane during the launch"
: >"$FLEET_LOG"
p=$(pane resumed "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tresumer\t%s\t%s\t/w\n' "$p" "$work/brief.src" "$SID" >"$REGISTRY"
printf '%s' '{"above":["Claude Code"]}' >"$work/newp.json"; : >"$work/newp.log"
cat >"$work/launch-resumed.sh" <<EOF
#!/usr/bin/env bash
# AJ resumes the old pane while the new one starts on its brief, as launch.sh would leave it.
tmux -L "$FLEET_SOCK" send-keys -t "$p" -l "AJ: carry on"
tmux -L "$FLEET_SOCK" send-keys -t "$p" Enter
new=\$(tmux -L "$FLEET_SOCK" new-window -d -P -F '#{pane_id}' -t fleet: "python3 -I $fake $work/newp.json $work/newp.log")
for _ in \$(seq 50); do tmux -L "$FLEET_SOCK" capture-pane -t "\$new" -p | grep -q '❯' && break; sleep 0.1; done
tmux -L "$FLEET_SOCK" send-keys -t "\$new" -l "the brief"
tmux -L "$FLEET_SOCK" send-keys -t "\$new" Enter
sleep 0.5
sed -i "s|^$p\t|\$new\t|" "$REGISTRY"
echo "pane=\$new session=x account=x avail=1MiB brief=started"
EOF
resume "$(TZ=America/New_York date -d '2026-10-28 09:00' +%s)"
LAUNCH="$work/launch-resumed.sh" FLEET_NOW=$(( noon + 4330 )) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "rc 4: nothing is typed into the pane AJ resumed" "$(grep -c '^SUBMIT' "$work/resumed.log") $(grep -c 'The usage limit' "$work/resumed.log")" "1 0"
check "the new pane: its turn stopped, its returned brief cleared, then /exit" "$(grep -E '^(SUBMIT|INTERRUPTED|CTRL)' "$work/newp.log" | tr '\n' '|')" "SUBMIT the brief|INTERRUPTED|SUBMIT /exit|"
check "and the registry points at the old pane again" "$(cut -f1,4 "$REGISTRY")" "$p	$SID"
t kill-window -t "$p"; : >"$REGISTRY"

echo "live_session"
p=$(pane two '{"above":["idle"]}'); settle
live "$p"
jq -n --arg p "$p" '{ended: null, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/88888888-2222-4333-8444-555555555555.json"
check "two live files naming one pane are no answer" "$(live_session "$p" || echo none)" "none"
rm -f -- "${KLEPSYDRA_DIR:?}/fleet/88888888-2222-4333-8444-555555555555.json"
check "one is the answer" "$(live_session "$p")" "$SID"
t kill-window -t "$p"

echo "registry session ids (S-1, S-2)"
p=$(pane clr '{"above":["idle"]}'); settle
live "$p"
printf '%s\tclr\t%s\t%s\t/w\n' "$p" "$work/brief.src" "$SID" >"$REGISTRY"
NEW_SID=99999999-2222-4333-8444-555555555555
( for _ in $(seq 50); do grep -q '^SUBMIT /clear' "$work/clr.log" 2>/dev/null && break; sleep 0.2; done
  jq '.ended = {reason: "clear"}' "$KLEPSYDRA_DIR/fleet/$SID.json" >"$work/e.json" && mv "$work/e.json" "$KLEPSYDRA_DIR/fleet/$SID.json"
  jq -n --arg p "$p" '{ended: null, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/$NEW_SID.json" ) &
FLEET_START_WAIT=2 FLEET_TURN_WAIT=2 bash "$here/fresh-now.sh" "$p" >/dev/null 2>&1
wait
check "S-1: after /clear the registry follows the new session id" "$(cut -f4 "$REGISTRY")" "$NEW_SID"
rm -f -- "${KLEPSYDRA_DIR:?}/fleet/$NEW_SID.json"
live "$p"
printf '%s\tclr\t%s\n' "$p" "$work/brief.src" >"$REGISTRY"
FLEET_SYSTEMCTL="$work/bin/systemctl" FLEET_UNITS="$work/units" FLEET_CUTOVER_WAIT=1 bash "$here/cutover.sh" >/dev/null 2>&1
check "S-2: the cut-over gives a row from before session ids its live one" "$(cut -f4 "$REGISTRY")" "$SID"
t kill-window -t "$p"; : >"$REGISTRY"

echo "resume: menus, the orchestrator and Remote Control"
: >"$FLEET_LOG"
p=$(pane menu '{"above":["work"],"menu":"limit"}'); settle
resume "$noon"
check "the limit menu gets option 1" "$(events menu)" "LIMIT MENU STOP"
t kill-window -t "$p"

: >"$FLEET_LOG"
p=$(pane orchlim "{\"above\":[\"work\",\"$LIMIT\"]}"); settle
printf '%s\n' "$p" >"$FLEET_STATE/orchestrator.pane"
resume "$noon"
check "the orchestrator's limited pane is not typed into before its reset" "$(events orchlim)" ""
resume "$(( noon + 4330 ))"
check "#175: with no other account, he is resumed at the reset like a worker" "$(has "$(events orchlim)" "SUBMIT The usage limit has reset.")" "yes"
t kill-window -t "$p"
p=$(pane orch '{"above":["idle"]}'); settle
printf '%s\n' "$p" >"$FLEET_STATE/orchestrator.pane"
resume "$(( noon + 4400 ))"
check "but gets /remote-control once per account while idle at an empty prompt" "$(events orch)" $'RC REQUESTED\nRC ON'
resume "$(( noon + 4460 ))"
check "only once per account" "$(grep -c 'RC REQUESTED' "$work/orch.log")" "1"
check "logged" "$(jq -r 'select(.message == "remote control on") | [.pane, .account, .orchestrator] | join(" ")' "$FLEET_LOG")" "$p Personal 1"
t kill-window -t "$p"; rm -f "$FLEET_STATE/orchestrator.pane"

: >"$FLEET_LOG"
p=$(pane worker '{"above":["idle"],"rc":"on"}'); u=$(pane stranger '{"above":["idle"]}'); settle
printf '%s\tworker\t%s\n' "$p" "$work/brief.src" >"$REGISTRY"
resume "$noon"
check "a registered pane already on answers the menu with Continue" "$(events worker)" $'RC REQUESTED\nRC CONTINUE'
check "a pane outside the registry is left alone" "$(events stranger)" ""
t send-keys -t "$p" -l "typing"; settle
reading a RIT 10 4000
resume "$(( noon + 60 ))"
check "a pane holding typed text gets no /remote-control" "$(grep -c 'RC REQUESTED' "$work/worker.log")" "1"
t kill-window -t "$p"; t kill-window -t "$u"; reading a Personal 40 1000

echo "resume: a fresh session after a long idle"
: >"$FLEET_LOG"
p=$(pane idle "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"]}"); settle
printf 'the brief body\n' >"$work/brief.src"
live "$p"
printf '%s\tidler\t%s\t%s\t/w\n' "$p" "$work/brief.src" "$SID" >"$REGISTRY"
cat >"$work/launch-stub.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$work/launched"
echo "pane=%999 session=x avail=1MiB brief=started"
EOF
morning=$(TZ=America/New_York date -d '2026-10-28 09:00' +%s)
resume "$morning"
LAUNCH="$work/launch-stub.sh" FLEET_NOW=$(( noon + 4330 )) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "past an hour idle, the registered pane exits" "$(events idle)" "SUBMIT /exit"
check "and launch.sh starts its brief fresh" "$(head -1 "$work/launched")" "idler"
check "the fresh brief starts with the preamble and ends with the brief" \
  "$(head -c 61 "$(sed -n 2p "$work/launched")") | $(tail -1 "$(sed -n 2p "$work/launched")")" "Fresh start: a previous agent with the brief below stopped at | the brief body"
check "logged with the new pane" "$(jq -r 'select(.message == "fresh session after a long idle") | .new_pane' "$FLEET_LOG")" "%999"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

: >"$FLEET_LOG"
p=$(pane reused "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"]}"); settle
live "%0"   # a tmux restart: the registered session now sits elsewhere; this pane id is another agent's
printf '%s\tidler\t%s\t%s\t/w\n' "$p" "$work/brief.src" "$SID" >"$REGISTRY"
: >"$work/launched"
resume "$morning"
LAUNCH="$work/launch-stub.sh" FLEET_NOW=$(( noon + 4330 )) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "B2: a reused pane id is never exited; it is resumed in place" \
  "$(grep -c 'SUBMIT /exit' "$work/reused.log") $(has "$(events reused)" "SUBMIT The usage limit has reset.") $(wc -c <"$work/launched")" "0 yes 0"
check "and the refusal is logged" "$(logged "fresh session refused")" "$p "
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

: >"$FLEET_LOG"
p=$(pane late "{\"above\":[\"⏺ Done. done 11:50 PM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tidler\t%s\t%s\t/w\n' "$p" "$work/brief.src" "$SID" >"$REGISTRY"
: >"$work/launched"
resume "$morning"
LAUNCH="$work/launch-stub.sh" FLEET_NOW=$(( noon + 4330 )) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "a done time later in the day than now is the night before: idle since then, it starts fresh" \
  "$(grep -c 'SUBMIT /exit' "$work/late.log") $(head -1 "$work/launched")" "1 idler"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

# 55 min 10 s from the start of its minute, 54 min 11 s from the end: past an
# hour by the cache's measure, so it starts fresh (12:17 PM, below, does not).
: >"$FLEET_LOG"
p=$(pane sixteen "{\"above\":[\"⏺ Done. done 12:16 PM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tidler\t%s\t%s\t/w\n' "$p" "$work/brief.src" "$SID" >"$REGISTRY"
: >"$work/launched"
resume "$morning"
LAUNCH="$work/launch-stub.sh" FLEET_NOW=$(( noon + 4330 )) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "done 12:16 PM at 1:12:10 PM is past the hour: it starts fresh" \
  "$(grep -c 'SUBMIT /exit' "$work/sixteen.log") $(head -1 "$work/launched")" "1 idler"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

# Stopped 22 min ago; in a minute after the pass began (NOW is its start),
# also across midnight; or 5 min ago in the hour that repeats when clocks go
# back (an hour in London, two in Troll, half an hour on Lord Howe): none is
# idle, so each gets the continue message.
# Each cell: pane name, stamp, NOW, time zone, and the pass that first sees the limit.
london=$(TZ=Europe/London date -d '2026-10-25 01:20 +01:00' +%s)
troll=$(TZ=Antarctica/Troll date -d '2026-10-25 01:40 +02' +%s)
lhi=$(TZ=Australia/Lord_Howe date -d '2027-04-04 01:45 +11' +%s)
for cell in "recent|12:50 PM|$(( noon + 4330 ))" "racing|1:13 PM|$(( noon + 4330 ))" \
  "minuteend|12:17 PM|$(( noon + 4330 ))" \
  "midnight|12:00 AM|$(TZ=America/New_York date -d '2026-10-28 23:59:30' +%s)" \
  "springnight|12:00 AM|$(TZ=America/New_York date -d '2027-03-14 23:59:30' +%s)" \
  "fallback|1:45 AM|$(TZ=America/New_York date -d '2026-11-01 01:50 EST' +%s)" \
  "firsthour|1:45 AM|$(TZ=America/New_York date -d '2026-11-01 01:50 EDT' +%s)" \
  "london|1:10 AM|$london|Europe/London|$(( london - 43200 ))" \
  "troll|1:30 AM|$troll|Antarctica/Troll|$(( troll - 43200 ))" \
  "lordhowe|1:35 AM|$lhi|Australia/Lord_Howe|$(( lhi - 86400 ))"; do
  IFS='|' read -r name done_at at zone first <<<"$cell"
  : >"$FLEET_LOG"
  p=$(pane "$name" "{\"above\":[\"⏺ Done. done $done_at\",\"$LIMIT\"]}"); settle
  live "$p"
  printf '%s\tidler\t%s\t%s\t/w\n' "$p" "$work/brief.src" "$SID" >"$REGISTRY"
  : >"$work/launched"
  TZ=${zone:-$TZ} resume "${first:-$morning}"
  TZ=${zone:-$TZ} LAUNCH="$work/launch-stub.sh" FLEET_NOW=$at bash "$here/resume-at-reset.sh" --once 2>/dev/null
  check "done $done_at at $(TZ=${zone:-$TZ} date -d "@$at" '+%F %R %Z') is not idle: no fresh session, the continue message" \
    "$(grep -c 'SUBMIT /exit' "$work/$name.log") $(wc -c <"$work/launched") $(has "$(events "$name")" "SUBMIT The usage limit has reset.")" "0 0 yes"
  t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"
done

echo "launch.sh"
cat >"$work/launcher.sh" <<EOF
#!/usr/bin/env bash
# The launcher's "new": one more fleet window running KLEPSYDRA_CLAUDE.
printf '%s\n' "\${KLEPSYDRA_BACKGROUND-unset}" >>"$work/launcher-bg"
tmux -L "\$KLEPSYDRA_TMUX_SOCKET" new-window -d -t fleet: -c "\$3" "\$KLEPSYDRA_CLAUDE"
EOF
: >"$work/launcher-bg"
printf 'Do the thing.\nThen the other thing.\n' >"$work/task.src"
launch() { # NAME STATE-JSON: launch.sh with a fake claude starting from STATE
  printf '%s' "$2" >"$work/$1.json"; : >"$work/$1.log"
  FLEET_SCOPE=0 FLEET_MIN_AVAIL_MB=0 FLEET_LAUNCHER="${LAUNCHER:-$work/launcher.sh}" FLEET_DIR="$work" \
    FLEET_CLAUDE="python3 -I $fake $work/$1.json $work/$1.log" bash "$here/launch.sh" "$1" "$work/task.src" 2>/dev/null | head -1
}
cp "$work/task.src" "$FLEET_STATE/task-agent1.src"
out=$(launch agent1 '{"above":["Claude Code"]}')
check "delivered: Remote Control settles first, then the brief goes in whole and a turn starts" \
  "$(events agent1)" $'RC REQUESTED\nRC ON\nPASTE 36\nSUBMIT Do the thing.\\nThen the other thing.\\n'
check "reported started" "${out##* }" "brief=started"
check "#216: it asks the launcher to open behind the window in view" "$(cat "$work/launcher-bg")" "1"
sid=$(sed -E 's/.*session=([^ ]+).*/\1/' <<<"$out")
check "registered with its session id and folder" "$(cut -f2,3,4,5 "$REGISTRY")" "agent1	$FLEET_STATE/task-agent1.src	$sid	$work"
out=$(launch agent1 '{"above":["Claude Code"]}')
p=${out%% *}; p=${p#pane=}
check "a relaunch repoints the same row" "$(wc -l <"$REGISTRY") $(cut -f1 "$REGISTRY")" "1 $p"
check "the fleet log has the launch" "$(jq -r 'select(.target == "fleet::launch" and .pane == "'"$p"'") | .message' "$FLEET_LOG" | tail -1)" "brief delivered: a turn started"

# #289: the scope's task cap, from the tightest pids.max above the caller's own
# cgroup, split over the two workers and Heph.
cgr="$work/cg"; leaf=/user.slice/user-1.slice/user@1.service/app.slice/me.scope
mkdir -p "$cgr$leaf"
echo 11926 >"$cgr$leaf/pids.max"; echo max >"$cgr${leaf%/*}/pids.max"; echo 26237 >"$cgr/user.slice/user-1.slice/pids.max"; echo max >"$cgr/user.slice/pids.max"
tm() { FLEET_CGROUP_ROOT="$cgr" FLEET_CGROUP=$leaf fleet_tasks_max; }
check "#289: the user slice's cap over three, never the caller's own scope's" "$(tm)" "8745"
echo 9000 >"$cgr${leaf%/*}/pids.max"
check "#289: a tighter cap higher up wins" "$(tm)" "3000"
echo max >"$cgr${leaf%/*}/pids.max"; echo max >"$cgr/user.slice/user-1.slice/pids.max"
check "#289: no cap readable: fails (the scope then inherits)" "$(tm || echo none)" "none"
check "#289: FLEET_TASKS_MAX sets it, and a bad one is refused" "$(FLEET_TASKS_MAX=500 tm) $(FLEET_TASKS_MAX=5x tm || echo refused)" "500 refused"
echo 26237 >"$cgr/user.slice/user-1.slice/pids.max"
# A systemd-run that records its arguments and runs the command after its options.
cat >"$work/systemd-run" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$work/sdrun.calls"
while [[ \$1 == --* || \$1 == -p ]]; do [[ \$1 == -p ]] && shift; shift; done
exec "\$@"
EOF
chmod +x "$work/systemd-run"; : >"$work/sdrun.calls"
printf '%s' '{"above":["Claude Code"]}' >"$work/scoped.json"; : >"$work/scoped.log"
out=$(FLEET_SCOPE=1 FLEET_SYSTEMD_RUN="$work/systemd-run" FLEET_CGROUP_ROOT="$cgr" FLEET_CGROUP=$leaf FLEET_MIN_AVAIL_MB=0 \
  FLEET_LAUNCHER="$work/launcher.sh" FLEET_DIR="$work" FLEET_CLAUDE="python3 -I $fake $work/scoped.json $work/scoped.log" \
  bash "$here/launch.sh" scoped "$work/task.src" 2>/dev/null | head -1)
check "#289: the session's scope gets its own task cap beside the memory caps" \
  "$(grep -o 'MemorySwapMax=[^ ]* -p TasksMax=[0-9]*' "$work/sdrun.calls")" "MemorySwapMax=1G -p TasksMax=8745"
check "#289: the launch logs the cap it set" "$(jq -r 'select(.message == "window opened" and .name == "scoped") | .tasks_max' "$FLEET_LOG")" "8745"
check "#289: the scoped launch still delivers" "${out##* }" "brief=started"
t kill-pane -t "$(sed -E 's/^pane=([^ ]+).*/\1/' <<<"$out")" 2>/dev/null
# #353: the scope in the workers' slice, kept when the kernel kills a job in it,
# capped hard (no MemoryHigh: it freezes rather than kills); claude at OOM rank
# 0, and every shell it starts ranked first through BASH_ENV.
call=$(tail -1 "$work/sdrun.calls")
check "#353: a worker's scope sits in the workers' slice and outlives an OOM kill in it" \
  "$(grep -o -- '--slice=[^ ]* -p OOMPolicy=[^ ]* -p MemoryMax=[^ ]* -p MemorySwapMax=[^ ]*' <<<"$call")" "--slice=fleet-workers.slice -p OOMPolicy=continue -p MemoryMax=5G -p MemorySwapMax=1G"
check "#353: no MemoryHigh on the scope" "$(grep -c MemoryHigh <<<"$call")" "0"
check "#353: claude starts at OOM rank 0, its shells ranked first by BASH_ENV" \
  "$(grep -c "fleet-oom env .*BASH_ENV=$here/oom-tool.sh KLEPSYDRA_AGENT=scoped" <<<"$call") $(grep -c 'echo 0 >/proc/self/oom_score_adj' <<<"$call")" "1 1"
: >"$work/sdrun.calls"
out=$(FLEET_SETTINGS='' FLEET_SCOPE=1 FLEET_SYSTEMD_RUN="$work/systemd-run" FLEET_CGROUP_ROOT="$cgr" FLEET_CGROUP=$leaf FLEET_MIN_AVAIL_MB=0 \
  FLEET_LAUNCHER="$work/launcher.sh" FLEET_DIR="$work" FLEET_CLAUDE="python3 -I $fake $work/scoped.json $work/scoped.log" \
  bash "$here/launch.sh" heph "$work/task.src" 2>/dev/null | head -1)
check "#353: the orchestrator's scope sits in the fleet's slice, beside the workers'" \
  "$(grep -o -- '--slice=[^ ]* -p OOMPolicy=[^ ]*' "$work/sdrun.calls")" "--slice=fleet.slice -p OOMPolicy=continue"
check "#353: and the launch logs which" "$(jq -r 'select(.message == "window opened" and .name == "heph") | .slice' "$FLEET_LOG")" "orchestrator"
t kill-pane -t "$(sed -E 's/^pane=([^ ]+).*/\1/' <<<"$out")" 2>/dev/null
# Placed by name, not by missing settings: a bare launch under another name is a worker.
: >"$work/sdrun.calls"
out=$(FLEET_SETTINGS='' FLEET_SCOPE=1 FLEET_SYSTEMD_RUN="$work/systemd-run" FLEET_CGROUP_ROOT="$cgr" FLEET_CGROUP=$leaf FLEET_MIN_AVAIL_MB=0 \
  FLEET_LAUNCHER="$work/launcher.sh" FLEET_DIR="$work" FLEET_CLAUDE="python3 -I $fake $work/scoped.json $work/scoped.log" \
  bash "$here/launch.sh" scoped-bare "$work/task.src" 2>/dev/null | head -1)
check "#353 review 4: a launch with no worker settings under another name sits in the workers' slice" \
  "$(grep -o -- '--slice=[^ ]* -p OOMPolicy=[^ ]*' "$work/sdrun.calls")" "--slice=fleet-workers.slice -p OOMPolicy=continue"
t kill-pane -t "$(sed -E 's/^pane=([^ ]+).*/\1/' <<<"$out")" 2>/dev/null

out=$(launch agent2 '{"above":["Claude Code"],"on_submit":"limit"}')
check "blocked by a limit" "${out##* }" "brief=blocked-by-limit"

out=$(launch agent3 '{"above":["Claude Code"],"on_submit":"none"}')
check "not delivered when no turn ever starts" "${out##* }" "brief=NOT-DELIVERED"
check "and the retries never sent Escape" "$(grep -cE 'ESC|INTERRUPTED' "$work/agent3.log")" "0"

out=$(launch agent4 '{"above":["Claude Code"],"rc":"on","rc_delay":6}')
check "10-28 2c: a slow Remote Control menu is answered before the brief is pasted" "$(events agent4)" \
  $'RC REQUESTED\nRC CONTINUE\nPASTE 36\nSUBMIT Do the thing.\\nThen the other thing.\\n'
check "reported started" "${out##* }" "brief=started"

out=$(FLEET_START_WAIT=1 launch agent5 '{"above":["Claude Code"],"busy_delay":2}')
check "a turn whose spinner shows late is never interrupted by a retry" "$(grep -cE 'ESC|INTERRUPTED' "$work/agent5.log") ${out##* }" "0 brief=started"
check "nor submitted twice" "$(grep -c '^SUBMIT' "$work/agent5.log")" "1"
# The cause, with the screen mocked: the wait after Enter ends, the log line after it takes
# long enough for the box to empty, and the second Enter must not be pressed on the old reading.
dbcalls="$work/db.calls"; : >"$dbcalls"; rm -f -- "$work/db.gate"
check "a box that emptied while the retry's log line ran gets no second Enter (the CI red: an empty line submitted)" \
  "$( ( screen() { :; }; busy() { return 1; }; has_input_box() { return 0; }
        input_text() { [[ -s $work/db.gate ]] || echo brief; }
        holds_input() { [[ -n $(input_text) ]]; }
        wait_for() { [[ $3 == sent_or_started ]] && return 1; return 0; }
        t() { [[ $1 == send-keys ]] && echo enter >>"$dbcalls"; return 0; }
        flog() { echo gone >"$work/db.gate"; }
        deliver_brief %9 /dev/null >/dev/null; grep -c enter "$dbcalls" ) )" "1"

echo "launch.sh: a slow or stuck start (#187)"
: >"$FLEET_LOG"
out=$(launch agent6 '{"above":["Claude Code"],"enter_ignore":1}')
check "#187: an Enter lost after the paste is pressed again, and the brief starts once" \
  "${out##* } $(grep -c '^SUBMIT' "$work/agent6.log") $(grep -c 'lost after a paste' "$work/agent6.log")" "brief=started 1 1"
check "the second press is logged" "$(jq -r 'select(.message | startswith("the brief is still in the prompt")) | .try' "$FLEET_LOG")" "1"
: >"$FLEET_LOG"
began=$SECONDS
out=$(FLEET_LAUNCH_DEADLINE=8 launch agent7 '{"above":["Claude Code"],"stall":120}')
check "#187: a session that takes no Enter fails within the launch's deadline, not 9 min later" \
  "${out##* } $(( SECONDS - began < 25 ))" "brief=NOT-DELIVERED 1"
check "with no Escape sent, and Remote Control's unsent command backed out before the paste" \
  "$(grep -cE 'ESC|INTERRUPTED' "$work/agent7.log") $(grep -c '^PASTE' "$work/agent7.log")" "0 1"
check "each step is logged with its time" \
  "$(jq -r 'select(.target == "fleet::launch" and .took_s != null) | .message' "$FLEET_LOG" | tr '\n' '|')" \
  "window opened|prompt showed|remote control did not settle before the brief|brief not delivered|"
cat >"$work/launcher-hold.sh" <<EOF
#!/usr/bin/env bash
tmux -L "\$KLEPSYDRA_TMUX_SOCKET" new-window -d -t fleet: -c "\$3" "\$KLEPSYDRA_CLAUDE"
EOF
printf '%s' '{"above":["Claude Code"],"stall":120}' >"$work/slow1.json"; : >"$work/slow1.log"
( FLEET_LAUNCH_DEADLINE=10 FLEET_SCOPE=0 FLEET_MIN_AVAIL_MB=0 FLEET_LAUNCHER="$work/launcher-hold.sh" FLEET_DIR="$work" \
  FLEET_CLAUDE="python3 -I $fake $work/slow1.json $work/slow1.log" bash "$here/launch.sh" slow1 "$work/task.src" >/dev/null 2>&1 ) &
slowjob=$!
sleep 3
began=$SECONDS
out=$(launch agent8 '{"above":["Claude Code"]}')
check "#187: a second launch runs beside a stuck one instead of waiting for it" "${out##* } $(( SECONDS - began < 8 ))" "brief=started 1"
check "and the stuck launch marks its pane as starting" "$(find "$FLEET_STATE/launching" -mindepth 1 | wc -l)" "1"
wait "$slowjob"
check "the mark goes when the launch ends" "$(find "$FLEET_STATE/launching" -mindepth 1 | wc -l)" "0"
cat >"$work/launcher-drain.sh" <<EOF
#!/usr/bin/env bash
# wt.exe drains whatever stdin WSL interop hands it (10-31): so does this.
cat >/dev/null
tmux -L "\$KLEPSYDRA_TMUX_SOCKET" new-window -d -t fleet: -c "\$3" "\$KLEPSYDRA_CLAUDE"
EOF
got=$(printf 'row 2\nrow 3\n' | { LAUNCHER="$work/launcher-drain.sh" launch agent9 '{"above":["Claude Code"]}' >/dev/null; cat; })
check "#242: a launch from a loop reading rows on stdin leaves the rest of the rows" "$got" $'row 2\nrow 3'

echo "briefs"
printf 'Do X.\nThen Y.' >"$work/body"
out=$(bash "$here/brief.sh" demo "$work/body" 2>/dev/null)
check "brief.sh writes task-NAME.src in the state folder" "$out" "$FLEET_STATE/task-demo.src"
check "the body, a blank line, then the shared rules word for word" \
  "$(head -3 "$out" | tr '\n' '|')$(tail -n +4 "$out" | cmp -s - "$here/brief-tail.md" && echo same)" "Do X.|Then Y.||same"
check "the tail carries the one-change experiment line (#157)" "$(grep -c '^Subagent use (experiment klepsydra#157' "$out")" "1"
bash "$here/brief.sh" demo "$work/body" >/dev/null 2>&1
check "a brief it replaces is archived" "$(find "$FLEET_STATE/archive/briefs" -name 'task-demo.*.src' | wc -l)" "1"
check "a body that already has the rules is refused" "$(bash "$here/brief.sh" demo "$out" >/dev/null 2>&1; echo $?)" "2"
check "a name that is not a plain slug is refused" "$(bash "$here/brief.sh" '../x' "$work/body" >/dev/null 2>&1; echo $?)" "2"
check "--check passes a current brief" "$(bash "$here/brief.sh" --check "$out" 2>/dev/null; echo $?)" "0"
sed 's/^Usage cap: run at most two/Usage cap: run at most three/' "$out" >"$FLEET_STATE/task-old.src"
check "--check names a brief whose shared rules drifted" "$(bash "$here/brief.sh" --check "$FLEET_STATE/task-old.src" "$out" 2>/dev/null)" "stale: task-old.src"
printf 'Last item (AJ 10-28): ship the thing.\n' >>"$FLEET_STATE/task-old.src"
bash "$here/brief.sh" --refresh "$FLEET_STATE/task-old.src" >/dev/null 2>&1
check "--refresh brings the rules up to date, keeping the body and a line added after them" \
  "$(head -2 "$FLEET_STATE/task-old.src" | tr '\n' '|')$(grep -c '^Usage cap: run at most two' "$FLEET_STATE/task-old.src") $(grep -c 'at most three' "$FLEET_STATE/task-old.src") $(grep -c '^Last item (AJ 10-28): ship the thing.$' "$FLEET_STATE/task-old.src") $(bash "$here/brief.sh" --check "$FLEET_STATE/task-old.src" >/dev/null 2>&1; echo $?)" \
  "Do X.|Then Y.|1 0 1 0"
# #262: a rule without a colon, or under a label the tail has since renamed, is
# still an old rule. A throwaway repo holds an old tail and the current one, so
# the history is there however shallow this checkout is.
hist=$work/briefhist
mkdir -p "$hist/fleet"
cp "$here/brief.sh" "$here/lib.sh" "$hist/fleet/"
git -C "$hist" init -q && git -C "$hist" config user.email t@t && git -C "$hist" config user.name t
{ printf 'Resources: old wording.\n'; printf 'Keep AJ'"'"'s to-do list current: the old label.\n'; printf 'Engage full auto mode (memory x). Stop when done.\n'; } >"$hist/fleet/brief-tail.md"
git -C "$hist" add fleet && git -C "$hist" commit -qm old
{ printf 'Resources: new wording.\n'; printf 'Keep the fleet queue current: the new label.\n'; printf 'Engage full auto mode (memory x). Stop when done.\n'; } >"$hist/fleet/brief-tail.md"
git -C "$hist" commit -qam new
{ printf 'Do Z.\n\n'
  printf 'Resources: old wording.\n'; printf 'Keep AJ'"'"'s to-do list current: the old label.\n'
  printf 'Engage full auto mode (memory x). Stop when done.\n'; printf 'Also (AJ 10-28): a real added line.\n'
  printf 'Engage full auto mode (memory x). Stop when done.\n'; printf 'Engage full auto mode (memory x). Stop when done.\n'
} >"$FLEET_STATE/task-hist.src"
bash "$hist/fleet/brief.sh" --refresh "$FLEET_STATE/task-hist.src" >/dev/null 2>&1
check "#262: a colon-less rule is kept once, a renamed label's old line goes, an added line stays" \
  "$(grep -c '^Engage full auto' "$FLEET_STATE/task-hist.src") $(grep -c "^Keep AJ's to-do" "$FLEET_STATE/task-hist.src") $(grep -c '^Keep the fleet queue current' "$FLEET_STATE/task-hist.src") $(grep -c '^Also (AJ 10-28): a real added line.$' "$FLEET_STATE/task-hist.src")" "1 0 1 1"
check "#262: the refreshed brief is the body, the tail, then the added line" \
  "$(tr '\n' '|' <"$FLEET_STATE/task-hist.src")" "Do Z.||Resources: new wording.|Keep the fleet queue current: the new label.|Engage full auto mode (memory x). Stop when done.|Also (AJ 10-28): a real added line.|"
cp "$FLEET_STATE/task-hist.src" "$work/hist.once"
bash "$hist/fleet/brief.sh" --refresh "$FLEET_STATE/task-hist.src" >/dev/null 2>&1
check "#262: a second refresh leaves it byte for byte" "$(cmp -s "$work/hist.once" "$FLEET_STATE/task-hist.src" && echo same)" "same"
printf 'Engage full auto mode (memory x). Stop when done.\n' >>"$FLEET_STATE/task-hist.src"
check "#262: --check names a brief that has every rule but carries one twice" \
  "$(bash "$hist/fleet/brief.sh" --check "$FLEET_STATE/task-hist.src" 2>/dev/null; echo "rc=$?")" $'stale: task-hist.src\nrc=1'
bash "$hist/fleet/brief.sh" --refresh "$FLEET_STATE/task-hist.src" >/dev/null 2>&1
check "#262: and --refresh drops the second copy" "$(cmp -s "$work/hist.once" "$FLEET_STATE/task-hist.src" && echo same)" "same"
# #275 review: with the tail missing or empty, old rules still come from the
# history, so a refresh would strip every rule: every mode refuses instead.
printf 'Usage cap: stale.\n' >>"$FLEET_STATE/task-hist.src"
cp "$FLEET_STATE/task-hist.src" "$work/hist.stale"
: >"$hist/fleet/brief-tail.md"
check "#275: an empty tail: --refresh refuses (2) and the brief is left as it was" \
  "$(bash "$hist/fleet/brief.sh" --refresh "$FLEET_STATE/task-hist.src" >/dev/null 2>&1; echo $?) $(cmp -s "$work/hist.stale" "$FLEET_STATE/task-hist.src" && echo same)" "2 same"
rm -f -- "$hist/fleet/brief-tail.md"
check "#275: a missing tail: --refresh, --check and a new brief all refuse" \
  "$(for a in --refresh --check; do bash "$hist/fleet/brief.sh" "$a" "$FLEET_STATE/task-hist.src" >/dev/null 2>&1; printf '%s ' $?; done; bash "$hist/fleet/brief.sh" demo2 "$work/body" >/dev/null 2>&1; echo $?) $(cmp -s "$work/hist.stale" "$FLEET_STATE/task-hist.src" && echo same) $([[ -e $FLEET_STATE/task-demo2.src ]] && echo written)" "2 2 2 same "
# #275 review: an unreadable brief is never rebuilt as the tail alone.
git -C "$hist" checkout -q -- fleet/brief-tail.md
cp "$work/hist.stale" "$FLEET_STATE/task-hist.src"; chmod 000 "$FLEET_STATE/task-hist.src"
if [[ -r $FLEET_STATE/task-hist.src ]]; then
  check "#275: an unreadable brief (skipped: running as root)" "skip" "skip"
else
  check "#275: an unreadable brief is left as it was and the refresh exits 1" \
    "$(bash "$hist/fleet/brief.sh" --refresh "$FLEET_STATE/task-hist.src" >/dev/null 2>&1; echo $?) $(chmod 600 "$FLEET_STATE/task-hist.src"; cmp -s "$work/hist.stale" "$FLEET_STATE/task-hist.src" && echo same)" "1 same"
fi
chmod 600 "$FLEET_STATE/task-hist.src"
# Each guard alone: a stale, readable brief whose archive folder, or own folder, is read-only.
printf 'Do Z.\n\nResources: old wording.\n' >"$work/hist.old"
if [[ $(id -u) != 0 ]]; then
  cp "$work/hist.old" "$FLEET_STATE/task-hist.src"
  mkdir -p "$FLEET_STATE/archive/briefs"; chmod 555 "$FLEET_STATE/archive/briefs"
  check "#275: no archive copy, no rewrite: the brief stays and the refresh exits 1" \
    "$(bash "$hist/fleet/brief.sh" --refresh "$FLEET_STATE/task-hist.src" >/dev/null 2>&1; echo $?) $(cmp -s "$work/hist.old" "$FLEET_STATE/task-hist.src" && echo same) $(find "$FLEET_STATE" -maxdepth 1 -name 'task-hist.src.*' | wc -l)" "1 same 0"
  printf 'old brief\n' >"$FLEET_STATE/task-demo3.src"
  check "#275 review 4: a new brief over one it cannot archive is refused and the old one stays" \
    "$(bash "$hist/fleet/brief.sh" demo3 "$work/body" >/dev/null 2>&1; echo $?) $(cat "$FLEET_STATE/task-demo3.src")" "1 old brief"
  chmod 755 "$FLEET_STATE/archive/briefs"
  rm -f -- "$FLEET_STATE/task-demo3.src"
  # Its archive folder stays writable, so only the temp-file guard can stop it.
  mkdir -p "$work/rostate/archive/briefs"; printf 'old brief\n' >"$work/rostate/task-demo4.src"; chmod 555 "$work/rostate"
  check "#275 review 5: a new brief with no room for its temp file is refused, archives nothing, and the old one stays" \
    "$(FLEET_STATE=$work/rostate bash "$hist/fleet/brief.sh" demo4 "$work/body" >/dev/null 2>&1; echo $?) $(cat "$work/rostate/task-demo4.src") $(find "$work/rostate/archive/briefs" -type f | wc -l)" "1 old brief 0"
  chmod 755 "$work/rostate"
  mkdir -p "$work/ro"; cp "$work/hist.old" "$work/ro/task-ro.src"; chmod 555 "$work/ro"
  check "#275: no temp file beside it: the brief stays, nothing is archived, and the refresh exits 1" \
    "$(n=$(find "$FLEET_STATE/archive/briefs" -name 'task-ro.src.*' | wc -l); bash "$hist/fleet/brief.sh" --refresh "$work/ro/task-ro.src" >/dev/null 2>&1; echo "$? $n $(find "$FLEET_STATE/archive/briefs" -name 'task-ro.src.*' | wc -l)") $(cmp -s "$work/hist.old" "$work/ro/task-ro.src" && echo same)" "1 0 0 same"
  chmod 755 "$work/ro"
fi
rm -rf -- "${hist:?}" "${FLEET_STATE:?}/task-hist.src"
check "the tail carries the friction-log rule (AJ 11-01)" "$(grep -c '^Friction log (AJ 11-01, every agent): read ~/.local/state/fleet-orchestrator/friction.md' "$here/brief-tail.md")" "1"
check "the tail puts performance first, above the security floor, and asks for DS&A checks (AJ 11-01, 11-03)" "$(grep -c '^Quality (AJ 11-01, 11-03): performance is AJ.s #1 quality attribute; when it trades off with security, performance wins, above the security floor. In every workflow, check the data structures and algorithms' "$here/brief-tail.md")" "1"
check "the tail carries the team-ceremony rule (AJ 10-29)" "$(grep -c '^Team ceremony in every repo' "$here/brief-tail.md")" "1"
check "the tail keeps asks for AJ out of public issues and PRs (AJ 10-29)" "$(grep -c '^Asks for AJ stay private' "$here/brief-tail.md")" "1"
check "#325 review 1: the tail sends messages to panes through fleet send (#320)" "$(grep -c '^Messages to another pane .*fleet send PANE -' "$here/brief-tail.md")" "1"
check "#239: the tail has heavy commands take the lock with flock -o, so nothing they leave running keeps it" "$(grep -c 'flock -o /tmp/fleet-heavy.lock' "$here/brief-tail.md")" "1"
check "#291 review: the tail says the make targets take the lock themselves and run bare" "$(grep -c 'make test-fleet., .make test-launch., .make test-delegate., .make test-heavy-lock., .make test-slice. and .make shellcheck. in klepsydra take the lock themselves: run them bare' "$here/brief-tail.md")" "1"
check "#291 review 5: the tail's hand form puts a group-wide timeout inside the lock (no --foreground)" "$(grep -c 'flock -o /tmp/fleet-heavy.lock timeout 1800 <command>' "$here/brief-tail.md") $(grep -c -- '--foreground' "$here/brief-tail.md")" "1 0"
# Every target whose recipe runs $(HEAVY) (#291 review 4): it takes the lock
# unless the caller says it holds it, a test target runs a file that exists,
# and the brief tail, the skill context and CI each name it.
heavy_targets=$(awk '/^[A-Za-z][A-Za-z0-9_-]*:/ { t = $1; sub(/:.*/, "", t) } /^\t@?\$\(HEAVY\)/ { print t }' "$here/../Makefile" | paste -sd ' ' -)
check "#291 review 4: the Makefile's heavy targets" "$heavy_targets" "test-fleet test-launch test-delegate test-heavy-lock test-slice shellcheck"
# What each runs, exactly (review 5: "a file that exists" passed a swapped suite).
declare -A heavy_runs=([test-fleet]="bash fleet/test_fleet.sh" [test-launch]="bash hooks/test_launch.sh" [test-delegate]="bash fleet/test_delegate.sh"
  [test-heavy-lock]="bash fleet/test_heavy_lock.sh" [test-slice]="bash fleet/test_slice.sh" [shellcheck]="sc -x hooks/*.sh statusline/*.sh scripts/*.sh fleet/*.sh fleet/fleet")
for ht in $heavy_targets; do
  check "#291 review 4: make $ht takes the lock unless held, runs its own suite, and the tail, skill context and CI name it" \
    "$(make -s -n -C "$here/.." "$ht" FLEET_HEAVY_HELD= SHELLCHECK=sc | grep -cxF "FLEET_HEAVY_HELD=1 bash fleet/heavy.sh ${heavy_runs[$ht]:-?}") $(make -s -n -C "$here/.." "$ht" FLEET_HEAVY_HELD=0 | grep -c 'fleet/heavy.sh') | $(make -s -n -C "$here/.." "$ht" FLEET_HEAVY_HELD=1 SHELLCHECK=sc) | $(grep -c "make $ht" "$here/brief-tail.md") $(grep -c "make $ht" "$here/../.claude/skill-context.md" | sed 's/^[1-9][0-9]*$/1/') $(grep -c "make $ht .*FLEET_HEAVY_HELD=1" "$here/../.github/workflows/ci.yml")" \
    "1 1 | ${heavy_runs[$ht]:-?} | 1 1 1"
done
# Any doc, anywhere on a line: a heavy suite or the tree's shellcheck run by
# hand, or the heavy lock taken without -o (#291 reviews 2 to 4). Plans are
# history, so they are left out. A sweep with no docs to read says so.
bare_re="((^|[ \`(;&|])(ba)?sh( +-[a-z]+)* +|(^|[ \`(;&|])[.]/)((([^ \`]*/)?fleet/)?test_fleet|([^ \`]*/)?(fleet/)?test_heavy_lock|([^ \`]*/)?test_launch)[.]sh|shellcheck( +-[-A-Za-z=]+)* +[^ \`]*(hooks|fleet|statusline|scripts)/[^ \`]*[*]"
docs_bare() { # repo
  local docs
  docs=$(git -C "$1" ls-files -- '*.md' ':!docs/superpowers/plans/' 2>/dev/null)
  [[ -n $docs ]] || { echo "no docs to sweep in $1"; return; }
  (
    cd "$1" || exit
    git ls-files -z -- '*.md' ':!docs/superpowers/plans/' | xargs -0 grep -nE "$bare_re"
    # Each flock on the lock, not each line: a line may hold a good form and a bad one.
    git ls-files -z -- '*.md' ':!docs/superpowers/plans/' | xargs -0 grep -noE 'flock( +-[^ `]+( +[0-9.]+)?)* +/tmp/fleet-heavy[.]lock' | grep -vE ':flock( +[^ ]+)* +-o( |$)'
  ) | sort -u
}
check "#291 review 3: no doc runs a heavy suite or the tree's shellcheck by hand; the make targets do" \
  "$(docs_bare "$here/.." | wc -l) $(grep -c "make shellcheck" "$here/../AGENTS.md") $(grep -c "make test-fleet" "$here/../.claude/skill-context.md") $(grep -c "make test-launch" "$here/../AGENTS.md" "$here/../.claude/skill-context.md" "$here/../README.md" | grep -c ':[1-9]')" "0 1 2 3"
# The sweep itself, on a scratch repo: each bare form found, plans and the
# allowed forms left alone, and a repo with no docs is a failure, not a pass.
sw=$work/sweep291
mkdir -p "$sw/docs/superpowers/plans"
git -C "$sw" init -q
# shellcheck disable=SC2016 # the backticks are the doc's, not a command
printf '%s\n' 'Run `bash hooks/test_launch.sh` first.' 'then (shellcheck -x fleet/*.sh).' 'Or: flock /tmp/fleet-heavy.lock make x' './fleet/test_fleet.sh' \
  'cd fleet && bash test_fleet.sh' 'bash -x fleet/test_fleet.sh' 'sh hooks/test_launch.sh' 'shellcheck --external-sources hooks/*.sh' \
  'flock -w 60 /tmp/fleet-heavy.lock make y' 'flock -w 0.5 /tmp/fleet-heavy.lock make w' 'Good: `flock -o /tmp/fleet-heavy.lock x`, bad: flock /tmp/fleet-heavy.lock y' 'bash fleet/test_heavy_lock.sh' >"$sw/bare.md"
# shellcheck disable=SC2016
printf '%s\n' 'Run `make test-fleet` bare; the hook suite runs bare too: `bash hooks/test_fleet.sh`.' 'One file: `uvx --from shellcheck-py shellcheck -x fleet/lib.sh`.' 'See [the suite](../fleet/test_fleet.sh); `fleet/test_fleet.sh` takes 19 min.' \
  'Hand form: `flock -o /tmp/fleet-heavy.lock timeout 1800 <command>`, or flock -w 60 -o /tmp/fleet-heavy.lock z.' >"$sw/ok.md"
printf '%s\n' 'bash fleet/test_fleet.sh' >"$sw/docs/superpowers/plans/old.md"
git -C "$sw" add -A
check "#291 review 4: the sweep finds each of 12 bare forms, only in bare.md" \
  "$(docs_bare "$sw" | wc -l) $(docs_bare "$sw" | grep -vc '^bare[.]md:')" "12 0"
check "#291 review 4: a sweep with no docs to read fails" "$(docs_bare "$work/sweep291-none" | wc -l) $(docs_bare "$work/sweep291-none" | grep -c 'no docs to sweep')" "1 1"

echo "doctor"
mkdir -p "$KLEPSYDRA_DIR/fleet" "$work/bin"
cat >"$work/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
# DOC_SCOPES (#289, #353): one "UNIT TASKS_CURRENT TASKS_MAX [SLICE]" line per
# fleet scope (no slice: the workers'; gone: ended since list-units); DOC_SLICES: "UNIT MEMORY_MAX [PARENT]" per slice.
# DOC_SHOW_FAILS: show answers nothing (a user manager that does not answer).
# show prints one block per unit asked for, as systemctl does, with Id last.
case $* in
  *list-units*) [[ -n ${DOC_SCOPES:-} ]] && awk '{ print $1 " loaded active running x" }' "$DOC_SCOPES"; exit 0 ;;
  *" show "*)
    [[ -n ${DOC_SHOW_FAILS:-} ]] && exit 1
    first=1
    for u; do
      [[ $u == *.scope || $u == *.slice ]] || continue
      (( first )) || echo
      first=0
      [[ -n ${DOC_SCOPES:-} ]] && awk -v u="$u" '$1 == u { print "TasksCurrent=" $2; print "TasksMax=" $3; g = ($4 == "gone"); print "Slice=" (g ? "" : $4 == "" ? "fleet-workers.slice" : $4); print "MemoryMax=infinity"; print "ActiveState=" (g ? "inactive" : "active") }' "$DOC_SCOPES"
      if [[ $u == *.slice ]]; then
        m=$( [[ -n ${DOC_SLICES:-} ]] && awk -v u="$u" '$1 == u { print $2 }' "$DOC_SLICES")
        printf 'MemoryMax=%s\n' "${m:-infinity}"
        par=$( [[ -n ${DOC_SLICES:-} ]] && awk -v u="$u" '$1 == u { print $3 }' "$DOC_SLICES")
        [[ -z $par && $u == fleet-workers.slice ]] && par=fleet.slice
        printf 'Slice=%s\n' "${par:-user.slice}"
      fi
      echo "Id=$u"
    done
    exit 0 ;;
esac
[[ $* == *is-active* && -e $DOC_ACTIVE ]]
EOF
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
# The phone wall: answers with $DOC_FLEET for the URL named in $DOC_UP.
for a; do url=$a; done
# DOC_FLAKY: a file whose presence fails one call, as Windows interop now and then does.
[[ -n ${DOC_FLAKY:-} && -e $DOC_FLAKY ]] && { rm -f -- "$DOC_FLAKY"; exit 7; }
[[ -n ${DOC_UP:-} && $url == "$DOC_UP"* ]] || exit 7
cat "$DOC_FLEET"
EOF
cat >"$work/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
case $1 in
  status) echo '{"Self":{"DNSName":"desk.tail1.ts.net."}}' ;;
  serve) echo "${DOC_SERVE:-No serve config}" ;;
esac
EOF
cat >"$work/bin/ps" <<'PS'
#!/usr/bin/env bash
# The host's processes: a watcher when $DOC_WATCH names its panes.
echo "/usr/bin/bash -c echo watch-panes.sh %1"
[[ -n ${DOC_WATCH:-} ]] && echo "/usr/bin/bash /state/watch-panes.sh $DOC_WATCH"
exit 0
PS
chmod +x "$work/bin/"*
rm -f "$FLEET_STATE/resume.beat"
login a
# The section's sessions are alive by recover's test (this boot, the same process).
mkdir -p "$work/dproc/4242"; printf '4242 (claude) S %s 777 1 2 3\n' "$(seq -s ' ' 1 18)" >"$work/dproc/4242/stat"
echo 44444444-4444-4444-8444-444444444444 >"$work/dboot"
# The phone wall is on in these cases unless DOC_PREFS names other contents (#328):
# the wrappers write the shipped path, $KLEPSYDRA_DIR/prefs.json, and remove it
# after, so later sections see no file. DOC_PREFS=none: no file.
doc_prefs() { local c=${DOC_PREFS-'{"phone_wall": true}'}; rm -f -- "$KLEPSYDRA_DIR/prefs.json"; [[ $c == none ]] || printf '%s' "$c" >"$KLEPSYDRA_DIR/prefs.json"; }
doctor() { local rc; doc_prefs; FLEET_PS="$work/bin/ps" FLEET_SYSTEMCTL="$work/bin/systemctl" FLEET_CURL="$work/bin/curl" FLEET_TAILSCALE="$work/bin/tailscale" \
  DOC_ACTIVE="$work/active" DOC_FLEET="$work/fleet.json" FLEET_RETRY_S=0 FLEET_PROC="$work/dproc" FLEET_BOOT_ID="$work/dboot" FLEET_UNITS="$work/dunits" bash "$here/doctor.sh" 2>/dev/null; rc=$?
  rm -f -- "$KLEPSYDRA_DIR/prefs.json"; return $rc; }
phone_lines() { grep -E '^(ok|warn|FAIL) +phone wall' | cut -d: -f1 | paste -sd'|'; }
sid_of() { case $1 in w1) echo dddddddd-0000-4000-8000-000000000001 ;; w2) echo dddddddd-0000-4000-8000-000000000002 ;; *) echo dddddddd-0000-4000-8000-0000000000"${1#o}"0 ;; esac; }
w=$(pane wpane '{"above":["idle"]}'); o=$(pane opane '{"above":["idle"]}'); settle
printf '%s\tworker\t%s\t%s\n' "$w" "$FLEET_STATE/task-demo.src" "$(sid_of w1)" >"$REGISTRY"
printf '%s\n' "$o" >"$FLEET_STATE/orchestrator.pane"
session_file() { # ID PANE [URL]
  jq -n --arg p "$2" --arg u "${3:-}" '{session_id: "x", started_at: 5, ended: null, claude: {pid: 4242, start: 777}, host: {boot: "44444444-4444-4444-8444-444444444444"}, tmux: {pane: $p}} + (if $u == "" then {} else {remote_url: $u} end)' \
    >"$KLEPSYDRA_DIR/fleet/$(sid_of "$1").json"
}
session_file w1 "$w" https://claude.ai/code/session_01W; session_file o1 "$o"
jq -n --argjson at "$(( $(date +%s) - 30 ))" '{usage: [{observed_at: $at}]}' >"$work/fleet.json"
out=$(doctor); code=$?
check "a stopped resume service fails" "$(grep -c '^FAIL resume service' <<<"$out")" "1"
check "a resume loop that never ran fails" "$(grep '^FAIL resume loop' <<<"$out")" "FAIL resume loop: no pass recorded"
check "a worker with Remote Control is ok" "$(grep -c "^ok   remote control $w (worker)" <<<"$out")" "1"
check "the orchestrator without it fails (Heph's must always be on)" "$(grep -c "^FAIL remote control $o (orchestrator): off" <<<"$out")" "1"
check "no phone wall fails, after a second try" "$(grep -c '^FAIL phone wall: no answer from http://127.0.0.1:8318/fleet.json (tried twice)' <<<"$out")" "1"
check "#328 review 1: with the wall on and down, both phone lines fail" "$(phone_lines <<<"$out")" "FAIL phone wall|FAIL phone wall over Tailscale"
# Each is off as the wall reads it (serde's as_bool: only the boolean true is on).
for pw in '{"phone_wall": false}' '{"phone_wall": "true"}' '{"phone_wall": 1}' '{"phone_wall": "yes"}' '{}' none; do
  check "#328: prefs.json $pw (the wall's own reading: off): ok, and neither phone line is tried" \
    "$(DOC_PREFS=$pw doctor | phone_lines)" "ok   phone wall"
done
# A file that is not one JSON object is off for the wall too, but says so.
for pw in '{phone' '{"phone_wall": true} garbage' '{"phone_wall": true}{}' '[true]' 'null'; do
  check "#328 review 1: prefs.json $pw does not read: a warning, and neither phone line is tried" \
    "$(DOC_PREFS=$pw doctor | phone_lines)" "warn phone wall"
done
check "#289: with no fleet scope there is no task caps line" "$(grep -c 'task caps' <<<"$out")" "0"
printf 'fleet-a-1.scope 7000 8745\nfleet-b-2.scope 100 8745\nnot-fleet.scope 9 10\n' >"$work/scopes"
check "#289: a scope past 80% of its task cap warns, naming it" "$(DOC_SCOPES="$work/scopes" doctor | grep 'task caps')" \
  "warn task caps: past 80% of the cap: fleet-a-1 7000/8745 (its next forks fail at the cap)"
printf 'fleet-a-1.scope 6900 8745\nfleet-b-2.scope 100 8745\nfleet-c-3.scope 50 infinity\n' >"$work/scopes"
check "#289: under the line: ok, the fullest named, and a scope from before the cap listed" "$(DOC_SCOPES="$work/scopes" doctor | grep 'task caps')" \
  "ok   task caps: fullest scope: fleet-a-1 6900/8745; no task cap: fleet-c-3"
check "#353: slices with no cap fail, both named" "$(grep 'memory cap' <<<"$out")" \
  "FAIL memory cap: no MemoryMax on fleet.slice fleet-workers.slice (fleet install writes it)"
printf 'fleet.slice 8820621312\nfleet-workers.slice 7970226176\n' >"$work/slices"
printf 'fleet-a-1.scope 6900 8745\nfleet-b-2.scope 100 8745 fleet-workers.slice\n' >"$work/scopes"
check "#353: both capped, every scope in its slice: ok, with the sizes" "$(DOC_SLICES="$work/slices" DOC_SCOPES="$work/scopes" doctor | grep 'memory cap')" \
  "ok   memory cap: fleet.slice 8412 MiB, fleet-workers.slice 7601 MiB"
printf 'fleet-a-1.scope 6900 8745 app.slice\nfleet-b-2.scope 100 8745\nfleet-c-3.scope 1 8745 fleet.slice\n' >"$work/scopes"
check "#353: a scope started before the slices, or a worker's beside the workers' cap, fails, named" \
  "$(DOC_SLICES="$work/slices" DOC_SCOPES="$work/scopes" doctor | grep 'memory cap')" \
  "FAIL memory cap: outside their slice: fleet-a-1 in app.slice, fleet-c-3 in fleet.slice"
printf 'fleet-a-1.scope 6900 8745 gone\nfleet-b-2.scope 100 8745\n' >"$work/scopes"
check "#353: a scope that ended between the listing and the read is not called astray" \
  "$(DOC_SLICES="$work/slices" DOC_SCOPES="$work/scopes" doctor | grep 'memory cap')" \
  "ok   memory cap: fleet.slice 8412 MiB, fleet-workers.slice 7601 MiB"
# The orchestrator's claude (pid 4242 in the section's /proc) in its scope.
printf '0::/user.slice/user-1.slice/user@1.service/fleet.slice/fleet-heph-9.scope\n' >"$work/dproc/4242/cgroup"
printf 'fleet-heph-9.scope 10 8745 fleet.slice\nfleet-b-2.scope 100 8745\n' >"$work/scopes"
check "#353: the orchestrator's scope belongs in the fleet's slice" "$(DOC_SLICES="$work/slices" DOC_SCOPES="$work/scopes" doctor | grep -c '^ok   memory cap')" "1"
printf 'fleet-heph-9.scope 10 8745 fleet-workers.slice\n' >"$work/scopes"
check "#353: and fails in the workers'" "$(DOC_SLICES="$work/slices" DOC_SCOPES="$work/scopes" doctor | grep 'memory cap')" \
  "FAIL memory cap: outside their slice: fleet-heph-9 in fleet-workers.slice"
printf '900\n' >"$FLEET_STATE/orchestrator.mem"
check "#353: an orchestrator's peak past the room the workers' slice leaves it warns" "$(DOC_SLICES="$work/slices" doctor | grep 'memory cap')" \
  "warn memory cap: the orchestrator's peak, 900 MiB, passed the 811 MiB fleet-workers.slice leaves it: fleet install resizes the slices"
rm -f "$FLEET_STATE/orchestrator.mem" "$work/dproc/4242/cgroup"
# With no pid on record (a restart), the orchestrator's scope is the one named for it.
printf 'fleet-heph-9.scope 10 8745 fleet.slice\nfleet-b-2.scope 100 8745\n' >"$work/scopes"
check "#353 review: no orchestrator pid: its named scope in the fleet's slice is ok" "$(DOC_SLICES="$work/slices" DOC_SCOPES="$work/scopes" doctor | grep -c '^ok   memory cap')" "1"
printf 'fleet-heph-9.scope 10 8745 fleet-workers.slice\n' >"$work/scopes"
check "#353 review: and in the workers' it fails" "$(DOC_SLICES="$work/slices" DOC_SCOPES="$work/scopes" doctor | grep 'memory cap')" \
  "FAIL memory cap: outside their slice: fleet-heph-9 in fleet-workers.slice"
printf 'fleet.slice 8820621312\nfleet-workers.slice 7970226176 user.slice\n' >"$work/slices2"
check "#353 review: a workers' slice outside the fleet's fails (its workers escape the total)" "$(DOC_SLICES="$work/slices2" doctor | grep 'memory cap')" \
  "FAIL memory cap: fleet-workers.slice sits in user.slice, not fleet.slice (fleet install writes both)"
printf 'fleet.slice 7970226176\nfleet-workers.slice 7970226176\n' >"$work/slices2"
check "#353 review: a workers' cap not below the fleet's fails (the orchestrator has no room)" "$(DOC_SLICES="$work/slices2" doctor | grep 'memory cap')" \
  "FAIL memory cap: fleet-workers.slice's 7601 MiB is not below fleet.slice's 7601 MiB (fleet install writes both)"
printf 'fleet.slice 0\nfleet-workers.slice 1048575\n' >"$work/slices2"
check "#353 review: a cap of 0, or under 1 MiB, reads as none" "$(DOC_SLICES="$work/slices2" doctor | grep 'memory cap')" \
  "FAIL memory cap: no MemoryMax on fleet.slice fleet-workers.slice (fleet install writes it)"
# A move: the new orchestrator's scope starts before orchestrator.pane names its pane.
printf '0::/user.slice/user-1.slice/user@1.service/fleet.slice/fleet-heph-9.scope\n' >"$work/dproc/4242/cgroup"
printf 'fleet-heph-9.scope 10 8745 fleet.slice\nfleet-heph-12.scope 10 8745 fleet.slice\n' >"$work/scopes"
check "#353 review 2: during a move both orchestrator scopes belong in the fleet's slice" "$(DOC_SLICES="$work/slices" DOC_SCOPES="$work/scopes" doctor | grep -c '^ok   memory cap')" "1"
# A stale orchestrator.pane naming a worker's pane: its scope stays a worker's.
printf '0::/user.slice/user-1.slice/user@1.service/fleet.slice/fleet-workers.slice/fleet-w-5.scope\n' >"$work/dproc/4242/cgroup"
printf 'fleet-w-5.scope 10 8745\nfleet-heph-12.scope 10 8745 fleet.slice\n' >"$work/scopes"
check "#353 review 3: a worker's scope that a stale orchestrator.pane names is still a worker's" "$(DOC_SLICES="$work/slices" DOC_SCOPES="$work/scopes" doctor | grep -c '^ok   memory cap')" "1"
rm -f "$work/dproc/4242/cgroup"
# Scopes whose names date them before the slices' units were first written warn; one since fails.
mkdir -p "$work/dunits"; printf 'old\n' >"$work/dunits/fleet.slice"
born=$(stat -c %W "$work/dunits/fleet.slice"); [[ $born =~ ^[1-9][0-9]*$ ]] || born=$(stat -c %Y "$work/dunits/fleet.slice")
printf 'fleet-a-%s.scope 1 8745 app.slice\nfleet-b-%s.scope 1 8745\n' "$((born - 1))" "$((born + 1))" >"$work/scopes"
check "#353 review 2: a scope started before the slices, outside them, warns (it moves at its next fresh start)" \
  "$(DOC_SLICES="$work/slices" DOC_SCOPES="$work/scopes" doctor | grep 'memory cap')" \
  "warn memory cap: started before the slices, outside them: fleet-a-$((born - 1)) in app.slice (each moves at its next fresh start)"
printf 'fleet-a-%s.scope 1 8745 app.slice\n' "$((born + 1))" >"$work/scopes"
check "#353 review 2: one started since fails" "$(DOC_SLICES="$work/slices" DOC_SCOPES="$work/scopes" doctor | grep 'memory cap')" \
  "FAIL memory cap: outside their slice: fleet-a-$((born + 1)) in app.slice"
# A resize rewrites the unit in place (install's unit()): the slices keep their first date.
if [[ $(stat -c %W "$work/dunits/fleet.slice") =~ ^[1-9][0-9]*$ ]]; then
  printf 'resized\n' >"$work/dunits/fleet.slice"; touch -d "@$((born + 100))" "$work/dunits/fleet.slice"
  check "#353 review 5: after a resize, a scope astray since the first install still fails" "$(DOC_SLICES="$work/slices" DOC_SCOPES="$work/scopes" doctor | grep 'memory cap')" \
    "FAIL memory cap: outside their slice: fleet-a-$((born + 1)) in app.slice"
else
  echo "  skip #353 review 5: this filesystem keeps no birth times"
fi
rm -rf -- "${work:?}/dunits"
# A MemTotal fixture as a file: doctor reads MemTotal more than once.
memfile() { printf 'MemTotal: %s kB\n' "$1" >"$work/meminfo-$1"; printf '%s' "$work/meminfo-$1"; }
check "#353 review 2: caps sized for another machine warn (the fixture's 9948 MiB gives 8412)" \
  "$(FLEET_MEMINFO=$(memfile 8388608) DOC_SLICES="$work/slices" doctor | grep 'memory cap')" \
  "warn memory cap: fleet.slice's 8412 MiB was sized for another MemTotal or earlyoom line; this machine's is 6656 MiB: fleet install resizes the slices"
check "#353 review 4: a memory= 300 MiB smaller warns (its old cap would let earlyoom act first)" \
  "$(FLEET_MEMINFO=$(memfile 9879552) DOC_SLICES="$work/slices" doctor | grep -c '^warn memory cap: fleet.slice.s 8412 MiB was sized')" "1"
check "#353 review 3: a kernel update's few MiB pass" \
  "$(FLEET_MEMINFO=$(memfile 10180000) DOC_SLICES="$work/slices" doctor | grep -c '^ok   memory cap')" "1"
check "#353 review 2: a systemctl that does not answer is said so, not called a missing cap" \
  "$(DOC_SLICES="$work/slices" DOC_SHOW_FAILS=1 doctor | grep 'memory cap')" \
  "warn memory cap: could not read the slices: systemctl --user did not answer"
check "no Tailscale Serve fails" "$(grep -c '^FAIL phone wall over Tailscale: Tailscale Serve is not set up' <<<"$out")" "1"
check "and the exit is non-zero" "$code" "1"
check "#244: hooks and cast never installed fail, named" "$(grep '^FAIL installed copies' <<<"$out" | grep -c 'make install-fleet: differ from .*: klepsydra-common.sh klepsydra-fleet.sh .*klepsydra-cast.json$')" "1"
root=${here%/fleet}
for c in "${HOOK_COPIES[@]}"; do mkdir -p "$(dirname "$FLEET_HOOK_DIR/${c#* }")"; cp "$root/${c%% *}" "$FLEET_HOOK_DIR/${c#* }"; done
touch "$work/active" "$FLEET_STATE/resume.beat"
session_file o1 "$o" https://claude.ai/code/session_01O
# The fleet's server carries the pane-died hook, as install sets it (#290).
t set-hook -g pane-died "run-shell ': klepsydra-pane-died.sh'"
# Readings 30 s old as of this run, however long the cases above took.
jq -n --argjson at "$(( $(date +%s) - 30 ))" '{usage: [{observed_at: $at}]}' >"$work/fleet.json"
# Both memory slices capped, as fleet install leaves them (#353).
export DOC_SLICES="$work/slices"
out=$(DOC_UP=http DOC_SERVE="https://desk.tail1.ts.net (tailnet only)" doctor); code=$?
# Which rows are not ok, not how many are: a new check that passes here breaks no case.
notok() { grep -v '^ok ' | cut -d: -f1 | paste -sd'|'; }
check "all well but the watcher: a shell that names the script is not one" "$(notok <<<"$out")" "warn account $work/cfg-b|FAIL pane watcher|warn voices"
check "the default account is logged in; the second, not yet, is a warning" \
  "$(grep '^ok   account' <<<"$out" | cut -d: -f1) | $(grep '^warn account' <<<"$out" | cut -d: -f1)" "ok   account $work/cfg-a | warn account $work/cfg-b"
check "with a watcher running, nothing fails and the exit is 0 (the second account and voices warn here)" \
  "$(DOC_WATCH='%2 %5' DOC_UP=http DOC_SERVE=on doctor | notok; echo "rc=${PIPESTATUS[0]}")" "warn account $work/cfg-b|warn voices"$'\nrc=0'
check "the watcher's panes are named" "$(DOC_WATCH='%2 %5' doctor | grep '^ok   pane watcher')" "ok   pane watcher: watching %2 %5"
t set-hook -gu pane-died
state wpane '{"above":["  ⎿  You'"'"'ve hit your 5-hour limit · resets 11:30am (America/New_York)","",""]}'
check "#263: a pane still at its limit well past the reset fails, named with its reset" \
  "$(FLEET_NOW=$noon doctor | grep '^FAIL limits')" "FAIL limits: still at a limit past its reset: $w (the resume service missed it)"
check "#263: one whose reset is near is not" "$(FLEET_NOW=$((noon - 2400)) doctor | grep -c '^ok   limits')" "1"
check "#265 review: still failing 7 h past the reset (time-only resets once rolled to tomorrow at 6 h)" \
  "$(FLEET_NOW=$((noon + 25200)) doctor | grep -c '^FAIL limits')" "1"
state wpane '{"above":["  ⎿  You'"'"'ve hit your 5-hour limit · resets 11:30am (America/New_York)","❯ The usage limit has reset. Please continue.","● Queue is empty"]}'
check "#265 review: a limit the resume service answered is not missed" "$(FLEET_NOW=$noon doctor | grep -c '^ok   limits')" "1"
state wpane '{"above":["  ⎿  You'"'"'ve hit your weekly limit · resets 8pm (America/New_York)","",""]}'
check "#265 review 2: a time-only weekly reset 10 h ahead is not read as yesterday's, so no false FAIL" "$(FLEET_NOW=$((noon - 7200)) doctor | grep -c '^ok   limits')" "1"
state wpane '{"above":["  ⎿  You'"'"'ve hit your 5-hour limit · resets 11pm (America/New_York)","",""]}'
check "#265 review 2: a 5-hour reset just before midnight, still shown after it, fails" "$(FLEET_NOW=$((noon + 46800)) doctor | grep -c '^FAIL limits')" "1"
state wpane '{"above":["  ⎿  Limit hit for this window · resets 11:30am","",""]}'
check "#263: a reset beside a limit wording the fleet does not know is a warning" \
  "$(doctor | grep '^warn limits')" "warn limits: a reset time shows beside a limit message the fleet does not recognise: $w (LIMIT_RE in fleet/lib.sh)"
for notice in "You've used 90% of your 5-hour limit · resets 3pm" "Approaching weekly limit · resets Nov 9, 1pm" \
  "Now using usage credits for Opus · Your Opus limit resets 3pm" "You've hit your fast limit · resets in 3m"; do
  state wpane "{\"above\":[\"  ⎿  $notice\",\"\",\"\"]}"
  check "#265 review 3: not a stop, so no unknown-wording warning: $notice" "$(doctor | grep -c '^ok   limits')" "1"
done
state wpane '{"above":["idle"]}'
# Recorded on the account the pane's folder holds (a): a stop on another one is
# dated by its own text (the /login case above).
# In the pane's own session file: a second live file naming the pane is no answer.
stop_file "$(sid_of w1)" "$w" "$noon" a "$L5"; win a 100 $((noon + 600))
check "#311: a pane the hook recorded at a limit, past its resets_at, fails though its screen shows none" \
  "$(FLEET_NOW=$((noon + 1300)) doctor | grep '^FAIL limits')" "FAIL limits: still at a limit past its reset: $w (the resume service missed it)"
check "#311: before then it is ok" "$(FLEET_NOW=$((noon + 900)) doctor | grep -c '^ok   limits')" "1"
check "#313 review 2: and with no watcher, the watcher check holds it limited too: a warning, no FAIL" \
  "$(FLEET_NOW=$((noon + 900)) doctor | grep -c '^warn pane watcher: none running while every agent waits out a usage limit')" "1"
check "#313 review 3: the warning gives the account's reset (12:10pm), not the stop's text (1:10pm)" \
  "$(FLEET_NOW=$((noon + 900)) doctor | grep -c '^warn pane watcher: none running while every agent waits out a usage limit (resets 12:10pm)')" "1"
stop_file "$(sid_of w1)" "$w" "$noon" a "API Error: Rate limit reached"; win a 30 $((noon + 600)) 100 $((noon + 3 * 86400))
check "#313 review 4: a reset days away names its day" \
  "$(FLEET_NOW=$((noon + 900)) doctor | grep -c '^warn pane watcher: none running while every agent waits out a usage limit (resets Sat 12:00pm)')" "1"
session_file w1 "$w" https://claude.ai/code/session_01W
rm -f -- "${KLEPSYDRA_DIR:?}/accounts/a/ev.json"
state wpane '{"above":["idle"]}'
printf 'panes=3 limited=1 limited_panes=%%9 at=5\n' >"$FLEET_STATE/resume.beat"
check "#263: the resume loop line says what its last pass saw" "$(doctor | grep '^ok   resume loop' | sed 's/.*: //')" "panes=3 limited=1 limited_panes=%9"
printf '# 10-29 copy\n' >>"$FLEET_HOOK_DIR/klepsydra-fleet.sh"
check "#244: a hook copy older than the checkout fails, and only it is named" \
  "$(doctor | grep '^FAIL installed copies')" "FAIL installed copies: make install-fleet: differ from $(tilde "$root"): klepsydra-fleet.sh"
cp "$root/hooks/klepsydra-fleet.sh" "$FLEET_HOOK_DIR/klepsydra-fleet.sh"
check "the phone wall and its Tailscale twin answer" "$(grep -c '^ok   phone wall.*: answers at ' <<<"$out")" "2"
check "#246: and the usage readings are fresh" "$(grep -c '^ok   usage readings: observed 3[0-9] s ago' <<<"$out")" "1"
: >"$work/flaky"
check "#246: a wall that misses once and then answers is ok" "$(DOC_FLAKY="$work/flaky" DOC_UP=http doctor | grep -c '^ok   phone wall: answers')" "1"
jq -n '{usage: [{observed_at: 1000, label: "RIT"}]}' >"$work/fleet.json"
: >"$FLEET_LOG"
out=$(DOC_UP=http doctor)
check "#246: old readings with no turn running are not a failure: the wall answers" \
  "$(grep -c '^ok   phone wall: answers' <<<"$out") $(grep '^ok   usage readings' <<<"$out" | grep -c 'no pane runs a turn')" "1 1"
state wpane '{"above":["⏺ working"],"busy":true}'
out=$(DOC_UP=http doctor)
check "#246: while a pane runs a turn, old readings are a warning naming it" "$(grep '^warn usage readings' <<<"$out" | grep -c "while $w runs a turn")" "1"
check "#246: logged with the values it was decided on" \
  "$(jq -r 'select(.message == "doctor: usage readings") | [.observed_at, .max_s, .account, .mid_turn] | join(" ")' "$FLEET_LOG" | tail -1)" "1000 120 RIT $w"
state wpane '{"above":["idle"]}'
jq -n '{usage: []}' >"$work/fleet.json"
check "#246: no readings at all are unknown, a warning" "$(DOC_UP=http doctor | grep -c '^warn usage readings: fleet.json holds none')" "1"
jq -n --argjson at "$(( $(date +%s) - 30 ))" '{usage: [{observed_at: $at}]}' >"$work/fleet.json"
state wpane '{"above":["  ⎿  You'"'"'ve hit your session limit · resets 1:10pm (America/New_York)","",""]}'
: >"$FLEET_LOG"
out=$(doctor)
check "#246: no watcher while every agent waits out a limit is a warning with the reset" \
  "$(grep '^warn pane watcher' <<<"$out")" "warn pane watcher: none running while every agent waits out a usage limit (resets 1:10pm): start one after the reset"
check "#246: logged with the limited panes and the reset" \
  "$(jq -r 'select(.message == "doctor: pane watcher") | [.limited, .resets] | join(" | ")' "$FLEET_LOG")" "$w | 1:10pm"
w2=$(pane wpane2 '{"above":["idle"]}'); settle
printf '%s\tworker2\t%s\t%s\n' "$w2" "$FLEET_STATE/task-demo.src" "$(sid_of w2)" >>"$REGISTRY"; session_file w2 "$w2" https://claude.ai/code/session_01X
check "#246: with one agent free, no watcher still fails" "$(doctor | grep -c '^FAIL pane watcher: none running')" "1"
t kill-window -t "$w2"; rm -f "$KLEPSYDRA_DIR/fleet/w2.json"
# A registry whose panes are all gone leaves nothing to watch (#348).
printf '%%998\tworker\t%s\tgone\n' "$FLEET_STATE/task-demo.src" >"$REGISTRY"
check "#348: no watcher and no live agent pane is ok, not a FAIL" \
  "$(doctor | grep '^[a-zA-Z]* *pane watcher')" "ok   pane watcher: no agents to watch"
: >"$REGISTRY"
check "#348: an empty registry is the same" "$(doctor | grep -c '^ok   pane watcher: no agents to watch')" "1"
printf '%s\tworker\t%s\t%s\n' "$w" "$FLEET_STATE/task-demo.src" "$(sid_of w1)" >"$REGISTRY"
state wpane '{"above":["idle"]}'
printf 'parked\tPAUSED 11-01 07:16: no room\n' >"$FLEET_STATE/paused.tsv"
check "#246: paused agents are listed, never a failure" "$(doctor | grep '^ok   paused agents')" "ok   paused agents: parked: fleet unpause NAME brings one back"
rm -f "$FLEET_STATE/paused.tsv"
jq -n '{usage: [{observed_at: 1000}]}' >"$work/fleet.json"
touch -d '@1000' "$FLEET_STATE/resume.beat"
check "a resume loop that stopped passing fails" "$(doctor | grep -c '^FAIL resume loop: last pass')" "1"
logout a
out=$(doctor)
check "a default account not logged in fails" "$(grep -c "^FAIL account $work/cfg-a: not logged in: claude auth login" <<<"$out")" "1"
djson() { doc_prefs; FLEET_PS="$work/bin/ps" FLEET_SYSTEMCTL="$work/bin/systemctl" FLEET_CURL="$work/bin/curl" FLEET_TAILSCALE="$work/bin/tailscale" \
  DOC_ACTIVE="$work/active" DOC_FLEET="$work/fleet.json" bash "$here/doctor.sh" --json "$work/health.json" >/dev/null 2>&1; echo $?; rm -f -- "$KLEPSYDRA_DIR/prefs.json"; }
: >"$FLEET_LOG"; rm -f "$work/health.json"
check "#208: --json writes each check with its status and detail, and exits as doctor does" \
  "$(djson) $(jq -r --arg a "account $work/cfg-a" '[.v, .failed, (.checks | length), (.checks[] | select(.check == $a) | .status)] | map(tostring) | join(" ")' "$work/health.json")" \
  "1 1 1 $(grep -c . <<<"$out") FAIL"
check "#208: and its time is now" "$(( $(date +%s) - $(jq .observed_at "$work/health.json") < 30 ))" "1"
fails=$(jq -c 'select(.level == "ERROR" and (.message | startswith("doctor: ")))' "$FLEET_LOG" | wc -l)
check "#208: the first --json run logs each failing check" "$(( fails > 0 ))" "1"
# The second folder's settings drift from the first's (accounts-sync --check).
mkdir -p "$work/cfg-b"; printf '{"x":1}\n' >"$work/cfg-a/settings.json"
djson >/dev/null
logged=$(jq -c 'select(.message | startswith("doctor"))' "$FLEET_LOG" | wc -l)
all=$(wc -l <"$FLEET_LOG")
djson >/dev/null
check "#208: a second run with nothing changed logs nothing more, the settings drift included" \
  "$(jq -c 'select(.message | startswith("doctor"))' "$FLEET_LOG" | wc -l) $(wc -l <"$FLEET_LOG") $(jq -r '[.checks[] | select(.check | startswith("settings ")) | .status] | join(",")' "$work/health.json")" "$logged $all FAIL"
login a
djson >/dev/null
check "#208: a check that recovers logs once that it did, without its detail" \
  "$(jq -r 'select(.message | endswith("recovered")) | [.message, .detail // "none"] | join(" | ")' "$FLEET_LOG")" "doctor: account $work/cfg-a recovered | none"
rm -f "$work/cfg-a/settings.json"; rm -rf -- "${work:?}/cfg-b"
session_file w1 "$w" $'https://claude.ai/code/session_01W\tx\ny'
djson >/dev/null
check "#208 review 1: a tab or newline in a detail stays inside its check" \
  "$(jq -r --arg c "remote control $w (worker)" '.checks[] | select(.check == $c) | .detail' "$work/health.json")" "https://claude.ai/code/session_01W x y"
session_file w1 "$w" https://claude.ai/code/session_01W
check "#208 review 1: the home folder reads as ~" \
  "$(HOME=$work djson >/dev/null; jq -r '.checks[] | select(.check | startswith("account ")) | .check' "$work/health.json" | head -1)" "account ~/cfg-a"
printf 'not json' >"$work/health.json"
check "#208: a report it cannot read is a first run" "$(djson) $(jq -r '.checks | length > 0' "$work/health.json")" "1 true"
chmod a-w "$work"; touch "$work/x" 2>/dev/null || {
  check "#208: a report it cannot write is logged, and nothing half-written is left" \
    "$(djson; jq -r 'select(.message == "doctor: could not write its report") | .level' "$FLEET_LOG"; find "$work" -maxdepth 1 -name 'health.json.tmp.*' | wc -l)" $'1\nERROR\n0'
}
chmod u+w "$work"; rm -f "$work/x"
# A wall AJ switches off while it fails is logged as switched off, not as recovered.
rm -f "$work/health.json"; djson >/dev/null; : >"$FLEET_LOG"
DOC_PREFS='{"phone_wall": false}' djson >/dev/null
check "#328 review 1: a failing phone wall switched off logs that, not a recovery" \
  "$(jq -r 'select(.message | startswith("doctor: phone wall")) | .message' "$FLEET_LOG" | paste -sd'|')" "doctor: phone wall switched off"
t kill-window -t "$w"; t kill-window -t "$o"; rm -f "$FLEET_STATE/orchestrator.pane"; : >"$REGISTRY"

echo "install"
inst=$work/inst
mkdir -p "$inst/state" "$inst/claude"
printf 'old copy\n' >"$inst/state/launch.sh"
printf 'old hook\n' >"$inst/claude/klepsydra-fleet.sh"
ln -s "$here/agora.py" "$inst/state/agora.py"
FLEET_STATE="$inst/state" FLEET_UNITS="$inst/units" FLEET_BIN="$inst/bin" FLEET_HOOK_DIR="$inst/claude" \
  bash "$here/install.sh" --force >/dev/null 2>&1
check "#326: a retired script's link is removed" "$([[ -L $inst/state/agora.py ]] && echo kept || echo gone)" "gone"
printf 'mine\n' >"$inst/state/agora.py"
FLEET_STATE="$inst/state" FLEET_UNITS="$inst/units" FLEET_BIN="$inst/bin" FLEET_HOOK_DIR="$inst/claude" \
  bash "$here/install.sh" --force >/dev/null 2>&1
check "#326: a file of that name that is no link stays" "$(cat "$inst/state/agora.py")" "mine"
rm -f -- "${inst:?}/state/agora.py"
check "#244: the hooks, status line, launcher, tmux conf, wrap-up and cast are copied in, each matching the checkout" \
  "$(for c in "${HOOK_COPIES[@]}"; do cmp -s "${here%/fleet}/${c%% *}" "$inst/claude/${c#* }" && [[ ! -L $inst/claude/${c#* } ]] && echo same; done | wc -l)" "${#HOOK_COPIES[@]}"
check "#244: the scripts are executable, the cast is not, and no temp file is left" \
  "$(stat -c %a "$inst/claude/klepsydra-fleet.sh" "$inst/claude/klepsydra-cast.json" | tr '\n' ' ')$(find "$inst/claude" -name '*.new.*' | wc -l)" "755 644 0"
check "#244: the hook copy it replaced is archived" "$(cat "$inst/state/archive/fleet-scripts-$(date +%Y%m%d)/claude/klepsydra-fleet.sh".*)" "old hook"
hinst() { FLEET_STATE="$inst/state" FLEET_HOOK_DIR="$inst/claude" bash "$here/install.sh" --hooks --force >/dev/null 2>&1; echo $?; }
printf 'a second local edit\n' >"$inst/claude/klepsydra-fleet.sh"; sleep 1
check "#244 review: a second install the same day keeps both archived copies" \
  "$(hinst) $(cat "$inst/state/archive/fleet-scripts-$(date +%Y%m%d)/claude/klepsydra-fleet.sh".* | sort | tr '\n' '|')" "0 a second local edit|old hook|"
printf 'the old hook\n' >"$inst/claude/klepsydra-fleet.sh"
# A disk that fills mid-copy: the hook (over 12 KiB) is cut short in its temp file.
check "#244 review 2: a copy cut short leaves the old one whole, and the install fails" \
  "$( (ulimit -f 12; FLEET_LOG="$work/instlog/short.log" hinst) ) $(cat "$inst/claude/klepsydra-fleet.sh") $(find "$inst/claude" -name '*.new.*' | wc -l) $(grep -c 'klepsydra-fleet.sh' <(jq -r 'select(.message | startswith("a copy was not installed")) | .file' "$work/instlog/short.log"))" \
  "1 the old hook 0 1"
chmod a-w "$inst/claude"
check "#244 review 2: a full install with a copy it cannot write fails too" \
  "$(FLEET_STATE="$inst/state" FLEET_UNITS="$inst/units" FLEET_BIN="$inst/bin" FLEET_HOOK_DIR="$inst/claude" bash "$here/install.sh" --force >/dev/null 2>&1; echo $?) $(cat "$inst/claude/klepsydra-fleet.sh")" "1 the old hook"
chmod u+w "$inst/claude"; rm -f "$inst/claude/klepsydra-tmux.conf"; mkdir "$inst/claude/klepsydra-tmux.conf"
check "#244 review: a folder where a copy goes is left alone, said so, and the install fails" \
  "$(FLEET_LOG="$work/instlog/dir.log" hinst) $(find "$inst/claude/klepsydra-tmux.conf" -mindepth 1 | wc -l) $(grep -c "is not a file" "$work/instlog/dir.log")" "1 0 1"
rmdir "$inst/claude/klepsydra-tmux.conf"
check "#244: --hooks installs only the copies: no scripts, units or command" \
  "$(FLEET_STATE="$inst/h" FLEET_UNITS="$inst/hu" FLEET_BIN="$inst/hb" FLEET_HOOK_DIR="$inst/hc" bash "$here/install.sh" --hooks --force >/dev/null 2>&1; echo $?) $(find "$inst/hc" -type f | wc -l) $(find "$inst" -mindepth 1 -maxdepth 1 \( -name hu -o -name hb \) | wc -l) $(find "$inst/h" -mindepth 1 -not -path "$inst/h/log*" 2>/dev/null | wc -l)" "0 ${#HOOK_COPIES[@]} 0 0"
rm -rf -- "${inst:?}/hc" "${inst:?}/h"
check "#244: the wrap-up skill lands in its skill folder" "$(cmp -s "${here%/fleet}/hooks/klepsydra-wrapup.md" "$inst/claude/skills/klepsydra-wrapup/SKILL.md" && echo same)" "same"
hinst >/dev/null # the tmux conf the folder case removed comes back first
before=$(find "$inst/state/archive" -type f | wc -l)
check "#244 nit: an install with nothing changed copies and archives nothing" \
  "$(FLEET_LOG="$work/instlog/same.log" hinst) $(( $(find "$inst/state/archive" -type f | wc -l) - before )) $(cat "$work/instlog/same.log" 2>/dev/null | grep -c 'installed a copy')" "0 0 0"
mkdir -p "$work/dryfail" && cp -r "$here" "$work/dryfail/fleet"
check "#244 nit: a dry run that meets an error writes no log, and says it on stderr" \
  "$(FLEET_STATE="$inst/dl" FLEET_HOOK_DIR="$inst/dc" bash "$work/dryfail/fleet/install.sh" --dry-run --hooks --force 2>&1 >/dev/null | grep -c "ERROR a copy's source is missing") $(find "$inst/dl" "$inst/dc" -mindepth 1 2>/dev/null | wc -l)" "${#HOOK_COPIES[@]} 0"
rm -rf -- "${work:?}/dryfail" "${inst:?}/dl" "${inst:?}/dc"
check "each script is linked from the checkout" "$(readlink "$inst/state/resume-at-reset.sh")" "$here/resume-at-reset.sh"
check "the copy a link replaced is archived" "$(cat "$inst/state/archive/fleet-scripts-$(date +%Y%m%d)/launch.sh")" "old copy"
check "the fleet command is linked" "$(readlink "$inst/bin/fleet")" "$here/fleet"
check "the resume service is a unit that restarts and comes back at boot" \
  "$(grep -E '^(ExecStart|Restart|WantedBy)=' "$inst/units/fleet-resume-at-reset.service" | tr '\n' '|')" \
  "ExecStart=/usr/bin/bash $inst/state/resume-at-reset.sh|Restart=always|WantedBy=default.target|"
check "the memfrag timer too" "$(grep -c 'OnCalendar=\*:0/30' "$inst/units/fleet-memfrag-log.timer")" "1"
check "#208: the doctor timer runs every 5 min into the data folder, and a failing check is no failed run" \
  "$(grep -c 'OnUnitActiveSec=5min' "$inst/units/fleet-doctor.timer") $(grep -E '^(ExecStart|SuccessExitStatus)=' "$inst/units/fleet-doctor.service" | tr '\n' '|')" \
  "1 SuccessExitStatus=1|ExecStart=/usr/bin/bash $inst/state/doctor.sh --json \"$KLEPSYDRA_DIR/fleet-health.json\"|"
check "#208 review 1: and what it prints stays out of the journal" "$(grep -c '^StandardOutput=null$' "$inst/units/fleet-doctor.service")" "1"
# #292 review 4: on WSL both the doctor's unit and the watchdog's get the distro's name.
# In a folder of its own: the dry-run case below lists what $inst holds.
iw=$work/inst-wsl
WSL_DISTRO_NAME=Test FLEET_STATE="$iw/s" FLEET_UNITS="$iw/u" FLEET_BIN="$iw/b" FLEET_HOOK_DIR="$iw/c" bash "$here/install.sh" --force >/dev/null 2>&1
check "#292 review 4: an install on WSL passes WSL_DISTRO_NAME to the doctor's and the watchdog's units" \
  "$(grep -c '^Environment=.*"WSL_DISTRO_NAME=Test"' "$iw/u/fleet-doctor.service" "$iw/u/fleet-tmux-watch.service" | cut -d: -f2 | paste -sd' ')" "1 1"
FLEET_STATE="$inst/s2" FLEET_UNITS="$inst/u2" FLEET_BIN="$inst/b2" FLEET_HOOK_DIR="$inst/c2" bash "$here/install.sh" --dry-run --force >"$work/dry" 2>/dev/null
check "a dry run says what it would do and changes nothing" "$(grep -c '^would' "$work/dry" | sed 's/^[1-9][0-9]*$/some/') $(find "$inst" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ')" "some bin claude state units "
# #353: the fleet's slice and the workers' inside it, sized from MemTotal (the
# fixture's 9948 MiB) less the 1536 MiB margin, and that less the orchestrator's
# peak for the workers; MemoryMax only.
mkdir -p "$inst/sl"; printf '811\n' >"$inst/sl/orchestrator.mem"
slice_inst() { FLEET_STATE="$inst/sl" FLEET_UNITS="$inst/slu" FLEET_BIN="$inst/slb" FLEET_HOOK_DIR="$inst/slc" FLEET_LOG="$inst/sl.log" \
  bash "$here/install.sh" --force --no-cutover >/dev/null 2>&1; echo "rc=$?"; }
check "#353: install writes both slices, sized from MemTotal, the margin and the orchestrator's peak" \
  "$(slice_inst) $(grep -h '^Memory' "$inst/slu/fleet.slice" "$inst/slu/fleet-workers.slice" | paste -sd' ')" \
  "rc=0 MemoryAccounting=yes MemoryMax=8412M MemoryAccounting=yes MemoryMax=7601M"
check "#353: and logs the sizes" "$(jq -r 'select(.message == "memory slices sized") | "\(.fleet_mb) \(.workers_mb) \(.orchestrator_mb) \(.margin_mb)"' "$inst/sl.log")" "8412 7601 811 1536"
touch -d @1794400000 "$inst/slu/fleet.slice"
check "#353 review 2: an install that changes no unit leaves its time" \
  "$(slice_inst) $(stat -c %Y "$inst/slu/fleet.slice")" "rc=0 1794400000"
# Doctor dates the slices by the unit's birth, so a resize must rewrite it in place.
ino=$(stat -c %i "$inst/slu/fleet.slice")
printf 'MemTotal:       12000000 kB\n' >"$work/meminfo-big"
check "#353 review 5: a resize rewrites the unit in place (same file, new cap: doctor keeps its first date)" \
  "$(FLEET_MEMINFO="$work/meminfo-big" slice_inst) $(stat -c %i "$inst/slu/fleet.slice") $(grep '^MemoryMax=' "$inst/slu/fleet.slice")" "rc=0 $ino MemoryMax=10182M"
printf 'MemTotal:       1572864 kB\n' >"$work/meminfo-small"
check "#353: a machine too small for the orchestrator's peak fails the install, saying so" \
  "$(FLEET_MEMINFO="$work/meminfo-small" slice_inst) $(jq -r 'select(.level == "ERROR") | .message' "$inst/sl.log" | grep -c '^memory slices not sized')" "rc=1 1"
cat >"$work/sc-live" <<'EOF'
#!/usr/bin/env bash
# systemctl with the resume service running: logs each call.
printf '%s\n' "$*" >>"$SC_CALLS"
[[ $* == *"is-active --quiet fleet-resume-at-reset.service"* ]] && exit 0
[[ $* == *"show -p Transient"* ]] && { echo no; exit 0; }
exit 0
EOF
chmod +x "$work/sc-live"
inst2() { FLEET_STATE="$inst/state" FLEET_UNITS="$inst/units" FLEET_BIN="$inst/bin" FLEET_HOOK_DIR="$inst/claude" FLEET_SYSTEMCTL="$work/sc-live" SC_CALLS="$work/sc.calls" \
  FLEET_LOG="$work/instlog/cut.log" bash "$here/install.sh" --force "$@" 2>/dev/null; echo "rc=$?"; }
: >"$work/sc.calls"
out=$(inst2)
check "#263: an install onto a running fleet cuts over, so the new scripts run" \
  "$(grep -c 'enable --now fleet-resume-at-reset.service' "$work/sc.calls") $(grep -c 'install cuts the running fleet over' "$work/instlog/cut.log")" "1 1"
check "#263: and a cut-over that cannot confirm the service's start fails the install, saying so" "$(tail -1 <<<"$out")" "rc=1"
: >"$work/sc.calls"
check "#263: --no-cutover installs only" "$(inst2 --no-cutover | tail -1) $(grep -c 'enable --now' "$work/sc.calls")" "rc=0 0"

repo=$work/repo
git init -q "$repo" && cp -r "$here" "$repo/fleet"
for c in "${HOOK_COPIES[@]}"; do mkdir -p "$(dirname "$repo/${c%% *}")"; cp "${here%/fleet}/${c%% *}" "$repo/${c%% *}"; done
git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm x
git -C "$repo" worktree add -q "$work/wt" 2>/dev/null
guard() { FLEET_STATE="$inst/g" FLEET_UNITS="$inst/gu" FLEET_BIN="$inst/gb" bash "$1/fleet/install.sh" --dry-run >/dev/null 2>&1; echo $?; }
check "the main checkout installs (10-29: from fleet/ git named its common dir relatively, so main read as a worktree)" "$(guard "$repo")" "0"
check "a worktree is refused" "$(guard "$work/wt")" "2"
mkdir -p "$work/onlyfleet" && cp -r "$here" "$work/onlyfleet/fleet"
check "#244 review: a copy missing from the checkout fails the doctor, never an ok over nothing" \
  "$(bash "$work/onlyfleet/fleet/doctor.sh" 2>/dev/null | grep -c "^FAIL installed copies: missing from $(tilde "$work/onlyfleet"): hooks/klepsydra-common.sh hooks/klepsydra-fleet.sh ")" "1"

echo "cut-over"
export SC="$work/sc" FLEET_LOG
mkdir -p "$SC"
cat >"$work/bin/systemctl" <<'SC'
#!/usr/bin/env bash
# A user systemd: each unit's state is a file under $SC. Like systemd, it will
# not enable a unit file while a transient unit of that name exists.
shift
cmd=$1
shift
case $cmd in
  show) u=${*: -1}; [[ -e $SC/$u.transient ]] && echo yes || echo no ;;
  stop) rm -f -- "${SC:?}/${1:?}.transient" "${SC:?}/${1:?}.active" ;;
  daemon-reload) : ;;
  enable)
    [[ $1 == --now ]] && shift
    if [[ -e $SC/$1.transient ]]; then echo "Failed to enable unit: Unit $1 is transient or generated." >&2; exit 1; fi
    touch "$SC/$1.enabled" "$SC/$1.active"
    if [[ $1 == fleet-resume-at-reset.service && -z ${SC_SILENT:-} ]]; then
      jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '{ts: $ts, level: "INFO", target: "fleet::resume", message: "resume service started"}' >>"$FLEET_LOG"
    fi
    ;;
  is-enabled) [[ -e $SC/$1.enabled ]] && echo enabled || echo disabled ;;
  is-active) [[ $1 == --quiet ]] && shift && { [[ -e $SC/$1.active ]]; exit; }; [[ -e $SC/$1.active ]] && echo active || echo inactive ;;
  restart)
    touch "$SC/$1.active" "$SC/$1.restarted"
    [[ $1 == fleet-resume-at-reset.service ]] && jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '{ts: $ts, level: "INFO", target: "fleet::resume", message: "resume service started"}' >>"$FLEET_LOG"
    ;;
esac
SC
chmod +x "$work/bin/systemctl"
cutover() { FLEET_SYSTEMCTL="$work/bin/systemctl" FLEET_UNITS="$work/units" FLEET_CUTOVER_WAIT=2 bash "$here/cutover.sh" 2>/dev/null; }
touch "$SC/fleet-resume-at-reset.service.transient" "$SC/fleet-resume-at-reset.service.active" \
  "$SC/fleet-memfrag-log.timer.transient" "$SC/fleet-memfrag-log.service.transient"
check "the stand-in refuses enable over a transient unit, as systemd does (10-29 review)" \
  "$("$work/bin/systemctl" --user enable fleet-resume-at-reset.service 2>&1 | tr -d '\n'; echo " rc=${PIPESTATUS[0]}")" \
  "Failed to enable unit: Unit fleet-resume-at-reset.service is transient or generated. rc=1"
out=$(cutover); code=$?
check "the cut-over stops each transient unit, then enables and starts the installed one" "$out
rc=$code" "ok   fleet-resume-at-reset.service: enabled and active
ok   fleet-memfrag-log.timer: enabled and active
ok   fleet-accounts-sync.path: enabled and active
ok   fleet-accounts-sync.timer: enabled and active
ok   fleet-sync-briefing.timer: enabled and active
ok   fleet-ci-watch.service: enabled and active
ok   fleet-doctor.timer: enabled and active
ok   fleet-tmux-watch.timer: enabled and active
ok   the resume service logged its start
rc=0"
check "no transient unit is left" "$(find "$SC" -name '*.transient' | wc -l)" "0"
check "a first cut-over restarts nothing it just started" "$(find "$SC" -name '*.restarted' | wc -l)" "0"
out=$(SC_SILENT=1 cutover); code=$?
check "10-29: a second cut-over (after a pull) restarts the running installed services, and the resume service logs its start" \
  "$code $(find "$SC" -name '*.restarted' -printf '%f\n' | sort | tr '\n' ' ')" "0 fleet-ci-watch.service.restarted fleet-resume-at-reset.service.restarted "
check "each stop is logged" "$(jq -r 'select(.message | startswith("transient unit stopped")) | .unit' "$FLEET_LOG" | sort | tr '\n' ' ')" \
  "fleet-memfrag-log.service fleet-memfrag-log.timer fleet-resume-at-reset.service "
rm -f -- "${SC:?}"/*
touch "$SC/fleet-resume-at-reset.service.transient"
out=$(SC_SILENT=1 cutover); code=$?
check "a resume service that never logs its start fails the cut-over" "$code $(tail -1 <<<"$out")" "1 FAIL the resume service did not log its start"
check "install writes the units but never enables them over a transient one" \
  "$(grep -c -- '--user enable' "$here/install.sh") $(grep -c -- '--user daemon-reload' "$here/install.sh")" "0 1"

echo "two accounts: picking one"
login a; login b
reading a Personal 40 1000; reading b RIT 10 2000
now=$(date +%s)
check "#175: the first folder with room wins over one with more room" "$(best_account "$now")" "$work/cfg-a"
check "Heph's order starts from the other end" "$(FLEET_ACCOUNTS=$FLEET_HEPH_ACCOUNTS best_account "$now")" "$work/cfg-b"
reading a Personal 95 1000
check "the first folder out of room gives way to the next with room" "$(best_account "$now")" "$work/cfg-b"
reading b RIT 95 2000
jq -n --argjson r "$((now + 3600))" '{label: "RIT", windows: {five_hour: {used_percentage: 95, resets_at: $r}, seven_day: {used_percentage: 20, resets_at: $r}}}' >"$KLEPSYDRA_DIR/accounts/a/s.json"
check "with none in room, a five-hour tie goes to the weekly window (a Team seat has none)" "$(best_account "$now")" "$work/cfg-b"
reading a Personal 98 1000
check "with none in room, the most five-hour room" "$(best_account "$now")" "$work/cfg-b"
reading a Personal 40 1000; reading b RIT 0 2000; logout b
check "a folder not logged in is never picked" "$(best_account "$now")" "$work/cfg-a"
jq -n --argjson r "$((now + 3600))" '{label: "RIT", windows: {five_hour: {used_percentage: 0, resets_at: $r}, seven_day: {used_percentage: 100, resets_at: ($r + 86400)}}}' >"$KLEPSYDRA_DIR/accounts/b/s.json"
login b; jq -n --argjson r "$((now + 3600))" '{label: "Personal", windows: {five_hour: {used_percentage: 40, resets_at: $r}, seven_day: {used_percentage: 50, resets_at: $r}}}' >"$KLEPSYDRA_DIR/accounts/a/s.json"
check "review 2B: an account whose week is spent is not picked over one with room" "$(best_account "$now")" "$work/cfg-a"
logout b
login b
reading a Personal 100 1000; reading b RIT 10 2000
check "room elsewhere: the other account, when it has room" "$(room_elsewhere "$work/cfg-a" "$now")" "$work/cfg-b"
reading b RIT 95 2000
check "and none when it is nearly full too" "$(room_elsewhere "$work/cfg-a" "$now" || echo none)" "none"

echo "fresh-now moves every row, even when a launch reads stdin (#242)"
reading a Personal 95 1000; reading b RIT 10 2000
S2=22222222-2222-4333-8444-555555555555
fa=$(pane fma '{"above":["idle"],"exit_on_exit":true}'); fb=$(pane fmb '{"above":["idle"],"exit_on_exit":true}'); settle
live "$fa"; live "$fb" "$S2"
printf '%s\tfma\t%s\t%s\t/w\t%s\n%s\tfmb\t%s\t%s\t/w\t%s\n' "$fa" "$work/brief.src" "$SID" "$work/cfg-a" "$fb" "$work/brief.src" "$S2" "$work/cfg-a" >"$REGISTRY"
: >"$work/fm.log"
cat >"$work/launch-fm.sh" <<EOF
#!/usr/bin/env bash
# wt.exe drains whatever stdin its caller hands it (10-31): this records what it was handed.
# Checked before any command substitution, whose pipe would take fd 3.
[[ -e /proc/\$\$/fd/3 ]] && fd3=open || fd3=closed
echo "\$(readlink /proc/\$\$/fd/0) fd3=\$fd3" >>"$work/fm.fds"
echo "\$1 \${FLEET_ACCOUNT:-}" >>"$work/fm.log"
new=\$(tmux -L "$FLEET_SOCK" new-window -d -P -F '#{pane_id}' -t fleet: "sleep 600")
echo "\$new" >>"$work/fm.panes"
echo "pane=\$new session=x account=\${FLEET_ACCOUNT:-} avail=1MiB brief=started"
EOF
# A pipe on stdin, not the runner's /dev/null, so the launch's own </dev/null is what the stub sees.
out=$(printf 'stdin\n' | LAUNCH="$work/launch-fm.sh" bash "$here/fresh-now.sh" 2>/dev/null)
check "both rows are moved to the account with room, not just the first" "$(sort "$work/fm.log" | tr '\n' '|')" "fma $work/cfg-b|fmb $work/cfg-b|"
check "and each says so" "$(grep -c '^fresh: fm[ab] moved to' <<<"$out")" "2"
check "each launch gets no stdin and not the registry's fd 3" "$(sort -u "$work/fm.fds")" "/dev/null fd3=closed"
rm -f -- "${KLEPSYDRA_DIR:?}/fleet/$S2.json" "${KLEPSYDRA_DIR:?}/fleet/$SID.json"
xargs -r -n1 tmux -L "$FLEET_SOCK" kill-pane -t <"$work/fm.panes" 2>/dev/null
: >"$REGISTRY"
reading a Personal 60 1000
check "back room: under FLEET_BACK_ROOM_PCT (50%) free is not enough to move back" "$(back_room a "$now" && echo yes || echo no)" "no"
reading a Personal 50 1000
check "at 50% free it is" "$(back_room a "$now" && echo yes || echo no)" "yes"
# #319: a limit seen on the account outranks a reading the limit kept from refreshing.
mark_limited a $((now + 3600))
check "#319: an account at a limit seen on it has no room to move back to, whatever its reading says" \
  "$(back_room a "$now" && echo yes || echo no) $(headroom a "$now") $(id_has_room a "$now" && echo room || echo full)" "no 0 100 full"
mark_limited a $((now + 60))
check "#319: an earlier reset never shortens a later one" "$(cut -d' ' -f1 "$FLEET_STATE/limited/a.five")" "$((now + 3600))"
mark_limited a $((now + 3600)) seven
check "#322 review 1: a weekly limit zeroes the weekly window, a 5-hour one the 5-hour window" "$(headroom a "$now")" "0 0"
rm -f -- "$FLEET_STATE/limited/a.five"
check "#322 review 1: the weekly mark alone leaves the 5-hour window to the reading" "$(headroom a "$now")" "50 0"
rm -f -- "$FLEET_STATE/limited/a.seven"; mark_limited a $((now + 3600))
check "#319: past its reset the reading decides again" "$(back_room a $((now + 3601)) && echo yes || echo no)" "yes"
touch -d "@$(( $(date +%s) + 120 ))" "$KLEPSYDRA_DIR/accounts/a/s.json"
check "#319: and so does a reading taken after the limit was seen" "$(back_room a "$now" && echo yes || echo no)" "yes"
mark_limited a $((now + 3600))
check "#322 review 1: the same limit seen again after that reading holds again, its newest reading no news" "$(back_room a "$now" && echo yes || echo no)" "no"
mark_limited a $((now + 60))
check "#322 review 1: so does a sighting with an earlier reset, keeping the later one" \
  "$(back_room a "$now" && echo yes || echo no) $(cut -d' ' -f1 "$FLEET_STATE/limited/a.five")" "no $((now + 3600))"
check "#319: a malformed id or reset marks nothing" "$(mark_limited '../x' 5 || echo refused) $(mark_limited a soon || echo refused)" "refused refused"
rm -rf -- "${FLEET_STATE:?}/limited"
mkdir -p "$KLEPSYDRA_DIR/accounts/rd"; printf '{}' >"$KLEPSYDRA_DIR/accounts/rd/old.json"; printf '{}' >"$KLEPSYDRA_DIR/accounts/rd/new.json"
touch -d '2026-10-01' "$KLEPSYDRA_DIR/accounts/rd/old.json"
check "#319: reading_of takes the newest reading in one pass" "$(reading_of rd)" "$KLEPSYDRA_DIR/accounts/rd/new.json"
rm -rf -- "${KLEPSYDRA_DIR:?}/accounts/rd"
check "#319: and fails with none" "$(reading_of rd || echo none)" "none"
# #335: a listing past a pipe buffer (64 KB) made sort | head -1 fail every time
# under systemd, which ignores SIGPIPE (IgnoreSIGPIPE=yes), as the run here does.
big=$KLEPSYDRA_DIR/accounts/big; mkdir -p "$big"; pad=$(printf 'r%.0s' {1..200})
for i in {1..400}; do printf '{}' >"$big/$pad-$i.json"; done
touch -d '2026-10-01' "$big/$pad-7.json"; touch -d '2030-01-01' "$big/$pad-9.json"
# shellcheck disable=SC2016 # $1 expands in the inner bash
check "#335: newest_reading reads a listing past a pipe buffer with no sort error" \
  "$(env --ignore-signal=PIPE bash -c 'source "$1"; newest_reading' _ "$here/lib.sh" 2>&1)" "$big/$pad-9.json"
check "#335: pick_file oldest takes the oldest (the inbox's order)" \
  "$(find "$big" -name '*.json' -printf '%T@ %p\n' | pick_file oldest 2>&1)" "$big/$pad-7.json"
# Equal mtimes (ext4 stamps coarsely) pick as sort did, by path, not by the folder's listing order.
check "#336 review 1: a tie goes to the last path for newest and the first for oldest" \
  "$(printf '5 %s\n' c a d b | pick_file newest) $(printf '5 %s\n' c a d b | pick_file oldest)" "d a"
rm -rf -- "${big:?}"
rm -f "$KLEPSYDRA_DIR/accounts/a/s.json"
check "and with no reading at all it is not" "$(back_room a "$now" && echo yes || echo no)" "no"
check "the default folder unsets CLAUDE_CONFIG_DIR; the second sets it" "$(config_env "$work/cfg-a")| $(config_env "$work/cfg-b")" "-u CLAUDE_CONFIG_DIR | CLAUDE_CONFIG_DIR=$work/cfg-b "

echo "two accounts: launch"
: >"$REGISTRY"
reading a Personal 95 1000; reading b RIT 10 2000
cp "$work/task.src" "$FLEET_STATE/task-acct1.src"; cp "$work/task.src" "$FLEET_STATE/task-acct2.src"
out=$(launch acct1 '{"above":["Claude Code"]}')
check "launch starts the session on the first account with room" "$(grep -c "^CONFIG $work/cfg-b$" "$work/acct1.log") $(grep -o 'account=[^ ]*' <<<"$out")" "1 account=$work/cfg-b"
check "and records the folder in the registry" "$(awk -F'\t' '$2 == "acct1" { print $6 }' "$REGISTRY")" "$work/cfg-b"
reading a Personal 40 1000; reading b RIT 10 2000
t set-environment -g CLAUDE_CONFIG_DIR "$work/cfg-b"   # a tmux server started from the second folder's shell
out=$(launch acct2 '{"above":["Claude Code"]}')
t set-environment -gu CLAUDE_CONFIG_DIR
check "on the default account, a CLAUDE_CONFIG_DIR in tmux's environment is not passed on" "$(grep -c '^CONFIG' "$work/acct2.log") ${out##* }" "0 brief=started"
check "the brief still goes in" "$(grep -c '^SUBMIT Do the thing' "$work/acct2.log")" "1"
t kill-window -t "$(awk -F'\t' '$2 == "acct1" { print $1 }' "$REGISTRY")"; t kill-window -t "$(awk -F'\t' '$2 == "acct2" { print $1 }' "$REGISTRY")"; : >"$REGISTRY"

echo "two accounts: the resume service"
: >"$FLEET_LOG"
reading a Personal 100 5000; reading b RIT 10 4000
p=$(pane own "{\"above\":[\"work\",\"$LIMIT\"]}"); settle
resume "$noon"
reading b RIT 10 6000   # both accounts publish: which reading is newest flips minute to minute
resume "$(( noon + 60 ))"
check "with both logged in, the other account's newer reading is no switch for a pane on the default" "$(events own)" ""
check "the limit is logged with the pane's own account" "$(jq -r --arg p "$p" 'select(.message == "limit seen" and .pane == $p) | .account' "$FLEET_LOG")" "Personal"
t kill-window -t "$p"

cat >"$work/launch-move.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$FLEET_ACCOUNT" "\$@" >"$work/moved"
cp "\$2" "$work/moved-brief"
echo "pane=%997 session=x account=\$FLEET_ACCOUNT avail=1MiB brief=started"
EOF
mover() { LAUNCH="$work/launch-move.sh" FLEET_NOW=$1 bash "$here/resume-at-reset.sh" --once 2>/dev/null; } # NOW
: >"$FLEET_LOG"; : >"$work/moved"
p=$(pane mover "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tmover\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
mover "$noon"
check "a registered pane at a limit moves to the other account at once" "$(head -2 "$work/moved" | tr '\n' ' ')" "$work/cfg-b mover "
check "#319: and the limit is marked on its account's 5-hour window until the reset" "$(cut -d' ' -f1 "$FLEET_STATE/limited/a.five" 2>/dev/null)" "$(TZ=America/New_York date -d '2026-10-28 13:10' +%s)"
rm -rf -- "${FLEET_STATE:?}/limited"
check "its old pane exits" "$(events mover)" "SUBMIT /exit"
check "the fresh brief says why, then carries the brief" "$(grep -c 'continue on the other, which has room' "$work/moved-brief") $(tail -1 "$work/moved-brief")" "1 the brief body"
check "logged with both folders and the new pane" \
  "$(jq -r 'select(.message == "moved to the other account at a limit") | [.from, .to, .new_pane] | join(" ")' "$FLEET_LOG")" "$work/cfg-a $work/cfg-b %997"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"
# #322 review 2: a weekly limit marks the weekly window; a move at a limit
# whose brief meets the limit on the other account marks that one too.
rm -f -- "$FLEET_STATE/resume-state"; rm -rf -- "${FLEET_STATE:?}/limited"
cat >"$work/launch-lim3.sh" <<EOF
#!/usr/bin/env bash
echo "pane=%994 session=x account=\$FLEET_ACCOUNT avail=1MiB brief=blocked-by-limit"
EOF
chmod +x "$work/launch-lim3.sh"
p=$(pane wkly "{\"above\":[\"⏺ Done. done 11:50 AM\",\"  ⎿  You've hit your weekly limit · resets Nov 2, 1pm (America/New_York)\"]}"); settle
live "$p"
printf '%s\twkly\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
LAUNCH="$work/launch-lim3.sh" FLEET_NOW=$noon bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "#322 review 2: a weekly limit marks the account's weekly window, and the log names the mark" \
  "$([[ -e $FLEET_STATE/limited/a.seven ]] && echo seven) $([[ -e $FLEET_STATE/limited/a.five ]] && echo five) $(jq -r 'select(.message == "limit seen") | .marked' "$FLEET_LOG" | tail -1)" "seven  a.seven"
check "#322 review 2: and the move whose brief met a limit on the other account marks that one" "$([[ -e $FLEET_STATE/limited/b.five ]] && echo marked)" "marked"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"; rm -rf -- "${FLEET_STATE:?}/limited"; rm -f -- "$FLEET_STATE/resume-state" "$FLEET_STATE/back-hold"

# A background task's notification starts a turn during the launch; at the
# limit it fails at once, so the move goes on.
cat >"$work/launch-limturn.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$FLEET_ACCOUNT" "\$@" >"$work/moved"
jq '.turn_at = 999999999999' "$KLEPSYDRA_DIR/fleet/$SID.json" >"$work/st.json" && mv "$work/st.json" "$KLEPSYDRA_DIR/fleet/$SID.json"
echo "pane=%995 session=x account=\$FLEET_ACCOUNT avail=1MiB brief=started"
EOF
chmod +x "$work/launch-limturn.sh"
: >"$FLEET_LOG"; : >"$work/moved"
p=$(pane limturn "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tlimturn\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
LAUNCH="$work/launch-limturn.sh" FLEET_NOW=$noon bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "#198 review 3: a notification's turn during a move at a limit does not keep the old pane" \
  "$(events limturn) $(logged 'moved to the other account at a limit')" "SUBMIT /exit $p "
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

: >"$FLEET_LOG"; : >"$work/moved"
p=$(pane carrier "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tcarrier\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
t send-keys -t "$p" -l "AJ: and fix the footer"; settle
mover "$noon"
check "AJ's line is not moved while he may still be typing it" "$(wc -c <"$work/moved") $(events carrier)" "0 "
mover "$(( noon + 60 ))"
check "then the move carries it into the new brief" "$(grep -c '^AJ: and fix the footer$' "$work/moved-brief")" "1"
check "and the old pane never sends it: its box is cleared, then /exit" "$(events carrier)" "SUBMIT /exit"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

: >"$FLEET_LOG"; : >"$work/moved"
SOON='  ⎿  You'"'"'ve hit your session limit · resets 12:10pm (America/New_York)'
p=$(pane soon "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$SOON\"]}"); settle
live "$p"
printf '%s\tsoon\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
mover "$noon"
check "a reset under 15 min away is waited for, not moved" "$(wc -c <"$work/moved") $(events soon)" "0 "
t kill-window -t "$p"; : >"$REGISTRY"

: >"$work/moved"
reading b RIT 95 4000
p=$(pane full2 "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tfull2\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
mover "$noon"
check "no move when the other account is nearly full too" "$(wc -c <"$work/moved") $(events full2)" "0 "
t kill-window -t "$p"; : >"$REGISTRY"
logout a; logout b; reading a Personal 40 1000; rm -f "$KLEPSYDRA_DIR/accounts/b/s.json"

echo "two accounts: the orchestrator at a limit (#175, #173)"
cat >"$work/launch-heph.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$FLEET_ACCOUNT" "\$1" "settings=[\${FLEET_SETTINGS-unset}]" >"$work/moved"
cp "\$2" "$work/moved-brief"
echo "pane=%996 session=aaaaaaaa-0000-4000-8000-0000000000cc account=\$FLEET_ACCOUNT avail=1MiB brief=started"
EOF
hmove() { LAUNCH="$work/launch-heph.sh" FLEET_HEPH="$work/HEPH.md" FLEET_NOW=$1 bash "$here/resume-at-reset.sh" --once 2>/dev/null; } # NOW
printf 'handoff\n' >"$work/HEPH.md"
login a; login b; reading a Personal 100 5000; reading b RIT 10 4000
: >"$FLEET_LOG"; : >"$work/moved"; : >"$REGISTRY"; rm -f "$FLEET_STATE/orchestrator.config" "$FLEET_STATE/orchestrator.session"
h=$(pane heph "{\"above\":[\"⏺ ok\",\"$LIMIT\"]}"); settle
printf '%s\n' "$h" >"$FLEET_STATE/orchestrator.pane"
hmove "$noon"
check "Heph at a limit moves to the other account at once, without worker settings" "$(tr '\n' ' ' <"$work/moved")" "$work/cfg-b heph settings=[] "
check "from a note naming HEPH.md" "$(grep -c "^Fresh start: the orchestrator (Heph) stopped at a usage limit on one account, and moves to the other, which has room; you replace it. Read $work/HEPH.md first" "$work/moved-brief")" "1"
check "the records follow him: pane, session and folder" \
  "$(cat "$FLEET_STATE/orchestrator.pane" "$FLEET_STATE/orchestrator.session" "$FLEET_STATE/orchestrator.config" | tr '\n' ' ')" "%996 aaaaaaaa-0000-4000-8000-0000000000cc $work/cfg-b "
check "the old pane exits" "$(events heph)" "SUBMIT /exit"
check "logged as the orchestrator's move" "$(jq -r 'select(.message == "moved to the other account at a limit") | [.orchestrator, .from, .to] | join(" ")' "$FLEET_LOG")" "1 $work/cfg-a $work/cfg-b"
t kill-window -t "$h" 2>/dev/null

# #216: the new Heph opens behind, and comes forward once the old one has gone.
cat >"$work/launch-hfwd.sh" <<EOF
#!/usr/bin/env bash
np=\$(tmux -L "$FLEET_SOCK" new-window -d -P -F '#{pane_id}' -t fleet: 'sleep 600')
echo "pane=\$np session=aaaaaaaa-0000-4000-8000-0000000000ce account=\$FLEET_ACCOUNT avail=1MiB brief=started"
EOF
chmod +x "$work/launch-hfwd.sh"
: >"$work/moved"; rm -f "$FLEET_STATE/orchestrator.config" "$FLEET_STATE/orchestrator.session" "$FLEET_STATE/resume-state"
h=$(pane hfwd "{\"above\":[\"⏺ ok\",\"$LIMIT\"]}"); settle
printf '%s\n' "$h" >"$FLEET_STATE/orchestrator.pane"
t select-window -t "$h"
LAUNCH="$work/launch-hfwd.sh" FLEET_HEPH="$work/HEPH.md" FLEET_NOW=$noon bash "$here/resume-at-reset.sh" --once 2>/dev/null
nh=$(cat "$FLEET_STATE/orchestrator.pane")
check "#216: after the move the new Heph is the window in view" "$(events hfwd) $(t display -p -t fleet: '#{pane_id}')" "SUBMIT /exit $nh"
t kill-window -t "$nh" 2>/dev/null; t kill-window -t "$h" 2>/dev/null
# AJ watching a worker while Heph moves stays on the worker.
: >"$work/moved"; rm -f "$FLEET_STATE/orchestrator.config" "$FLEET_STATE/orchestrator.session" "$FLEET_STATE/resume-state"
h=$(pane hfwd "{\"above\":[\"⏺ ok\",\"$LIMIT\"]}"); wv=$(pane watched '{"above":["idle"]}'); settle
printf '%s\n' "$h" >"$FLEET_STATE/orchestrator.pane"
t select-window -t "$wv"
LAUNCH="$work/launch-hfwd.sh" FLEET_HEPH="$work/HEPH.md" FLEET_NOW=$noon bash "$here/resume-at-reset.sh" --once 2>/dev/null
nh=$(cat "$FLEET_STATE/orchestrator.pane")
check "#229 review: a move while AJ watches another window leaves him there" "$(events hfwd) $([[ $nh != "$h" ]] && echo moved) $(t display -p -t fleet: '#{pane_id}')" "SUBMIT /exit moved $wv"
t kill-window -t "$nh" 2>/dev/null; t kill-window -t "$h" 2>/dev/null; t kill-window -t "$wv" 2>/dev/null
# A worker replaced at a limit: its successor takes its place in view only if it was in view.
cat >"$work/launch-wfwd.sh" <<EOF
#!/usr/bin/env bash
np=\$(tmux -L "$FLEET_SOCK" new-window -d -P -F '#{pane_id}' -t fleet: 'sleep 600')
echo "\$np" >"$work/wfwd.new"
echo "pane=\$np session=x account=\$FLEET_ACCOUNT avail=1MiB brief=started"
EOF
chmod +x "$work/launch-wfwd.sh"
for view in self other; do
  : >"$FLEET_LOG"; rm -f "$FLEET_STATE/resume-state"
  p=$(pane wfwd "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); wv=$(pane wother '{"above":["idle"]}'); settle
  live "$p"
  printf '%s\twfwd\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
  if [[ $view == self ]]; then t select-window -t "$p"; else t select-window -t "$wv"; fi
  LAUNCH="$work/launch-wfwd.sh" FLEET_NOW=$noon bash "$here/resume-at-reset.sh" --once 2>/dev/null
  np=$(cat "$work/wfwd.new" 2>/dev/null)
  want=$np; [[ $view == other ]] && want=$wv
  check "#229 review: a worker moved while $([[ $view == self ]] && echo "AJ watched it: its successor is in view" || echo "AJ watched another: he stays there")" \
    "$(events wfwd) $(t display -p -t fleet: '#{pane_id}')" "SUBMIT /exit $want"
  t kill-window -t "$np" 2>/dev/null; t kill-window -t "$p" 2>/dev/null; t kill-window -t "$wv" 2>/dev/null; : >"$REGISTRY"
done

# A background task's notification starts a turn during his launch; at the
# limit it fails at once, so he still moves.
cat >"$work/launch-hturn.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$FLEET_ACCOUNT" "\$1" >"$work/moved"
printf '%s\n' "\${FLEET_SUCCEEDS-unset}" >"$work/succeeds"
jq '.turn_at = 999999999999' "$KLEPSYDRA_DIR/fleet/$SID.json" >"$work/st.json" && mv "$work/st.json" "$KLEPSYDRA_DIR/fleet/$SID.json"
echo "pane=%993 session=aaaaaaaa-0000-4000-8000-0000000000cd account=\$FLEET_ACCOUNT avail=1MiB brief=started"
EOF
chmod +x "$work/launch-hturn.sh"
: >"$FLEET_LOG"; : >"$work/moved"; rm -f "$FLEET_STATE/orchestrator.config" "$FLEET_STATE/orchestrator.session"
h=$(pane hturn "{\"above\":[\"⏺ ok\",\"$LIMIT\"]}"); settle
printf '%s\n' "$h" >"$FLEET_STATE/orchestrator.pane"; live "$h"
LAUNCH="$work/launch-hturn.sh" FLEET_HEPH="$work/HEPH.md" FLEET_NOW=$noon bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "#198 review 4: a notification's turn during Heph's move at a limit does not keep him" \
  "$(events hturn) $(cat "$FLEET_STATE/orchestrator.pane")" "SUBMIT /exit %993"
check "#226: the move names the session it replaces, so the new one takes its face" "$(cat "$work/succeeds")" "$SID"
t kill-window -t "$h" 2>/dev/null; rm -f "$KLEPSYDRA_DIR/fleet/$SID.json" "$FLEET_STATE/resume-state"

: >"$work/moved"; rm -f "$FLEET_STATE/orchestrator.config" "$FLEET_STATE/orchestrator.session"
h=$(pane hephtyped "{\"above\":[\"⏺ ok\",\"$LIMIT\"]}"); settle
printf '%s\n' "$h" >"$FLEET_STATE/orchestrator.pane"
t send-keys -t "$h" -l "AJ: hold the sphragis PR"; settle
hmove "$noon"
check "AJ's line at Heph's limit waits a pass, in case he is still typing" "$(wc -c <"$work/moved") $(events hephtyped)" "0 "
hmove "$((noon + 60))"
check "then goes with the move, never sent in the old pane" \
  "$(grep -c '^AJ: hold the sphragis PR$' "$work/moved-brief") $(events hephtyped)" "1 SUBMIT /exit"
t kill-window -t "$h" 2>/dev/null

: >"$work/moved"; rm -f "$FLEET_STATE/orchestrator.config" "$FLEET_STATE/orchestrator.session"
cat >"$work/launch-heph-bad.sh" <<EOF
#!/usr/bin/env bash
echo try >>"$work/moved"
echo "pane=%995 session=x account=\$FLEET_ACCOUNT avail=1MiB brief=NOT-DELIVERED"
EOF
h=$(pane hephbad "{\"above\":[\"⏺ ok\",\"$LIMIT\"]}"); settle
printf '%s\n' "$h" >"$FLEET_STATE/orchestrator.pane"
for at in "$noon" "$((noon + 60))" "$((noon + 120))"; do
  LAUNCH="$work/launch-heph-bad.sh" FLEET_HEPH="$work/HEPH.md" FLEET_NOW=$at bash "$here/resume-at-reset.sh" --once 2>/dev/null
done
check "a move whose note never started keeps Heph's pane and records, and is not retried for 15 min" \
  "$(wc -l <"$work/moved") $(cat "$FLEET_STATE/orchestrator.pane") $(events hephbad)" "1 $h "
t kill-window -t "$h" 2>/dev/null

: >"$work/moved"; : >"$FLEET_LOG"
h=$(pane hephother "{\"above\":[\"⏺ ok\",\"$LIMIT\"]}"); settle
printf '%s\n' "$h" >"$FLEET_STATE/orchestrator.pane"; live "$h"
printf 'aaaaaaaa-0000-4000-8000-0000000000ee\n' >"$FLEET_STATE/orchestrator.session"
hmove "$noon"
check "review 1: a session other than the recorded Heph in his pane is never replaced" "$(wc -c <"$work/moved") $(events hephother)" "0 "
check "review 2: nor recorded as Heph" "$(cat "$FLEET_STATE/orchestrator.session")" "aaaaaaaa-0000-4000-8000-0000000000ee"
printf '%s\tw\t%s\t%s\t/w\t%s\n' "$h" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
rm -f "$FLEET_STATE/orchestrator.session"
LAUNCH="$work/launch-heph.sh" FLEET_NOW=$((noon + 1000)) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "review 1: a registered agent in the pane orchestrator.pane names is moved as a worker, not as Heph" "$(sed -n 2p "$work/moved")" "w"
t kill-window -t "$h" 2>/dev/null; : >"$REGISTRY"

rm -f "$FLEET_STATE/orchestrator.pane" "$FLEET_STATE/orchestrator.session" "$KLEPSYDRA_DIR/fleet/$SID.json"
logout a; logout b; reading a Personal 40 1000; rm -f "$KLEPSYDRA_DIR/accounts/b/s.json"

echo "two accounts: back to the preferred account (#175)"
# The live session in pane $1, at turn state $2 with background work $3.
done_live() { jq -n --arg p "$1" --arg st "${2:-done}" --argjson bg "${3:-[]}" \
  '{session_id: "x", ended: null, tmux: {pane: $p}, state: $st, reason: null, background: $bg}' >"$KLEPSYDRA_DIR/fleet/$SID.json"; }
login a; login b; reading a Personal 10 5000; reading b RIT 10 4000
backpane() { # NAME: a registered pane on the second folder, idle at a finished turn
  local q
  q=$(pane "$1" '{"above":["⏺ Done. done 11:50 AM"]}'); settle
  done_live "$q"
  printf '%s\t%s\t%s\t%s\t/w\t%s\n' "$q" "$1" "$work/brief.src" "$SID" "$work/cfg-b" >"$REGISTRY"
  printf '%s' "$q"
}
: >"$FLEET_LOG"; : >"$work/moved"; rm -f "$FLEET_STATE/resume-state"
p=$(backpane back)
mover "$noon"; mover "$((noon + 60))"
check "a worker on the second account moves back to the first once it has room, at a finished turn" \
  "$(head -2 "$work/moved" | tr '\n' ' ')$(grep -c 'SUBMIT /exit' "$work/back.log")" "$work/cfg-a back 1"
check "its fresh brief says why" "$(grep -c 'moved back to its preferred account, Personal, which has room again' "$work/moved-brief")" "1"
check "logged with both folders" "$(jq -r 'select(.message == "moved back to the preferred account") | [.from, .to, .new_pane] | join(" ")' "$FLEET_LOG")" "$work/cfg-b $work/cfg-a %997"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

echo "a finished agent is never relaunched (#269)"
: >"$FLEET_LOG"; : >"$work/moved"; rm -f "$FLEET_STATE/resume-state" "$FLEET_STATE/finished.tsv"
p=$(backpane finished)
printf '%s\tother\t%s\tsid-o\t/w\t%s\n' "%9999" "$work/brief.src" "$work/cfg-a" >>"$REGISTRY"
check "#269: fleet done outside a pane, with no name, is refused" "$(TMUX_PANE='' bash "$here/fleet" "done" >/dev/null 2>&1; echo $?) $(wc -l <"$REGISTRY")" "2 2"
check "#269: an unknown name is refused and changes nothing" "$(bash "$here/fleet" "done" nobody >/dev/null 2>&1; echo $?) $(wc -l <"$REGISTRY")" "1 2"
check "#269 review: a pane id from another tmux server (AJ's terminal) is refused, and nothing moves" \
  "$(TMUX=/tmp/tmux-1/default,1,0 TMUX_PANE="$p" bash "$here/fleet" "done" >/dev/null 2>&1; echo $?) $(wc -l <"$REGISTRY")" "2 2"
fsock="TMUX=/tmp/tmux-1/$FLEET_SOCK,1,0"
jq --arg p "%9998" '.tmux.pane = $p' "$KLEPSYDRA_DIR/fleet/$SID.json" >"$work/st.json" && mv "$work/st.json" "$KLEPSYDRA_DIR/fleet/$SID.json"
check "#269 review: a stale row whose session runs in another pane is refused" \
  "$(env "$fsock" TMUX_PANE="$p" bash "$here/fleet" "done" >/dev/null 2>&1; echo $?) $(wc -l <"$REGISTRY")" "1 2"
done_live "$p"
out=$(env "$fsock" TMUX_PANE="$p" bash "$here/fleet" "done" 2>/dev/null); rc=$?
check "#269: fleet done in the agent's own pane moves its row, and only its row, to finished.tsv" \
  "$rc $(cut -f1,2 "$REGISTRY") | $(cut -f1,2 "$FLEET_STATE/finished.tsv")" "0 %9999	other | $p	finished"
check "#269: with the time it finished, and says so" "$(awk -F'\t' '{ print ($7 ~ /^20[0-9][0-9]-/) }' "$FLEET_STATE/finished.tsv") $out" "1 finished: $p (1 row); it will not be relaunched"
check "#269: logged" "$(jq -r 'select(.message | startswith("agent marked finished")) | .pane' "$FLEET_LOG")" "$p"
mover "$noon"; mover "$((noon + 60))"
check "#269: the resume service never moves a finished agent back, nor types into it" \
  "$(wc -c <"$work/moved") $(grep -c '^SUBMIT' "$work/finished.log")" "0 0"
printf '%s\tfinished\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-b" >>"$REGISTRY"
check "#269: fleet done NAME works from any pane, for Heph" "$(TMUX_PANE=%1 bash "$here/fleet" "done" finished >/dev/null 2>&1; echo $?) $(cut -f2 "$REGISTRY" | tr '\n' ' ')$(wc -l <"$FLEET_STATE/finished.tsv")" "0 other 2"
check "#269 review: a second fleet done NAME says it already finished" "$(bash "$here/fleet" "done" finished 2>/dev/null; echo "rc=$?")" $'already finished: finished\nrc=0'
printf '%s\t01\t%s\tsid-1\t/w\t%s\n' "%9997" "$work/brief.src" "$work/cfg-a" >>"$REGISTRY"
check "#269 review: names compare as text: fleet done 1 leaves the agent named 01" "$(bash "$here/fleet" "done" 1 >/dev/null 2>&1; echo $?) $(cut -f2 "$REGISTRY" | tr '\n' ' ')" "1 other 01 "
# #269 verify: finished.tsv that cannot be written keeps the row in panes.tsv.
printf '%s\tkeep\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-b" >"$REGISTRY"
mkdir -p "$work/rofin"; chmod 555 "$work/rofin"
check "#269 verify: a finished.tsv that cannot be written fails the run and the row stays" \
  "$(FLEET_FINISHED=$work/rofin/finished.tsv bash "$here/fleet" "done" keep >/dev/null 2>&1; echo $?) $(cut -f2 "$REGISTRY")" "1 keep"
cp "$REGISTRY" "$work/reg.before"
check "#269 verify: an append that fails after the probe (a full disk) puts the row back (one row: unchanged)" \
  "$(FLEET_FINISHED=/dev/full bash "$here/fleet" "done" keep >/dev/null 2>&1; echo $?) $(cmp -s "$work/reg.before" "$REGISTRY" && echo same)" "1 same"
chmod 755 "$work/rofin"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"; rm -f "$FLEET_STATE/finished.tsv" "$FLEET_STATE/resume-state"
# #269 verify: a finished agent whose pane sits at a limit is not told to carry on.
: >"$FLEET_LOG"
p=$(pane finlim "{\"above\":[\"work\",\"$LIMIT\"],\"on_submit\":\"busy\"}"); settle
live "$p"
printf '%s\tfinlim\t%s\t%s\t/w\t%s\t2026-11-02T20:00:00-05:00\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$FLEET_STATE/finished.tsv"
resume "$noon"; resume "$(( noon + 3600 + 600 + 130 ))"
check "#269 verify: a finished agent at a limit gets no continue message, nor is its limit logged" \
  "$(grep -c '^SUBMIT' "$work/finlim.log") $(jq -r --arg p "$p" 'select(.pane == $p) | .message' "$FLEET_LOG" | wc -l)" "0 0"
rm -f "$FLEET_STATE/finished.tsv" "$FLEET_STATE/resume-state"
resume "$noon"; resume "$(( noon + 3600 + 600 + 130 ))"
check "#269 verify: the same pane not in finished.tsv is resumed (the control)" "$(has "$(events finlim)" "SUBMIT The usage limit has reset.")" "yes"
t kill-window -t "$p" 2>/dev/null; rm -f "$FLEET_STATE/resume-state"; : >"$FLEET_LOG"
p=$(pane finlim2 "{\"above\":[\"work\",\"$LIMIT\"],\"on_submit\":\"busy\"}"); settle
live "$p"
printf '%s\tfinlim\t%s\t%s\t/w\t%s\t2026-11-02T20:00:00-05:00\n' "$p" "$work/brief.src" "99999999-0000-4000-8000-000000000000" "$work/cfg-a" >"$FLEET_STATE/finished.tsv"
resume "$noon"; resume "$(( noon + 3600 + 600 + 130 ))"
check "#269 verify 3: a new session in a finished agent's reused pane is looked after as usual" "$(has "$(events finlim2)" "SUBMIT The usage limit has reset.")" "yes"
rm -f "$FLEET_STATE/finished.tsv"
t kill-window -t "$p" 2>/dev/null; rm -f "$KLEPSYDRA_DIR/fleet/$SID.json"

: >"$work/moved"
p=$(backpane bgwork); done_live "$p" working '[{"id": "t1", "kind": "agent"}]'
mover "$noon"; mover "$((noon + 60))"
check "not while background work still runs" "$(wc -c <"$work/moved")" "0"
done_live "$p" working
mover "$((noon + 120))"
check "nor while the turn runs" "$(wc -c <"$work/moved")" "0"
t send-keys -t "$p" -l "AJ: one more thing"; settle; done_live "$p" "done"
mover "$((noon + 180))"
check "nor over a line AJ is typing" "$(wc -c <"$work/moved") $(grep -c '^SUBMIT' "$work/bgwork.log")" "0 0"
t kill-window -t "$p"; : >"$REGISTRY"

echo "two accounts: a worker that keeps background work is asked to move back (#198)"
# The live session in pane $1, as the hook writes it: its turn $2 (settled:
# over, with background work left; running), background $3, last reply $4 at
# $5 (the turn started a little before it).
reply_live() { jq -n --arg p "$1" --arg turn "$2" --argjson bg "$3" --arg r "$4" --argjson at "$5" \
  '{session_id: "x", ended: null, tmux: {pane: $p}, state: "working", reason: (if $turn == "settled" then "background" else null end),
    background: $bg, reply: {text: $r, at: $at}, prompt: {at: 1}, turn_at: ($at - 5)}' >"$KLEPSYDRA_DIR/fleet/$SID.json"; }
: >"$FLEET_LOG"; : >"$work/moved"; rm -f "$FLEET_STATE/resume-state" "$FLEET_STATE/back-room-since"
p=$(backpane keeper); state keeper '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none"}'
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "Watching the TIGRIS job." "$noon"
mover "$noon"
check "#198: a finished turn with a background shell is not moved at once" "$(wc -c <"$work/moved") $(grep -c '^SUBMIT' "$work/keeper.log")" "0 0"
mover "$((noon + 240))"
check "#198: nor asked before the preferred account has had room for 5 min" "$(grep -c '^SUBMIT' "$work/keeper.log")" "0"
mover "$((noon + 300))"
check "#198: then it is asked to save, stop its background work and answer READY-TO-MOVE" \
  "$(grep -c '^SUBMIT Your preferred account, Personal, has room again.*first line is READY-TO-MOVE alone' "$work/keeper.log")" "1"
check "#198: the request is logged, not urgent while Heph's account has room" \
  "$(jq -r 'select(.message | startswith("asked to save")) | [.pane, .from, .to, .urgent, .delivery] | join(" ")' "$FLEET_LOG")" "$p RIT Personal 0 sent"
mover "$((noon + 360))"
check "#198: asked once, not every pass" "$(wc -c <"$work/moved") $(grep -c '^SUBMIT' "$work/keeper.log")" "0 1"
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "READY-TO-MOVE" "$((noon + 200))"
mover "$((noon + 420))"
check "#198: a READY-TO-MOVE from before the request does not move it" "$(wc -c <"$work/moved")" "0"
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "READY-TO-MOVE" "$((noon + 410))"
jq ".turn_at = $((noon + 415))" "$KLEPSYDRA_DIR/fleet/$SID.json" >"$work/st.json" && mv "$work/st.json" "$KLEPSYDRA_DIR/fleet/$SID.json"
mover "$((noon + 425))"
check "#198 review 2: nor one a later turn, ended with no reply, left standing" "$(wc -c <"$work/moved")" "0"
reply_live "$p" running '[{"id": "w1", "kind": "bash"}]' "READY-TO-MOVE" "$((noon + 430))"
mover "$((noon + 440))"
check "#198: nor one whose turn still runs" "$(wc -c <"$work/moved")" "0"
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "Saved and pushed. READY-TO-MOVE" "$((noon + 430))"
mover "$((noon + 435))"
check "#198: a READY-TO-MOVE that ends a line, not alone on the first, does not move it" "$(wc -c <"$work/moved")" "0"
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "Not yet: the TIGRIS job still runs, so I am not READY-TO-MOVE." "$((noon + 430))"
mover "$((noon + 440))"
check "#198: a reply that only mentions READY-TO-MOVE does not move it" "$(wc -c <"$work/moved")" "0"
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' $'READY-TO-MOVE once job 4411 ends.\nIt has an hour left.' "$((noon + 430))"
mover "$((noon + 450))"
check "#198: nor a first line that goes on past it" "$(wc -c <"$work/moved")" "0"
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' $'**READY-TO-MOVE**\nSaved IMPL.md and pushed; stopped w1.' "$((noon + 430))"
mover "$((noon + 480))"
check "#198: it moves on a first line of READY-TO-MOVE at a finished turn" "$(head -2 "$work/moved" | tr '\n' ' ')" "$work/cfg-a keeper "
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

# #319 (11-04, site-deslop): the preferred account's reading still showed room
# 13 min after a weekly limit was seen on it. No ask while the limit stands;
# and a move that meets the limit anyway tells the worker to carry on.
: >"$FLEET_LOG"; : >"$work/moved"; rm -f "$FLEET_STATE/resume-state" "$FLEET_STATE/back-room-since"
p=$(backpane stale); state stale '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none"}'
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "Watching." "$noon"
mark_limited a $((noon + 3600))
mover "$noon"; mover "$((noon + 300))"
check "#319: no move-back ask while a limit seen on the preferred account stands" "$(grep -c '^SUBMIT' "$work/stale.log")" "0"
rm -rf -- "${FLEET_STATE:?}/limited"
cat >"$work/launch-limited.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$FLEET_ACCOUNT" "\$@" >"$work/moved"
echo "pane=%995 session=x account=\$FLEET_ACCOUNT avail=1MiB brief=blocked-by-limit"
EOF
chmod +x "$work/launch-limited.sh"
mover "$((noon + 600))"; mover "$((noon + 900))"
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "READY-TO-MOVE" "$((noon + 930))"
LAUNCH="$work/launch-limited.sh" FLEET_NOW=$((noon + 960)) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "#319: a move back whose brief meets the limit tells the stopped worker to carry on where it is" \
  "$(grep -c '^SUBMIT The move back to Personal did not happen: its brief met the usage limit there. Carry on here' "$work/stale.log") $(logged "told the worker to carry on: the move back did not happen")" "1 $p "
check "#322 review 1: and the account it met the limit on reads full for new launches too" \
  "$([[ -e $FLEET_STATE/limited/a.five ]] && echo marked) $(best_account "$((noon + 1000))")" "marked $work/cfg-b"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"
# #322 review 1: a worker asked, that declined, then finished a turn of its own,
# was never stopped for the move: a failed move back sends it no note.
rm -rf -- "${FLEET_STATE:?}/limited"; rm -f -- "$FLEET_STATE/back-hold" "$FLEET_STATE/resume-state" "$FLEET_STATE/back-room-since"; : >"$work/moved"
reading a Personal 10 5000
p=$(backpane dec); state dec '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none"}'
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "Watching." "$noon"
mover "$noon"; mover "$((noon + 300))"
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "Not yet: the TIGRIS job still runs." "$((noon + 310))"
mover "$((noon + 320))"
done_live "$p" "done" '[]'
LAUNCH="$work/launch-limited.sh" FLEET_NOW=$((noon + 1500)) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "#322 review 1: a worker that declined and later finished a turn gets no carry-on note when the move fails" \
  "$(head -1 "$work/moved") $(grep -c '^SUBMIT The move back' "$work/dec.log")" "$work/cfg-a 0"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"
# #322 review 2: a worker that did as asked (stopped its shells, so its turn
# reads as done, and answered READY-TO-MOVE) gets the note when the new
# session never starts (3); it is not asked again within the hour; and a note
# it cannot take (busy) is logged as not delivered.
rm -rf -- "${FLEET_STATE:?}/limited"; rm -f -- "$FLEET_STATE/back-hold" "$FLEET_STATE/resume-state" "$FLEET_STATE/back-room-since"; : >"$FLEET_LOG"
reading a Personal 10 5000
cat >"$work/launch-nd.sh" <<EOF
#!/usr/bin/env bash
echo "pane=%993 session=x account=\$FLEET_ACCOUNT avail=1MiB brief=NOT-DELIVERED"
EOF
chmod +x "$work/launch-nd.sh"
p=$(backpane rtm); state rtm '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none"}'
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "Watching." "$noon"
mover "$noon"; mover "$((noon + 300))"
# It answers half an hour after the ask (it saved and pushed first), so the
# note's hour and the ask's differ.
jq -n --arg p "$p" --argjson at "$((noon + 2100))" '{session_id: "x", ended: null, tmux: {pane: $p}, state: "done", reason: null,
  background: [], reply: {text: "READY-TO-MOVE", at: $at}, prompt: {at: 1}, turn_at: ($at - 5)}' >"$KLEPSYDRA_DIR/fleet/$SID.json"
LAUNCH="$work/launch-nd.sh" FLEET_NOW=$((noon + 2130)) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "#322 review 2: a worker that stopped its shells and answered READY-TO-MOVE is told to carry on when the new session never starts" \
  "$(grep -c '^SUBMIT The move back to Personal did not happen: the new session did not start. Carry on here' "$work/rtm.log")" "1"
# It carries on, with a shell running again: only the hour's gate keeps the ask away.
reply_live "$p" settled '[{"id": "w2", "kind": "bash"}]' "Carrying on here." "$((noon + 2200))"
mover "$((noon + 300 + 3600 + 60))"
check "#322 review 3: and it is not asked again within the hour of the note, though the ask's hour has passed" "$(grep -c '^SUBMIT Your preferred account' "$work/rtm.log")" "1"
mover "$((noon + 2130 + 3600 + 10))"
check "#322 review 3: an hour after the note it is asked again" "$(grep -c '^SUBMIT Your preferred account' "$work/rtm.log")" "2"
jq -n --arg p "$p" --argjson at "$((noon + 5800))" '{session_id: "x", ended: null, tmux: {pane: $p}, state: "done", reason: null,
  background: [], reply: {text: "READY-TO-MOVE", at: $at}, prompt: {at: 1}, turn_at: ($at - 5)}' >"$KLEPSYDRA_DIR/fleet/$SID.json"
# The launch leaves the old pane busy (a turn started meanwhile), so the note cannot go in.
cat >"$work/launch-busy.sh" <<EOF
#!/usr/bin/env bash
printf '%s' '{"above":["working"],"busy":true,"on_submit":"none"}' >"$work/rtm.json"; sleep 1
echo "pane=%992 session=x account=\$FLEET_ACCOUNT avail=1MiB brief=blocked-by-limit"
EOF
chmod +x "$work/launch-busy.sh"
LAUNCH="$work/launch-busy.sh" FLEET_NOW=$((noon + 5900)) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "#322 review 2: a carry-on note the worker cannot take is logged as not delivered" \
  "$(grep -c 'the carry-on note did not reach the worker' "$FLEET_LOG") $(grep -c 'told the worker to carry on: the move back did not happen' "$FLEET_LOG")" "1 1"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"
# #322 review 3: a worker that stopped for the move after its preferred account
# lost its room (a limit seen there, or a hold from another worker's failed
# move) is told to carry on once, and that READY-TO-MOVE no longer moves it.
for room_gone in limit hold; do
  rm -rf -- "${FLEET_STATE:?}/limited"; rm -f -- "$FLEET_STATE/back-hold" "$FLEET_STATE/resume-state" "$FLEET_STATE/back-room-since"; : >"$FLEET_LOG"; : >"$work/moved"
  reading a Personal 10 5000
  p=$(backpane "gone$room_gone"); state "gone$room_gone" '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none"}'
  reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "Watching." "$noon"
  mover "$noon"; mover "$((noon + 300))"
  if [[ $room_gone == limit ]]; then
    mark_limited a "$((noon + 86400))" seven
  else
    printf 'a %s %s\n' "$(reading_mtime a)" "$((noon + 320))" >"$FLEET_STATE/back-hold"
  fi
  # Its shell is still listed (the hook has not seen it stop), so only the
  # READY-TO-MOVE, never a finished turn, could move it later.
  reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "READY-TO-MOVE" "$((noon + 330))"
  # A note never goes into a busy screen; it waits for the next idle pass.
  state "gone$room_gone" '{"above":["working"],"busy":true,"on_submit":"none"}'
  mover "$((noon + 345))"
  check "#322 review 4 ($room_gone): no carry-on note while its screen is busy" "$(grep -c '^SUBMIT The move back' "$work/gone$room_gone.log")" "0"
  state "gone$room_gone" '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none"}'
  mover "$((noon + 360))"
  check "#322 review 3 ($room_gone): a worker that stopped for the move is told to carry on when the account loses its room first" \
    "$(grep -c '^SUBMIT The move back to Personal did not happen: it has no room any more. Carry on here' "$work/gone$room_gone.log") $(jq -r 'select(.message | startswith("told the worker to carry on")) | .why' "$FLEET_LOG")" "1 room"
  rm -rf -- "${FLEET_STATE:?}/limited"; rm -f -- "$FLEET_STATE/back-hold"
  mover "$((noon + 1300))"
  check "#322 review 3 ($room_gone): told once, and its old READY-TO-MOVE moves nothing once the room is back" \
    "$(grep -c '^SUBMIT The move back' "$work/gone$room_gone.log") $(wc -c <"$work/moved")" "1 0"
  t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"
done
# #322 review 4: the room path's guards. The asked stamp comes from the
# service's saved state (fields: pane, rc label, asked), as after a restart.
asked_on_record() { # PANE ASKED RC_LABEL
  { printf '#server %s\n' "$(t display-message -p '#{pid}')"; printf '%s\x1f\x1f\x1f%s\x1f\x1f\x1f\x1f\x1f\x1f%s\x1f\n' "$1" "$3" "$2"; } >"$FLEET_STATE/resume-state"
}
room_fresh() { rm -rf -- "${FLEET_STATE:?}/limited"; rm -f -- "$FLEET_STATE/back-hold" "$FLEET_STATE/resume-state" "$FLEET_STATE/back-room-since"; : >"$work/moved"; : >"$FLEET_LOG"; }
# Heph is never told to carry on: his move back has its own path.
room_fresh; reading a Personal 10 5000; reading b RIT 10 4000
q=$(pane hephroom '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none","rc":"on"}'); settle
printf '%s\n' "$q" >"$FLEET_STATE/orchestrator.pane"; printf '%s\n' "$work/cfg-a" >"$FLEET_STATE/orchestrator.config"
mark_limited b "$((noon + 86400))" seven
asked_on_record "$q" "$((noon + 300))" Personal
reply_live "$q" settled '[{"id": "w1", "kind": "bash"}]' "READY-TO-MOVE" "$((noon + 330))"
mover "$((noon + 360))"; mover "$((noon + 1300))"
check "#322 review 4: Heph, asked and READY-TO-MOVE when his preferred account loses its room, gets no carry-on note" \
  "$(grep -c '^SUBMIT The move back' "$work/hephroom.log")" "0"
t kill-window -t "$q" 2>/dev/null; rm -f "$FLEET_STATE/orchestrator.pane" "$FLEET_STATE/orchestrator.config"
# A worker already on its preferred account has nowhere to move back to.
room_fresh; reading a Personal 10 5000
q=$(pane onpref '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none"}'); settle
printf '%s\tonpref\t%s\t%s\t/w\t%s\n' "$q" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
mark_limited a "$((noon + 86400))" seven
asked_on_record "$q" "$((noon + 300))" Personal
reply_live "$q" settled '[{"id": "w1", "kind": "bash"}]' "READY-TO-MOVE" "$((noon + 330))"
mover "$((noon + 360))"; mover "$((noon + 1300))"
check "#322 review 4: a worker on its preferred account gets no carry-on note when that account loses its room" \
  "$(grep -c '^SUBMIT The move back' "$work/onpref.log")" "0"
t kill-window -t "$q" 2>/dev/null; : >"$REGISTRY"
# A worker at a limit of its own waits for its reset, not for a note.
room_fresh; reading a Personal 10 5000
p=$(backpane ownlim); state ownlim '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none"}'
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "Watching." "$noon"
mover "$noon"; mover "$((noon + 300))"
mark_limited a "$((noon + 86400))" seven
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "READY-TO-MOVE" "$((noon + 330))"
state ownlim '{"above":["  ⎿  You'"'"'ve hit your session limit · resets 1:10pm (America/New_York)","",""],"on_submit":"none"}'
mover "$((noon + 360))"; mover "$((noon + 1300))"
check "#322 review 4: a worker at a limit of its own gets no carry-on note" \
  "$(grep -c '^SUBMIT The move back' "$work/ownlim.log")" "0"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"
# The limit hold and the pass's state go with it, as the cases below expect a fresh start.
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"; rm -rf -- "${FLEET_STATE:?}/limited"; rm -f -- "$FLEET_STATE/back-hold" "$FLEET_STATE/resume-state" "$FLEET_STATE/back-room-since"

# A turn that starts while the fresh session launches (a background task's
# notification) keeps the old pane.
cat >"$work/launch-turn.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$FLEET_ACCOUNT" "\$@" >"$work/moved"
jq '.turn_at = 999999999999' "$KLEPSYDRA_DIR/fleet/$SID.json" >"$work/st.json" && mv "$work/st.json" "$KLEPSYDRA_DIR/fleet/$SID.json"
echo "pane=%996 session=x account=\$FLEET_ACCOUNT avail=1MiB brief=started"
EOF
chmod +x "$work/launch-turn.sh"
: >"$FLEET_LOG"; : >"$work/moved"; rm -f "$FLEET_STATE/resume-state" "$FLEET_STATE/back-room-since"
p=$(backpane notified); state notified '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none"}'
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "Watching." "$noon"
mover "$noon"; mover "$((noon + 300))"
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "READY-TO-MOVE" "$((noon + 330))"
LAUNCH="$work/launch-turn.sh" FLEET_NOW=$((noon + 360)) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "#198 review 1: a turn begun during the launch keeps the old pane" \
  "$(logged "the old pane changed while its fresh session launched")$(grep -c 'SUBMIT /exit' "$work/notified.log")" "$p 0"
check "#322 review 3: and the stopped worker, now in a turn of its own, gets no carry-on note (4)" \
  "$(grep -c '^SUBMIT The move back' "$work/notified.log")" "0"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

# Room that goes away while the worker waits starts its 5 min again.
: >"$FLEET_LOG"; : >"$work/moved"; rm -f "$FLEET_STATE/resume-state" "$FLEET_STATE/back-room-since"
p=$(backpane flap); state flap '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none"}'
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "Watching." "$noon"
mover "$noon"
reading a Personal 60 5000; mover "$((noon + 100))"
reading a Personal 10 5000; mover "$((noon + 200))"; mover "$((noon + 320))"
check "#198 review 1: room that went away starts the 5 min again" "$(grep -c '^SUBMIT' "$work/flap.log")" "0"
mover "$((noon + 500))"
check "#198 review 1: and it is asked 5 min after room came back" "$(grep -c '^SUBMIT' "$work/flap.log")" "1"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

# Heph keeps his background work: he is never asked.
: >"$FLEET_LOG"; : >"$work/moved"; rm -f "$FLEET_STATE/resume-state" "$FLEET_STATE/back-room-since"
q=$(pane hephbg '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none","rc":"on"}'); settle
reply_live "$q" settled '[{"id": "w1", "kind": "bash"}]' "Watching." "$noon"
printf '%s\n' "$q" >"$FLEET_STATE/orchestrator.pane"; printf '%s\n' "$work/cfg-a" >"$FLEET_STATE/orchestrator.config"
# The first pass turns Remote Control on; the 5 min count from the second.
mover "$noon"; mover "$((noon + 300))"; mover "$((noon + 700))"; mover "$((noon + 800))"
check "#198 review 1: Heph with background work is never asked, once Remote Control is on" \
  "$(grep -c 'RC REQUESTED' "$work/hephbg.log") $(grep '^SUBMIT' "$work/hephbg.log" | grep -vc remote-control) $(wc -c <"$work/moved")" "1 0 0"
t kill-window -t "$q" 2>/dev/null; rm -f "$FLEET_STATE/orchestrator.pane" "$FLEET_STATE/orchestrator.config"

: >"$FLEET_LOG"; : >"$work/moved"; rm -f "$FLEET_STATE/resume-state" "$FLEET_STATE/back-room-since"
reading b RIT 80 4000
printf '%s\n' "$work/cfg-b" >"$FLEET_STATE/orchestrator.config"
p=$(backpane hurry); state hurry '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none"}'
reply_live "$p" settled '[{"id": "w1", "kind": "agent"}]' "Waiting on a subagent." "$noon"
mover "$noon"; mover "$((noon + 300))"
check "#198: urgent while it borrows Heph's account and that one has under 30% room" \
  "$(grep -c '^SUBMIT Urgent: Heph' "$work/hurry.log") $(jq -r 'select(.message | startswith("asked to save")) | .urgent' "$FLEET_LOG")" "1 1"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"
: >"$FLEET_LOG"; rm -f "$FLEET_STATE/resume-state" "$FLEET_STATE/back-room-since"
printf '%s\n' "$work/cfg-a" >"$FLEET_STATE/orchestrator.config"
p=$(backpane calm); state calm '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none"}'
reply_live "$p" settled '[{"id": "w1", "kind": "agent"}]' "Waiting on a subagent." "$noon"
mover "$noon"; mover "$((noon + 300))"
check "#198 review 1: not urgent once Heph runs on the other account" \
  "$(grep -c '^SUBMIT Your preferred' "$work/calm.log") $(jq -r 'select(.message | startswith("asked to save")) | .urgent' "$FLEET_LOG")" "1 0"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"; rm -f "$FLEET_STATE/orchestrator.config"
reading b RIT 10 4000

: >"$work/moved"; rm -f "$FLEET_STATE/resume-state" "$FLEET_STATE/back-room-since"
p=$(backpane typing); state typing '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none"}'
reply_live "$p" settled '[{"id": "w1", "kind": "bash"}]' "Watching." "$noon"
t send-keys -t "$p" -l "AJ: hold on"; settle
mover "$noon"; mover "$((noon + 300))"
check "#198: never asked over a line AJ is typing" "$(grep -c '^SUBMIT' "$work/typing.log")" "0"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

reading a Personal 60 5000
p=$(backpane low)
mover "$noon"; mover "$((noon + 60))"
check "not while the preferred account has under 50% room" "$(wc -c <"$work/moved")" "0"
t kill-window -t "$p"; : >"$REGISTRY"
reading a Personal 10 5000

launcher() { # NAME BRIEF-RESULT: a launch that counts its tries in $work/tries
  # shellcheck disable=SC2016 # $FLEET_ACCOUNT is the launcher's own, at its run
  printf '#!/usr/bin/env bash\necho try >>"%s"\necho "pane=%%995 session=x account=$FLEET_ACCOUNT avail=1MiB brief=%s"\n' "$work/tries" "$2" >"$work/$1"
}
launcher launch-fail.sh NOT-DELIVERED; launcher launch-limit.sh blocked-by-limit
failer() { LAUNCH="$work/${2:-launch-fail.sh}" FLEET_NOW=$1 bash "$here/resume-at-reset.sh" --once 2>/dev/null; } # NOW [LAUNCHER]
: >"$work/tries"; rm -f "$FLEET_STATE/back-hold"
p=$(backpane flaky)
failer "$noon"; failer "$((noon + 60))"; failer "$((noon + 120))"
check "a failed move back is not retried for 15 min, across service restarts" "$(wc -l <"$work/tries") $(grep -c '^SUBMIT' "$work/flaky.log")" "1 0"
failer "$((noon + 60 + 900))"
check "then it is, and a failure that is not a limit holds no account" "$(wc -l <"$work/tries") $([[ -e $FLEET_STATE/back-hold ]] && echo held)" "2 "
t kill-window -t "$p"; : >"$REGISTRY"

: >"$work/tries"; rm -f "$FLEET_STATE/resume-state"
p=$(backpane limited1)
failer "$noon" launch-limit.sh; failer "$((noon + 60))" launch-limit.sh
check "a move back the account answers with a limit holds the account" "$(wc -l <"$work/tries") $(cut -d' ' -f1 "$FLEET_STATE/back-hold")" "1 a"
t kill-window -t "$p"; : >"$REGISTRY"
p=$(backpane limited2)
failer "$((noon + 120))" launch-limit.sh; failer "$((noon + 180))" launch-limit.sh
check "review 1: so another pane does not try it until the account publishes a newer reading" "$(wc -l <"$work/tries")" "1"
reading a Personal 10 6000
failer "$((noon + 240))" launch-limit.sh
check "then it does" "$(wc -l <"$work/tries")" "2"
t kill-window -t "$p"; : >"$REGISTRY"
p=$(backpane limited3)
failer "$((noon + 300))" launch-limit.sh; failer "$((noon + 360))" launch-limit.sh
check "review 2: held again, with no newer reading" "$(wc -l <"$work/tries")" "2"
failer "$((noon + 240 + 1800))" launch-limit.sh
check "review 2: the hold lasts BACK_HOLD_S (30 min) at most, from its last refusal (noon + 240)" "$(wc -l <"$work/tries")" "3"
t kill-window -t "$p"; : >"$REGISTRY"; rm -f "$FLEET_STATE/back-hold" "$FLEET_STATE/resume-state"

: >"$work/tries"
p=$(backpane lagging); state lagging '{"above":["⏺ Done. done 11:50 AM"],"busy":true}'
failer "$noon"; failer "$((noon + 60))"
check "review 2: not while the screen shows a turn running, even if the session's file says done" "$(wc -l <"$work/tries")" "0"
t kill-window -t "$p"; : >"$REGISTRY"

: >"$FLEET_LOG"; rm -f "$FLEET_STATE/resume-state"
p=$(pane limback "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); settle
done_live "$p"
printf '%s\tlimback\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-b" >"$REGISTRY"
reading b RIT 100 4000
failer "$noon"
check "review 2: a limited pane is not moved back, its limit path takes it" "$(jq -r --arg p "$p" 'select(.pane == $p and (.message == "moved back to the preferred account" or .message == "could not move back to the preferred account; trying again later")) | .pane' "$FLEET_LOG") $(jq -r --arg p "$p" 'select(.message == "limit seen" and .pane == $p) | .pane' "$FLEET_LOG")" " $p"
t kill-window -t "$p"; : >"$REGISTRY"; reading b RIT 10 4000; rm -f "$FLEET_STATE/resume-state"

p=$(backpane away)
check "review 2: fleet doctor names a pane left away from its preferred account" \
  "$(bash "$here/doctor.sh" 2>/dev/null | grep 'preferred accounts' | cut -c1-61)" "warn preferred accounts: on another account while their own h"
reading a Personal 60 5000
check "and not while that account is short of room" "$(bash "$here/doctor.sh" 2>/dev/null | grep -c '^ok *preferred accounts')" "1"
reading a Personal 10 5000
t kill-window -t "$p"; : >"$REGISTRY"

: >"$FLEET_LOG"; rm -f "$FLEET_STATE/resume-state"
p=$(backpane phoned)
cat >"$work/launch-phoned.sh" <<EOF
#!/usr/bin/env bash
jq '.prompt.at = 5' "$KLEPSYDRA_DIR/fleet/$SID.json" >"$work/st.json" && mv "$work/st.json" "$KLEPSYDRA_DIR/fleet/$SID.json"
echo "pane=%995 session=x account=\$FLEET_ACCOUNT avail=1MiB brief=started"
EOF
LAUNCH="$work/launch-phoned.sh" FLEET_NOW=$noon bash "$here/resume-at-reset.sh" --once 2>/dev/null
LAUNCH="$work/launch-phoned.sh" FLEET_NOW=$((noon + 60)) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "review 2: a prompt the worker took during its move back (a phone message) keeps the old pane" \
  "$(grep -c 'SUBMIT /exit' "$work/phoned.log") $(jq -r --arg p "$p" 'select(.message | startswith("the old pane changed while")) | .pane' "$FLEET_LOG") $(cut -f1 "$REGISTRY")" "0 $p $p"
t kill-window -t "$p"; : >"$REGISTRY"; rm -f "$FLEET_STATE/resume-state"

echo "two accounts: Heph's preferred account is the other end (#175)"
: >"$work/moved"; : >"$FLEET_LOG"; rm -f "$FLEET_STATE/orchestrator.session" "$FLEET_STATE/resume-state"
printf '%s\n' "$work/cfg-a" >"$FLEET_STATE/orchestrator.config"
h=$(pane hephback '{"above":["⏺ Done. done 11:50 AM"]}'); settle
printf '%s\n' "$h" >"$FLEET_STATE/orchestrator.pane"; done_live "$h"
hmove "$noon"; hmove "$((noon + 60))"
check "Heph on the workers' first account moves back to his own, the last, once it has room, at a finished turn" \
  "$(head -2 "$work/moved" | tr '\n' ' ')$(cat "$FLEET_STATE/orchestrator.config") $(grep -c 'moved back to its preferred account, RIT' "$work/moved-brief")" "$work/cfg-b heph $work/cfg-b 1"
check "logged as the orchestrator's" "$(jq -r 'select(.message == "moved back to the preferred account") | .orchestrator' "$FLEET_LOG")" "1"
t kill-window -t "$h" 2>/dev/null
: >"$work/moved"; rm -f "$FLEET_STATE/orchestrator.session" "$FLEET_STATE/resume-state"
printf '%s\n' "$work/cfg-b" >"$FLEET_STATE/orchestrator.config"
h=$(pane hephhome '{"above":["⏺ Done. done 11:50 AM"]}'); settle
printf '%s\n' "$h" >"$FLEET_STATE/orchestrator.pane"; done_live "$h"
hmove "$noon"; hmove "$((noon + 60))"
check "Heph already on his own account stays" "$(wc -c <"$work/moved")" "0"
t kill-window -t "$h" 2>/dev/null

echo "two accounts: Heph's pane watcher never holds his move back (#215)"
heph_away() { # BACKGROUND-JSON: Heph on the workers' account, his turn over with that background work
  : >"$work/moved"; : >"$FLEET_LOG"; rm -f "$FLEET_STATE/orchestrator.session" "$FLEET_STATE/resume-state"
  printf '%s\n' "$work/cfg-a" >"$FLEET_STATE/orchestrator.config"
  h=$(pane hephwatch '{"above":["⏺ Done. done 11:50 AM"]}'); settle
  printf '%s\n' "$h" >"$FLEET_STATE/orchestrator.pane"; done_live "$h" working "$1"
  jq '.reason = "background"' "$KLEPSYDRA_DIR/fleet/$SID.json" >"$work/st.json" && mv "$work/st.json" "$KLEPSYDRA_DIR/fleet/$SID.json"
}
w=$(pane watched '{"above":["⏺ ok"]}'); settle
w2=$(pane watched2 '{"above":["⏺ ok"]}'); settle
printf '%s\tw\t%s\tsid-w\t/w\t%s\n%s\tw2\t%s\tsid-w2\t/w\t%s\n' "$w" "$work/brief.src" "$work/cfg-b" "$w2" "$work/brief.src" "$work/cfg-b" >"$REGISTRY"
heph_away "[{\"id\":\"b1\",\"kind\":\"shell\",\"at\":1,\"watcher\":true,\"watch\":[\"$w2\",\"%9999\"]}]"
hmove "$noon"; hmove "$((noon + 60))"
check "Heph whose only background work is his pane watcher moves back at a finished turn" \
  "$(head -2 "$work/moved" | tr '\n' ' ')$(cat "$FLEET_STATE/orchestrator.config")" "$work/cfg-b heph $work/cfg-b"
check "and his successor is told to start the watcher again on the panes it watched that are still live" \
  "$(grep -c "^The last orchestrator's pane watcher stopped with its session. Start it again in the background now: bash $FLEET_STATE/watch-panes.sh $w2\$" "$work/moved-brief")" "1"
check "the note's watcher line is logged with its panes and where they came from" \
  "$(jq -r 'select(.message == "orchestrator move note written") | "\(.watchers) \(.watch_panes) \(.panes_from)"' "$FLEET_LOG" | head -1)" "1 $w2 watched"
t kill-window -t "$h" 2>/dev/null
heph_away '[{"id":"b1","kind":"shell","at":1,"watcher":true}]'
hmove "$noon"; hmove "$((noon + 60))"
check "#215 review: a watcher recorded before its panes were: every live registered pane" \
  "$(jq -r 'select(.message == "orchestrator move note written") | "\(.watch_panes) \(.panes_from)"' "$FLEET_LOG" | head -1)" "$w $w2 registered"
t kill-window -t "$h" 2>/dev/null
heph_away '[{"id":"b1","kind":"shell","at":1,"watcher":true},{"id":"b2","kind":"shell","at":2}]'
hmove "$noon"; hmove "$((noon + 60))"; hmove "$((noon + 120))"
check "a watcher beside other background work keeps Heph where he is" "$(wc -c <"$work/moved") $(cat "$FLEET_STATE/orchestrator.config")" "0 $work/cfg-a"
check "logged once an hour, with what held him" \
  "$(jq -r 'select(.message == "orchestrator stays: background work other than pane watchers is running") | "\(.watchers) \(.to)"' "$FLEET_LOG")" "1 RIT"
hmove "$((noon + 3700))"
check "#215 review: and again once the hour has passed" \
  "$(jq -r 'select(.message == "orchestrator stays: background work other than pane watchers is running") | .pane' "$FLEET_LOG" | wc -l)" "2"
t kill-window -t "$h" 2>/dev/null
heph_away '[{"id":"a1","kind":"agent","at":1,"async":true,"watcher":true}]'
hmove "$noon"; hmove "$((noon + 60))"
check "a background agent is never taken for a watcher" "$(wc -c <"$work/moved")" "0"
t kill-window -t "$h" 2>/dev/null; t kill-window -t "$w" 2>/dev/null; t kill-window -t "$w2" 2>/dev/null; : >"$REGISTRY"
rm -f "$FLEET_STATE/orchestrator."* "$FLEET_STATE/resume-state" "$KLEPSYDRA_DIR/fleet/$SID.json"
logout a; logout b; reading a Personal 40 1000; rm -f "$KLEPSYDRA_DIR/accounts/b/s.json"

echo "two accounts: review round 1"
login a; login b; reading a Personal 100 5000; reading b RIT 10 4000
: >"$FLEET_LOG"; : >"$work/moved"
p=$(pane rb "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\trb\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
cat >"$work/launch-rb.sh" <<EOF
#!/usr/bin/env bash
# A move launch during which AJ types into the old pane; it repoints the row, account too, as launch.sh does.
tmux -L "$FLEET_SOCK" send-keys -t "$p" -l "AJ: wait"
sleep 1
sed -i "s|^$p\t\(.*\)\t$work/cfg-a\$|%995\t\1\t$work/cfg-b|" "$REGISTRY"
echo "pane=%995 session=x account=$work/cfg-b avail=1MiB brief=started"
EOF
LAUNCH="$work/launch-rb.sh" FLEET_NOW=$noon bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "review 2: a move AJ undid points the row back at the old pane and its own account" "$(cut -f1,4,6 "$REGISTRY")" "$p	$SID	$work/cfg-a"
: >"$work/moved"
LAUNCH="$work/launch-move.sh" FLEET_NOW=$((noon + 60)) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "review 5: and it waits before launching again" "$(wc -c <"$work/moved")" "0"
t kill-window -t "$p"; : >"$REGISTRY"

: >"$FLEET_LOG"
p=$(pane nd "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tnd\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
printf '%s' '{"above":["Claude Code"]}' >"$work/ndnew.json"; : >"$work/ndnew.log"
cat >"$work/launch-nd.sh" <<EOF
#!/usr/bin/env bash
new=\$(tmux -L "$FLEET_SOCK" new-window -d -P -F '#{pane_id}' -t fleet: "python3 -I $fake $work/ndnew.json $work/ndnew.log")
sed -i "s|^$p\t\(.*\)\t$work/cfg-a\$|\$new\t\1\t$work/cfg-b|" "$REGISTRY"
echo "pane=\$new session=x account=$work/cfg-b avail=1MiB brief=NOT-DELIVERED"
EOF
t send-keys -t "$p" -l "AJ: keep this"; settle
resume "$noon"
LAUNCH="$work/launch-nd.sh" FLEET_NOW=$((noon + 60)) bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "review 3: a brief that never started leaves the old pane, AJ's line and the row as they were" \
  "$(grep -c '^SUBMIT' "$work/nd.log") [$(input_text "$(screen "$p")")] $(cut -f1,6 "$REGISTRY")" "0 [AJ: keep this] $p	$work/cfg-a"
check "and the new pane is exited" "$(grep -c 'SUBMIT /exit' "$work/ndnew.log")" "1"
t kill-window -t "$p"; : >"$REGISTRY"

: >"$FLEET_LOG"; : >"$work/moved"
p=$(pane sentit "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tsentit\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
t send-keys -t "$p" -l "AJ: do the footer"; settle
FLEET_NOW=$noon MOVE_MIN_S=999999 bash "$here/resume-at-reset.sh" --once 2>/dev/null
state sentit "{\"above\":[\"⏺ Done. done 11:50 AM\",\"❯ AJ: do the footer\",\"$LIMIT\"],\"clear\":true}"
mover "$((noon + 60))"
check "review 4: a line AJ sent into the limit is carried: the session never acted on it" "$(grep -c '^AJ: do the footer$' "$work/moved-brief")" "1"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

: >"$FLEET_LOG"; : >"$work/moved"
p=$(pane pasted "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tpasted\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
t load-buffer -b x "$work/three.txt"; t paste-buffer -p -d -b x -t "$p"; settle
mover "$noon"; mover "$((noon + 60))"
check "review 4: a pasted block is not moved, and the log says why" "$(wc -c <"$work/moved") $(logged 'pasted block cannot be carried' | wc -w)" "0 1"
t kill-window -t "$p"; : >"$REGISTRY"

: >"$FLEET_LOG"; : >"$work/moved"
p=$(pane between "{\"above\":[\"⏺ Done. done 11:50 AM\",\"❯ AJ: sent between two passes\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tbetween\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
mover "$noon"
check "review 2, 4: a line AJ sent between two passes, answered only by the limit, is carried" "$(grep -c '^AJ: sent between two passes$' "$work/moved-brief")" "1"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

: >"$FLEET_LOG"; : >"$work/moved"
p=$(pane midpaste "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tmidpaste\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
t send-keys -t "$p" -l "see "; t load-buffer -b x "$work/three.txt"; t paste-buffer -p -d -b x -t "$p"; settle
mover "$noon"; mover "$((noon + 60))"
check "review 2, 4: a paste in the middle of a line is not moved either" "$(wc -c <"$work/moved") $(logged 'pasted block cannot be carried' | wc -w)" "0 1"
t kill-window -t "$p"; : >"$REGISTRY"

: >"$FLEET_LOG"; : >"$work/moved"
p=$(pane pastesent "{\"above\":[\"⏺ Done. done 11:50 AM\",\"❯ [Pasted text #1 +3 lines]\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tpastesent\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
mover "$noon"
check "review 4: a paste AJ sent into the limit keeps the pane for its reset" "$(wc -c <"$work/moved") $(events pastesent | grep -c 'SUBMIT /exit')" "0 0"
t kill-window -t "$p"; : >"$REGISTRY"

: >"$FLEET_LOG"
p=$(pane stuck "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tstuck\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
printf '%s' '{"above":["Claude Code"],"input":"the brief, pasted and never sent"}' >"$work/stucknew.json"; : >"$work/stucknew.log"
cat >"$work/launch-stuck.sh" <<EOF
#!/usr/bin/env bash
new=\$(tmux -L "$FLEET_SOCK" new-window -d -P -F '#{pane_id}' -t fleet: "python3 -I $fake $work/stucknew.json $work/stucknew.log")
sed -i "s|^$p\t\(.*\)\t$work/cfg-a\$|\$new\t\1\t$work/cfg-b|" "$REGISTRY"
echo "pane=\$new session=x account=$work/cfg-b avail=1MiB brief=NOT-DELIVERED"
EOF
LAUNCH="$work/launch-stuck.sh" FLEET_NOW=$noon bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "review 2C: a new pane whose brief sits unsent in its box is cleared and exited, never left running" "$(grep -c 'SUBMIT /exit' "$work/stucknew.log") $(grep -c 'SUBMIT the brief' "$work/stucknew.log")" "1 0"
t kill-window -t "$p"; : >"$REGISTRY"
logout a; logout b; reading a Personal 40 1000; rm -f "$KLEPSYDRA_DIR/accounts/b/s.json"

echo "two accounts: moves side by side, retried, and before the limit (#187)"
login a; login b; reading a Personal 100 5000; reading b RIT 10 4000
: >"$FLEET_LOG"; : >"$work/par-starts"; rm -f "$FLEET_STATE/resume-state"
SID2=22222222-2222-4333-8444-555555555555
p1=$(pane par1 "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); p2=$(pane par2 "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); settle
live "$p1"; jq -n --arg p "$p2" '{session_id: "y", ended: null, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/$SID2.json"
printf '%s\tpar1\t%s\t%s\t/w\t%s\n%s\tpar2\t%s\t%s\t/w\t%s\n' "$p1" "$work/brief.src" "$SID" "$work/cfg-a" "$p2" "$work/brief.src" "$SID2" "$work/cfg-a" >"$REGISTRY"
cat >"$work/launch-par.sh" <<EOF
#!/usr/bin/env bash
# A launch that takes 5 s, as a slow start would.
date +%s.%N >>"$work/par-starts"
sleep 5
echo "pane=%99\$\$ session=x account=\$FLEET_ACCOUNT avail=1MiB brief=started"
EOF
LAUNCH="$work/launch-par.sh" FLEET_NOW=$noon bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "#187: two limited panes start their moves in one pass, side by side" \
  "$(wc -l <"$work/par-starts") $(sort -n "$work/par-starts" | awk 'NR == 1 { a = $1 } END { print ($1 - a < 3) }')" "2 1"
check "and both are moved" "$(logged 'moved to the other account at a limit' | wc -w)" "2"
t kill-window -t "$p1" 2>/dev/null; t kill-window -t "$p2" 2>/dev/null; rm -f "$KLEPSYDRA_DIR/fleet/$SID2.json"; : >"$REGISTRY"

: >"$FLEET_LOG"; : >"$work/moved"; : >"$work/nd2-calls"; rm -f "$FLEET_STATE/resume-state"
p=$(pane retry "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tretry\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
printf '%s' '{"above":["Claude Code"]}' >"$work/ndnew.json"; : >"$work/ndnew.log"
nd2() { # a launch for pane $p whose brief never starts: it opens a pane, repoints the row, says NOT-DELIVERED
  cat >"$work/launch-nd2.sh" <<EOF
#!/usr/bin/env bash
echo x >>"$work/nd2-calls"
new=\$(tmux -L "$FLEET_SOCK" new-window -d -P -F '#{pane_id}' -t fleet: "python3 -I $fake $work/ndnew.json $work/ndnew.log")
sed -i "s|^$p\t\(.*\)\t$work/cfg-a\$|\$new\t\1\t$work/cfg-b|" "$REGISTRY"
echo "pane=\$new session=x account=$work/cfg-b avail=1MiB brief=NOT-DELIVERED"
EOF
}
nd2
LAUNCH="$work/launch-nd2.sh" FLEET_NOW=$noon bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "#187: a move whose brief never started is tried again at the next pass" "$(logged 'trying again next pass' | wc -w)" "1"
mover "$((noon + 60))"
check "and that try moves it" "$(head -2 "$work/moved" | tr '\n' ' ')" "$work/cfg-b retry "
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

: >"$FLEET_LOG"; : >"$work/moved"; : >"$work/nd2-calls"; rm -f "$FLEET_STATE/resume-state"
p=$(pane retry "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tretry\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
nd2
LAUNCH="$work/launch-nd2.sh" FLEET_NOW=$noon bash "$here/resume-at-reset.sh" --once 2>/dev/null
LAUNCH="$work/launch-nd2.sh" FLEET_NOW=$((noon + 60)) bash "$here/resume-at-reset.sh" --once 2>/dev/null
mover "$((noon + 120))"
check "two failures in a row wait 15 min before the next try" "$(wc -l <"$work/nd2-calls") $(wc -c <"$work/moved") $(logged 'trying again in 15 min' | wc -w)" "2 0 1"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

: >"$FLEET_LOG"; : >"$work/moved"; rm -f "$FLEET_STATE/resume-state"
reading a Personal 96 5000
p=$(pane pre '{"above":["⏺ Done. done 11:50 AM"]}'); settle
done_live "$p"
printf '%s\tpre\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
mover "$noon"; mover "$((noon + 60))"
check "#187: a worker whose account has used 96% moves at a finished turn, before the limit" "$(head -2 "$work/moved" | tr '\n' ' ')" "$work/cfg-b pre "
check "its brief says why" "$(grep -c 'was near its usage limit on one account (4% of its five-hour window left)' "$work/moved-brief")" "1"
check "logged" "$(logged 'moved before the limit')" "$p "
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

: >"$work/moved"; rm -f "$FLEET_STATE/resume-state"
p=$(pane prebusy '{"above":["⏺ working"],"busy":true}'); settle
done_live "$p" working
printf '%s\tprebusy\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
mover "$noon"; mover "$((noon + 60))"
check "not while its turn runs" "$(wc -c <"$work/moved") $(grep -cE 'ESC|INTERRUPTED|SUBMIT' "$work/prebusy.log")" "0 0"
t kill-window -t "$p"; : >"$REGISTRY"

: >"$work/moved"; rm -f "$FLEET_STATE/resume-state"
p=$(pane pretyped '{"above":["⏺ Done. done 11:50 AM"]}'); settle
done_live "$p"
printf '%s\tpretyped\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
t send-keys -t "$p" -l "AJ: half a thought"; settle
mover "$noon"; mover "$((noon + 60))"
check "nor over a line AJ is typing" "$(wc -c <"$work/moved") [$(input_text "$(screen "$p")")]" "0 [AJ: half a thought]"
t kill-window -t "$p"; : >"$REGISTRY"

: >"$work/moved"; rm -f "$FLEET_STATE/resume-state"
reading a Personal 90 5000
p=$(pane prelow '{"above":["⏺ Done. done 11:50 AM"]}'); settle
done_live "$p"
printf '%s\tprelow\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
mover "$noon"; mover "$((noon + 60))"
check "nor at 90% used" "$(wc -c <"$work/moved")" "0"
t kill-window -t "$p"; : >"$REGISTRY"

: >"$FLEET_LOG"; : >"$work/par-starts"; rm -f "$FLEET_STATE/resume-state"
p=$(pane marked "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"],\"exit_on_exit\":true}"); settle
live "$p"
printf '%s\tmarked\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
mkdir -p "$FLEET_STATE/launching"; : >"$FLEET_STATE/launching/$p"
LAUNCH="$work/launch-par.sh" FLEET_NOW=$noon bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "review 1: a pane still being started (launching/ mark) is left alone" "$(wc -l <"$work/par-starts") $(has " $(logged 'limit seen')" " $p ")" "0 no"
rm -f "$FLEET_STATE/launching/$p"
cat >"$work/launch-slow3.sh" <<EOF
#!/usr/bin/env bash
date +%s.%N >>"$work/par-starts"
sleep 3
echo "pane=%99\$\$ session=x account=\$FLEET_ACCOUNT avail=1MiB brief=started"
EOF
LAUNCH="$work/launch-slow3.sh" FLEET_NOW=$noon POLL_S=1 timeout 40 bash "$here/resume-at-reset.sh" 2>/dev/null &
svc=$!
for _ in $(seq 60); do [[ -n $(logged 'moved to the other account at a limit') ]] && break; sleep 0.5; done
sleep 2.5 # two more passes, which must not launch again
kill "$svc" 2>/dev/null; wait "$svc" 2>/dev/null
check "review 1: passes while its move runs leave the pane alone: one launch, then moved" \
  "$(wc -l <"$work/par-starts") $(logged 'moved to the other account at a limit' | wc -w)" "1 1"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

: >"$FLEET_LOG"; : >"$work/par-starts"; rm -f "$FLEET_STATE/resume-state"
SID3=33333333-2222-4333-8444-555555555555
q1=$(pane cap1 "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"],\"exit_on_exit\":true}"); q2=$(pane cap2 "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"],\"exit_on_exit\":true}"); q3=$(pane cap3 "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"],\"exit_on_exit\":true}"); settle
live "$q1"
jq -n --arg p "$q2" '{session_id: "y", ended: null, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/$SID2.json"
jq -n --arg p "$q3" '{session_id: "z", ended: null, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/$SID3.json"
printf '%s\tcap1\t%s\t%s\t/w\t%s\n%s\tcap2\t%s\t%s\t/w\t%s\n%s\tcap3\t%s\t%s\t/w\t%s\n' \
  "$q1" "$work/brief.src" "$SID" "$work/cfg-a" "$q2" "$work/brief.src" "$SID2" "$work/cfg-a" "$q3" "$work/brief.src" "$SID3" "$work/cfg-a" >"$REGISTRY"
LAUNCH="$work/launch-slow3.sh" FLEET_NOW=$noon bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "review 1: at most two moves at once (each starts a session beside the old); the third waits a pass" \
  "$(wc -l <"$work/par-starts") $(logged 'move put off to a later pass' | wc -w)" "2 1"
for q in "$q1" "$q2" "$q3"; do t kill-window -t "$q" 2>/dev/null; done
rm -f "$KLEPSYDRA_DIR/fleet/$SID2.json" "$KLEPSYDRA_DIR/fleet/$SID3.json"; : >"$REGISTRY"

: >"$FLEET_LOG"; : >"$work/nd2-calls"; rm -f "$FLEET_STATE/resume-state"
p=$(pane cadence "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\tcadence\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
nd2
for at in 0 60 120 960 1020 1080; do
  LAUNCH="$work/launch-nd2.sh" FLEET_NOW=$((noon + at)) bash "$here/resume-at-reset.sh" --once 2>/dev/null
done
check "review 2: a move that keeps failing is tried, tried again the next pass, then once every 15 min" "$(wc -l <"$work/nd2-calls")" "3"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

: >"$FLEET_LOG"; rm -f "$FLEET_STATE/resume-state"
p=$(pane leftover '{"above":["⏺ Done. done 11:50 AM"]}'); settle
mkdir -p "$FLEET_STATE/moves"
server=$(t display-message -p '#{pid}')
printf '3\t\n' >"$FLEET_STATE/moves/${p#%}.out"
printf '%s\x1fidle\x1fleftover\x1f60\x1fPersonal\x1f\n' "999999$server" >"$FLEET_STATE/moves/${p#%}.ctx"
FLEET_NOW=$noon bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "review 2: a move's result from another tmux server is dropped, its pane left alone" \
  "$(grep -c '^SUBMIT' "$work/leftover.log") $(find "$FLEET_STATE/moves" -name "${p#%}.*" | wc -l) $(logged 'from another tmux server' | wc -w)" "0 0 1"
printf '3\t\n' >"$FLEET_STATE/moves/${p#%}.out"
printf '%s\x1fidle\x1fleftover\x1f60\x1fPersonal\x1f\n' "$server" >"$FLEET_STATE/moves/${p#%}.ctx"
FLEET_NOW=$noon bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "and one from this server is applied: the failed fresh start is resumed in place" "$(has "$(events leftover)" "SUBMIT The usage limit has reset.")" "yes"
t kill-window -t "$p" 2>/dev/null

: >"$FLEET_LOG"; : >"$work/moved"; rm -f "$FLEET_STATE/resume-state"
p=$(pane heldto "{\"above\":[\"⏺ Done. done 11:50 AM\",\"$LIMIT\"]}"); settle
live "$p"
printf '%s\theldto\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
printf 'b %s %s\n' "$(find "$KLEPSYDRA_DIR/accounts/b/s.json" -printf '%T@')" "$noon" >"$FLEET_STATE/back-hold"
mover "$noon"
check "review 2: an account held after it answered a move with a limit takes no limit move either" "$(wc -c <"$work/moved")" "0"
rm -f "$FLEET_STATE/back-hold"; t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"
logout a; logout b; reading a Personal 40 1000; rm -f "$KLEPSYDRA_DIR/accounts/b/s.json"

echo "two accounts: review round 3"
st() { state abl "{\"above\":$1}"; screen "$abl"; }
abl=$(pane abl '{"above":["x"]}'); settle
check "the line the last limit answered" "$(answered_by_limit "$(st "[\"⏺ ok\",\"❯ AJ: fix the README\",\"$LIMIT\"]")")" "AJ: fix the README"
check "review 3: not a line an earlier limit answered and the session acted on since" \
  "[$(answered_by_limit "$(st "[\"❯ AJ: fix the README\",\"$LIMIT\",\"❯ AJ: go on\",\"⏺ working on it\",\"$LIMIT\"]")")]" "[]"
check "review 3: not the service's own continue message" \
  "[$(answered_by_limit "$(st "[\"⏺ ok\",\"❯ The usage limit has reset. Continue from where you stopped\",\"$LIMIT\"]")")]" "[]"
check "review 3: not a brief that hit the limit; a paste comes back as its placeholder, so the pane waits" \
  "[$(answered_by_limit "$(st "[\"❯ Fresh start: a previous agent with the brief below\",\"$LIMIT\"]")")][$(answered_by_limit "$(st "[\"❯ [Pasted text #1 +40 lines]\",\"$LIMIT\"]")")]" "[][[Pasted text #1 +40 lines]]"
if command -v mawk >/dev/null; then
  mkdir -p "$work/mawk"; ln -sf "$(command -v mawk)" "$work/mawk/awk"
  check "#265 review: under mawk too, the line the 5-hour limit answered" \
    "$(PATH="$work/mawk:$PATH" answered_by_limit "$(st '["❯ please fix the bug","  ⎿  You'"'"'ve hit your 5-hour limit · resets 12:40pm"]')")" "please fix the bug"
fi
t kill-window -t "$abl"

: >"$FLEET_LOG"
p=$(pane relold '{"above":["idle"]}'); settle
live "$p"
printf '%s\trel\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
printf '%s' '{"above":["Claude Code"],"input":"the brief, never sent"}' >"$work/relnew.json"; : >"$work/relnew.log"
cat >"$work/launch-rel.sh" <<EOF
#!/usr/bin/env bash
new=\$(tmux -L "$FLEET_SOCK" new-window -d -P -F '#{pane_id}' -t fleet: "python3 -I $fake $work/relnew.json $work/relnew.log")
sed -i "s|^$p\t\(.*\)\t$work/cfg-a\$|\$new\t\1\t$work/cfg-b|" "$REGISTRY"
echo "pane=\$new session=x account=$work/cfg-b avail=1MiB brief=NOT-DELIVERED"
EOF
LAUNCH="$work/launch-rel.sh" bash "$here/relaunch-fresh.sh" "$p" rel "$work/brief.src" "hint" >/dev/null 2>&1; rc=$?
check "review 3: a relaunch whose brief never started keeps the old pane, points the row back and exits the new one" \
  "$rc $(cut -f1,4,6 "$REGISTRY") $(grep -c 'SUBMIT /exit' "$work/relnew.log") $(grep -c '^SUBMIT' "$work/relold.log")" "1 $p	$SID	$work/cfg-a 1 0"
t kill-window -t "$p"; : >"$REGISTRY"
# #229 review: a relaunch whose old pane AJ was watching puts the new one in view.
p=$(pane relview '{"above":["idle"],"exit_on_exit":true}'); settle
live "$p"
printf '%s\trelv\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
cat >"$work/launch-relv.sh" <<EOF
#!/usr/bin/env bash
new=\$(tmux -L "$FLEET_SOCK" new-window -d -P -F '#{pane_id}' -t fleet: 'sleep 600')
echo "\$new" >"$work/relv.new"
echo "pane=\$new session=x account=$work/cfg-a avail=1MiB brief=started"
EOF
t select-window -t "$p"
LAUNCH="$work/launch-relv.sh" bash "$here/relaunch-fresh.sh" "$p" relv "$work/brief.src" "hint" >/dev/null 2>&1
check "#229 review: a relaunch of the window AJ watched leaves its successor in view" \
  "$(fleet_panes | grep -cx -- "$p") $(t display -p -t fleet: '#{pane_id}')" "0 $(cat "$work/relv.new")"
t kill-window -t "$(cat "$work/relv.new")" 2>/dev/null; rm -f -- "${KLEPSYDRA_DIR:?}/fleet/$SID.json"; : >"$REGISTRY"
# ...and one while AJ watched another window leaves him there.
p=$(pane relview2 '{"above":["idle"],"exit_on_exit":true}'); settle
live "$p"
printf '%s\trelv\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
other=$(t new-window -P -F '#{pane_id}' -t fleet: 'sleep 600')
LAUNCH="$work/launch-relv.sh" bash "$here/relaunch-fresh.sh" "$p" relv "$work/brief.src" "hint" >/dev/null 2>&1
check "#229 review: a relaunch while AJ watched another window leaves him there" \
  "$(fleet_panes | grep -cx -- "$p") $(fleet_panes | grep -cx -- "$(cat "$work/relv.new")") $(t display -p -t fleet: '#{pane_id}')" "0 1 $other"
t kill-window -t "$(cat "$work/relv.new")" 2>/dev/null; t kill-window -t "$other" 2>/dev/null
rm -f -- "${KLEPSYDRA_DIR:?}/fleet/$SID.json"; : >"$REGISTRY"

# #229 review 2: the successor is in view before the old window closes, so a
# sibling replacement never reads the window tmux falls back to as watched.
p=$(pane relview3 '{"above":["idle"],"exit_on_exit":true,"exit_delay":3}'); settle
live "$p"
printf '%s\trelv\t%s\t%s\t/w\t%s\n' "$p" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
t select-window -t "$p"
rm -f -- "$work/relv.new"
( LAUNCH="$work/launch-relv.sh" bash "$here/relaunch-fresh.sh" "$p" relv "$work/brief.src" "hint" >/dev/null 2>&1 ) &
relpid=$!
for _ in $(seq 100); do grep -q 'SUBMIT /exit' "$work/relview3.log" 2>/dev/null && break; sleep 0.1; done
check "#229 review 2: while the old pane is still exiting, its successor is already in view" \
  "$(fleet_panes | grep -cx -- "$p") $(t display -p -t fleet: '#{pane_id}')" "1 $(cat "$work/relv.new" 2>/dev/null)"
wait "$relpid"
t kill-window -t "$(cat "$work/relv.new")" 2>/dev/null
rm -f -- "${KLEPSYDRA_DIR:?}/fleet/$SID.json"; : >"$REGISTRY"

# #229 review 3: an OLD that will not exit comes back into view only while its
# successor still is: AJ who moved on meanwhile stays where he went.
stuck() { # MOVE(0|1): retire_into a pane that never takes /exit, AJ moving away after 1 s or not
  local o n c rp
  o=$(t new-window -d -P -F '#{pane_id}' -t fleet: 'sleep 600')
  n=$(t new-window -d -P -F '#{pane_id}' -t fleet: 'sleep 600')
  c=$(t new-window -d -P -F '#{pane_id}' -t fleet: 'sleep 600')
  t select-window -t "$o"
  ( retire_into "$o" "$n"; echo "$?" >"$work/stuck.rc" ) & rp=$!
  if (( $1 )); then sleep 1; t select-window -t "$c"; fi
  wait "$rp"
  printf '%s %s' "$(cat "$work/stuck.rc")" "$(t display -p -t fleet: '#{pane_id}')"
  printf ' %s %s %s' "$o" "$n" "$c" >"$work/stuck.ids"
  t kill-window -t "$o"; t kill-window -t "$n"; t kill-window -t "$c"
}
got=$(stuck 1); read -r _ _ c <"$work/stuck.ids"
check "#229 review 3: AJ who moved on while the old pane would not exit stays where he went" "$got" "1 $c"
got=$(stuck 0); read -r o _ _ <"$work/stuck.ids"
check "#229 review 3: AJ who stayed gets the old pane back when it will not exit" "$got" "1 $o"

echo "relaunch never leaves two agents on one row (#274)"
relpane() { # STATE-JSON: a registered pane rb2 on cfg-a; prints its id
  local q
  q=$(pane rb2 "$1"); settle
  live "$q"
  printf '%s\trb2\t%s\t%s\t/w\t%s\n' "$q" "$work/brief.src" "$SID" "$work/cfg-a" >"$REGISTRY"
  printf '%s' "$q"
}
# A launch that starts a pane whose brief started, repointing the row as launch.sh
# does; BEFORE runs first (to change the old pane mid-launch).
cat >"$work/launch-rb2.sh" <<EOF
#!/usr/bin/env bash
date +%s.%N >>"$work/rb2-launched"
[[ -n \${BEFORE:-} ]] && eval "\$BEFORE"
printf '%s' '{"above":["⏺ on it"]}' >"$work/rb2new.json"; : >"$work/rb2new.log"
new=\$(tmux -L "$FLEET_SOCK" new-window -d -P -F '#{pane_id}' -t fleet: "python3 -I $fake $work/rb2new.json $work/rb2new.log")
sed -i "s|^\$OLD\t\(.*\)\t$work/cfg-a\$|\$new\t\1\t$work/cfg-a|" "$REGISTRY"
echo "pane=\$new session=x account=$work/cfg-a avail=1MiB brief=started"
EOF
: >"$FLEET_LOG"; rm -f "$work/rb2-launched"
p=$(relpane '{"above":["⏺ working"],"busy":true}')
RELAUNCH_WAIT_S=2 OLD=$p LAUNCH="$work/launch-rb2.sh" bash "$here/relaunch-fresh.sh" "$p" rb2 "$work/brief.src" "hint" >/dev/null 2>&1; rc=$?
check "#274: a pane still in a turn after the wait is refused and nothing launches" \
  "$rc $([[ -e $work/rb2-launched ]] && echo launched) $(cut -f1 "$REGISTRY") $(grep -c 'SUBMIT /exit' "$work/rb2.log")" "1  $p 0"
check "#274: logged with how long it waited" "$(jq -r 'select(.message == "relaunch refused: the old pane was still busy; nothing launched") | "\(.pane) \(.waited_s)"' "$FLEET_LOG")" "$p 2"
t kill-window -t "$p"
: >"$FLEET_LOG"; rm -f "$work/rb2-launched"
p=$(relpane '{"above":["⏺ working"],"busy":true}')
( sleep 1.5; printf '%s' '{"above":["⏺ Done. done 11:50 AM"]}' >"$work/rb2.json" ) &
RELAUNCH_WAIT_S=20 OLD=$p LAUNCH="$work/launch-rb2.sh" bash "$here/relaunch-fresh.sh" "$p" rb2 "$work/brief.src" "carry on" >"$work/rb2.out" 2>/dev/null; rc=$?
wait
newp=$(cut -f1 "$REGISTRY")
check "#274: a turn that ends within the wait: one launch, the old pane exits, the row moves" \
  "$rc $(wc -l <"$work/rb2-launched") $(grep -c 'SUBMIT /exit' "$work/rb2.log") $([[ $newp != "$p" ]] && echo moved) $(cat "$work/rb2.out")" "0 1 1 moved pane=$newp name=rb2"
check "#274: the new brief carries the resume hint" "$(grep -c '^Resume hint: carry on$' "$(find "$FLEET_STATE" -maxdepth 1 -name 'fresh-rb2-*.src' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)")" "1"
t kill-window -t "$newp" 2>/dev/null; t kill-window -t "$p" 2>/dev/null
: >"$FLEET_LOG"; rm -f "$work/rb2-launched"
p=$(relpane '{"above":["⏺ Done. done 11:50 AM"]}')
BEFORE="printf '%s' '{\"above\":[\"⏺ working\"],\"busy\":true}' >$work/rb2.json; sleep 0.6" \
  OLD=$p LAUNCH="$work/launch-rb2.sh" bash "$here/relaunch-fresh.sh" "$p" rb2 "$work/brief.src" "hint" >/dev/null 2>&1; rc=$?
check "#274: the old pane starts a turn while the new one launches: the new one goes, the old one stays, the row points back" \
  "$rc $(cut -f1,4 "$REGISTRY") $(grep -c 'SUBMIT /exit' "$work/rb2new.log") $(grep -c 'SUBMIT /exit' "$work/rb2.log") $(t list-panes -a -F '#{pane_id}' | grep -cx "$p")" "1 $p	$SID 1 0 1"
check "#274: never logged as both left running" "$(grep -c 'both are left running' "$FLEET_LOG")" "0"
t kill-window -t "$p" 2>/dev/null
# #274 review: with no account named, a new pane whose brief met a limit is not kept.
p=$(relpane '{"above":["⏺ Done. done 11:50 AM"]}')
sed 's/brief=started/brief=blocked-by-limit/' "$work/launch-rb2.sh" >"$work/launch-rb2-lim.sh"; chmod +x "$work/launch-rb2-lim.sh"
env -u FLEET_ACCOUNT OLD="$p" LAUNCH="$work/launch-rb2-lim.sh" bash "$here/relaunch-fresh.sh" "$p" rb2 "$work/brief.src" "hint" >/dev/null 2>&1; rc=$?
check "#274 review: a relaunch whose new brief met a limit is refused, the old pane kept and never sent /exit" \
  "$rc $(cut -f1 "$REGISTRY") $(grep -c 'SUBMIT /exit' "$work/rb2.log")" "1 $p 0"
t kill-window -t "$p"; : >"$REGISTRY"

echo "CI reds typed into the agent on the branch (#180)"
: >"$FLEET_LOG"; mkdir -p "$FLEET_STATE/inbox/cia"
printf 'CI red in r: wf1 failed on feat/x: boom. https://x/1' >"$FLEET_STATE/inbox/cia/r-1.txt"
touch -d '-2 min' "$FLEET_STATE/inbox/cia/r-1.txt"
printf 'CI red in r: wf2 failed on feat/x: bang. https://x/2' >"$FLEET_STATE/inbox/cia/r-2.txt"
p=$(pane cia '{"above":["⏺ Done. done 11:50 AM"],"busy":true}'); settle
printf '%s\tcia\t%s\n' "$p" "$work/brief.src" >"$REGISTRY"
resume "$noon"
check "not into a running turn" "$(grep -c '^SUBMIT' "$work/cia.log") $(find "$FLEET_STATE/inbox/cia" -name '*.txt' | wc -l)" "0 2"
state cia '{"above":["⏺ Done. done 11:50 AM"],"rc":"on"}'
t send-keys -t "$p" -l "AJ: wait"; settle
resume "$((noon + 60))"; resume "$((noon + 120))"
check "nor over AJ's line" "$(grep -c '^SUBMIT' "$work/cia.log")" "0"
state cia '{"above":["⏺ Done. done 11:50 AM"],"rc":"on","clear":true}'
resume "$((noon + 180))"; resume "$((noon + 240))"
check "at an idle, empty prompt the oldest goes in, and its file goes" \
  "$(grep '^SUBMIT' "$work/cia.log") $(ls "$FLEET_STATE/inbox/cia")" "SUBMIT CI red in r: wf1 failed on feat/x: boom. https://x/1 r-2.txt"
check "logged with the pane and the agent" "$(jq -r 'select(.message == "CI alert delivered") | [.pane, .name, .alert, .result] | join(" ")' "$FLEET_LOG")" "$p cia r-1.txt sent"
t kill-window -t "$p"; : >"$REGISTRY"; rm -rf -- "${FLEET_STATE:?}/inbox"
printf 'CI red in r: wf3 failed. https://x/3' >"$work/alert3.txt"
p=$(pane cib '{"above":["⏺ working"],"busy":true}'); settle
check "review 1: a pane busy by the time of delivery gets nothing pasted or pressed" "$(inbox_deliver "$p" "$work/alert3.txt") $(wc -l <"$work/cib.log")" "not-pasted 0"
state cib '{"above":["⏺ Done. done 11:50 AM"]}'
t send-keys -t "$p" -l "AJ: half"; settle
check "review 1: nor one where AJ has begun a line" "$(inbox_deliver "$p" "$work/alert3.txt") [$(input_text "$(screen "$p")")] $(grep -c '^SUBMIT' "$work/cib.log")" "not-pasted [AJ: half] 0"
t kill-window -t "$p"
p=$(pane cil '{"above":["⏺ Done. done 11:50 AM"]}'); settle
head -c 900 /dev/zero | tr '\0' 'x' >"$work/alert-long.txt"
check "review 2: an alert over 800 characters (shown as [Pasted text #1]) is sent" \
  "$(inbox_deliver "$p" "$work/alert-long.txt") $(grep -c '^SUBMIT x' "$work/cil.log")" "sent 1"
state cil '{"above":["⏺ Done. done 11:50 AM"],"paste_prefix":"AJ: ","clear":true}'
check "review 5: a long alert pasted as AJ began a line shows beside it, and nothing is sent" \
  "$(inbox_deliver "$p" "$work/alert-long.txt") [$(input_text "$(screen "$p")")] $(grep -c '^SUBMIT' "$work/cil.log")" "mixed [AJ: [Pasted text #2]] 1"
state cil '{"above":["⏺ Done. done 11:50 AM"],"paste_prefix":"AJ: ","clear":true}'
check "review 4: pasted as AJ began a line, nothing is sent and none of his line is taken" \
  "$(inbox_deliver "$p" "$work/alert3.txt") [$(input_text "$(screen "$p")")] $(grep -c '^SUBMIT' "$work/cil.log")" "mixed [AJ: $(<"$work/alert3.txt")] 1"
t kill-window -t "$p"
echo "the watcher holds panes limited when it starts (#246)"
: >"$FLEET_LOG"
lp=$(pane wlim '{"above":["  ⎿  You'"'"'ve hit your session limit · resets 1:10pm (America/New_York)","",""]}'); settle
IDLE_S=0 WATCH_TICK=0.1 timeout 60 bash "$here/watch-panes.sh" "$lp" >"$work/wlim.out" 2>/dev/null &
wjob=$!
sleep 1.5
check "#246: a pane limited at start wakes nobody" "$(kill -0 "$wjob" 2>/dev/null && echo watching || echo "woke: $(cat "$work/wlim.out")")" "watching"
check "#246: logged as limited at start, with the reset" \
  "$(jq -r 'select(.message == "watching") | [.limited_at_start, .resets] | join(" | ")' "$FLEET_LOG")" "$lp | 1:10pm"
state wlim '{"above":["⏺ Done. done 11:50 AM"]}'
wait "$wjob"
check "#246: once its limit clears it is watched again, and wakes on its finish" "$(cut -d' ' -f1,2 "$work/wlim.out")" "IDLE $lp"
state wlim '{"above":["  ⎿  You'"'"'ve hit your session limit · resets 1:10pm (America/New_York)","",""]}'
IDLE_S=0 WATCH_TICK=0.1 timeout 60 bash "$here/watch-panes.sh" "$lp" >"$work/wlim.out" 2>/dev/null &
wjob=$!; sleep 1; state wlim '{"above":["⏺ working"],"busy":true}'; sleep 1
state wlim '{"above":["  ⎿  You'"'"'ve hit your session limit · resets 6:10pm (America/New_York)","",""]}'
wait "$wjob"
check "#246: a limit hit after it cleared still wakes" "$(cut -d' ' -f1,2 "$work/wlim.out")" "LIMIT $lp"
t kill-window -t "$lp"

echo "fleet pause and unpause (#246)"
: >"$FLEET_LOG"; rm -f "$FLEET_STATE/paused.tsv"
SG=33333333-2222-4333-8444-555555555555
printf '%%41\tgone1\t%s\t%s\t/w\t%s\n%%42\tother\t/b.src\n' "$work/brief.src" "$SG" "$work/cfg-a" >"$REGISTRY"
row1=$(head -1 "$REGISTRY")
fp() { # what fleet pause says: its result, then any error line (not its log lines)
  local rc
  bash "$here/pause.sh" "$@" 2>"$work/fp.err"; rc=$?
  grep '^error:' "$work/fp.err"
  return "$rc"
}
check "#246: pause sets a gone agent aside, keeping its row" \
  "$(fp pause gone1 no room yet) | $(cut -f2- "$REGISTRY") | $(cut -f1 "$FLEET_STATE/paused.tsv") $(cut -f3- "$FLEET_STATE/paused.tsv")" \
  "paused: gone1 (%41): fleet unpause gone1 brings it back | other	/b.src | gone1 $row1"
check "#246: and the note says why" "$(cut -f2 "$FLEET_STATE/paused.tsv" | grep -c 'PAUSED .*: no room yet$')" "1"
check "#246: pausing it twice is refused" "$(fp pause gone1 again; echo "rc=$?")" $'error: fleet pause: no agent named gone1 in panes.tsv\nrc=1'
check "#246: a pause needs a reason" "$(fp pause other; echo "rc=$?")" $'error: usage: fleet pause NAME WHY...\nrc=2'
check "#246: unpause puts the row back, its past pane id parked, and records the unpause (#261 review 10)" \
  "$(fp unpause gone1) | $(grep -c . "$FLEET_STATE/paused.tsv") | $(grep -c -xF -- "-${row1#%41}" "$REGISTRY") $(grep -c '^%41' "$REGISTRY") | $(cut -f1,2 "$FLEET_STATE/unpaused.tsv")" \
  "unpaused: gone1: fleet recover launches it fresh from its brief | 0 | 1 0 | gone1	$SG"
rm -f -- "$FLEET_STATE/unpaused.tsv"
printf '%%43\t01\t/b.src\t%s\n%%44\t1\t/c.src\t%s\n' 33333333-2222-4333-8444-000000000043 33333333-2222-4333-8444-000000000044 >>"$REGISTRY"
check "#261 review: a name is matched as text, so 1 is not 01" \
  "$(fp pause 1 numbers; cut -f2 "$REGISTRY" | grep -cx 01; cut -f1 "$FLEET_STATE/paused.tsv")" $'paused: 1 (%44): fleet unpause 1 brings it back\n1\n1'
fp unpause 1 >/dev/null; awk -F'\t' '$2 "" != "01" && $2 "" != "1"' "$REGISTRY" >"$work/reg.tmp" && mv -f -- "$work/reg.tmp" "$REGISTRY"
rm -f -- "$FLEET_STATE/unpaused.tsv"
printf 'byhand\tPAUSED 10-28 by Heph\n' >"$FLEET_STATE/paused.tsv"
check "#246: a row paused by hand, with nothing saved, is refused, not invented" \
  "$(fp unpause byhand | grep -c 'paused by hand, with no saved row'; grep -c . "$FLEET_STATE/paused.tsv")" $'1\n1'
lv=$(pane plive '{"above":["idle"]}'); settle
printf '%s\tlive1\t%s\t%s\t/w\n' "$lv" "$work/brief.src" "$SID" >"$REGISTRY"
# A session alive by the same test as recover's: this boot, the same process.
mkdir -p "$work/pproc/4242"; printf '4242 (claude) S %s 777 1 2 3\n' "$(seq -s ' ' 1 18)" >"$work/pproc/4242/stat"
echo 33333333-3333-4333-8333-333333333333 >"$work/pboot"
jq -n --arg p "$lv" '{session_id: "x", ended: null, claude: {pid: 4242, start: 777}, host: {boot: "33333333-3333-4333-8333-333333333333"}, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/$SID.json"
check "#246: an agent whose session still runs is never paused" \
  "$(FLEET_PROC=$work/pproc FLEET_BOOT_ID=$work/pboot fp pause live1 because | grep -c "live1 still runs in $lv"; grep -c . "$REGISTRY")" $'1\n1'
rm -f -- "$KLEPSYDRA_DIR/fleet/$SID.json"
check "#246: each refusal is logged with its reason" "$(jq -r 'select(.message | startswith("fleet pause refused")) | .reason' "$FLEET_LOG" | grep -c .)" "2"
t kill-window -t "$lv"; rm -f -- "${KLEPSYDRA_DIR:?}/fleet/$SID.json" "$FLEET_STATE/paused.tsv"; : >"$REGISTRY"
check "review 1: the pane watcher is quiet while no alert has ever been written" \
  "$(FLEET_STATE="$work/noalerts" IDLE_S=1 timeout 2 bash "$here/watch-panes.sh" %999 2>&1 | grep -c 'No such file')" "0"

echo "two accounts: the second folder follows the first"
src=$work/sync-src dst=$work/sync-dst
mkdir -p "$src/plugins/data" "$src/skills/one" "$src/skills/synced" "$src/projects/p" "$src/agents" "$dst"
printf '{"statusLine":{"command":"x"}}\n' >"$src/settings.json"
printf '{"plugins":{}}\n' >"$src/plugins/installed_plugins.json"
printf '{}\n' >"$src/plugins/known_marketplaces.json"
printf 'rules\n' >"$src/CLAUDE.md"
jq -n '{mcpServers: {m: {command: "x"}}, projects: {"/w": {hasTrustDialogAccepted: true}}, hasCompletedOnboarding: true,
  oauthAccount: {accountUuid: "a", emailAddress: "first@example.com"}, userID: "first"}' >"$src/.claude.json-default"
jq -n '{oauthAccount: {accountUuid: "b"}, userID: "second", numStartups: 3}' >"$dst/.claude.json"
printf 'secret' >"$dst/.credentials.json"; cp "$dst/.credentials.json" "$work/creds-before"
mkdir -p "$dst/agents"; printf 'its own\n' >"$dst/agents/x.md"
acsync() { FLEET_DEFAULT_CONFIG="$src" FLEET_DEFAULT_JSON="$src/.claude.json-default" bash "$here/accounts-sync.sh" "$@" 2>/dev/null; }
check "--check before the first sync finds differences" "$(acsync --check "$dst" >/dev/null; echo $?)" "1"
acsync "$dst" >/dev/null
check "settings.json is a copy, not a link" "$(find "$dst/settings.json" -type l | wc -l) $(jq -c . "$dst/settings.json")" '0 {"statusLine":{"command":"x"}}'
jq '.model = "opus[1m]"' "$dst/settings.json" >"$work/j" && mv "$work/j" "$dst/settings.json"
jq '.model = "opus"' "$src/settings.json" >"$work/j" && mv "$work/j" "$src/settings.json"
check "10-29: the second folder keeps the model Claude Code wrote for its account; no drift" "$(acsync --check "$dst"; echo $?) $(acsync "$dst" >/dev/null; jq -r .model "$dst/settings.json")" "0 opus[1m]"
jq 'del(.model)' "$src/settings.json" >"$work/j" && mv "$work/j" "$src/settings.json"
check "the plugin lists are copies and plugin data is shared" \
  "$(cmp -s "$src/plugins/installed_plugins.json" "$dst/plugins/installed_plugins.json" && echo same) $(readlink "$dst/plugins/data")" "same $src/plugins/data"
check "CLAUDE.md, projects and each skill are links; claude.ai's synced skills are not" \
  "$(readlink "$dst/CLAUDE.md") $(readlink "$dst/projects") $(readlink "$dst/skills/one") $( [[ -e $dst/skills/synced ]] && echo synced || echo none)" \
  "$src/CLAUDE.md $src/projects $src/skills/one none"
check "a folder in the way is moved aside, out of the folders Claude Code reads, never deleted" "$(cat "$dst"/.sync-bak/agents.*/x.md) $(find "$dst" -maxdepth 1 -name 'agents.bak*' | wc -l)" "its own 0"
check ".claude.json gets the shared keys and keeps its own account" \
  "$(jq -c '[.mcpServers.m.command, .projects["/w"].hasTrustDialogAccepted, .hasCompletedOnboarding, .oauthAccount.accountUuid, .userID, .numStartups]' "$dst/.claude.json")" \
  '["x",true,true,"b","second",3]'
check "and stays private" "$(stat -c %a "$dst/.claude.json")" "600"
check "the login is never touched" "$(cmp -s "$dst/.credentials.json" "$work/creds-before" && echo same)" "same"
check "--check after a sync is clean" "$(acsync --check "$dst"; echo $?)" "0"
printf '{"statusLine":{"command":"y"}}\n' >"$src/settings.json"
check "a change to ~/.claude's settings is drift" "$(acsync --check "$dst" | grep -c 'settings.json'; echo "rc=${PIPESTATUS[0]}")" $'1\nrc=1'
check "the first folder is never its own second" "$(acsync "$src" >/dev/null; echo $?)" "2"
jq '.projects["/w"].lastCost = 9 | .projects["/w"].lastSessionId = "s9"' "$src/.claude.json-default" >"$work/j" && mv "$work/j" "$src/.claude.json-default"
printf '{"statusLine":{"command":"x"}}\n' >"$src/settings.json"; acsync "$dst" >/dev/null
jq '.projects["/rit-only"] = {hasTrustDialogAccepted: true}' "$dst/.claude.json" >"$work/j" && mv "$work/j" "$dst/.claude.json"
jq '.projects["/w"].lastCost = 1' "$src/.claude.json-default" >"$work/j" && mv "$work/j" "$src/.claude.json-default"
check "review 7: a session's per-folder figures, and folders only the second trusts, are no drift" "$(acsync --check "$dst"; echo $?)" "0"
jq '.projects["/new"] = {hasTrustDialogAccepted: true}' "$src/.claude.json-default" >"$work/j" && mv "$work/j" "$src/.claude.json-default"
acsync "$dst" >/dev/null
check "review 7: a sync adds the first's trust and keeps the second's own" \
  "$(jq -c '[.projects["/new"].hasTrustDialogAccepted, .projects["/rit-only"].hasTrustDialogAccepted, .projects["/w"].lastCost]' "$dst/.claude.json")" "[true,true,null]"
jq '.remoteDialogSeen = true | .projects["/w"].hasClaudeMdExternalIncludesApproved = true' "$dst/.claude.json" >"$work/j" && mv "$work/j" "$dst/.claude.json"
touch -d '@1000' "$dst/.claude.json"
check "review 2A: keys only the second holds are no drift, and nothing is rewritten" "$(acsync --check "$dst"; echo $?) $(acsync "$dst" >/dev/null; stat -c %Y "$dst/.claude.json")" "0 1000"
check "review 2: a second folder that holds the first is refused" "$(acsync "$(dirname "$src")" >/dev/null; echo $?)" "2"
: >"$dst/.claude.json"
check "review 7: a second .claude.json that does not parse is left alone and the sync fails" "$(acsync "$dst" >/dev/null; echo $?) $(wc -c <"$dst/.claude.json")" "1 0"
jq -n '{oauthAccount: {accountUuid: "b"}}' >"$dst/.claude.json"
mkdir -p "$src/skills/two"; rm -rf -- "${dst:?}/skills"; ln -s "$src/skills" "$dst/skills"
check "review 1: a second folder whose skills link into the first is refused, and the first's skills are untouched" \
  "$(acsync "$dst" >/dev/null; echo $?) $(find "$src/skills" -mindepth 1 -maxdepth 1 | sort | sed "s|$src/skills/||" | tr '\n' ' ')" "1 one synced two "

echo "recover after a hard shutdown (#154)"
: >"$FLEET_LOG"; : >"$REGISTRY"
export FLEET_BOOT_ID="$work/boot_id" FLEET_PROC="$work/proc" FLEET_PROJECTS="$work/projects"
echo 11111111-1111-4111-8111-111111111111 >"$FLEET_BOOT_ID"
mkdir -p "$FLEET_PROC/4242"
printf '4242 (claude code) S %s 777 1 2 3\n' "$(seq -s ' ' 1 18)" >"$FLEET_PROC/4242/stat"
# The fleet tmux server started at tick 500: sessions at 777 started after it.
spid=$(t display -p '#{pid}')
mkdir -p "$FLEET_PROC/$spid"
printf '%s (tmux: server) S %s 500 1 2 3\n' "$spid" "$(seq -s ' ' 1 18)" >"$FLEET_PROC/$spid/stat"
sfile() { # SID PID START BOOT PANE [STARTED_AT]
  jq -n --argjson pid "$2" --argjson st "$3" --arg b "$4" --arg p "$5" --argjson at "${6:-1}" \
    '{session_id: "x", started_at: $at, ended: null, claude: {pid: $pid, start: $st}, host: {boot: $b}, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/$1.json"
}
NOWBOOT=11111111-1111-4111-8111-111111111111 OLDBOOT=22222222-2222-4222-8222-222222222222
SA=aaaaaaaa-0000-4000-8000-000000000001 SB=aaaaaaaa-0000-4000-8000-000000000002 SC=aaaaaaaa-0000-4000-8000-000000000003
sfile "$SA" 4242 777 "$NOWBOOT" %1
check "alive: this boot, and a process with the same start time" "$(session_alive "$SA" && echo yes)" "yes"
sfile "$SB" 4242 777 "$OLDBOOT" %2
check "dead: another boot (a reboot reuses pids)" "$(session_alive "$SB" || echo no)" "no"
sfile "$SB" 4242 778 "$NOWBOOT" %2
check "dead: the pid now runs another process" "$(session_alive "$SB" || echo no)" "no"
sfile "$SB" 4243 777 "$NOWBOOT" %2
check "dead: no such process" "$(session_alive "$SB" || echo no)" "no"
jq '.ended = {reason: "other", at: 1}' "$KLEPSYDRA_DIR/fleet/$SA.json" >"$work/e.json"
check "dead: it ended" "$(KLEPSYDRA_DIR="$work/x" session_alive "$SA" || echo no)" "no"
sfile "$SB" 4242 777 "$OLDBOOT" %2; sfile "$SC" 4242 777 "$OLDBOOT" %3
repo=$work/recrepo
git init -q "$repo"; mkdir -p "$repo/.claude/worktrees/wt"
printf 'old\n' >"$repo/IMPL.md"; touch -d '@1000' "$repo/IMPL.md"
printf 'newest\n' >"$repo/.claude/worktrees/wt/IMPL.md"
mkdir -p "$FLEET_PROJECTS/p"
for r in "first reply" "second reply" "third reply"; do
  jq -nc --arg t "$r" --arg c "$repo" '{type: "assistant", cwd: $c, message: {content: [{type: "text", text: $t}, {type: "tool_use", name: "Bash"}]}}'
done >"$FLEET_PROJECTS/p/$SB.jsonl"
printf 'brief A\n' >"$work/ba.src"; printf 'brief B\n' >"$work/bb.src"; printf 'brief C\n' >"$work/bc.src"
printf '%s\ta\t%s\t%s\t/w\n%s\tb\t%s\t%s\t/w\n%s\tc\t%s\t%s\t/w\n' %1 "$work/ba.src" "$SA" %2 "$work/bb.src" "$SB" %3 "$work/bc.src" "$SC" >"$REGISTRY"
cat >"$work/launch-rec.sh" <<EOF
#!/usr/bin/env bash
# wt.exe drains whatever stdin its caller hands it (10-31): this records what recover hands it.
# Checked before any command substitution, whose pipe would take fd 3.
fds=; for f in 3 9; do [[ -e /proc/\$\$/fd/\$f ]] && fds+=" fd\$f=open" || fds+=" fd\$f=closed"; done
echo "\$(readlink /proc/\$\$/fd/0)\$fds" >>"$work/rec.fds"
n=\$(( \$(cat "$work/rec.n" 2>/dev/null || echo 900) + 1 )); echo \$n >"$work/rec.n"
printf '%s %s settings=%s account=%s\n' "\$(date +%s.%N)" "\$1" "\${FLEET_SETTINGS-UNSET}" "\${FLEET_ACCOUNT:-}" >>"$work/rec.log"
cp "\$2" "$work/rec-\$1.txt"
echo "pane=%\$n session=x account=x avail=1MiB brief=started"
EOF
echo "the orchestrator's config folder (#175)"
SHC=aaaaaaaa-0000-4000-8000-0000000000dd
printf '%%77\n' >"$FLEET_STATE/orchestrator.pane"; rm -f "$FLEET_STATE/orchestrator.config"
check "no live Heph and no record: the default folder" "$(heph_config)" "$FLEET_DEFAULT_CONFIG"
printf '%s/\n' "$work/cfg-b" >"$FLEET_STATE/orchestrator.config"
check "no live Heph: orchestrator.config" "$(heph_config)" "$work/cfg-b"
sfile "$SHC" 4242 777 "$NOWBOOT" %77
printf 'HOME=/h\0CLAUDE_CONFIG_DIR=%s/\0' "$work/cfg-c" >"$FLEET_PROC/4242/environ"
check "a live Heph: his process's CLAUDE_CONFIG_DIR, over the record (10-29: Heph ran on the second folder with no record)" "$(heph_config)" "$work/cfg-c"
printf 'HOME=/h\0' >"$FLEET_PROC/4242/environ"
check "a live Heph with none set: the default folder" "$(heph_config)" "$FLEET_DEFAULT_CONFIG"
check "his account order is the workers' last first" "$FLEET_HEPH_ACCOUNTS" "$work/cfg-b $work/cfg-a "
rm -f "$KLEPSYDRA_DIR/fleet/$SHC.json" "$FLEET_PROC/4242/environ" "$FLEET_STATE/orchestrator.pane" "$FLEET_STATE/orchestrator.config"

rec() { LAUNCH="$work/launch-rec.sh" FLEET_STAGGER_S=${STAG:-0} bash "$here/recover.sh" "$@" 2>/dev/null; }
out=$(rec --dry-run --no-orchestrator)
check "a dry run names what it would recover and launches nothing" "$(grep -c '^would recover' <<<"$out") $(wc -l <"$work/rec.log" 2>/dev/null || echo 0)" "2 0"
check "the doctor names the agents whose sessions are gone" "$(bash "$here/doctor.sh" 2>/dev/null | grep '^FAIL agents')" "FAIL agents: sessions gone: b c: fleet recover"
out=$(printf 'stdin\n' | STAG=1 rec --no-orchestrator) # a pipe, so the launch's own </dev/null is checked
check "a running agent is left alone; the others are launched fresh" "$out" $'running: a (%1)\nrecovered: b -> %901\nrecovered: c -> %902'
check "#242: each launch gets no stdin, nor the registry's fd 3 or the recover lock's fd 9" "$(sort -u "$work/rec.fds")" "/dev/null fd3=closed fd9=closed"
check "the brief: why, its last two replies, its newest IMPL.md, then the brief" \
  "$(grep -c 'stopped by a hard shutdown' "$work/rec-b.txt") $(grep -c '^> first reply' "$work/rec-b.txt") $(grep -c '^> second reply$' "$work/rec-b.txt") $(grep -c '^> third reply$' "$work/rec-b.txt") $(grep -o 'IMPL.md: .*' "$work/rec-b.txt") | $(tail -1 "$work/rec-b.txt")" \
  "1 0 1 1 IMPL.md: $repo/.claude/worktrees/wt/IMPL.md | brief B"
check "with no transcript it says so" "$(grep -c 'no transcript found' "$work/rec-c.txt")" "1"

echo "an agent's own IMPL.md (#233)"
ir=$work/implrepo
git init -q "$ir"; git -C "$ir" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$ir" worktree add -q "$ir/.claude/worktrees/mine" -b mine; git -C "$ir" worktree add -q "$ir/.claude/worktrees/sib" -b sib
mkdir -p "$ir/.claude/worktrees/mine/docs" "$work/norepo/x"
printf 'mine\n' >"$ir/.claude/worktrees/mine/IMPL.md"; touch -d '@1000' "$ir/.claude/worktrees/mine/IMPL.md"
printf 'sib\n' >"$ir/.claude/worktrees/sib/IMPL.md"; printf 'x\n' >"$work/norepo/x/IMPL.md"
printf 'top\n' >"$ir/IMPL.md"; touch -d '@1000' "$ir/IMPL.md"
tx() { # CWD [TOOL INPUT JSON]...: a transcript of one call per input ("name" the tool, Bash by default), run from CWD
  local c=$1; shift
  (($#)) || set -- '{}'
  for i in "$@"; do
    jq -nc --arg c "$c" --argjson i "$i" '{type: "assistant", cwd: $c, message: {content: [{type: "tool_use", name: ($i.name // "Bash"), input: ($i | del(.name))}]}}'
  done >"$work/t.jsonl"
  newest_impl "$work/t.jsonl" || echo none
}
check "working inside its worktree: that worktree's, not a newer sibling's" "$(tx "$ir/.claude/worktrees/mine/docs")" "$ir/.claude/worktrees/mine/IMPL.md"
check "inside its worktree, reading a sibling's last does not hand it over" \
  "$(tx "$ir/.claude/worktrees/mine" "{\"command\": \"cat $ir/.claude/worktrees/sib/IMPL.md\"}" "{\"name\": \"Read\", \"file_path\": \"$ir/.claude/worktrees/sib/IMPL.md\"}")" \
  "$ir/.claude/worktrees/mine/IMPL.md"
git -C "$ir" worktree add -q "$ir/.claude/worktrees/bare" -b bare
check "a worktree with no IMPL.md: none, not a sibling's" "$(tx "$ir/.claude/worktrees/bare")" "none"
check "the main checkout and nothing written: the repo's newest" "$(tx "$ir")" "$ir/.claude/worktrees/sib/IMPL.md"
check "from the main checkout, the last one it wrote wins over the newest" \
  "$(tx "$ir" "{\"command\": \"cat >$ir/.claude/worktrees/mine/IMPL.md <<'E'\"}")" "$ir/.claude/worktrees/mine/IMPL.md"
check "a relative write is read against that call's folder or its cd; a later read does not count" \
  "$(tx "$ir" '{"command": "date | tee -a .claude/worktrees/mine/IMPL.md"}' '{"command": "cd .claude/worktrees/sib && printf x >> IMPL.md"}' \
    '{"command": "cat .claude/worktrees/mine/IMPL.md; git show origin/main:IMPL.md"}' "{\"name\": \"Read\", \"file_path\": \"$ir/.claude/worktrees/mine/IMPL.md\"}")" \
  "$ir/.claude/worktrees/sib/IMPL.md"
check "a Write or Edit counts" "$(tx "$ir" "{\"name\": \"Edit\", \"file_path\": \"$ir/.claude/worktrees/mine/IMPL.md\"}")" "$ir/.claude/worktrees/mine/IMPL.md"
check "a cd ending in ; and a quoted path count; a heredoc body's > IMPL.md does not" \
  "$(tx "$ir" "{\"command\": \"printf x > \\\"$ir/.claude/worktrees/sib/IMPL.md\\\"\"}" '{"command": "cd .claude/worktrees/mine; printf x >> IMPL.md"}' \
    "{\"command\": \"git commit -F - <<'E'\\nnotes > IMPL.md\\nE\"}")" "$ir/.claude/worktrees/mine/IMPL.md"
check "a quoted absolute path counts" "$(tx "$ir" "{\"command\": \"printf x > \\\"$ir/.claude/worktrees/mine/IMPL.md\\\"\"}")" "$ir/.claude/worktrees/mine/IMPL.md"
git -C "$ir" worktree add -q "$ir/.claude/worktrees/link" -b link; ln -s "$ir/.claude/worktrees/sib/IMPL.md" "$ir/.claude/worktrees/link/IMPL.md"
check "a worktree whose IMPL.md is a symlink: none" "$(tx "$ir/.claude/worktrees/link")" "none"
sg=$work/sepgit
git init -q --separate-git-dir "$work/sepgit.git" "$sg"; printf 's\n' >"$sg/IMPL.md"
check "a checkout with its git folder elsewhere: its own IMPL.md" "$(tx "$sg")" "$sg/IMPL.md"
check "a write through ~ is read against HOME" \
  "$(HOME=$ir tx "$ir" '{"command": "printf x > ~/.claude/worktrees/mine/IMPL.md"}')" "$ir/.claude/worktrees/mine/IMPL.md"
check "a written file that is gone falls through to the newest" "$(tx "$ir" '{"name": "Write", "file_path": "/nowhere/IMPL.md"}')" "$ir/.claude/worktrees/sib/IMPL.md"
check "a folder outside any repo: none, not a neighbour's" "$(tx "$work/norepo")" "none"
check "a folder outside any repo: the IMPL.md it wrote by full path" \
  "$(tx "$work/norepo" "{\"command\": \"cat >> $ir/.claude/worktrees/mine/IMPL.md\"}")" "$ir/.claude/worktrees/mine/IMPL.md"
check "launches are staggered" "$(awk 'NR == 1 { a = $1 } NR == 2 { print ($1 - a >= 1) ? "apart" : "burst" }' "$work/rec.log")" "apart"
: >"$work/rec.log"
sfile "$SB" 4242 777 "$NOWBOOT" %2; sfile "$SC" 4242 777 "$NOWBOOT" %3
check "once they run, a second run recovers nothing" "$(rec --no-orchestrator | tail -1) $(wc -l <"$work/rec.log")" "nothing to recover 0"

echo "finished agents: one verdict per row, and --prune (#220)"
SF=aaaaaaaa-0000-4000-8000-0000000000f1 SL=aaaaaaaa-0000-4000-8000-0000000000f2 SR=aaaaaaaa-0000-4000-8000-0000000000f3
# The hook's own shape: SessionEnd's reason (prompt_input_exit, a /exit), or "gone".
ended() { jq --arg r "${2:-prompt_input_exit}" '.ended = {reason: $r, at: 1792520221}' "$KLEPSYDRA_DIR/fleet/$1.json" >"$work/ended.tmp" && mv -f -- "$work/ended.tmp" "$KLEPSYDRA_DIR/fleet/$1.json"; }
sfile "$SF" 4242 777 "$NOWBOOT" %4; ended "$SF"   # finished cleanly
cp -p -- "$REGISTRY" "$work/reg-before-220"
printf '%s\td\t%s\t%s\t/w\n%s\te\t%s\t%s\t/w\n' %4 "$work/bc.src" "$SF" %5 "$work/bc.src" "$SL" >>"$REGISTRY"
check "row states: running, finished, gone (no end recorded)" "$(row_state %1 "$SA") $(row_state %4 "$SF") $(row_state %5 "$SL")" "running finished gone"
# #261 review: only a final end is a finish. The hook marks a dead session
# "gone" on the next SessionStart (as after a hard shutdown), and /clear and
# /resume end a session that goes on under a new id.
for r in gone clear resume other logout prompt_input_exit; do
  sfile "$SL" 4242 777 "$NOWBOOT" %5; ended "$SL" "$r"
  printf '%s=%s ' "$r" "$(row_state %5 "$SL")"
done >"$work/reasons"
check "#261 review: the end reasons that are a finish" "$(cat "$work/reasons")" \
  "gone=gone clear=gone resume=gone other=gone logout=finished prompt_input_exit=finished "
sfile "$SL" 4242 777 "$NOWBOOT" %5; ended "$SL" gone
check "#261 review: a row the hook marked gone is recovered, not called finished" \
  "$(rec --dry-run --no-orchestrator | grep -E '^(finished|would recover): e' | sed 's/ (.*//')" "would recover: e"
rm -f "$KLEPSYDRA_DIR/fleet/$SL.json"
sfile "$SR" 4242 777 "$NOWBOOT" %6; sfile "$SL" 4242 777 "$NOWBOOT" %9; ended "$SL"
check "a /clear: the row's session ended but its pane runs a new one, so it is running" "$(row_state %6 "$SL")" "running"
printf '%s\n' "$SR" >"$FLEET_STATE/orchestrator.session"
check "#261 review: the orchestrator in a row's pane is never its successor" "$(row_state %6 "$SL")" "finished"
rm -f "$FLEET_STATE/orchestrator.session"
sfile "$SL" 4242 777 "$OLDBOOT" %9; ended "$SL" gone
check "#261 review: a row from an earlier server is not running in its reused pane id" "$(row_state %6 "$SL")" "gone"
sfile "$SL" 4242 777 "$NOWBOOT" %9; ended "$SL"
rm -f "$KLEPSYDRA_DIR/fleet/$SL.json" "$KLEPSYDRA_DIR/fleet/$SR.json"
doc=$(bash "$here/doctor.sh" 2>/dev/null)
check "a lost row is one FAIL, a finished one one warn, and neither gets a remote control line" \
  "$(grep '^FAIL agents' <<<"$doc") | $(grep '^warn finished agents' <<<"$doc") | $(grep -c 'remote control %[45] ' <<<"$doc")" \
  "FAIL agents: sessions gone: e: fleet recover | warn finished agents: still in panes.tsv: d: fleet doctor --prune | 0"
doc=$(FLEET_AGY=/nonexistent FLEET_COPILOT=/nonexistent bash "$here/doctor.sh" 2>/dev/null)
check "doctor: an engine that is not installed says its lanes are off" "$(grep -c '^ok *engine [a-z]*: not installed: its lanes are off' <<<"$doc")" "2"
mkdir -p "$work/enghome/.gemini/antigravity-cli"; echo '{}' >"$work/enghome/.gemini/antigravity-cli/antigravity-oauth-token"
doc=$(HOME="$work/enghome" FLEET_AGY=/bin/true FLEET_COPILOT=/bin/true FLEET_HOOK_DIR="$here/../hooks" bash "$here/doctor.sh" 2>/dev/null)
check "doctor: an installed engine with the lock policy shows its lanes, locked, and its login" \
  "$(grep '^ok *engine agy' <<<"$doc" | sed 's/^ok *//') | $(grep '^[a-zA-Z]* *engine copilot' <<<"$doc" | sed 's/^\([a-zA-Z]*\) .*lanes: \(.*\)$/\1 \2/')" \
  "engine agy: signed in; lanes: print interactive, locked | warn print interactive"
doc=$(HOME="$work/enghome" FLEET_AGY=/bin/true FLEET_COPILOT=/bin/true FLEET_HOOK_DIR="$work/nohooks" bash "$here/doctor.sh" 2>/dev/null)
check "doctor: without the lock policy the lanes are OFF, never silently on" "$(grep -c '^warn *engine [a-z]*: .*lanes OFF' <<<"$doc")" "2"
check "recover leaves a finished agent alone and relaunches the lost one" \
  "$(rec --dry-run --no-orchestrator | grep -E '^(finished|would recover)' | sed 's/ (.*//')" $'finished: d\nwould recover: e'
# #261 review 4: d's finish is recorded; AJ resumes it in its pane (the same id,
# a new process), then a shutdown and the hook's prune drop its file. The record
# must not outlive the resume, or recover skips a lost agent.
fin_d() { awk -F'\t' -v s="$SF" '$4 == s' "$FLEET_STATE/finished.tsv" 2>/dev/null | wc -l; }
check "#261 review 4: the doctor recorded d's finish" "$(fin_d)" "1"
sfile "$SF" 4242 777 "$NOWBOOT" %4
: >"$FLEET_LOG"
bash "$here/doctor.sh" >/dev/null 2>&1
check "#261 review 4: the doctor drops a recorded finish whose own session runs again, and logs it" \
  "$(fin_d) $(jq -r 'select(.message == "recorded finish dropped: the session runs again") | .name' "$FLEET_LOG")" "0 d"
rm -f -- "$KLEPSYDRA_DIR/fleet/$SF.json"
check "#261 review 4: after the shutdown and the prune, d is lost, not finished" \
  "$(row_state %4 "$SF") $(rec --dry-run --no-orchestrator | grep -E '^(finished|would recover): d' | sed 's/ (.*//')" "gone would recover: d"
# recover's running branch drops it too (a recover run while the resumed session runs).
cp -p -- "$REGISTRY" "$work/reg-before-261r4"
printf '%s\t%s\n' "$(awk -F'\t' -v s="$SF" '$4 == s { print; exit }' "$REGISTRY")" "$(date -Is)" >>"$FLEET_STATE/finished.tsv"
sfile "$SF" 4242 777 "$NOWBOOT" %4
awk -F'\t' '$2 == "d"' "$REGISTRY" >"$work/reg.tmp" && mv -f -- "$work/reg.tmp" "$REGISTRY"
check "#261 review 4: recover, seeing the resumed session run, drops its recorded finish" \
  "$(rec --no-orchestrator | grep -c '^running: d') $(fin_d)" "1 0"
cp -p -- "$work/reg-before-261r4" "$REGISTRY"
# #261 review 5: a resume never seen alive. d's finish is recorded; AJ resumes
# it (the same id), and a shutdown loses it before any doctor tick, so the hook
# marks it gone on a later boot. Its file names no final end: the record goes
# on the next read, before the file does.
sfile "$SF" 4242 777 "$NOWBOOT" %4; ended "$SF"
bash "$here/doctor.sh" >/dev/null 2>&1
check "#261 review 5: d's finish is recorded again" "$(fin_d)" "1"
sfile "$SF" 4242 777 "$OLDBOOT" %4; ended "$SF" gone
: >"$FLEET_LOG"
bash "$here/doctor.sh" >/dev/null 2>&1
check "#261 review 5: a file that names no final end drops the recorded finish, logged" \
  "$(fin_d) $(jq -r 'select(.message == "recorded finish dropped: the session'\''s file names no final end") | .name' "$FLEET_LOG")" "0 d"
rm -f -- "$KLEPSYDRA_DIR/fleet/$SF.json"
check "#261 review 5: once its file is gone too, d is lost and recover relaunches it" \
  "$(row_state %4 "$SF") $(rec --dry-run --no-orchestrator | grep -E '^(finished|would recover): d' | sed 's/ (.*//')" "gone would recover: d"
rm -f -- "$KLEPSYDRA_DIR/fleet/$SF.json"; sfile "$SF" 4242 777 "$NOWBOOT" %4; ended "$SF"
# #261 review 5: an unpaused agent AJ resumed by hand rather than by recover:
# the unpause goes once its session is seen running, so a later /exit is a finish.
printf 'e\t%s\t%s\n' "$SL" "$(date -Is)" >>"$FLEET_STATE/unpaused.tsv"
sfile "$SL" 4242 777 "$NOWBOOT" %5
check "#261 review 5: recover sees the unpaused agent run and drops its unpause" \
  "$(rec --no-orchestrator | grep -c '^running: e') $(grep -c -- "$SL" "$FLEET_STATE/unpaused.tsv")" "1 0"
ended "$SL"
check "#261 review 5: its later /exit is a finish, never relaunched" \
  "$(row_state %5 "$SL") $(rec --dry-run --no-orchestrator | grep -E '^(finished|would recover): e' | sed 's/ (.*//')" "finished finished: e"
printf 'e\t%s\t%s\n' "$SL" "$(date -Is)" >>"$FLEET_STATE/unpaused.tsv"
sfile "$SL" 4242 777 "$NOWBOOT" %5
bash "$here/doctor.sh" >/dev/null 2>&1
check "#261 review 5: the doctor drops it too, seeing the session run" "$(grep -c -- "$SL" "$FLEET_STATE/unpaused.tsv")" "0"
rm -f -- "$KLEPSYDRA_DIR/fleet/$SL.json" "$FLEET_STATE/unpaused.tsv"
# #261 review 5: a row with no session id cannot be followed back, so it is never paused.
printf '%s\tnosid\t%s\t\t/w\n' %7 "$work/bc.src" >>"$REGISTRY"
check "#261 review 5: pause refuses a row that names no session" \
  "$(bash "$here/pause.sh" pause nosid because 2>&1 | grep -c '^error: .*names no session') $(grep -c $'\tnosid\t' "$REGISTRY")" "1 1"
awk -F'\t' '$2 != "nosid"' "$REGISTRY" >"$work/reg.tmp" && mv -f -- "$work/reg.tmp" "$REGISTRY"
awk -F'\t' '$2 != "e"' "$REGISTRY" >"$work/reg.tmp" && mv -f -- "$work/reg.tmp" "$REGISTRY"
# #261 review 6: the registry follows a session at the event (registry-event.sh,
# called by the fleet hook), so neither order of a poll and a delete loses it.
rev() { bash "$here/registry-event.sh" "$@" 2>/dev/null; }
with_registry forget_finished "$SF" >/dev/null; rm -f -- "$FLEET_STATE/unpaused.tsv"; : >"$FLEET_LOG"
rev SessionEnd "$SF" clear
check "#261 review 6: an end that is no finish records nothing" "$(fin_d)" "0"
rev SessionEnd "$SF" prompt_input_exit
check "#261 review 6: a final end records the finish of the row naming it, at once, logged" \
  "$(fin_d) $(jq -r 'select(.message == "finish recorded at the session'\''s end") | .name' "$FLEET_LOG")" "1 d"
rm -f -- "$KLEPSYDRA_DIR/fleet/$SF.json"
check "#261 review 6: the wall's Clear before any poll leaves it finished, never relaunched" \
  "$(row_state %4 "$SF") $(rec --dry-run --no-orchestrator | grep -E '^(finished|would recover): d' | sed 's/ (.*//')" "finished finished: d"
rev SessionStart "$SF" compact
check "#261 review 6: a compact is no new start" "$(fin_d)" "1"
printf 'd\t%s\t%s\n' "$SF" "$(date -Is)" >>"$FLEET_STATE/unpaused.tsv"
rev SessionStart "$SF" resume
check "#261 review 6: a start of the same id drops its finish and its unpause at once" "$(fin_d) $(grep -c -- "$SF" "$FLEET_STATE/unpaused.tsv")" "0 0"
rev SessionEnd "$SF" prompt_input_exit
check "#261 review 6: resumed by hand and /exited between polls: finished, never relaunched" \
  "$(row_state %4 "$SF") $(rec --dry-run --no-orchestrator | grep -E '^(finished|would recover): d' | sed 's/ (.*//')" "finished finished: d"
# #261 review 8: a recorded finish parks the row's pane; its session starting again takes it back.
check "#261 review 8: a finished row holds no pane" "$(awk -F'\t' '$2 == "d" { print $1 }' "$REGISTRY")" "-"
rev SessionStart "$SF" resume %4 "" "/tmp/tmux-1/$FLEET_SOCK"
check "#261 review 8: a hand resume in its pane gives the row its pane back, logged" \
  "$(awk -F'\t' '$2 == "d" { print $1 }' "$REGISTRY") $(jq -r 'select(.message | contains("takes its pane back")) | .pane' "$FLEET_LOG" | tail -1)" "%4 %4"
SN=aaaaaaaa-0000-4000-8000-0000000000f9
rev SessionStart "$SN" clear %4 "$SF" "/tmp/tmux-1/default"
check "#261 review 9: a /clear in another tmux server's pane of the same id leaves the row alone" "$(awk -F'\t' '$2 == "d" { print $1, $4 }' "$REGISTRY")" "%4 $SF"
rev SessionStart "$SN" clear %5 "$SF" "/tmp/tmux-1/$FLEET_SOCK"
check "#261 review 6: a /clear in another pane leaves the row alone" "$(awk -F'\t' '$2 == "d" { print $1, $4 }' "$REGISTRY")" "%4 $SF"
rev SessionStart "$SN" clear %4 "$SF" "/tmp/tmux-1/$FLEET_SOCK"
check "#261 review 6: a /clear repoints the row that named the cleared session in its pane, logged" \
  "$(awk -F'\t' '$2 == "d" { print $1, $4 }' "$REGISTRY") $(jq -r 'select(.message == "registry follows a /clear") | .name' "$FLEET_LOG")" "%4 $SN d"
with_registry set_session_now %4 "$SN" "$SF"
# The doctor repairs a row to its /clear successor as recover does, so the
# successor's own /exit is a finish, not a loss.
with_registry forget_finished "$SF" >/dev/null
sfile "$SF" 4242 777 "$NOWBOOT" %4; ended "$SF" clear; sfile "$SN" 4242 777 "$NOWBOOT" %4
: >"$FLEET_LOG"
bash "$here/doctor.sh" >/dev/null 2>&1
check "#261 review 6: the doctor repoints a row running as its /clear successor, logged" \
  "$(awk -F'\t' '$2 == "d" { print $4 }' "$REGISTRY") $(jq -r 'select(.message == "registry repaired") | .by' "$FLEET_LOG")" "$SN doctor"
ended "$SN"
check "#261 review 6: then the successor's /exit is a finish" "$(row_state %4 "$SN")" "finished"
rm -f -- "$KLEPSYDRA_DIR/fleet/$SN.json"; with_registry set_session_now %4 "$SN" "$SF"; with_registry forget_finished "$SN" >/dev/null
rm -f -- "$KLEPSYDRA_DIR/fleet/$SF.json"; sfile "$SF" 4242 777 "$NOWBOOT" %4; ended "$SF"
# Pause after a reboot: a lost agent's old pane id now holds another agent
# that recover started there; pause sets the lost one aside, never naming it.
SX=aaaaaaaa-0000-4000-8000-0000000000fa SY=aaaaaaaa-0000-4000-8000-0000000000fb
sfile "$SX" 4242 777 "$OLDBOOT" %8; ended "$SX" gone; sfile "$SY" 4242 777 "$NOWBOOT" %8
printf '%s\tlostx\t%s\t%s\t/w\n%s\tnewy\t%s\t%s\t/w\n' %8 "$work/bc.src" "$SX" %8 "$work/bc.src" "$SY" >>"$REGISTRY"
check "#261 review 6: pause sets aside a lost row whose reused pane id runs another row's agent" \
  "$(FLEET_PAUSED=$work/p6.tsv bash "$here/pause.sh" pause lostx because 2>&1 | grep -c '^paused: lostx') $(cut -f1 "$work/p6.tsv" 2>/dev/null)" "1 lostx"
awk -F'\t' '$2 != "newy"' "$REGISTRY" >"$work/reg.tmp" && mv -f -- "$work/reg.tmp" "$REGISTRY"
rm -f -- "$work/p6.tsv" "$KLEPSYDRA_DIR/fleet/$SX.json" "$KLEPSYDRA_DIR/fleet/$SY.json" "$FLEET_STATE/unpaused.tsv"
# #261 review 7: a pane id alone is no key. Rows from an earlier tmux server
# keep pane ids the running server hands out again; a repoint names the row by
# its pane and its old session, and leaves every other row alone.
cp -p -- "$REGISTRY" "$work/reg-before-261r7"
S1=aaaaaaaa-0000-4000-8000-0000000000c1 S2=aaaaaaaa-0000-4000-8000-0000000000c2 SC2=aaaaaaaa-0000-4000-8000-0000000000c3
printf '%s\tfin1\t%s\t%s\t/w\n%s\tlost1\t%s\t%s\t/w\n%s\twork1\t%s\t%s\t/w\n' %3 "$work/bc.src" "$S1" %3 "$work/bc.src" "" %3 "$work/bc.src" "$S2" >"$REGISTRY"
rev SessionStart "$SC2" clear %3 "$S2" "/tmp/tmux-1/$FLEET_SOCK"
check "#261 review 7: a /clear repoints only the row naming the cleared session, never others on its pane id" \
  "$(cut -f2,4 "$REGISTRY" | tr '\t\n' ': ')" "fin1:$S1 lost1: work1:$SC2 "
check "#261 review 7: a repoint naming a session no row on that pane names changes nothing" \
  "$(set_session %3 "$S2" "$S1"; echo "rc=$?") $(cut -f4 "$REGISTRY" | tr '\n' ' ')" "rc=1 $S1  $SC2 "
check "#261 review 7: a row with no session gets one only by its own empty key" \
  "$(set_session %3 "" "$S2"; cut -f2,4 "$REGISTRY" | tr '\t\n' ': ')" "fin1:$S1 lost1:$S2 work1:$SC2 "
cp -p -- "$work/reg-before-261r7" "$REGISTRY"
# #261 review 8: a pane id the running server hands out again never finds a
# finished row: recorded, it is parked ("-"), so every pane-keyed lookup finds
# the live agent alone, in either row order.
cp -p -- "$REGISTRY" "$work/reg-before-261r8"
for order in fin-first live-first; do
  if [[ $order == fin-first ]]; then
    printf '%s\tfinx\t%s\t%s\t/w\n%s\tlivey\t%s\t%s\t/w\n' %2 "$work/bc.src" "$S1" %2 "$work/bc.src" "$S2" >"$REGISTRY"
  else
    printf '%s\tlivey\t%s\t%s\t/w\n%s\tfinx\t%s\t%s\t/w\n' %2 "$work/bc.src" "$S2" %2 "$work/bc.src" "$S1" >"$REGISTRY"
  fi
  with_registry record_finished "$(awk -F'\t' '$2 == "finx"' "$REGISTRY")"
  check "#261 review 8 ($order): reg_field and registered find only the live agent on the reused pane id" \
    "$(reg_field %2 2) $(reg_field %2 4) $(awk -F'\t' '$1 == "%2"' "$REGISTRY" | wc -l)" "livey $S2 1"
  with_registry set_pane %2 %7 "$S2" "" livey
  check "#261 review 8 ($order): a rollback's set_pane moves only the live row" \
    "$(awk -F'\t' '{ print $2 ":" $1 ":" $4 }' "$REGISTRY" | sort | tr '\n' ' ')" "finx:-:$S1 livey:%7:$S2 "
done
cp -p -- "$work/reg-before-261r8" "$REGISTRY"; with_registry forget_finished "$S1" >/dev/null
# #261 review 9: a pane id names something only on the fleet's own server. A
# parked finished row resumed by hand in another tmux, in a pane with the same
# id as a live agent's, never takes that pane, by either restore path.
fsock="/tmp/tmux-1/$FLEET_SOCK"
for path in hook poll; do
  for sock in fleet foreign none; do
    for order in parked-first live-first; do
      if [[ $order == parked-first ]]; then
        printf '%s\tfinx\t%s\t%s\t/w\n%s\tlivey\t%s\t%s\t/w\n' - "$work/bc.src" "$S1" %2 "$work/bc.src" "$S2" >"$REGISTRY"
      else
        printf '%s\tlivey\t%s\t%s\t/w\n%s\tfinx\t%s\t%s\t/w\n' %2 "$work/bc.src" "$S2" - "$work/bc.src" "$S1" >"$REGISTRY"
      fi
      case $sock in fleet) sp=$fsock ;; foreign) sp=/tmp/tmux-1/default ;; none) sp="" ;; esac
      jq -n --arg s "$sp" '{session_id: "x", ended: null, claude: {pid: 4242, start: 777}, host: {boot: "'"$NOWBOOT"'"}, tmux: ({pane: "%2"} + (if $s == "" then {} else {socket: $s} end))}' >"$KLEPSYDRA_DIR/fleet/$S1.json"
      if [[ $path == hook ]]; then rev SessionStart "$S1" resume %2 "" "$sp"; else forget_resumed "$S1" finx; fi
      want="-"; [[ $sock == fleet ]] && want="%2"
      check "#261 review 9 ($path, $sock server, $order): the finished row takes the pane only on the fleet's server" \
        "$(awk -F'\t' '$2 == "finx" { print $1 }' "$REGISTRY")" "$want"
      [[ $sock == fleet ]] || check "#261 review 9 ($path, $sock server, $order): the live pane still names the live agent" "$(reg_field %2 2)" "livey"
    done
  done
done
sfile "$S1" 4242 777 "$NOWBOOT" %2; jq '.tmux.socket = "/tmp/tmux-1/default"' "$KLEPSYDRA_DIR/fleet/$S1.json" >"$work/s1.tmp" && mv -f -- "$work/s1.tmp" "$KLEPSYDRA_DIR/fleet/$S1.json"
check "#261 review 9: pane_runs refuses a session in another tmux server's pane of the same id" "$(pane_runs %2 "$S1" && echo runs || echo refused)" "refused"
jq ".tmux.socket = \"$fsock\"" "$KLEPSYDRA_DIR/fleet/$S1.json" >"$work/s1.tmp" && mv -f -- "$work/s1.tmp" "$KLEPSYDRA_DIR/fleet/$S1.json"
check "#261 review 9: and accepts it on the fleet's own server" "$(pane_runs %2 "$S1" && echo runs || echo refused)" "runs"
rm -f -- "$KLEPSYDRA_DIR/fleet/$S1.json"
cp -p -- "$work/reg-before-261r8" "$REGISTRY"; with_registry forget_finished "$S1" >/dev/null
# A `fleet done` record has no row; a hand resume of that session keeps it.
SDN=aaaaaaaa-0000-4000-8000-0000000000c4
printf '%s\tdonex\t%s\t%s\t/w\t%s\n' %9 "$work/bc.src" "$SDN" "$(date -Is)" >>"$FLEET_STATE/finished.tsv"
rev SessionStart "$SDN" resume
check "#261 review 7: a resumed session no row names keeps its fleet done record" "$(grep -c -- "$SDN" "$FLEET_STATE/finished.tsv")" "1"
awk -F'\t' -v s="$SDN" '$4 != s' "$FLEET_STATE/finished.tsv" >"$work/fin.tmp" && mv -f -- "$work/fin.tmp" "$FLEET_STATE/finished.tsv"
# A fleet file that will not read says nothing: the recorded finish stays.
with_registry record_finished "$(awk -F'\t' -v s="$SF" '$4 == s { print; exit }' "$REGISTRY")"
cp -p -- "$KLEPSYDRA_DIR/fleet/$SF.json" "$work/sf.bak"; : >"$KLEPSYDRA_DIR/fleet/$SF.json"
forget_resumed "$SF" d
check "#261 review 6: an empty fleet file never drops a recorded finish" "$(fin_d)" "1"
mv -f -- "$work/sf.bak" "$KLEPSYDRA_DIR/fleet/$SF.json"
# A restarted tmux server hands out %4 again: a running agent's row on the finished row's pane id.
SG=aaaaaaaa-0000-4000-8000-0000000000f4
sfile "$SG" 4242 777 "$NOWBOOT" %4
printf '%s\tg\t%s\t%s\t/w\n' %4 "$work/bc.src" "$SG" >>"$REGISTRY"
check "with only finished rows: a warn, no FAIL" "$(bash "$here/doctor.sh" 2>/dev/null | grep -E '^(FAIL|warn) (finished )?agents')" "warn agents: finished, still in panes.tsv: d: fleet doctor --prune"
out=$(bash "$here/doctor.sh" --prune 2>/dev/null); rc=$?
check "--prune drops only the finished row and keeps a backup" \
  "$rc|$(head -1 <<<"$out")|$(cut -f2 "$REGISTRY" | tr '\n' ' ')|$(find "$FLEET_STATE" -maxdepth 1 -name 'panes.tsv.bak-*' | wc -l)|$(grep -c $'\td\t' "$(find "$FLEET_STATE" -maxdepth 1 -name 'panes.tsv.bak-*' | head -1)")" \
  "0|pruned: d|a b c g |1|1"
check "#261 review 3: --prune records each finish before its row goes" "$(grep -c "$SF" "$FLEET_STATE/finished.tsv" 2>/dev/null)" "1"
check "#261 review: --prune says where the backup is" "$(grep -c '^backup: .*panes.tsv.bak-' <<<"$out") $(grep -c 'command not found' <<<"$out")" "1 0"
check "a second --prune finds nothing" "$(bash "$here/doctor.sh" --prune 2>/dev/null)" "nothing to prune: no finished agent's row in panes.tsv"
# #261 review 11: prune_now reads each row's state again under the lock, so a
# row whose session started again since the first look stays.
SR=aaaaaaaa-0000-4000-8000-0000000000ab
cp -p -- "$REGISTRY" "$work/reg-before-r11"
printf '%%4\trerun\t/b\t%s\t/w\n' "$SR" >>"$REGISTRY"
sfile "$SR" 4242 777 "$NOWBOOT" %4
( eval "$(sed -n '/^prune_now() {/,/^}/p' "$here/doctor.sh")"; with_registry prune_now "%4/$SR" >/dev/null 2>&1 )
check "#261 review 11: a row named for pruning whose session runs again stays" "$(grep -c "$SR" "$REGISTRY")" "1"
cp -p -- "$work/reg-before-r11" "$REGISTRY"; rm -f -- "$KLEPSYDRA_DIR/fleet/$SR.json"
# set_pane puts back only the row of that name, once (a stale row of another
# agent can carry the same pane id from a past server).
printf '%%3\tother\t/b\tOTHERSID\t/w\n%%3\tmine\t/b\tNEWSID\t/w\n' >"$work/reg-r11"
REGISTRY=$work/reg-r11 set_pane %3 %1 OLDSID "" mine
check "#261 review 11: set_pane moves only the named row back, the other agent's row listed first" "$(cut -f1,2,4 "$work/reg-r11" | tr '\t\n' ' |')" "%3 other OTHERSID|%1 mine OLDSID|"
# A rollback whose row cannot be put back (the registry lock stays busy)
# retires nothing: both panes stay, and it says so.
printf '%%7\tw1\t/b\tNEWSID\t/w\n' >"$work/reg-r11"
: >"$FLEET_LOG"
flock "$FLEET_STATE/.registry.lock" sleep 3 & lk=$!
for _ in $(seq 40); do flock -n "$FLEET_STATE/.registry.lock" true || break; sleep 0.05; done
out=$(retire() { echo "retired $1"; }; REGISTRY=$work/reg-r11 FLEET_REGISTRY_WAIT=1 rollback_fresh %7 %1 OLDSID "" w1)
wait "$lk"
check "#261 review 11: a busy lock: nothing is retired, the row is untouched, and an ERROR says both panes stay" \
  "[$out] $(cut -f1,4 "$work/reg-r11") $(jq -r 'select(.level == "ERROR") | .message' "$FLEET_LOG" | grep -c 'both panes stay running')" "[] %7	NEWSID 1"
out=$(retire() { echo "retired $1"; }; REGISTRY=$work/reg-r11 rollback_fresh %7 %1 OLDSID "" w1)
check "#261 review 11: a free lock: the row goes back first, then the new pane is retired" "[$out] $(cut -f1,4 "$work/reg-r11")" "[retired %7] %1	OLDSID"
check "--prune never touches a lost or running row" "$(diff <(cut -f1-4 "$work/reg-before-220") <(awk -F'\t' '$2 != "g"' "$REGISTRY" | cut -f1-4) && echo same)" "same"
awk -F'\t' '$2 != "g"' "$REGISTRY" >"$work/reg.tmp" && mv -f -- "$work/reg.tmp" "$REGISTRY"
find "$FLEET_STATE" -maxdepth 1 -name 'panes.tsv.bak-*' -delete; rm -f "$KLEPSYDRA_DIR/fleet/$SF.json" "$KLEPSYDRA_DIR/fleet/$SG.json"
# #261 review 2: a finish is recorded on first sight, so it holds after the
# session's file is gone (klepsydra keeps an ended file a day).
SD=aaaaaaaa-0000-4000-8000-0000000000f5
sfile "$SD" 4242 777 "$NOWBOOT" %7; ended "$SD"
printf '%s\tfin\t%s\t%s\t/w\n' %7 "$work/bc.src" "$SD" >>"$REGISTRY"
bash "$here/doctor.sh" >/dev/null 2>&1
rm -f -- "$KLEPSYDRA_DIR/fleet/$SD.json"
check "#261 review 2: a finished row stays finished once its session's file is gone" \
  "$(row_state %7 "$SD") | $(rec --dry-run --no-orchestrator | grep -E '^(finished|would recover): fin' | sed 's/ (.*//')" "finished | finished: fin"
# A recorded finish gives way to the session's own file while it exists: one
# resumed under the same id, then stopped by a shutdown, is gone, not finished.
SRS=aaaaaaaa-0000-4000-8000-0000000000e8
sfile "$SRS" 4242 777 "$NOWBOOT" %6; ended "$SRS"
printf '%s\tres\t%s\t%s\t/w\n' %6 "$work/bc.src" "$SRS" >>"$REGISTRY"
bash "$here/doctor.sh" >/dev/null 2>&1
sfile "$SRS" 4242 777 "$NOWBOOT" %6; ended "$SRS" gone
check "#261 review 3: a resumed session that a shutdown stopped is gone, though its finish was recorded" \
  "$(grep -c "$SRS" "$FLEET_STATE/finished.tsv") $(row_state %6 "$SRS") | $(rec --dry-run --no-orchestrator | grep -E '^(finished|would recover): res' | sed 's/ (.*//')" "1 gone | would recover: res"
awk -F'\t' '$2 != "res"' "$REGISTRY" >"$work/reg.tmp" && mv -f -- "$work/reg.tmp" "$REGISTRY"
rm -f -- "$KLEPSYDRA_DIR/fleet/$SRS.json"
# Paused when its session had ended with /exit, then unpaused: recover launches it.
FLEET_PAUSED=$work/p2.tsv bash "$here/pause.sh" pause fin because >/dev/null 2>&1
FLEET_PAUSED=$work/p2.tsv bash "$here/pause.sh" unpause fin >/dev/null 2>&1
check "#261 review 2: a paused, then unpaused, finished agent is relaunched by recover" \
  "$(row_state %7 "$SD") | $(rec --dry-run --no-orchestrator | grep -E '^(finished|would recover): fin' | sed 's/ (.*//')" "gone | would recover: fin"
# The real recover of that unpaused agent, with a stub launch: a launch that
# fails keeps the unpause, one that starts the agent (and repoints its row, as
# launch.sh does) clears it, and its brief says it was paused.
NEWS=aaaaaaaa-0000-4000-8000-0000000000e9
cat >"$work/launch-up.sh" <<EOF
#!/usr/bin/env bash
cp -- "\$2" "$work/up-brief"
[[ -e "$work/up-fail" ]] && exit 1
awk -F'\t' -v OFS='\t' '\$2 == "fin" { \$1 = "%95"; \$4 = "$NEWS" } 1' "$REGISTRY" >"$work/up.tmp" && mv -f -- "$work/up.tmp" "$REGISTRY"
echo "pane=%95 session=$NEWS account=x avail=1MiB brief=started"
EOF
chmod +x "$work/launch-up.sh"
touch "$work/up-fail"
LAUNCH="$work/launch-up.sh" FLEET_STAGGER_S=0 bash "$here/recover.sh" --no-orchestrator >/dev/null 2>&1
check "#261 review 3: a failed relaunch of an unpaused agent keeps its unpause" "$(cut -f1 "$FLEET_STATE/unpaused.tsv")" "fin"
rm -f -- "$work/up-fail"
LAUNCH="$work/launch-up.sh" FLEET_STAGGER_S=0 bash "$here/recover.sh" --no-orchestrator >/dev/null 2>&1
check "#261 review 3: a relaunch that starts it clears the unpause, and its brief says it was paused" \
  "$(grep -c . "$FLEET_STATE/unpaused.tsv") $(grep -c 'set aside with fleet pause' "$work/up-brief") $(awk -F'\t' '$2 == "fin" { print $4 }' "$REGISTRY")" "0 1 $NEWS"
awk -F'\t' '$2 != "fin"' "$REGISTRY" >"$work/reg.tmp" && mv -f -- "$work/reg.tmp" "$REGISTRY"
rm -f -- "$FLEET_STATE/finished.tsv" "$FLEET_STATE/unpaused.tsv" "$work/p2.tsv"
# The successor is read from the fleet's own sessions: one with the same pane
# id on another tmux server neither hides it nor stands in for it.
SX=aaaaaaaa-0000-4000-8000-0000000000f6 SY=aaaaaaaa-0000-4000-8000-0000000000f7 SZ=aaaaaaaa-0000-4000-8000-0000000000f8
sfile "$SX" 4242 777 "$NOWBOOT" %8; ended "$SX" clear
sfile "$SY" 4242 777 "$NOWBOOT" %8
jq -n '{session_id: "x", ended: null, claude: {pid: 4242, start: 777}, host: {boot: "11111111-1111-4111-8111-111111111111"}, tmux: {pane: "%8", socket: "/tmp/tmux-1/default"}}' >"$KLEPSYDRA_DIR/fleet/$SZ.json"
printf '%s\tcl\t%s\t%s\t/w\n' %8 "$work/bc.src" "$SX" >>"$REGISTRY"
check "#261 review 2: a /clear's successor is found beside a same-id pane on another server" "$(row_state %8 "$SX")" "running"
check "#261 review 2: and the row is never paused while it runs" "$(bash "$here/pause.sh" pause cl x 2>&1 | grep -c '^error:.*still runs')" "1"
rm -f -- "$KLEPSYDRA_DIR/fleet/$SY.json"
check "#261 review 2: the other server's session alone is no successor" "$(row_state %8 "$SX")" "gone"
printf '%s\tnosid\t%s\n' %8 "$work/bc.src" >>"$REGISTRY"
sfile "$SY" 4242 777 "$NOWBOOT" %8
check "#261 review 2: a row with no session id has no successor" "$(row_state %8 "")" "gone"
awk -F'\t' '$2 != "cl" && $2 != "nosid"' "$REGISTRY" >"$work/reg.tmp" && mv -f -- "$work/reg.tmp" "$REGISTRY"
rm -f -- "$KLEPSYDRA_DIR/fleet/$SX.json" "$KLEPSYDRA_DIR/fleet/$SY.json" "$KLEPSYDRA_DIR/fleet/$SZ.json"

echo "recover: the orchestrator"
# After a power cut nothing runs: the earlier checks' live sessions go.
rm -f "$KLEPSYDRA_DIR/fleet/$SA.json" "$KLEPSYDRA_DIR/fleet/$SB.json" "$KLEPSYDRA_DIR/fleet/$SC.json"
: >"$work/rec.log"; : >"$REGISTRY"
SH=aaaaaaaa-0000-4000-8000-0000000000aa SN=aaaaaaaa-0000-4000-8000-0000000000bb
printf '%%0\n' >"$FLEET_STATE/orchestrator.pane"
sfile "$SN" 4242 777 "$OLDBOOT" %0 5   # an older session that also sat in %0
sfile "$SH" 4242 777 "$OLDBOOT" %0 9
printf 'handoff\n' >"$work/HEPH.md"; touch -d '2026-10-28 17:00 UTC' "$work/HEPH.md"
{ jq -nc '{type: "user", message: {content: "before the handoff"}, timestamp: "2026-10-28T16:00:00.000Z"}'
  jq -nc '{type: "user", message: {content: "AJ: move InteFL to Friday"}, timestamp: "2026-10-28T17:05:00.000Z"}'
  jq -nc '{type: "user", message: {content: "<task-notification>x</task-notification>"}, timestamp: "2026-10-28T17:06:00.000Z"}'
  jq -nc '{type: "user", isMeta: true, message: {content: "meta"}, timestamp: "2026-10-28T17:07:00.000Z"}'
  jq -nc '{type: "user", message: {content: [{type: "tool_result"}]}, timestamp: "2026-10-28T17:08:00.000Z"}'
  jq -nc '{type: "user", message: {content: "AJ: and ping Dima"}, timestamp: "2026-10-28T17:09:00.000Z"}'
} >"$FLEET_PROJECTS/p/$SH.jsonl"
out=$(FLEET_HEPH="$work/HEPH.md" rec)
check "the orchestrator is relaunched without worker settings, on the default account" \
  "$(cut -d' ' -f2- "$work/rec.log")" "heph settings= account=$FLEET_DEFAULT_CONFIG"
check "its note names HEPH.md and holds AJ's messages since it was written, nothing else" \
  "$(grep -c "Read $work/HEPH.md first" "$work/rec-heph.txt") $(grep '^- ' "$work/rec-heph.txt" | tr '\n' '|')" "1 - AJ: move InteFL to Friday|- AJ: and ping Dima|"
check "and orchestrator.pane follows it" "$(cat "$FLEET_STATE/orchestrator.pane")" "$(tail -1 <<<"$out" | grep -o '%[0-9]*')"
check "and orchestrator.session records its session" "$(cat "$FLEET_STATE/orchestrator.session")" "x"
# #216, #229 review: with the fleet's session already running, the relaunched
# Heph opens behind and AJ stays where he is.
cat >"$work/launch-recfwd.sh" <<EOF
#!/usr/bin/env bash
np=\$(tmux -L "$FLEET_SOCK" new-window -d -P -F '#{pane_id}' -t fleet: 'sleep 600')
echo "pane=\$np session=x account=x avail=1MiB brief=started"
EOF
chmod +x "$work/launch-recfwd.sh"
printf '%%0\n' >"$FLEET_STATE/orchestrator.pane"; rm -f "$FLEET_STATE/orchestrator.session"
seen=$(t display -p -t fleet: '#{pane_id}')
LAUNCH="$work/launch-recfwd.sh" FLEET_STAGGER_S=0 FLEET_HEPH="$work/HEPH.md" bash "$here/recover.sh" >/dev/null 2>&1
nh=$(cat "$FLEET_STATE/orchestrator.pane")
check "#229 review: a recover into a running session leaves AJ's window in view" "$(t display -p -t fleet: '#{pane_id}')" "$seen"
t kill-window -t "$nh" 2>/dev/null
# From a cold start (no fleet session) Heph comes forward, unless AJ moved meanwhile.
cat >"$work/launch-cold.sh" <<EOF
#!/usr/bin/env bash
if tmux -L "$FLEET_SOCK" has-session -t coldrec 2>/dev/null; then
  [[ -e "$work/cold.move" ]] && tmux -L "$FLEET_SOCK" new-window -t coldrec: 'sleep 600' # AJ opens another
  np=\$(tmux -L "$FLEET_SOCK" new-window -d -P -F '#{pane_id}' -t coldrec: 'sleep 600')
else
  np=\$(tmux -L "$FLEET_SOCK" new-session -d -s coldrec -P -F '#{pane_id}' 'sleep 600')
fi
echo "pane=\$np session=x account=x avail=1MiB brief=started"
EOF
chmod +x "$work/launch-cold.sh"
for moved in 0 1; do
  (( moved )) && touch "$work/cold.move"
  printf '%s\tcw\t%s\t%s\t/w\n' %990 "$work/ba.src" "$SB" >"$REGISTRY"
  printf '%%989\n' >"$FLEET_STATE/orchestrator.pane"; rm -f "$FLEET_STATE/orchestrator.session"
  FLEET_SESSION=coldrec LAUNCH="$work/launch-cold.sh" FLEET_STAGGER_S=0 FLEET_HEPH="$work/HEPH.md" bash "$here/recover.sh" >/dev/null 2>&1
  nh=$(cat "$FLEET_STATE/orchestrator.pane")
  if (( moved )); then
    check "#229 review: from a cold start, a move during recover keeps Heph behind" "$(t display -p -t coldrec: '#{pane_id}' | grep -cx -- "$nh") $(t list-windows -t coldrec | wc -l)" "0 3"
  else
    check "#229 review: from a cold start, nothing moved: the recovered Heph is the window in view" "$(t display -p -t coldrec: '#{pane_id}')" "$nh"
  fi
  t kill-session -t coldrec 2>/dev/null
done
rm -f "$work/cold.move"; : >"$REGISTRY"

echo "recover: a relaunched worker that takes the old orchestrator pane is not Heph"
SW=aaaaaaaa-0000-4000-8000-0000000000c1 SNEW=aaaaaaaa-0000-4000-8000-0000000000c2
: >"$work/rec.log"; rm -f "$FLEET_STATE/orchestrator.session"
printf '%%0\n' >"$FLEET_STATE/orchestrator.pane"
sfile "$SW" 4242 777 "$OLDBOOT" %7
printf '%s\tw\t%s\t%s\t/w\n' %7 "$work/ba.src" "$SW" >"$REGISTRY"
cat >"$work/launch-steal.sh" <<STEAL
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$work/rec.log"
if [[ \$1 == w ]]; then
  jq -n '{session_id: "x", started_at: 99, ended: null, claude: {pid: 4242, start: 777}, host: {boot: "$NOWBOOT"}, tmux: {pane: "%0"}}' >"$KLEPSYDRA_DIR/fleet/$SNEW.json"
  echo "pane=%0 session=$SNEW account=x avail=1MiB brief=started"
else
  echo "pane=%950 session=heph-new account=x avail=1MiB brief=started"
fi
STEAL
out=$(LAUNCH="$work/launch-steal.sh" FLEET_STAGGER_S=0 FLEET_HEPH="$work/HEPH.md" bash "$here/recover.sh" 2>/dev/null)
check "the worker takes %0 and Heph is still relaunched" "$(tr '\n' '|' <<<"$out")" "recovered: w -> %0|recovered: orchestrator -> %950|"
check "Heph's records follow the new Heph" "$(cat "$FLEET_STATE/orchestrator.pane") $(cat "$FLEET_STATE/orchestrator.session")" "%950 heph-new"
rm -f "$KLEPSYDRA_DIR/fleet/$SNEW.json"

echo "recover: a stale orchestrator.session while Heph runs in its pane"
SLIVE=aaaaaaaa-0000-4000-8000-0000000000c3 SDEADH=aaaaaaaa-0000-4000-8000-0000000000c7
sfile "$SDEADH" 4242 778 "$NOWBOOT" %4   # Heph's last session, this server, its process gone
printf '%s\n' "$SDEADH" >"$FLEET_STATE/orchestrator.session"; printf '%%4\n' >"$FLEET_STATE/orchestrator.pane"
sfile "$SLIVE" 4242 777 "$NOWBOOT" %4
: >"$REGISTRY"; : >"$work/rec.log"
out=$(rec)
check "Heph's live session wins over the stale record; nothing launches" "$(tr '\n' '|' <<<"$out")$(wc -l <"$work/rec.log")" "running: orchestrator (%4)|nothing to recover|0"
rm -f "$KLEPSYDRA_DIR/fleet/$SLIVE.json" "$KLEPSYDRA_DIR/fleet/$SDEADH.json"

echo "recover: a pane that still runs a session the row does not name"
SOLD=aaaaaaaa-0000-4000-8000-0000000000c4 SCUR=aaaaaaaa-0000-4000-8000-0000000000c5
sfile "$SOLD" 4242 778 "$NOWBOOT" %8; sfile "$SCUR" 4242 777 "$NOWBOOT" %8   # this server, its process gone (a /clear)
printf '%s\tx\t%s\t%s\t/w\n%s\ty\t%s\t%s\t/w\n' %8 "$work/ba.src" "$SOLD" %9 "$work/gone.src" aaaaaaaa-0000-4000-8000-0000000000c6 >"$REGISTRY"
out=$(rec --no-orchestrator)
check "the row is repaired and no second agent starts; a missing brief is skipped" \
  "$(tr '\n' '|' <<<"$out")$(wc -l <"$work/rec.log") $(cut -f4 "$REGISTRY" | head -1)" \
  "running: x (%8, now session $SCUR)|not recovered: y (brief $work/gone.src is gone)|nothing to recover|0 $SCUR"
sfile "$SOLD" 4242 777 "$OLDBOOT" %8
printf '%s\tx\t%s\t%s\t/w\n' %8 "$work/ba.src" "$SOLD" >"$REGISTRY"; : >"$work/rec.log"
check "a row from an earlier boot is never repaired to a session in its reused pane" "$(rec --no-orchestrator --dry-run | head -1 | cut -d' ' -f1-3)" "would recover: x"
rm -f "$KLEPSYDRA_DIR/fleet/$SOLD.json" "$KLEPSYDRA_DIR/fleet/$SCUR.json"

echo "recover: a live Heph outside orchestrator.pane is never doubled"
SHEPH=aaaaaaaa-0000-4000-8000-0000000000d1
printf '%%3\n' >"$FLEET_STATE/orchestrator.pane"; printf '%s\n' "$SH" >"$FLEET_STATE/orchestrator.session"
sfile "$SHEPH" 4242 777 "$NOWBOOT" %0
: >"$REGISTRY"; : >"$work/rec.log"
out=$(rec)
check "a live session no record names is not taken for Heph, and no second Heph starts" \
  "$(tr '\n' '|' <<<"$out")$(wc -l <"$work/rec.log") $(cat "$FLEET_STATE/orchestrator.pane")" \
  "not recovered: orchestrator (1 live sessions in the fleet belong to no agent and none is on record as Heph; write Heph's pane to orchestrator.pane)|nothing to recover|0 %3"
printf '%s\n' "$SHEPH" >"$FLEET_STATE/orchestrator.session"
check "the session on record is Heph wherever it runs; the pane record follows him" \
  "$(rec | head -1) $(cat "$FLEET_STATE/orchestrator.pane")" "running: orchestrator (%0) %0"
printf '%s\n' "$SH" >"$FLEET_STATE/orchestrator.session"; printf '%%3\n' >"$FLEET_STATE/orchestrator.pane"
check "the caller is Heph when it is a Claude session in the fleet's tmux" \
  "$(CLAUDECODE=1 TMUX_PANE=%6 TMUX="/tmp/tmux-1/$FLEET_SOCK,1,0" rec --dry-run | head -1)" "running: orchestrator (%6)"
SOTHER=aaaaaaaa-0000-4000-8000-0000000000d2
sfile "$SOTHER" 4242 777 "$NOWBOOT" %5
printf '%s\n' "$SHEPH" >"$FLEET_STATE/orchestrator.session"
check "of two, the one on record is Heph" "$(rec --dry-run | head -1)" "running: orchestrator (%0)"
check "a Claude session that is not Heph running recover leaves the records alone" \
  "$(CLAUDECODE=1 TMUX_PANE=%5 TMUX="/tmp/tmux-1/$FLEET_SOCK,1,0" rec | head -1) $(cat "$FLEET_STATE/orchestrator.session")" "running: orchestrator (%0) $SHEPH"
printf '%s\n' "$SH" >"$FLEET_STATE/orchestrator.session"; printf '%%3\n' >"$FLEET_STATE/orchestrator.pane"
out=$(rec)
check "two live sessions that are no agent's: Heph is not launched" \
  "$(head -1 <<<"$out") $(wc -l <"$work/rec.log")" \
  "not recovered: orchestrator (2 live sessions in the fleet belong to no agent and none is on record as Heph; write Heph's pane to orchestrator.pane) 0"
# #269 verify: a finished agent's open pane is no stranger: with Heph gone, he is relaunched.
rm -f "$KLEPSYDRA_DIR/fleet/$SHEPH.json"
check "#269 verify: without finished.tsv, the finished agent's live session leaves Heph unsure (the control)" \
  "$(rec --dry-run | grep -c '^not recovered: orchestrator')" "1"
: >"$FLEET_STATE/finished.tsv"
check "#269 verify 3: an empty finished.tsv (the probe makes one) changes nothing" \
  "$(rec --dry-run | grep -c '^not recovered: orchestrator')" "1"
printf '%%5\tdone-agent\t%s\t%s\t/w\t\t2026-11-02T20:00:00-05:00\n' "$work/brief.src" "$SOTHER" >"$FLEET_STATE/finished.tsv"
check "#269 verify: listed in finished.tsv, it no longer does, and Heph would be recovered" \
  "$(rec --dry-run | grep -c '^not recovered: orchestrator') $(rec --dry-run | grep -c 'orchestrator')" "0 1"
printf '%%3\n' >"$FLEET_STATE/orchestrator.pane"; printf '%s\n' "$SH" >"$FLEET_STATE/orchestrator.session"
check "#269 verify 3: the finished agent running fleet recover in its own pane is not taken for Heph" \
  "$(CLAUDECODE=1 TMUX_PANE=%5 TMUX="/tmp/tmux-1/$FLEET_SOCK,1,0" rec --dry-run | grep -c 'running: orchestrator (%5)') $(cat "$FLEET_STATE/orchestrator.session")" "0 $SH"
printf '%s\n' "$SOTHER" >"$FLEET_STATE/orchestrator.session"
check "#269 verify 3: nor is a record naming the finished agent's session" \
  "$(rec --dry-run | grep -c "session $SOTHER")" "0"
printf '%s\n' "$SH" >"$FLEET_STATE/orchestrator.session"
rm -f "$FLEET_STATE/finished.tsv"
rm -f "$KLEPSYDRA_DIR/fleet/$SOTHER.json"
sfile "$SHEPH" 4242 777 "$NOWBOOT" %0 # live again, as the cases below expect

echo "recover: a row is repaired only to a session alive before any launch"
SA1=aaaaaaaa-0000-4000-8000-0000000000d3 SB1=aaaaaaaa-0000-4000-8000-0000000000d4 SNEWA=aaaaaaaa-0000-4000-8000-0000000000d5
sfile "$SA1" 4242 777 "$OLDBOOT" %1; sfile "$SB1" 4242 777 "$OLDBOOT" %2
printf '%s\ta\t%s\t%s\t/w\n%s\tb\t%s\t%s\t/w\n' %1 "$work/ba.src" "$SA1" %2 "$work/bb.src" "$SB1" >"$REGISTRY"
cat >"$work/launch-takes2.sh" <<TAKES
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$work/rec.log"
if [[ \$1 == a ]]; then
  jq -n '{session_id: "x", started_at: 50, ended: null, claude: {pid: 4242, start: 777}, host: {boot: "$NOWBOOT"}, tmux: {pane: "%2"}}' >"$KLEPSYDRA_DIR/fleet/$SNEWA.json"
  echo "pane=%2 session=$SNEWA account=x avail=1MiB brief=started"
else
  echo "pane=%7 session=b-new account=x avail=1MiB brief=started"
fi
TAKES
: >"$work/rec.log"
out=$(LAUNCH="$work/launch-takes2.sh" FLEET_STAGGER_S=0 bash "$here/recover.sh" --no-orchestrator 2>/dev/null)
check "a worker relaunched into a later row's pane does not swallow that row" "$(tr '\n' '|' <<<"$out")" "recovered: a -> %2|recovered: b -> %7|"
rm -f "$KLEPSYDRA_DIR/fleet/$SNEWA.json" "$KLEPSYDRA_DIR/fleet/$SA1.json" "$KLEPSYDRA_DIR/fleet/$SB1.json"
SW0=aaaaaaaa-0000-4000-8000-0000000000d6
sfile "$SW0" 4242 777 "$OLDBOOT" %0
printf '%s\tw\t%s\t%s\t/w\n' %0 "$work/ba.src" "$SW0" >"$REGISTRY"
printf '%s\n' "$SHEPH" >"$FLEET_STATE/orchestrator.session"
: >"$work/rec.log"; rm -f "$work/rec.n"
out=$(rec)
check "Heph in a worker row's old pane is never repaired into that row" "$(tr '\n' '|' <<<"$out")" "recovered: w -> %901|running: orchestrator (%0)|"
rm -f "$KLEPSYDRA_DIR/fleet/$SHEPH.json" "$KLEPSYDRA_DIR/fleet/$SW0.json"; : >"$REGISTRY"

echo "recover: a session on another tmux server is never taken for a row"
SX=aaaaaaaa-0000-4000-8000-0000000000d7 SAJ=aaaaaaaa-0000-4000-8000-0000000000d8
sfile "$SX" 4242 778 "$NOWBOOT" %3
jq -n '{session_id: "x", started_at: 1, ended: null, claude: {pid: 4242, start: 777}, host: {boot: "'"$NOWBOOT"'"}, tmux: {pane: "%3", socket: "/tmp/tmux-1001/default"}}' >"$KLEPSYDRA_DIR/fleet/$SAJ.json"
printf '%s\tw\t%s\t%s\t/w\n' %3 "$work/ba.src" "$SX" >"$REGISTRY"
check "AJ's own session in pane %3 of his tmux is not worker w's" "$(rec --no-orchestrator --dry-run | head -1 | cut -d' ' -f1-3)" "would recover: w"
rm -f "$KLEPSYDRA_DIR/fleet/$SX.json" "$KLEPSYDRA_DIR/fleet/$SAJ.json"; : >"$REGISTRY"

echo "recover: after a power cut, Heph in a pane an old worker row names"
SW1=aaaaaaaa-0000-4000-8000-0000000000e1 SH2=aaaaaaaa-0000-4000-8000-0000000000e2
sfile "$SW1" 4242 777 "$OLDBOOT" %1; sfile "$SH2" 4242 777 "$NOWBOOT" %1
printf '%s\tw1\t%s\t%s\t/w\n' %1 "$work/ba.src" "$SW1" >"$REGISTRY"
printf '%%0\n' >"$FLEET_STATE/orchestrator.pane"; printf '%s\n' "$SH" >"$FLEET_STATE/orchestrator.session"
check "the calling Heph in %1 is recognised and w1 is relaunched" \
  "$(CLAUDECODE=1 TMUX_PANE=%1 TMUX="/tmp/tmux-1/$FLEET_SOCK,1,0" rec --dry-run | tr '\n' '|' | cut -d'|' -f1-2)" \
  "would recover: w1 (session $SW1, transcript none, IMPL.md none)|running: orchestrator (%1)"
rm -f "$KLEPSYDRA_DIR/fleet/$SH2.json"   # no live Heph: the gone path reads the record
check "a record that names an agent is no Heph's" \
  "$(printf '%s\n' "$SW1" >"$FLEET_STATE/orchestrator.session"; rec --dry-run | grep -c 'orchestrator (session '"$SW1")" "0"
rm -f "$KLEPSYDRA_DIR/fleet/$SW1.json" "$KLEPSYDRA_DIR/fleet/$SH2.json"; : >"$REGISTRY"

echo "resume: Heph's session is recorded, never a worker's"
SHR=aaaaaaaa-0000-4000-8000-0000000000e3
po=$(pane orchrec '{"above":["idle"]}'); settle
printf '%s\n' "$po" >"$FLEET_STATE/orchestrator.pane"; rm -f "$FLEET_STATE/orchestrator.session"
sfile "$SHR" 4242 777 "$NOWBOOT" "$po"
resume "$noon"; resume "$(( noon + 60 ))"
check "the live session in orchestrator.pane is recorded" "$(cat "$FLEET_STATE/orchestrator.session" 2>/dev/null)" "$SHR"
printf '%s\tw9\t%s\t%s\t/w\n' "$po" "$work/ba.src" "$SHR" >"$REGISTRY"; printf 'old\n' >"$FLEET_STATE/orchestrator.session"
resume "$(( noon + 120 ))"
check "a session a registry row names is never recorded as Heph" "$(cat "$FLEET_STATE/orchestrator.session")" "old"
t kill-window -t "$po"; rm -f "$KLEPSYDRA_DIR/fleet/$SHR.json" "$FLEET_STATE/orchestrator.session"; : >"$REGISTRY"

echo "recover: the fleet's tmux server started again without a reboot"
SWOLD=aaaaaaaa-0000-4000-8000-0000000000f1 SHNEW=aaaaaaaa-0000-4000-8000-0000000000f2
sfile "$SWOLD" 4242 100 "$NOWBOOT" %1   # this boot, a process older than the server
sfile "$SHNEW" 4242 777 "$NOWBOOT" %1 "$(date +%s)"
printf '%s\tw1\t%s\t%s\t/w\n' %1 "$work/ba.src" "$SWOLD" >"$REGISTRY"
printf '%%0\n' >"$FLEET_STATE/orchestrator.pane"; rm -f "$FLEET_STATE/orchestrator.session"
check "Heph in %1 of the new server is recognised and w1 is relaunched, not repaired to him" \
  "$(CLAUDECODE=1 TMUX_PANE=%1 TMUX="/tmp/tmux-1/$FLEET_SOCK,1,0" rec --dry-run | tr '\n' '|' | cut -d'|' -f1-2 | cut -c1-26)" \
  "would recover: w1 (session"
check "and he is the orchestrator" "$(CLAUDECODE=1 TMUX_PANE=%1 TMUX="/tmp/tmux-1/$FLEET_SOCK,1,0" rec --dry-run | grep -c 'running: orchestrator (%1)')" "1"
rm -f "$KLEPSYDRA_DIR/fleet/$SWOLD.json" "$KLEPSYDRA_DIR/fleet/$SHNEW.json"; : >"$REGISTRY"

echo "recover: one run at a time"
flock "$FLEET_STATE/.recover.lock" sleep 3 &
sleep 0.3
check "a second run while one holds the lock refuses" "$(bash "$here/recover.sh" --no-orchestrator 2>&1; echo "rc=$?")" $'error: another fleet recover is running\nrc=1'
wait
rm -f "$FLEET_STATE/orchestrator.pane" "$FLEET_STATE/orchestrator.session"; : >"$REGISTRY"; unset FLEET_BOOT_ID FLEET_PROC FLEET_PROJECTS

echo "the orchestrator's identity across /clear and tmux restarts (#173 review)"
# The recover section's fake /proc: process 4242 started at tick 777, after the server (tick 500).
export FLEET_BOOT_ID="$work/boot_id" FLEET_PROC="$work/proc"
: >"$REGISTRY"; rm -f "$KLEPSYDRA_DIR"/fleet/*.json "$FLEET_STATE/resume-state"
login a; login b; reading a Personal 100 5000; reading b RIT 10 4000
OS=aaaaaaaa-0000-4000-8000-0000000000a1 CUR=aaaaaaaa-0000-4000-8000-0000000000a2
hfile() { # SID PID START PANE [ENDED-AT]: a fleet file, ended when ENDED-AT is given
  jq -n --argjson pid "$2" --argjson st "$3" --arg b "$NOWBOOT" --arg p "$4" --arg e "${5:-}" \
    '{session_id: "x", started_at: 1, ended: (if $e == "" then null else {at: ($e | tonumber)} end),
      claude: {pid: $pid, start: $st}, host: {boot: $b}, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/$1.json"
}
hcase() { # NAME OS-START: Heph's recorded session OS ended (started at OS-START); CUR, alive, in his pane
  : >"$work/moved"; : >"$FLEET_LOG"; rm -f "$KLEPSYDRA_DIR"/fleet/*.json "$FLEET_STATE/resume-state"
  h=$(pane "$1" "{\"above\":[\"⏺ ok\",\"$LIMIT\"]}"); settle
  printf '%s\n' "$h" >"$FLEET_STATE/orchestrator.pane"; printf '%s\n' "$OS" >"$FLEET_STATE/orchestrator.session"
  hfile "$OS" 4343 "$2" "$h" 5; hfile "$CUR" 4242 777 "$h"
  hmove "$noon"
}
hcase hclear 600
check "after a /clear (his recorded session ended on this server), the session in his pane is Heph: recorded, then moved" \
  "$(head -2 "$work/moved" | tr '\n' ' ')$(jq -r 'select(.message == "orchestrator session recorded") | .session' "$FLEET_LOG")" "$work/cfg-b heph $CUR"
t kill-window -t "$h" 2>/dev/null
hcase hrestart 100
check "after a tmux restart (his recorded session ended on an earlier server), another session in the reused pane id is not Heph" \
  "$(wc -c <"$work/moved") $(events hrestart) $(cat "$FLEET_STATE/orchestrator.session")" "0  $OS"
check "and it is logged" "$(jq -r 'select(.message | startswith("the orchestrator'"'"'s pane runs another session")) | .session' "$FLEET_LOG")" "$CUR"
t kill-window -t "$h" 2>/dev/null
hcase hstale 100; rm -f "$KLEPSYDRA_DIR/fleet/$CUR.json" "$FLEET_STATE/resume-state"; : >"$work/moved"
hfile "$OS" 4343 100 "$h"   # never ended (killed with its server): the only file naming the reused pane id
hmove "$noon"
check "review 4: a never-ended record from an earlier server does not make its reused pane id Heph" "$(wc -c <"$work/moved") $(events hstale)" "0 "
t kill-window -t "$h" 2>/dev/null

: >"$work/moved"; rm -f "$KLEPSYDRA_DIR"/fleet/*.json "$FLEET_STATE/resume-state" "$FLEET_STATE/orchestrator.config"
h=$(pane hephphone "{\"above\":[\"⏺ ok\",\"$LIMIT\"]}"); settle
printf '%s\n' "$h" >"$FLEET_STATE/orchestrator.pane"; printf '%s\n' "$CUR" >"$FLEET_STATE/orchestrator.session"
hfile "$CUR" 4242 777 "$h"
cat >"$work/launch-heph-phone.sh" <<EOF
#!/usr/bin/env bash
jq '.prompt.at = 5' "$KLEPSYDRA_DIR/fleet/$CUR.json" >"$work/st.json" && mv "$work/st.json" "$KLEPSYDRA_DIR/fleet/$CUR.json"
echo "pane=%996 session=x account=\$FLEET_ACCOUNT avail=1MiB brief=started"
EOF
LAUNCH="$work/launch-heph-phone.sh" FLEET_HEPH="$work/HEPH.md" FLEET_NOW=$noon bash "$here/resume-at-reset.sh" --once 2>/dev/null
check "review 2: a prompt Heph took during the launch (a phone message) keeps him and his records" \
  "$(cat "$FLEET_STATE/orchestrator.pane" "$FLEET_STATE/orchestrator.session" | tr '\n' ' ')$(events hephphone)" "$h $CUR "
t kill-window -t "$h" 2>/dev/null
rm -f "$KLEPSYDRA_DIR"/fleet/*.json "$FLEET_STATE/orchestrator."* "$FLEET_STATE/resume-state"
logout a; logout b; reading a Personal 40 1000; rm -f "$KLEPSYDRA_DIR/accounts/b/s.json"
unset FLEET_BOOT_ID FLEET_PROC

echo "launch without worker settings"
cat >"$work/launcher-rec.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$KLEPSYDRA_CLAUDE" >"$work/cmd"
env | grep -E '^FLEET_(SETTINGS|ACCOUNT|SUCCEEDS)=' >"$work/launcher-env"
tmux -L "\$KLEPSYDRA_TMUX_SOCKET" new-window -d -t fleet: -c "\$3" "\$KLEPSYDRA_CLAUDE"
EOF
printf '%s' '{"above":["Claude Code"]}' >"$work/nosettings.json"; : >"$work/nosettings.log"
FLEET_SETTINGS='' FLEET_SCOPE=0 FLEET_MIN_AVAIL_MB=0 FLEET_LAUNCHER="$work/launcher-rec.sh" FLEET_DIR="$work" \
  FLEET_CLAUDE="python3 -I $fake $work/nosettings.json $work/nosettings.log" bash "$here/launch.sh" nosettings "$work/task.src" >/dev/null 2>&1
check "FLEET_SETTINGS= starts claude with no --settings" "$(grep -c -- '--settings' "$work/cmd") $(grep -c -- '--session-id' "$work/cmd")" "0 1"
check "#273: no session starts with KERYX_ENABLED: keryx's own setting decides, live" \
  "$(jq -r '.env.KERYX_ENABLED // "unset"' "$here/worker-settings.json") $(grep -c 'KERYX_ENABLED=' "$work/cmd")" "unset 0"
check "#172: the session is told its agent's name, so its card keeps its face across a move" "$(grep -c 'KLEPSYDRA_AGENT=nosettings ' "$work/cmd")" "1"
check "#226: and no successor unless a move names one" "$(grep -c 'KLEPSYDRA_SUCCEEDS' "$work/cmd")" "0"
FLEET_SUCCEEDS=11111111-2222-4333-8444-555555555555 FLEET_SETTINGS='' FLEET_SCOPE=0 FLEET_MIN_AVAIL_MB=0 FLEET_LAUNCHER="$work/launcher-rec.sh" FLEET_DIR="$work" \
  FLEET_CLAUDE="python3 -I $fake $work/nosettings.json $work/nosettings.log" bash "$here/launch.sh" nosettings "$work/task.src" >/dev/null 2>&1
check "#226: a move's successor id reaches the session; anything else is dropped" \
  "$(grep -c 'KLEPSYDRA_SUCCEEDS=11111111-2222-4333-8444-555555555555 ' "$work/cmd")" "1"
check "#183 review 2: keryx's switch is never inherited from tmux's environment" "$(grep -c "^bash -c '.*' fleet-oom env -u KERYX_ENABLED " "$work/cmd")" "1"
check "#309: the orchestrator's launch (no worker settings) sets no worker mark, and drops an inherited one" "$(grep -c 'KLEPSYDRA_WORKER=' "$work/cmd") $(grep -c -- '-u KLEPSYDRA_WORKER ' "$work/cmd")" "0 1"
check "#310 review 1: the launcher gets none of the launch's FLEET_* settings, so a server it starts hands them to no later pane" \
  "$(cat "$work/launcher-env")" ""
# A real worker launch: FLEET_SETTINGS unset (worker-settings.json), claude's own
# environment read, an inherited mark dropped on the orchestrator's (#310 review 1).
cat >"$work/envclaude.sh" <<EOF
#!/usr/bin/env bash
{ echo ran; env | grep -E '^KLEPSYDRA_WORKER='; } >"$work/claude-env"
exec python3 -I $fake $work/nosettings.json $work/nosettings.log
EOF
chmod +x "$work/envclaude.sh"
: >"$work/claude-env"
( unset FLEET_SETTINGS; FLEET_SCOPE=0 FLEET_MIN_AVAIL_MB=0 FLEET_LAUNCHER="$work/launcher-rec.sh" FLEET_DIR="$work" \
  FLEET_CLAUDE="$work/envclaude.sh" bash "$here/launch.sh" nosettings "$work/task.src" >/dev/null 2>&1 )
for _ in $(seq 50); do [[ -s $work/claude-env ]] && break; sleep 0.1; done
check "#309: a worker's claude runs with the mark in its environment, so the stale-PR list skips it" \
  "$(tr '\n' ' ' <"$work/claude-env")$(grep -c -- '--settings' "$work/cmd")" "ran KLEPSYDRA_WORKER=1 1"
: >"$work/claude-env"
KLEPSYDRA_WORKER=1 FLEET_SETTINGS='' FLEET_SCOPE=0 FLEET_MIN_AVAIL_MB=0 FLEET_LAUNCHER="$work/launcher-rec.sh" FLEET_DIR="$work" \
  FLEET_CLAUDE="$work/envclaude.sh" bash "$here/launch.sh" nosettings "$work/task.src" >/dev/null 2>&1
for _ in $(seq 50); do [[ -s $work/claude-env ]] && break; sleep 0.1; done
check "#310 review 1: the orchestrator's claude drops a mark inherited from its caller" "$(tr '\n' ' ' <"$work/claude-env")" "ran "

echo "fleet voices: keryx follows the tray's mode, live (#273)"
# Stub keryx installs laid out as the plugin's (bin/ beside src/keryx), keeping
# their settings where keryx does and recording each call; keryx-old predates
# speak_only (0.11.0), keryx-flaky refuses speak-only once.
mkdir -p "$work/xdg/keryx"
stub_keryx() { # DIR [old|flaky]
  mkdir -p "$1/bin" "$1/src/keryx"
  if [[ ${2:-} == old ]]; then echo 'COMMANDS = ("on", "off")' >"$1/src/keryx/__main__.py"; else echo 'COMMANDS = ("on", "off", "speak-only")' >"$1/src/keryx/__main__.py"; fi
  cat >"$1/bin/keryx" <<EOF
#!/usr/bin/env bash
c=\${XDG_CONFIG_HOME}/keryx/config.json
[[ -s \$c ]] || echo '{}' >"\$c"
printf '%s\\n' "\$*" >>"\${XDG_CONFIG_HOME}/keryx/calls"
mode=${2:-}
if [[ \$1 == speak-only && \$mode == flaky && ! -e $1/failed-once ]]; then : >"$1/failed-once"; exit 1; fi
case \$1 in
  on) jq '.enabled = true' "\$c" >"\$c.t" && mv "\$c.t" "\$c" ;;
  off) jq '.enabled = false' "\$c" >"\$c.t" && mv "\$c.t" "\$c" ;;
  speak-only) shift; if [[ \$1 == --everyone ]]; then jq '.speak_only = []' "\$c" >"\$c.t"; else jq --args '.speak_only = \$ARGS.positional' "\$@" <"\$c" >"\$c.t"; fi && mv "\$c.t" "\$c" ;;
esac
EOF
  chmod +x "$1/bin/keryx"
}
stub_keryx "$work/kx"; stub_keryx "$work/kxold" old; stub_keryx "$work/kxflaky" flaky
kc="$work/xdg/keryx/config.json"; kcalls="$work/xdg/keryx/calls"; orch_rec=$(realpath -m "$FLEET_STATE/orchestrator.session")
fvk() { local k=$1; shift; : >"$kcalls"; FLEET_KERYX="$k/bin/keryx" bash "$here/fleet" voices "$@" 2>/dev/null; } # KERYX-DIR [ARGS]
fv() { fvk "$work/kx" "$@"; }
vreset() { rm -f "$kc" "$KLEPSYDRA_DIR/prefs.json" "$FLEET_STATE/voices.applied" "$FLEET_STATE/voices.failed"; }
vreset
check "#273: with no saved mode, Heph only: keryx speaks only for the orchestrator's session" \
  "$(fv) | $(jq -c '[.enabled // true, .speak_only]' "$kc") $(cat "$FLEET_STATE/voices.applied")" "voices: heph (changed: speak_only) | [true,[\"$orch_rec\"]] heph"
check "#273: run again, nothing changes and keryx is not called" "$(fv) $(wc -l <"$kcalls")" "voices: heph (keryx already matches) 0"
check "#273: fleet voices off saves the mode and turns keryx off" \
  "$(fv off) | $(jq -r .voices "$KLEPSYDRA_DIR/prefs.json") $(jq -c .enabled "$kc")" "voices: off (changed: enabled) | off false"
check "#273: Everyone turns it on, first, for every session" \
  "$(fv everyone) | $(jq -c '[.enabled, .speak_only]' "$kc") $(head -1 "$kcalls")" "voices: everyone (changed: enabled speak_only) | [true,[]] on"
check "#273: each change is logged with the values decided on" \
  "$(jq -r 'select(.message == "voices: keryx set to the tray'"'"'s mode") | "\(.mode) \(.enabled) \(.was_enabled)"' "$FLEET_LOG" | tail -1)" "everyone true false"
# The service's pass: a mode applies once; AJ's own keryx off between changes stays.
"$work/kx/bin/keryx" off
check "#273 review: --if-changed leaves a manual keryx off alone while the mode is unchanged" \
  "$(fv --if-changed; jq -c .enabled "$kc") $(wc -l <"$kcalls")" "false 0"
printf '{"voices":"heph","theme":"kourai"}' >"$KLEPSYDRA_DIR/prefs.json"
check "#273 review: --check names a saved mode not yet applied" "$(fv --check; echo "rc=$?")" $'heph not applied (last applied: everyone): fleet voices applies it\nrc=1'
check "#273: a changed mode the tray saved applies at the next pass, other prefs kept" \
  "$(fv --if-changed) | $(jq -c '[.enabled, .speak_only]' "$kc") $(jq -r .theme "$KLEPSYDRA_DIR/prefs.json")" "voices: heph (changed: enabled speak_only) | [true,[\"$orch_rec\"]] kourai"
check "#273: and --check then says so" "$(fv --check; echo "rc=$?")" $'applied heph\nrc=0'
"$work/kx/bin/keryx" off
check "#273 verify: --check names keryx turned off by hand since, still ok" "$(fv --check; echo "rc=$?")" $'applied heph; keryx is off now (turned off by hand?)\nrc=0'
"$work/kx/bin/keryx" on
for odd in 'not json' '{"voices":"loud"}' '{"voices":["off"]}' '{"voices":"off"}{}' 'null'; do
  printf '%s' "$odd" >"$KLEPSYDRA_DIR/prefs.json"
  check "#273: a prefs file reading $odd is Heph only" "$(fv | cut -d' ' -f2)" "heph"
done
check "#273: an unknown mode is refused" "$(fv loud >/dev/null 2>&1; echo $?)" "2"
vreset
check "#273: no keryx installed: said, and nothing fails" "$(FLEET_KERYX="$work/no-keryx" bash "$here/fleet" voices 2>/dev/null; echo "rc=$?")" $'keryx is not installed\nrc=0'
FLEET_KERYX="$work/no-keryx" bash "$here/fleet" voices --if-changed >/dev/null 2>&1; FLEET_KERYX="$work/no-keryx" bash "$here/fleet" voices --if-changed >/dev/null 2>&1
check "#273 verify: and the service says it once, and --check names it" \
  "$(jq -r 'select(.message | startswith("voices: keryx is not installed")) | .mode' "$FLEET_LOG" | wc -l) $(FLEET_KERYX="$work/no-keryx" bash "$here/fleet" voices --check 2>/dev/null | grep -c 'keryx is not installed')" "1 1"
# Two runs at once never interleave: a slow keryx (uv's start) holds the first.
vreset; echo '{"speak_only":[]}' >"$kc"
cat >"$work/kxslow-wrap" <<EOF
#!/usr/bin/env bash
sleep 1; exec "$work/kx/bin/keryx" "\$@"
EOF
chmod +x "$work/kxslow-wrap"; mkdir -p "$work/kxslow/bin" "$work/kxslow/src/keryx"; cp "$work/kx/src/keryx/__main__.py" "$work/kxslow/src/keryx/"; cp "$work/kxslow-wrap" "$work/kxslow/bin/keryx"
FLEET_KERYX="$work/kxslow/bin/keryx" bash "$here/fleet" voices off >/dev/null 2>&1 &
sleep 0.3
FLEET_KERYX="$work/kxslow/bin/keryx" bash "$here/fleet" voices heph >/dev/null 2>&1
wait
check "#273 verify: Off then Heph clicked together ends as Heph, keryx on, as recorded" \
  "$(jq -r .voices "$KLEPSYDRA_DIR/prefs.json") $(cat "$FLEET_STATE/voices.applied") $(jq -c '[.enabled, (.speak_only | length)]' "$kc")" "heph heph [true,1]"
flock "$FLEET_STATE/voices.lock" sleep 4 &
sleep 0.3
t0=$(date +%s)
fv --check >/dev/null; fv --if-changed >/dev/null
check "#273 verify 2: --check and an idle service pass never wait behind a running apply" "$(( $(date +%s) - t0 < 2 ))" "1"
wait
# A service pass that waited behind a failing run does not try keryx again.
vreset; echo '{"speak_only":[]}' >"$kc"; : >"$kcalls"; : >"$FLEET_LOG"
mkdir -p "$work/kxfail/bin" "$work/kxfail/src/keryx"; cp "$work/kx/src/keryx/__main__.py" "$work/kxfail/src/keryx/"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nsleep 1; exit 1\n' "$kcalls" >"$work/kxfail/bin/keryx"; chmod +x "$work/kxfail/bin/keryx"
FLEET_KERYX="$work/kxfail/bin/keryx" bash "$here/fleet" voices >/dev/null 2>&1 &
sleep 0.3
FLEET_KERYX="$work/kxfail/bin/keryx" bash "$here/fleet" voices --if-changed >/dev/null 2>&1
wait
check "#273 verify 3: a pass that waited behind a failing run does not try keryx again, nor log it twice" \
  "$(grep -c speak-only "$kcalls") $(jq -r 'select(.message == "voices: keryx could not be set to the tray'"'"'s mode") | .mode' "$FLEET_LOG" | wc -l)" "1 1"
# A keryx without speak_only (0.11.0): keryx is still turned on, the rest is said once.
vreset; echo '{"enabled": false}' >"$kc"
check "#273 review: a keryx without speak_only still turns keryx on, never runs speak-only, and fails" \
  "$(fvk "$work/kxold" heph >/dev/null; echo $?) $(jq -c .enabled "$kc") $(grep -c speak-only "$kcalls")" "1 true 0"
fvk "$work/kxold" --if-changed >/dev/null; fvk "$work/kxold" --if-changed >/dev/null
check "#273 review: and the service does not retry it, nor log it again, until another keryx is installed" \
  "$(jq -r 'select(.message == "voices: keryx could not be set to the tray'"'"'s mode") | .failed' "$FLEET_LOG" | grep -c 'keryx<0.12.0')" "1"
check "#273 review: --check says to update keryx" "$(fvk "$work/kxold" --check | grep -c 'update the keryx plugin to 0.12.0')" "1"
check "#273 review: a newer keryx is tried at once" "$(fv --if-changed)" "voices: heph (changed: speak_only)"
# A failure that is not a missing feature (a timeout, a failed sync) is retried after 15 min.
vreset
fvk "$work/kxflaky" >/dev/null
check "#273 review: a passing failure is not taken for an old keryx, and is not recorded as applied" \
  "$(cut -d' ' -f3 "$FLEET_STATE/voices.failed") [$(cat "$FLEET_STATE/voices.applied" 2>/dev/null)]" "other []"
check "#273 review: the service waits before trying again" "$(fvk "$work/kxflaky" --if-changed; wc -l <"$kcalls")" "0"
sed -i 's/^heph [0-9]* other /heph 1000 other /' "$FLEET_STATE/voices.failed"
check "#273 review: then tries again, and succeeds" "$(fvk "$work/kxflaky" --if-changed)" "voices: heph (changed: speak_only)"
# Which keryx: the newest version across both accounts' plugin caches.
vreset
stub_keryx "$work/home/.claude/plugins/cache/techne/keryx/0.11.0" old
stub_keryx "$work/home/.claude-rit/plugins/cache/techne/keryx/0.12.0"
check "#273 review: the newest keryx across both accounts' caches is used (0.12.0 under .claude-rit, not 0.11.0)" \
  "$(env -u FLEET_KERYX HOME="$work/home" bash "$here/fleet" voices 2>/dev/null)" "voices: heph (changed: speak_only)"
vreset; rm -f "$kcalls"

echo "briefing sync"
git init -q --bare "$work/brief-remote.git"
git clone -q "$work/brief-remote.git" "$work/brief" 2>/dev/null
git -C "$work/brief" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init && git -C "$work/brief" push -q origin HEAD 2>/dev/null
printf '#!/usr/bin/env bash\n[[ -e %s ]] && { echo "leak: token"; exit 1; }\nexit 0\n' "$work/leak" >"$work/bin/gitleaks"; chmod +x "$work/bin/gitleaks"
bsync() { BRIEFING_DIR="$work/brief" FLEET_GITLEAKS="$work/bin/gitleaks" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t bash "$here/sync-briefing.sh" 2>/dev/null; echo $?; }
check "nothing changed: no commit" "$(bsync) $(git -C "$work/brief" rev-list --count HEAD)" "0 1"
printf 'q\n' >"$work/brief/queue.md"; printf 'n\n' >"$work/brief/needs-you.md"; printf 'x\n' >"$work/brief/notes.txt"
touch "$work/leak"
check "a gitleaks finding blocks the commit, and is logged" "$(bsync) $(git -C "$work/brief" rev-list --count HEAD) $(jq -r 'select(.message | contains("gitleaks found")) | .level' "$FLEET_LOG")" "1 1 ERROR"
check "and leaves nothing staged" "$(git -C "$work/brief" diff --cached --name-only | wc -l)" "0"
rm -f "$work/leak"
printf '#!/usr/bin/env bash\necho "ERR [git] fatal: bad object" >&2\nexit 0\n' >"$work/bin/gitleaks-err"; chmod +x "$work/bin/gitleaks-err"
check "a scanner that exits 0 with an error is no verdict" \
  "$(BRIEFING_DIR="$work/brief" FLEET_GITLEAKS="$work/bin/gitleaks-err" bash "$here/sync-briefing.sh" 2>/dev/null; echo $?) $(git -C "$work/brief" rev-list --count HEAD)" "1 1"
check "a change is committed and pushed" "$(bsync) $(git -C "$work/brief-remote.git" rev-list --count HEAD)" "0 2"
check "only the briefing's own files go in, AJ's needs-you.md included" "$(git -C "$work/brief" show --name-only --format= HEAD | paste -sd' ')" "needs-you.md queue.md"
git -C "$work/brief" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "a prune commit"
touch "$work/leak"
check "a commit about to be pushed is scanned first" "$(bsync) $(git -C "$work/brief-remote.git" rev-list --count HEAD)" "1 2"
rm -f "$work/leak"; mkdir "$work/brief/.git/rebase-merge"
check "an unfinished rebase is left for a person" "$(bsync) $(git -C "$work/brief-remote.git" rev-list --count HEAD)" "1 2"
rmdir "$work/brief/.git/rebase-merge"
check "a commit made while the tree is clean is still pushed" "$(bsync) $(git -C "$work/brief-remote.git" rev-list --count HEAD)" "0 3"
git clone -q "$work/brief-remote.git" "$work/brief-phone" 2>/dev/null
printf 'ticked\n' >"$work/brief-phone/README.md"
git -C "$work/brief-phone" add README.md && git -C "$work/brief-phone" -c user.name=t -c user.email=t@t commit -q -m phone && git -C "$work/brief-phone" push -q origin HEAD 2>/dev/null
printf 'q2\n' >"$work/brief/queue.md"
check "a push the remote rejects rebases once and lands both" "$(bsync) $(git -C "$work/brief-remote.git" rev-list --count HEAD)" "0 5"
printf 'o\n' >"$work/brief/other.md"; git -C "$work/brief" add other.md && git -C "$work/brief" -c user.name=t -c user.email=t@t commit -q -m other && git -C "$work/brief" push -q origin HEAD 2>/dev/null
git -C "$work/brief-phone" pull -q 2>/dev/null; printf 'ticked again\n' >"$work/brief-phone/README.md"
git -C "$work/brief-phone" -c user.name=t -c user.email=t@t commit -qam phone2 && git -C "$work/brief-phone" push -q origin HEAD 2>/dev/null
printf 'o\nan edit in progress\n' >"$work/brief/other.md"; printf 'q3\n' >"$work/brief/queue.md"
check "a rejected push with edits in the tree waits rather than rebasing over them" \
  "$(bsync) $(tail -1 "$work/brief/other.md") $(git -C "$work/brief" ls-files -u | wc -l)" "1 an edit in progress 0"
git -C "$work/brief" checkout -q -- other.md
check "once the tree is clean it rebases and pushes" "$(bsync) $(git -C "$work/brief" rev-list --count '@{u}..HEAD')" "0 0"
printf 'm\n' >"$work/brief/claude-morning.md"
check "#277: a file under its old name is still committed" "$(bsync) $(git -C "$work/brief" show --name-only --format= HEAD)" "0 claude-morning.md"
mv "$work/brief/claude-morning.md" "$work/brief/morning.md"
check "#277: a plain mv to the new name commits as one rename and leaves neither name behind" \
  "$(bsync) $(git -C "$work/brief" show -M --name-status --format= HEAD | tr '\t' ' ' | paste -sd' ') $(git -C "$work/brief" status --porcelain -- claude-morning.md morning.md | wc -l)" "0 R100 claude-morning.md morning.md 0"

echo "fleet send: a message is submitted, never left in the box (#320)"
fsend() { bash "$here/send.sh" "$@" 2>/dev/null; }
p=$(pane snd '{"above":["idle"],"enter_ignore":1,"on_submit":"none"}'); settle
msg="Heph: #322 is red on its current head; read the report under ci/ and fix it before #319's follow-ups. This line runs past two hundred characters on purpose, as the 11-04 sends that stayed in the box did."
out=$(fsend "$p" "$msg"); rc=$?
check "#320: a long message whose first Enter is lost is still submitted, once" \
  "$out $rc $(grep -c "^SUBMIT ${msg:0:40}" "$work/snd.log") $(grep -c 'KEY ENTER (lost after a paste)' "$work/snd.log")" "sent 0 1 1"
check "and it is logged with its pane and length" "$(jq -r 'select(.message == "message sent") | [.pane, .chars] | join(" ")' "$FLEET_LOG" | tail -1)" "$p ${#msg}"
state snd '{"above":["working"],"busy":true,"on_submit":"none"}'; settle
check "#320: a running turn is no bar: the message is queued (sent)" "$(fsend "$p" "a note for later")" "sent"
state snd '{"above":["idle"],"input":"AJ is typing","on_submit":"none"}'; settle
: >"$work/snd.log"
check "#320: text already in the box is never touched" \
  "$(fsend "$p" "x"; echo "rc=$?") $(grep -c . "$work/snd.log") $(input_text "$(screen "$p")")" $'not-pasted\nrc=1 0 AJ is typing'
check "#320: stdin as the message" "$(state snd '{"above":["idle"],"clear":true,"on_submit":"none"}'; settle; printf 'from stdin\n' | fsend "$p" -)" "sent"
check "#320: a pane the server does not have, or no text, is refused (2)" \
  "$(fsend %99999 "x"; echo -n "$? "; fsend "$p" "   "; echo -n "$? "; fsend "$p"; echo $?)" "2 2 2"
check "#325 review 1: a target that is not a pane id (a window) is refused (2)" "$(fsend fleet:1 "x"; echo $?)" "2"
t kill-window -t "$p"
p=$(pane snb '{"above":["working"],"busy":true,"enter_ignore":1,"on_submit":"none"}'); settle
out=$(fsend "$p" "queued while busy, first Enter lost"); rc=$?
check "#325 review 1: a busy pane whose first Enter is lost still gets the message, once" \
  "$out $rc $(grep -c '^SUBMIT queued while busy' "$work/snb.log") $(grep -c 'KEY ENTER (lost after a paste)' "$work/snb.log")" "sent 0 1 1"
t kill-window -t "$p"
# A dialog (here the limit menu) takes the box's place while the first Enter is lost.
p=$(pane snm '{"above":["working"],"busy":true,"enter_ignore":1,"on_submit":"none"}'); settle
fsend "$p" "message while a dialog comes up" >"$work/snm.out" &
n2=$!
sleep 1.5
state snm '{"above":["working"],"busy":true,"on_submit":"none","menu":"limit"}'
wait "$n2"
check "#325 review 1: no Enter lands on a dialog that took the box's place; the send says held" \
  "$(grep -c 'LIMIT MENU STOP' "$work/snm.log") $(cat "$work/snm.out")" "0 held"
t kill-window -t "$p"
# Two senders at once (two workers reporting to Heph): one waits for the other.
p=$(pane snc '{"above":["idle"],"on_submit":"none"}'); settle
fsend "$p" "report A from worker one" >"$work/snc.a" &
a=$!
fsend "$p" "report B from worker two" >"$work/snc.b" &
b=$!
wait "$a" "$b"
check "#325 review 1: two sends at once to one pane both go, one after the other, never glued in the box" \
  "$(cat "$work/snc.a") $(cat "$work/snc.b") $(grep -c '^SUBMIT report [AB] from worker' "$work/snc.log") [$(input_text "$(screen "$p")")]" "sent sent 2 []"
t kill-window -t "$p"
check "#325 review 1: no message file is left under send/" "$(find "$FLEET_STATE/send" -type f 2>/dev/null | wc -l)" "0"
# A send still waiting for the pane's lock after FLEET_SEND_WAIT gives up untyped.
p=$(pane snl '{"above":["idle"],"on_submit":"none"}'); settle
exec 8>"$FLEET_STATE/locks/send-${p#%}"
flock 8
: >"$work/snl.log"
check "#325 review 2: a send that waits past FLEET_SEND_WAIT for another's lock says not-pasted and types nothing" \
  "$(FLEET_SEND_WAIT=1 fsend "$p" "behind a held lock"; echo "rc=$?") $(grep -c . "$work/snl.log")" $'not-pasted\nrc=1 0'
exec 8>&-
mkdir -p -- "$FLEET_STATE/locks/send-${p#%}.d" && mv -f -- "$FLEET_STATE/locks/send-${p#%}" "$FLEET_STATE/locks/send-${p#%}.f" && mv -- "$FLEET_STATE/locks/send-${p#%}.d" "$FLEET_STATE/locks/send-${p#%}"
check "#325 review 2: a lock file that cannot be opened (a folder in its place) reads as not-pasted" \
  "$(inbox_deliver "$p" /dev/null 2>/dev/null)" "not-pasted"
rmdir -- "$FLEET_STATE/locks/send-${p#%}" && mv -- "$FLEET_STATE/locks/send-${p#%}.f" "$FLEET_STATE/locks/send-${p#%}"
t kill-window -t "$p"
p=$(pane snt '{"above":["⏺ Done.","You'"'"'ve hit your session limit · resets 1:10pm (America/New_York)"],"on_submit":"none"}'); settle
: >"$work/snt.log"
check "#325 review 2: a pane at a usage limit gets nothing; the send says limited" \
  "$(fsend "$p" "nudge"; echo "rc=$?") $(grep -c . "$work/snt.log")" $'limited\nrc=1 0'
t kill-window -t "$p"
# A limit line still on screen above a running turn (Claude Code continued on its own) is past.
p=$(pane snu '{"above":["You'"'"'ve hit your session limit · resets 1:10pm (America/New_York)","working"],"busy":true,"on_submit":"none"}'); settle
check "#325 review 3: a busy pane with a limit line still on screen is no limited pane: the message is queued" \
  "$(fsend "$p" "report after the reset")" "sent"
t kill-window -t "$p"
# The hook's StopFailure record is a limit too (#311), though the screen shows only a generic error.
p=$(pane snh '{"above":["⏺ Done.","API Error: Request failed"],"on_submit":"none"}'); settle
stop_file aaaaaaaa-0000-4000-8000-000000000325 "$p" "$(date +%s)" "" "$L5"
: >"$work/snh.log"
check "#325 review 4: a pane the hook recorded at a usage limit gets nothing; the send says limited" \
  "$(fsend "$p" "nudge"; echo "rc=$?") $(grep -c . "$work/snh.log")" $'limited\nrc=1 0'
check "#325 review 4: pane_limited gives the record's reset and its message" \
  "$(pane_limited "$p" "$(screen "$p")" | cut -f2)" "$L5"
rm -f -- "${KLEPSYDRA_DIR:?}/fleet/aaaaaaaa-0000-4000-8000-000000000325.json"
check "#325 review 4: without the record the same pane takes the message" "$(fsend "$p" "nudge")" "sent"
t kill-window -t "$p"
# Every typer holds the pane's typing lock: with it held, none types.
p=$(pane sny '{"above":["idle"],"on_submit":"none"}'); settle
echo "a brief" >"$work/sny.txt"
exec 8>"$FLEET_STATE/locks/send-${p#%}"
flock 8
: >"$work/sny.log"
FLEET_SEND_WAIT=1 remote_control "$p"; rc1=$?
got=$(FLEET_SEND_WAIT=1 deliver "$p" "$work/sny.txt")
FLEET_SEND_WAIT=1 retire "$p" 2>/dev/null; rc2=$?
check "#325 review 4: with the pane's lock held, remote_control, deliver and retire type nothing" \
  "$rc1 $got $rc2 $(grep -c . "$work/sny.log") $(fleet_panes | grep -cx -- "$p")" "75 not-delivered 1 0 1"
exec 8>&-
check "#325 review 4: a sequence nested in a held one runs at once" \
  "$(FLEET_SEND_WAIT=1 pane_locked "$p" pane_locked "$p" echo nested; echo $?)" $'nested\n0'
# The pane stops at a limit while a send waits for the lock: it is read again under the lock.
# The sender gets no fd 8: holding the test's lock itself, it would wait out FLEET_SEND_WAIT.
exec 8>"$FLEET_STATE/locks/send-${p#%}"
flock 8
FLEET_SEND_WAIT=20 fsend "$p" "sent into a limit" >"$work/sny.out" 8>&- &
n2=$!
sleep 1
state sny '{"above":["⏺ Done.","You'"'"'ve hit your session limit · resets 1:10pm (America/New_York)"],"on_submit":"none"}'; settle
: >"$work/sny.log"
exec 8>&-
wait "$n2"
check "#325 review 4: a limit reached during the lock wait gets nothing" "$(cat "$work/sny.out") $(grep -c . "$work/sny.log")" "limited 0"
t kill-window -t "$p"

echo "the tmux server watchdog (#290)"
: >"$FLEET_LOG"
tw="$work/tw"; mkdir -p "$tw/proc/7001" "$tw/crashes"
echo 33333333-3333-4333-8333-333333333333 >"$tw/boot"
# Booted at 1793700000; server 7001 started 555 ticks (5 s) after: a dump counts from 1793700005.
printf 'cpu  1 2 3\nbtime 1793700000\n' >"$tw/proc/stat"
printf '#!/usr/bin/env bash\necho recover >>%q\necho "recovered: x -> %%%%9"\n' "$tw/recover.calls" >"$tw/recover"; chmod +x "$tw/recover"
# The journal as journalctl reads it (#292 review 3): fixture lines are "BOOT
# EPOCH TEXT"; -b alone is this boot, -b ID another, --since @N drops older lines.
cat >"$tw/journal" <<EOF
#!/usr/bin/env bash
b=\$(tr -d - <"$tw/boot") since=0
while (( \$# )); do
  case \$1 in
    -b) [[ \${2:-} =~ ^[0-9a-f]{32}\$ ]] && { b=\$2; shift; } ;;
    --since) since=\${2#@}; shift ;;
  esac
  shift
done
awk -v b="\$b" -v s="\$since" '\$1 == b && \$2 >= s { sub(/^[^ ]+ [^ ]+ /, ""); print }' "$tw/kernel" 2>/dev/null
EOF
chmod +x "$tw/journal"
CUR=33333333-3333-4333-8333-333333333333 PREV=22222222-2222-4222-8222-222222222222
CAP="WSL (1291 - CaptureCrash): Capturing crash for pid: 7001, executable: !usr!bin!tmux, signal: 11, port: 50005"
jl() { printf '%s %s Nov 03 06:02:27 host unknown: %s\n' "${1//-/}" "$2" "$3" >>"$tw/kernel"; } # BOOT EPOCH TEXT
stat7001() { printf '7001 (tmux: server) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' "$1" >"$tw/proc/7001/stat"; }
# W: the watchdog against a socket that answers (FLEET_SOCK) or none (WSOCK=gone).
W() { FLEET_SOCK=${WSOCK:-$FLEET_SOCK} FLEET_PROC=${WPROC:-/proc} FLEET_BOOT_ID="$tw/boot" FLEET_CRASH_DIR="$tw/crashes" \
  FLEET_JOURNAL="$tw/journal" FLEET_RECOVER="${WREC:-$tw/recover}" WSL_DISTRO_NAME=Test FLEET_INTEROP_PROBE=${WPROBE:-true} \
  FLEET_INIT_INTEROP="$tw/no-interop" bash "$here/tmux-watch.sh" 2>/dev/null; }
rm -f -- "$FLEET_STATE/tmux-server"
W
check "#290: the answering server is recorded with its pid and this boot" \
  "$(cut -d' ' -f1,3 "$FLEET_STATE/tmux-server")" "$(t display -p '#{pid}') 33333333-3333-4333-8333-333333333333"
check "#292 review 3: and when it started, as an epoch" "$(awk '{ print NF, ($4 ~ /^[0-9]+$/) }' "$FLEET_STATE/tmux-server")" "4 1"
# #292 review 4: the epoch's value decides what the next boot's journal is read
# from. A /proc of fixed btime (WSL's own steps forward now and then) holding
# the answering server's real stat.
sp=$(t display -p '#{pid}'); mkdir -p "$tw/p2/$sp"; cp "/proc/$sp/stat" "$tw/p2/$sp/stat"; printf 'cpu  1 2 3\nbtime 1793700000\n' >"$tw/p2/stat"
stt=$(cat "$tw/p2/$sp/stat"); read -ra stf <<<"${stt##*) }"
rm -f -- "$FLEET_STATE/tmux-server"; WPROC="$tw/p2" W
check "#292 review 4: the epoch is the boot's btime plus the server's start in seconds" \
  "$(cut -d' ' -f4 "$FLEET_STATE/tmux-server")" "$(( 1793700000 + stf[19] / $(getconf CLK_TCK) ))"
rm -f -- "$FLEET_STATE/tmux-server"; W
cut -d' ' -f1-3 "$FLEET_STATE/tmux-server" >"$work/tsold"; cp "$work/tsold" "$FLEET_STATE/tmux-server"; : >"$FLEET_LOG"
W
check "#292 review 3: a record from before the epoch was kept, of the same server: kept again with it, nothing recovered" \
  "$(awk '{ print NF }' "$FLEET_STATE/tmux-server") $(grep -c "watching the fleet's tmux server" "$FLEET_LOG") $(grep -c 'crashed' "$FLEET_LOG")" "4 1 0"
W
check "#290: an unchanged server is logged once" "$(grep -c "watching the fleet's tmux server" "$FLEET_LOG")" "1"
# A recorded server 7001 (start 555) that has since gone.
gone_server() { echo "7001 555 $(cat "$tw/boot") 1793700005" >"$FLEET_STATE/tmux-server"; rm -f -- "$tw/proc/7001/stat" "$tw/recover.calls" "$tw/kernel" "$tw"/crashes/*; }
gone_server
WSOCK=gone-$$ WPROC="$tw/proc" W
check "#290: gone with no crash record: logged, never recovered" \
  "$(grep -c 'ended with no crash record' "$FLEET_LOG") $(cat "$tw/recover.calls" 2>/dev/null || echo none) $(test -e "$FLEET_STATE/tmux-server" && echo kept || echo cleared)" "1 none cleared"
gone_server; : >"$tw/crashes/wsl-crash-1793703747-7001-_usr_bin_tmux-11.dmp"
WSOCK=gone-$$ WPROC="$tw/proc" W
check "#290: WSL's crash dump for its pid: fleet recover runs once, logged with the signal" \
  "$(cat "$tw/recover.calls") $(jq -r 'select(.message | startswith("the fleet'"'"'s tmux server crashed")) | .signal' "$FLEET_LOG")" "recover 11"
WSOCK=gone-$$ WPROC="$tw/proc" W
check "#290: the next minute does not recover again" "$(wc -l <"$tw/recover.calls")" "1"
gone_server; jl "$CUR" 1793703747 "tmux: server[7001]: segfault at 118 ip 00007d65 sp 00007ffd error 4 in libevent_core-2.1.so.7"
WSOCK=gone-$$ WPROC="$tw/proc" W
check "#292 review: the kernel's segfault line (another pid namespace's pid) is no crash record" "$(cat "$tw/recover.calls" 2>/dev/null || echo none)" "none"
gone_server; jl "$CUR" 1793703747 "$CAP"
WSOCK=gone-$$ WPROC="$tw/proc" W
check "#292 review: WSL's CaptureCrash line for its pid alone is a crash record" "$(cat "$tw/recover.calls")" "recover"
gone_server; jl "$CUR" 1793703747 "${CAP/pid: 7001/pid: 7002}"
WSOCK=gone-$$ WPROC="$tw/proc" W
check "#292 review 3: a CaptureCrash line for another pid is no crash record" "$(cat "$tw/recover.calls" 2>/dev/null || echo none)" "none"
gone_server; jl "$CUR" 1793690000 "$CAP"
WSOCK=gone-$$ WPROC="$tw/proc" W
check "#292 review 3: one for its pid dated before the server started is none either" "$(cat "$tw/recover.calls" 2>/dev/null || echo none)" "none"
gone_server; jl "$PREV" 1793703747 "$CAP"
WSOCK=gone-$$ WPROC="$tw/proc" W
check "#292 review 3: nor one in another boot's journal" "$(cat "$tw/recover.calls" 2>/dev/null || echo none)" "none"
gone_server; : >"$tw/crashes/wsl-crash-1793690000-7001-_usr_bin_tmux-11.dmp"; : >"$FLEET_LOG"
WSOCK=gone-$$ WPROC="$tw/proc" W
check "#292 review: a dump from before the server started (an earlier boot's, its pid reused) is no crash record" \
  "$(cat "$tw/recover.calls" 2>/dev/null || echo none) $(grep -c 'ended with no crash record' "$FLEET_LOG")" "none 1"
gone_server; : >"$tw/crashes/wsl-crash-$(date +%s)-7001-_usr_bin_tmux-11.dmp"
W
check "#290: a new server started before the watchdog looked: the old one's crash still recovers, and the new one is recorded" \
  "$(cat "$tw/recover.calls") $(cut -d' ' -f1 "$FLEET_STATE/tmux-server")" "recover $(t display -p '#{pid}')"
gone_server; : >"$tw/crashes/wsl-crash-1-7001-_usr_bin_tmux-11.dmp"; stat7001 555
WSOCK=gone-$$ WPROC="$tw/proc" W
check "#290: the recorded server still runs (it did not answer once): nothing yet" \
  "$(cat "$tw/recover.calls" 2>/dev/null || echo none) $(cut -d' ' -f1 "$FLEET_STATE/tmux-server")" "none 7001"
gone_server; : >"$tw/crashes/wsl-crash-1-7001-_usr_bin_tmux-11.dmp"; echo "7001 555 $PREV 1793600005" >"$FLEET_STATE/tmux-server"
WSOCK=gone-$$ WPROC="$tw/proc" W
check "#290: a server from an earlier boot is left to fleet recover by hand" \
  "$(cat "$tw/recover.calls" 2>/dev/null || echo none) $(grep -c 'from an earlier boot' "$FLEET_LOG")" "none 1"
# #292 review 2: on 11-03 WSL shut down 17 s after the crash took the fleet's
# tab, before the watchdog's next minute; the next boot finds the crash in the
# previous boot's journal and recovers.
gone_server; echo "7001 555 $PREV 1793600005" >"$FLEET_STATE/tmux-server"; jl "$PREV" 1793603747 "$CAP"
: >"$FLEET_LOG"; WSOCK=gone-$$ WPROC="$tw/proc" W
check "#292 review 2: a crash before the last shutdown, in the previous boot's journal: fleet recover runs on this boot" \
  "$(cat "$tw/recover.calls" 2>/dev/null || echo none) $(grep -c 'crashed before the last shutdown' "$FLEET_LOG")" "recover 1"
gone_server; echo "7001 555 $PREV 1793600005" >"$FLEET_STATE/tmux-server"; jl "$CUR" 1793603747 "$CAP"
WSOCK=gone-$$ WPROC="$tw/proc" W
check "#292 review 3: a record of that pid in this boot's journal, not the previous one's, recovers nothing" "$(cat "$tw/recover.calls" 2>/dev/null || echo none)" "none"
gone_server; echo "7001 555 $PREV 1793600005" >"$FLEET_STATE/tmux-server"; jl "$PREV" 1793590000 "$CAP"
WSOCK=gone-$$ WPROC="$tw/proc" W
check "#292 review 3: nor one from that boot dated before the server started (an earlier tmux with its pid)" "$(cat "$tw/recover.calls" 2>/dev/null || echo none)" "none"
gone_server; echo "7001 555 $PREV 1793600005" >"$FLEET_STATE/tmux-server"; jl "$PREV" 1793603747 "${CAP/pid: 7001/pid: 7002}"
WSOCK=gone-$$ WPROC="$tw/proc" W
check "#292 review 3: nor a crash of another pid in that boot" "$(cat "$tw/recover.calls" 2>/dev/null || echo none)" "none"
# #292 review: a recover that cannot reach Windows, or leaves an agent NOT
# STARTED, is tried again each minute, then given up and said so.
crash() { gone_server; : >"$tw/crashes/wsl-crash-1793703747-7001-_usr_bin_tmux-11.dmp"; rm -f -- "$FLEET_STATE/tmux-recover.pending"; : >"$FLEET_LOG"; }
crash; WPROBE=false WSOCK=gone-$$ WPROC="$tw/proc" W
check "#292 review: no Windows interop from the unit: nothing launched, left pending, logged why" \
  "$(cat "$tw/recover.calls" 2>/dev/null || echo none) $(cat "$FLEET_STATE/tmux-recover.pending") $(jq -r 'select(.message | contains("trying again next minute")) | .why' "$FLEET_LOG" | grep -c 'Windows interop did not answer')" "none 7001 1 1"
WSOCK=gone-$$ WPROC="$tw/proc" W
check "#292 review: the next minute, with interop back, it recovers and clears the pending record" \
  "$(cat "$tw/recover.calls") $(test -e "$FLEET_STATE/tmux-recover.pending" && echo pending || echo cleared)" "recover cleared"
printf '#!/usr/bin/env bash\necho recover >>%q\necho "recovered: x -> NOT STARTED"\n' "$tw/recover.calls" >"$tw/recover-ns"; chmod +x "$tw/recover-ns"
crash; for _ in 1 2 3; do FLEET_RECOVER_TRIES=3 WREC="$tw/recover-ns" WSOCK=gone-$$ WPROC="$tw/proc" W; done
check "#292 review: an agent NOT STARTED is tried again each minute, then given up after the tries and said so" \
  "$(wc -l <"$tw/recover.calls") $(test -e "$FLEET_STATE/tmux-recover.pending" && echo pending || echo cleared) $(grep -c 'gave up; run fleet recover by hand' "$FLEET_LOG")" "3 cleared 1"
crash; WSOCK=gone-$$ WPROC="$tw/proc" FLEET_STATE=$FLEET_STATE FLEET_SOCK=gone-$$ FLEET_PROC="$tw/proc" FLEET_BOOT_ID="$tw/boot" FLEET_CRASH_DIR="$tw/crashes" \
  FLEET_JOURNAL="$tw/journal" FLEET_RECOVER="$tw/recover" FLEET_INTEROP_PROBE=true env -u WSL_DISTRO_NAME bash "$here/tmux-watch.sh" 2>/dev/null
check "#292 review: a unit with no WSL_DISTRO_NAME says so and launches nothing" \
  "$(cat "$tw/recover.calls" 2>/dev/null || echo none) $(jq -r '.why // empty' "$FLEET_LOG" | grep -c 'no WSL_DISTRO_NAME')" "none 1"
rm -f -- "$FLEET_STATE/tmux-server" "$FLEET_STATE/tmux-recover.pending"
check "#292 review: install passes WSL_DISTRO_NAME into the watchdog's and the doctor's units, the watchdog with an hour to run" \
  "$(grep -cF 'WSL_DISTRO_NAME:+ \"WSL_DISTRO_NAME=' "$here/install.sh") $(grep -c '^TimeoutStartSec=3600$' "$here/install.sh")" "2 1"

echo "the running server reads the installed conf (#292 review)"
cs="kl-conf-$$" cdir="$work/confdir"; mkdir -p "$cdir"
cp "$here/../hooks/klepsydra-tmux.conf" "$here/../hooks/klepsydra-pane-died.sh" "$cdir/"
tmux -L "$cs" -f /dev/null new-session -d -s fleet "sleep 600"
tmux -L "$cs" set -g remain-on-exit failed
dp=$(tmux -L "$cs" new-window -d -P -F '#{pane_id}' -t fleet: "sh -c 'exit 3'")
for _ in $(seq 30); do [[ $(tmux -L "$cs" display -p -t "$dp" '#{pane_dead}' 2>/dev/null) == 1 ]] && break; sleep 0.1; done
check "a doctor run before: the server has no pane-died hook: a warning" \
  "$(FLEET_SOCK=$cs bash "$here/doctor.sh" 2>/dev/null | grep -c '^warn *pane-died hook: not set')" "1"
FLEET_SOCK=$cs KLEPSYDRA_DEAD_DIR="$work/dead290" bash "$here/tmux-conf.sh" "$cdir" 2>/dev/null; rc=$?
check "tmux-conf.sh: the running server takes the hook, and a pane already dead there is started again" \
  "$rc $(tmux -L "$cs" show-hooks -g pane-died | grep -c 'klepsydra-pane-died.sh') $(tmux -L "$cs" display -p -t "$dp" '#{pane_dead}') $(tmux -L "$cs" show -pqv -t "$dp" @klepsydra_dead | cut -d' ' -f2-)" \
  "0 1 0 its process exited with status 3"
check "and the doctor sees the hook" "$(FLEET_SOCK=$cs FLEET_HOOK_DIR=$cdir bash "$here/doctor.sh" 2>/dev/null | grep -c '^ok *pane-died hook')" "1"
check "#292 review 2: the hook set but its script missing: a warning" \
  "$(FLEET_SOCK=$cs FLEET_HOOK_DIR=$work/nohooks bash "$here/doctor.sh" 2>/dev/null | grep -c '^warn *pane-died hook: set, but .*klepsydra-pane-died.sh is missing')" "1"
printf '[wsl2]\nmemory=8GB\n' >"$work/wslconfig"
check "#292 review 2: a .wslconfig that lets WSL shut down when idle: a warning naming the setting" \
  "$(FLEET_SOCK=$cs FLEET_WSLCONFIG=$work/wslconfig bash "$here/doctor.sh" 2>/dev/null | grep -c '^warn *WSL stays up: add instanceIdleTimeout=-1 under \[general\]')" "1"
printf '[wsl2]\nmemory=8GB\n[General]\n instanceIdleTimeout = -1\n' >"$work/wslconfig"
check "#292 review 2: with instanceIdleTimeout=-1 under [general]: ok" \
  "$(FLEET_SOCK=$cs FLEET_WSLCONFIG=$work/wslconfig bash "$here/doctor.sh" 2>/dev/null | grep -c '^ok *WSL stays up')" "1"
printf '[wsl2]\ninstanceIdleTimeout=-1\n' >"$work/wslconfig"
check "#292 review 2: the setting under [wsl2] does nothing, so still a warning" \
  "$(FLEET_SOCK=$cs FLEET_WSLCONFIG=$work/wslconfig bash "$here/doctor.sh" 2>/dev/null | grep -c '^warn *WSL stays up')" "1"
# #292 review 4: the real gate and path: on WSL (WSL_DISTRO_NAME) the doctor reads
# the .wslconfig in the Windows home above klepsydra's AppData folder.
mkdir -p "$work/Users/x/AppData/Local/k"; printf '[general]\r\ninstanceIdleTimeout=-1\r\n' >"$work/Users/x/.wslconfig"
wdoc() { FLEET_SOCK=$cs KLEPSYDRA_DIR="$work/Users/x/AppData/Local/k" bash "$here/doctor.sh" 2>/dev/null | awk '/ WSL stays up:/ { print $1 }'; }
check "#292 review 4: on WSL, with the Windows home's .wslconfig keeping it up (CRLF): ok; off WSL: no check" \
  "$(WSL_DISTRO_NAME=Test wdoc)|$(wdoc)" "ok|"
printf '[wsl2]\r\nmemory=8GB\r\n' >"$work/Users/x/.wslconfig"
check "#292 review 4: and without the setting there: a warning" "$(WSL_DISTRO_NAME=Test wdoc)" "warn"
tmux -L "$cs" kill-server 2>/dev/null
check "tmux-conf.sh with no server running does nothing" "$(FLEET_SOCK=$cs bash "$here/tmux-conf.sh" "$cdir" 2>/dev/null; echo $?)" "0"

echo "the fleet log"
check "every line is one JSON object with ts, level, target and message" \
  "$(jq -s 'all(has("ts") and has("level") and has("target") and has("message"))' "$FLEET_LOG")" "true"
FLEET_LOG_MAX=200 FLEET_TARGET=fleet::test bash -c ". '$here/lib.sh'; for i in 1 2 3 4 5 6 7 8; do flog INFO line\$i; done"
check "past its cap the log is renamed, and only the newest four are kept" \
  "$(find "${FLEET_LOG%/*}" -name 'fleet_*.log' | wc -l)" "4"

echo "the suite's own isolation"
check "#265 review: no case reached a systemctl it did not stub" "$(cat "$work/guard.calls" 2>/dev/null)" ""
check "#273: no case touched AJ's own keryx config" "$(sha256sum "$real_keryx_config" 2>/dev/null | cut -d' ' -f1)" "$real_keryx_sum"

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))

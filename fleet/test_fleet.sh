#!/usr/bin/env bash
# Tests for the fleet scripts against a private tmux server and fake Claude
# Code panes (tests/fake_pane.py), with no real Claude. Run: bash fleet/test_fleet.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
fake="$here/tests/fake_pane.py"
work=$(mktemp -d)
export TZ=America/New_York # the fixtures' times are AJ's
export FLEET_SOCK="fleet-test-$$" FLEET_STATE="$work/state" FLEET_SESSION=fleet
export KLEPSYDRA_DIR="$work/klepsydra" FLEET_TICK=0.1 FLEET_START_WAIT=4 FLEET_TURN_WAIT=6 FLEET_RC_WAIT=12
mkdir -p "$FLEET_STATE" "$KLEPSYDRA_DIR/accounts/a" "$KLEPSYDRA_DIR/accounts/b"
# Two config folders, logged out until a case logs one in (accounts a and b).
export FLEET_DEFAULT_CONFIG="$work/cfg-a" FLEET_DEFAULT_JSON="$work/cfg-a.json" FLEET_ACCOUNTS="$work/cfg-a $work/cfg-b"
unset CLAUDE_CONFIG_DIR
login() { # a|b
  local d=$work/cfg-$1 j=$work/cfg-$1/.claude.json
  [[ $1 == a ]] && j=$FLEET_DEFAULT_JSON
  mkdir -p "$d"; : >"$d/.credentials.json"
  jq -n --arg u "$1" '{oauthAccount: {accountUuid: $u}}' >"$j"
}
logout() { rm -f -- "$work/cfg-${1:?}/.credentials.json"; }
cleanup() {
  tmux -L "$FLEET_SOCK" kill-server 2>/dev/null
  rm -rf -- "${work:?}"
}
trap cleanup EXIT

pass=0 fail=0
check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
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
  jq -n --arg l "$2" --argjson u "$3" --argjson r "$(( $(date +%s) + 3600 ))" \
    '{label: $l, windows: {five_hour: {used_percentage: $u, resets_at: $r}}}' >"$KLEPSYDRA_DIR/accounts/$1/s.json"
  touch -d "@$4" "$KLEPSYDRA_DIR/accounts/$1/s.json"
}
resume() { FLEET_NOW=$1 bash "$here/resume-at-reset.sh" --once 2>/dev/null; } # NOW
# A registered session, live in pane $1 by klepsydra's fleet file.
SID=11111111-2222-4333-8444-555555555555
mkdir -p "$KLEPSYDRA_DIR/fleet"
live() { jq -n --arg p "$1" '{session_id: "x", ended: null, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/$SID.json"; }
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
state read '{"above":["  ⎿  You'"'"'ve hit your session limit · resets 1:10pm (America/New_York)","",""]}'
check "the limit as the last thing printed" "$(limit_line "$(screen "$p")")" "  ⎿  You've hit your session limit · resets 1:10pm (America/New_York)"
state read '{"above":["  ⎿  You'"'"'ve hit your session limit · resets 1:10pm","a","b","c","d","e","f","g"]}'
check "an old limit far above the prompt is not one" "$(limit_line "$(screen "$p")" || echo none)" "none"
state read '{"above":["x"],"below":["  ⚠ Usage limit reached · limit resets 4:10am"]}'
check "the status line banner" "$(limit_line "$(screen "$p")")" "  ⚠ Usage limit reached · limit resets 4:10am"
state read '{"above":["x"],"menu":"limit"}'
check "a menu hides the input box" "$(has_input_box "$(screen "$p")" && echo box || echo none)" "none"
t kill-window -t "$p"

echo "resume: limits, resets and accounts"
reading a Personal 40 1000
LIMIT='  ⎿  You'"'"'ve hit your session limit · resets 1:10pm (America/New_York)'
p=$(pane lim "{\"above\":[\"work\",\"$LIMIT\"],\"on_submit\":\"busy\"}"); settle
noon=$(TZ=America/New_York date -d '2026-10-28 12:00' +%s)
resume "$noon"
check "a limit is seen and logged with its pane, account and reset" \
  "$(jq -r 'select(.message == "limit seen") | [.pane, .account, .resets] | join(" ")' "$FLEET_LOG")" "$p Personal Wed 2026-10-28 13:10"
check "nothing is typed before the reset" "$(events lim)" ""
resume "$(( noon + 3600 + 600 + 130 ))"
check "after the reset, the continue message goes in and starts a turn" "$(has "$(events lim)" "SUBMIT The usage limit has reset.")" "yes"
check "logged as resumed, with the turn started" "$(jq -r 'select(.message == "resumed with the continue message") | .started' "$FLEET_LOG")" "yes"
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

echo "launch.sh"
cat >"$work/launcher.sh" <<EOF
#!/usr/bin/env bash
# The launcher's "new": one more fleet window running KLEPSYDRA_CLAUDE.
tmux -L "\$KLEPSYDRA_TMUX_SOCKET" new-window -d -t fleet: -c "\$3" "\$KLEPSYDRA_CLAUDE"
EOF
printf 'Do the thing.\nThen the other thing.\n' >"$work/task.src"
launch() { # NAME STATE-JSON: launch.sh with a fake claude starting from STATE
  printf '%s' "$2" >"$work/$1.json"; : >"$work/$1.log"
  FLEET_SCOPE=0 FLEET_MIN_AVAIL_MB=0 FLEET_LAUNCHER="$work/launcher.sh" FLEET_DIR="$work" \
    FLEET_CLAUDE="python3 -I $fake $work/$1.json $work/$1.log" bash "$here/launch.sh" "$1" "$work/task.src" 2>/dev/null | head -1
}
cp "$work/task.src" "$FLEET_STATE/task-agent1.src"
out=$(launch agent1 '{"above":["Claude Code"]}')
check "delivered: Remote Control settles first, then the brief goes in whole and a turn starts" \
  "$(events agent1)" $'RC REQUESTED\nRC ON\nPASTE 36\nSUBMIT Do the thing.\\nThen the other thing.\\n'
check "reported started" "${out##* }" "brief=started"
sid=$(sed -E 's/.*session=([^ ]+).*/\1/' <<<"$out")
check "registered with its session id and folder" "$(cut -f2,3,4,5 "$REGISTRY")" "agent1	$FLEET_STATE/task-agent1.src	$sid	$work"
out=$(launch agent1 '{"above":["Claude Code"]}')
p=${out%% *}; p=${p#pane=}
check "a relaunch repoints the same row" "$(wc -l <"$REGISTRY") $(cut -f1 "$REGISTRY")" "1 $p"
check "the fleet log has the launch" "$(jq -r 'select(.target == "fleet::launch" and .pane == "'"$p"'") | .message' "$FLEET_LOG" | tail -1)" "brief delivered: a turn started"

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
check "the tail carries the team-ceremony rule (AJ 10-29)" "$(grep -c '^Team ceremony in every repo' "$here/brief-tail.md")" "1"
check "the tail keeps asks for AJ out of public issues and PRs (AJ 10-29)" "$(grep -c '^Asks for AJ stay private' "$here/brief-tail.md")" "1"
check "#185: the tail offers the Agora as optional and asks a post to name something real" "$(grep -c '^Agora (AJ 10-29, optional, never a task).*names something real' "$here/brief-tail.md")" "1"

echo "doctor"
mkdir -p "$KLEPSYDRA_DIR/fleet" "$work/bin"
cat >"$work/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ $* == *is-active* && -e $DOC_ACTIVE ]]
EOF
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
# The phone wall: answers with $DOC_FLEET for the URL named in $DOC_UP.
for a; do url=$a; done
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
doctor() { FLEET_PS="$work/bin/ps" FLEET_SYSTEMCTL="$work/bin/systemctl" FLEET_CURL="$work/bin/curl" FLEET_TAILSCALE="$work/bin/tailscale" \
  DOC_ACTIVE="$work/active" DOC_FLEET="$work/fleet.json" bash "$here/doctor.sh" 2>/dev/null; }
w=$(pane wpane '{"above":["idle"]}'); o=$(pane opane '{"above":["idle"]}'); settle
printf '%s\tworker\t%s\n' "$w" "$FLEET_STATE/task-demo.src" >"$REGISTRY"
printf '%s\n' "$o" >"$FLEET_STATE/orchestrator.pane"
session_file() { # ID PANE [URL]
  jq -n --arg p "$2" --arg u "${3:-}" '{session_id: "x", started_at: 5, ended: null, tmux: {pane: $p}} + (if $u == "" then {} else {remote_url: $u} end)' \
    >"$KLEPSYDRA_DIR/fleet/$1.json"
}
session_file w1 "$w" https://claude.ai/code/session_01W; session_file o1 "$o"
jq -n --argjson at "$(( $(date +%s) - 30 ))" '{usage: [{observed_at: $at}]}' >"$work/fleet.json"
out=$(doctor); code=$?
check "a stopped resume service fails" "$(grep -c '^FAIL resume service' <<<"$out")" "1"
check "a resume loop that never ran fails" "$(grep '^FAIL resume loop' <<<"$out")" "FAIL resume loop: no pass recorded"
check "a worker with Remote Control is ok" "$(grep -c "^ok   remote control $w (worker)" <<<"$out")" "1"
check "the orchestrator without it fails (Heph's must always be on)" "$(grep -c "^FAIL remote control $o (orchestrator): off" <<<"$out")" "1"
check "no phone wall fails" "$(grep -c '^FAIL phone wall: no answer' <<<"$out")" "1"
check "no Tailscale Serve fails" "$(grep -c '^FAIL phone wall over Tailscale: Tailscale Serve is not set up' <<<"$out")" "1"
check "and the exit is non-zero" "$code" "1"
touch "$work/active" "$FLEET_STATE/resume.beat"
session_file o1 "$o" https://claude.ai/code/session_01O
out=$(DOC_UP=http DOC_SERVE="https://desk.tail1.ts.net (tailnet only)" doctor); code=$?
check "all well but the watcher: a shell that names the script is not one" "$(grep -c '^ok ' <<<"$out") $(grep '^FAIL' <<<"$out" | cut -d: -f1)" "11 FAIL pane watcher"
check "the default account is logged in; the second, not yet, is a warning" \
  "$(grep '^ok   account' <<<"$out" | cut -d: -f1) | $(grep '^warn account' <<<"$out" | cut -d: -f1)" "ok   account $work/cfg-a | warn account $work/cfg-b"
check "with a watcher running, every check is ok and the exit is 0" \
  "$(DOC_WATCH='%2 %5' DOC_UP=http DOC_SERVE=on doctor | grep -c '^ok '; echo "rc=${PIPESTATUS[0]}")" $'12\nrc=0'
check "the watcher's panes are named" "$(DOC_WATCH='%2 %5' doctor | grep '^ok   pane watcher')" "ok   pane watcher: watching %2 %5"
check "the phone wall and its Tailscale twin answer fresh" "$(grep -c 'fleet.json observed 3[0-9] s ago' <<<"$out")" "2"
jq -n '{usage: [{observed_at: 1000}]}' >"$work/fleet.json"
check "a stale fleet.json fails" "$(DOC_UP=http doctor | grep -c 'fleet.json is stale')" "1"
touch -d '@1000' "$FLEET_STATE/resume.beat"
check "a resume loop that stopped passing fails" "$(doctor | grep -c '^FAIL resume loop: last pass')" "1"
logout a
out=$(doctor)
check "a default account not logged in fails" "$(grep -c "^FAIL account $work/cfg-a: not logged in: claude auth login" <<<"$out")" "1"
t kill-window -t "$w"; t kill-window -t "$o"; rm -f "$FLEET_STATE/orchestrator.pane"; : >"$REGISTRY"

echo "install"
inst=$work/inst
mkdir -p "$inst/state"
printf 'old copy\n' >"$inst/state/launch.sh"
FLEET_STATE="$inst/state" FLEET_UNITS="$inst/units" FLEET_BIN="$inst/bin" PATH="$work/nosystemctl:/usr/bin:/bin" \
  bash "$here/install.sh" --force >/dev/null 2>&1
check "each script is linked from the checkout" "$(readlink "$inst/state/resume-at-reset.sh")" "$here/resume-at-reset.sh"
check "the copy a link replaced is archived" "$(cat "$inst/state/archive/fleet-scripts-$(date +%Y%m%d)/launch.sh")" "old copy"
check "the fleet command is linked" "$(readlink "$inst/bin/fleet")" "$here/fleet"
check "the resume service is a unit that restarts and comes back at boot" \
  "$(grep -E '^(ExecStart|Restart|WantedBy)=' "$inst/units/fleet-resume-at-reset.service" | tr '\n' '|')" \
  "ExecStart=/usr/bin/bash $inst/state/resume-at-reset.sh|Restart=always|WantedBy=default.target|"
check "the memfrag timer too" "$(grep -c 'OnCalendar=\*:0/30' "$inst/units/fleet-memfrag-log.timer")" "1"
FLEET_STATE="$inst/s2" FLEET_UNITS="$inst/u2" FLEET_BIN="$inst/b2" bash "$here/install.sh" --dry-run --force >"$work/dry" 2>/dev/null
check "a dry run says what it would do and changes nothing" "$(grep -c '^would' "$work/dry" | sed 's/^[1-9][0-9]*$/some/') $(find "$inst" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ')" "some bin state units "

repo=$work/repo
git init -q "$repo" && cp -r "$here" "$repo/fleet" && git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm x
git -C "$repo" worktree add -q "$work/wt" 2>/dev/null
guard() { FLEET_STATE="$inst/g" FLEET_UNITS="$inst/gu" FLEET_BIN="$inst/gb" bash "$1/fleet/install.sh" --dry-run >/dev/null 2>&1; echo $?; }
check "the main checkout installs (10-29: from fleet/ git named its common dir relatively, so main read as a worktree)" "$(guard "$repo")" "0"
check "a worktree is refused" "$(guard "$work/wt")" "2"

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
reading a Personal 60 1000
check "back room: under FLEET_BACK_ROOM_PCT (50%) free is not enough to move back" "$(back_room a "$now" && echo yes || echo no)" "no"
reading a Personal 50 1000
check "at 50% free it is" "$(back_room a "$now" && echo yes || echo no)" "yes"
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
check "its old pane exits" "$(events mover)" "SUBMIT /exit"
check "the fresh brief says why, then carries the brief" "$(grep -c 'continue on the other, which has room' "$work/moved-brief") $(tail -1 "$work/moved-brief")" "1 the brief body"
check "logged with both folders and the new pane" \
  "$(jq -r 'select(.message == "moved to the other account at a limit") | [.from, .to, .new_pane] | join(" ")' "$FLEET_LOG")" "$work/cfg-a $work/cfg-b %997"
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
# The live session in pane $1: state $2, background $3, last reply $4 at $5.
reply_live() { jq -n --arg p "$1" --arg st "$2" --argjson bg "$3" --arg r "$4" --argjson at "$5" \
  '{session_id: "x", ended: null, tmux: {pane: $p}, state: $st, reason: null, background: $bg, reply: {text: $r, at: $at}, prompt: {at: 1}}' >"$KLEPSYDRA_DIR/fleet/$SID.json"; }
: >"$FLEET_LOG"; : >"$work/moved"; rm -f "$FLEET_STATE/resume-state" "$FLEET_STATE/back-room-since"
p=$(backpane keeper); state keeper '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none"}'
reply_live "$p" "done" '[{"id": "w1", "kind": "bash"}]' "Watching the TIGRIS job." "$noon"
mover "$noon"
check "#198: a finished turn with a background shell is not moved at once" "$(wc -c <"$work/moved") $(grep -c '^SUBMIT' "$work/keeper.log")" "0 0"
mover "$((noon + 240))"
check "#198: nor asked before the preferred account has had room for 5 min" "$(grep -c '^SUBMIT' "$work/keeper.log")" "0"
mover "$((noon + 300))"
check "#198: then it is asked to save, stop its background work and answer READY-TO-MOVE" \
  "$(grep -c '^SUBMIT Your preferred account, Personal, has room again.*reply READY-TO-MOVE' "$work/keeper.log")" "1"
check "#198: the request is logged, not urgent while Heph's account has room" \
  "$(jq -r 'select(.message | startswith("asked to save")) | [.pane, .from, .to, .urgent, .delivery] | join(" ")' "$FLEET_LOG")" "$p RIT Personal 0 sent"
mover "$((noon + 360))"
check "#198: asked once, not every pass" "$(wc -c <"$work/moved") $(grep -c '^SUBMIT' "$work/keeper.log")" "0 1"
reply_live "$p" "done" '[{"id": "w1", "kind": "bash"}]' "Earlier: READY-TO-MOVE" "$((noon + 200))"
mover "$((noon + 420))"
check "#198: a READY-TO-MOVE from before the request does not move it" "$(wc -c <"$work/moved")" "0"
reply_live "$p" working '[{"id": "w1", "kind": "bash"}]' "Saved and pushed. READY-TO-MOVE" "$((noon + 430))"
mover "$((noon + 440))"
check "#198: nor one whose turn still runs" "$(wc -c <"$work/moved")" "0"
reply_live "$p" "done" '[{"id": "w1", "kind": "bash"}]' "Saved and pushed. READY-TO-MOVE" "$((noon + 430))"
mover "$((noon + 480))"
check "#198: it moves on its READY-TO-MOVE at a finished turn" "$(head -2 "$work/moved" | tr '\n' ' ')" "$work/cfg-a keeper "
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"

: >"$FLEET_LOG"; : >"$work/moved"; rm -f "$FLEET_STATE/resume-state" "$FLEET_STATE/back-room-since"
reading b RIT 80 4000
p=$(backpane hurry); state hurry '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none"}'
reply_live "$p" "done" '[{"id": "w1", "kind": "agent"}]' "Waiting on a subagent." "$noon"
mover "$noon"; mover "$((noon + 300))"
check "#198: urgent while it borrows Heph's account and that one has under 30% room" \
  "$(grep -c '^SUBMIT Urgent: Heph' "$work/hurry.log") $(jq -r 'select(.message | startswith("asked to save")) | .urgent' "$FLEET_LOG")" "1 1"
t kill-window -t "$p" 2>/dev/null; : >"$REGISTRY"
reading b RIT 10 4000

: >"$work/moved"; rm -f "$FLEET_STATE/resume-state" "$FLEET_STATE/back-room-since"
p=$(backpane typing); state typing '{"above":["⏺ Done. done 11:50 AM"],"on_submit":"none"}'
reply_live "$p" "done" '[{"id": "w1", "kind": "bash"}]' "Watching." "$noon"
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
out=$(STAG=1 rec --no-orchestrator)
check "a running agent is left alone; the others are launched fresh" "$out" $'running: a (%1)\nrecovered: b -> %901\nrecovered: c -> %902'
check "the brief: why, its last two replies, its newest IMPL.md, then the brief" \
  "$(grep -c 'stopped by a hard shutdown' "$work/rec-b.txt") $(grep -c '^> first reply' "$work/rec-b.txt") $(grep -c '^> second reply$' "$work/rec-b.txt") $(grep -c '^> third reply$' "$work/rec-b.txt") $(grep -o 'IMPL.md: .*' "$work/rec-b.txt") | $(tail -1 "$work/rec-b.txt")" \
  "1 0 1 1 IMPL.md: $repo/.claude/worktrees/wt/IMPL.md | brief B"
check "with no transcript it says so" "$(grep -c 'no transcript found' "$work/rec-c.txt")" "1"
check "launches are staggered" "$(awk 'NR == 1 { a = $1 } NR == 2 { print ($1 - a >= 1) ? "apart" : "burst" }' "$work/rec.log")" "apart"
: >"$work/rec.log"
sfile "$SB" 4242 777 "$NOWBOOT" %2; sfile "$SC" 4242 777 "$NOWBOOT" %3
check "once they run, a second run recovers nothing" "$(rec --no-orchestrator | tail -1) $(wc -l <"$work/rec.log")" "nothing to recover 0"

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
rm -f "$KLEPSYDRA_DIR/fleet/$SOTHER.json"

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
tmux -L "\$KLEPSYDRA_TMUX_SOCKET" new-window -d -t fleet: -c "\$3" "\$KLEPSYDRA_CLAUDE"
EOF
printf '%s' '{"above":["Claude Code"]}' >"$work/nosettings.json"; : >"$work/nosettings.log"
FLEET_SETTINGS='' FLEET_SCOPE=0 FLEET_MIN_AVAIL_MB=0 FLEET_LAUNCHER="$work/launcher-rec.sh" FLEET_DIR="$work" \
  FLEET_CLAUDE="python3 -I $fake $work/nosettings.json $work/nosettings.log" bash "$here/launch.sh" nosettings "$work/task.src" >/dev/null 2>&1
check "FLEET_SETTINGS= starts claude with no --settings" "$(grep -c -- '--settings' "$work/cmd") $(grep -c -- '--session-id' "$work/cmd")" "0 1"
check "#183: workers run keryx off (only Heph speaks), from the installed worker settings" \
  "$(jq -r '.env.KERYX_ENABLED' "$here/worker-settings.json")" "false"
check "#172: the session is told its agent's name, so its card keeps its face across a move" "$(grep -c 'KLEPSYDRA_AGENT=nosettings ' "$work/cmd")" "1"

echo "briefing sync"
git init -q --bare "$work/brief-remote.git"
git clone -q "$work/brief-remote.git" "$work/brief" 2>/dev/null
git -C "$work/brief" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init && git -C "$work/brief" push -q origin HEAD 2>/dev/null
printf '#!/usr/bin/env bash\n[[ -e %s ]] && { echo "leak: token"; exit 1; }\nexit 0\n' "$work/leak" >"$work/bin/gitleaks"; chmod +x "$work/bin/gitleaks"
bsync() { BRIEFING_DIR="$work/brief" FLEET_GITLEAKS="$work/bin/gitleaks" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t bash "$here/sync-briefing.sh" 2>/dev/null; echo $?; }
check "nothing changed: no commit" "$(bsync) $(git -C "$work/brief" rev-list --count HEAD)" "0 1"
printf 'q\n' >"$work/brief/claude-queue.md"; printf 'x\n' >"$work/brief/notes.txt"
touch "$work/leak"
check "a gitleaks finding blocks the commit, and is logged" "$(bsync) $(git -C "$work/brief" rev-list --count HEAD) $(jq -r 'select(.message | contains("gitleaks found")) | .level' "$FLEET_LOG")" "1 1 ERROR"
check "and leaves nothing staged" "$(git -C "$work/brief" diff --cached --name-only | wc -l)" "0"
rm -f "$work/leak"
printf '#!/usr/bin/env bash\necho "ERR [git] fatal: bad object" >&2\nexit 0\n' >"$work/bin/gitleaks-err"; chmod +x "$work/bin/gitleaks-err"
check "a scanner that exits 0 with an error is no verdict" \
  "$(BRIEFING_DIR="$work/brief" FLEET_GITLEAKS="$work/bin/gitleaks-err" bash "$here/sync-briefing.sh" 2>/dev/null; echo $?) $(git -C "$work/brief" rev-list --count HEAD)" "1 1"
check "a change is committed and pushed" "$(bsync) $(git -C "$work/brief-remote.git" rev-list --count HEAD)" "0 2"
check "only the briefing's own files go in" "$(git -C "$work/brief" show --name-only --format= HEAD)" "claude-queue.md"
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
printf 'q2\n' >"$work/brief/claude-queue.md"
check "a push the remote rejects rebases once and lands both" "$(bsync) $(git -C "$work/brief-remote.git" rev-list --count HEAD)" "0 5"
printf 'o\n' >"$work/brief/other.md"; git -C "$work/brief" add other.md && git -C "$work/brief" -c user.name=t -c user.email=t@t commit -q -m other && git -C "$work/brief" push -q origin HEAD 2>/dev/null
git -C "$work/brief-phone" pull -q 2>/dev/null; printf 'ticked again\n' >"$work/brief-phone/README.md"
git -C "$work/brief-phone" -c user.name=t -c user.email=t@t commit -qam phone2 && git -C "$work/brief-phone" push -q origin HEAD 2>/dev/null
printf 'o\nan edit in progress\n' >"$work/brief/other.md"; printf 'q3\n' >"$work/brief/claude-queue.md"
check "a rejected push with edits in the tree waits rather than rebasing over them" \
  "$(bsync) $(tail -1 "$work/brief/other.md") $(git -C "$work/brief" ls-files -u | wc -l)" "1 an edit in progress 0"
git -C "$work/brief" checkout -q -- other.md
check "once the tree is clean it rebases and pushes" "$(bsync) $(git -C "$work/brief" rev-list --count '@{u}..HEAD')" "0 0"

echo "the fleet log"
check "every line is one JSON object with ts, level, target and message" \
  "$(jq -s 'all(has("ts") and has("level") and has("target") and has("message"))' "$FLEET_LOG")" "true"
FLEET_LOG_MAX=200 FLEET_TARGET=fleet::test bash -c ". '$here/lib.sh'; for i in 1 2 3 4 5 6 7 8; do flog INFO line\$i; done"
check "past its cap the log is renamed, and only the newest four are kept" \
  "$(find "${FLEET_LOG%/*}" -name 'fleet_*.log' | wc -l)" "4"

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))

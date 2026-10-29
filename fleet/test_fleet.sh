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

echo "resume: menus, the orchestrator and Remote Control"
: >"$FLEET_LOG"
p=$(pane menu '{"above":["work"],"menu":"limit"}'); settle
resume "$noon"
check "the limit menu gets option 1" "$(events menu)" "LIMIT MENU STOP"
t kill-window -t "$p"

: >"$FLEET_LOG"
p=$(pane orch "{\"above\":[\"work\",\"$LIMIT\"]}"); settle
printf '%s\n' "$p" >"$FLEET_STATE/orchestrator.pane"
resume "$noon"; resume "$(( noon + 4330 ))"
check "the orchestrator's limited pane is never typed into" "$(events orch)" ""
state orch '{"above":["idle"]}'
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
check "all well but the watcher: a shell that names the script is not one" "$(grep -c '^ok ' <<<"$out") $(grep '^FAIL' <<<"$out" | cut -d: -f1)" "7 FAIL pane watcher"
check "with a watcher running, every check is ok and the exit is 0" \
  "$(DOC_WATCH='%2 %5' DOC_UP=http DOC_SERVE=on doctor | grep -c '^ok '; echo "rc=${PIPESTATUS[0]}")" $'8\nrc=0'
check "the watcher's panes are named" "$(DOC_WATCH='%2 %5' doctor | grep '^ok   pane watcher')" "ok   pane watcher: watching %2 %5"
check "the phone wall and its Tailscale twin answer fresh" "$(grep -c 'fleet.json observed 3[0-9] s ago' <<<"$out")" "2"
jq -n '{usage: [{observed_at: 1000}]}' >"$work/fleet.json"
check "a stale fleet.json fails" "$(DOC_UP=http doctor | grep -c 'fleet.json is stale')" "1"
touch -d '@1000' "$FLEET_STATE/resume.beat"
check "a resume loop that stopped passing fails" "$(doctor | grep -c '^FAIL resume loop: last pass')" "1"
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
  is-active) [[ -e $SC/$1.active ]] && echo active || echo inactive ;;
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
ok   the resume service logged its start
rc=0"
check "no transient unit is left" "$(find "$SC" -name '*.transient' | wc -l)" "0"
check "each stop is logged" "$(jq -r 'select(.message | startswith("transient unit stopped")) | .unit' "$FLEET_LOG" | sort | tr '\n' ' ')" \
  "fleet-memfrag-log.service fleet-memfrag-log.timer fleet-resume-at-reset.service "
rm -f -- "${SC:?}"/*
touch "$SC/fleet-resume-at-reset.service.transient"
out=$(SC_SILENT=1 cutover); code=$?
check "a resume service that never logs its start fails the cut-over" "$code $(tail -1 <<<"$out")" "1 FAIL the resume service did not log its start"
check "install writes the units but never enables them over a transient one" \
  "$(grep -c -- '--user enable' "$here/install.sh") $(grep -c -- '--user daemon-reload' "$here/install.sh")" "0 1"

echo "the fleet log"
check "every line is one JSON object with ts, level, target and message" \
  "$(jq -s 'all(has("ts") and has("level") and has("target") and has("message"))' "$FLEET_LOG")" "true"
FLEET_LOG_MAX=200 FLEET_TARGET=fleet::test bash -c ". '$here/lib.sh'; for i in 1 2 3 4 5 6 7 8; do flog INFO line\$i; done"
check "past its cap the log is renamed, and only the newest four are kept" \
  "$(find "${FLEET_LOG%/*}" -name 'fleet_*.log' | wc -l)" "4"

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))

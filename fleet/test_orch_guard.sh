#!/usr/bin/env bash
# Tests for the orchestrator guard (#264): orch-tmux.sh, the tmux on the
# orchestrator's PATH that checks each send when it is made, and orch-guard.sh,
# the PreToolUse hook. Against a private tmux server, fake Claude Code panes
# (tests/fake_pane.py) and a fake /proc, with no real Claude. Each refusal has
# a case where it fires and a mutant without it that must fail that case.
# Run: make test-orch-guard (it takes the heavy lock)
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
fake="$here/tests/fake_pane.py"
work=$(mktemp -d)
export TZ=America/New_York
export FLEET_SOCK="orch-guard-test-$$" FLEET_STATE="$work/state" FLEET_SESSION=fleet
export FLEET_LOG="$work/state/log/fleet.log" FLEET_PROC="$work/proc" KLEPSYDRA_DIR="$work/klepsydra"
unset TMUX TMUX_PANE CLAUDE_CONFIG_DIR ORCH_GUARD_ALLOW
# Never AJ's config folders: the parser reads the settings a launch would use.
export HOME="$work/home" FLEET_DEFAULT_CONFIG="$work/cfg-a" FLEET_ACCOUNTS="$work/cfg-a $work/cfg-b"
mkdir -p "$FLEET_STATE/log" "$FLEET_PROC" "$HOME/.claude" "$work/cfg-a" "$work/cfg-b"
cleanup() {
  tmux -L "$FLEET_SOCK" kill-server 2>/dev/null
  rm -rf -- "${work:?}"
}
trap cleanup EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
# No inherited descriptor past stderr: the tmux server would keep a caller's lock (#193).
for fd in "/proc/$$/fd"/*; do n=${fd##*/}; (( n > 2 && n < 255 )) && eval "exec $n>&-"; done

CI_SCALE=1; [[ -n ${GITHUB_ACTIONS:-} ]] && CI_SCALE=2 # timing budgets: twice as long on a shared runner
pass=0 fail=0
check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %q\n       got:  %q\n' "$name" "$want" "$got"
    [[ -n ${GITHUB_ACTIONS:-} ]] && printf '::error file=fleet/test_orch_guard.sh,title=orch guard test failed::%s\n' "${name//$'\n'/ }"
  fi
}
has() { grep -qF -- "$2" <<<"$1" && echo yes || echo no; } # TEXT NEEDLE

t() { tmux -L "$FLEET_SOCK" "$@"; }
t new-session -d -s fleet -x 200 -y 50 "sleep 100000"
pane() { # NAME STATE-JSON: a fake pane; prints its id
  printf '%s' "$2" >"$work/$1.json"
  : >"$work/$1.log"
  t new-window -d -P -F '#{pane_id}' -t fleet: "python3 -I $fake $work/$1.json $work/$1.log"
}
settle() { sleep 0.8; }
got_keys() { grep -c '^SUBMIT' "$work/$1.log"; } # NAME: lines the pane took

LIMIT='  ⎿  You'"'"'ve hit your 5-hour limit · resets 1:10pm (America/New_York)'
at() { date -d "2026-11-02 $1" +%s; } # HH:MM AM|PM, the fixtures' day
FLEET_NOW=$(at '10:30 AM')
export FLEET_NOW

# The orchestrator: its pane on record, and its PATH with the guard's tmux first.
orchp=$(t new-window -d -P -F '#{pane_id}' -t fleet: 'sleep 100000')
printf '%s\n' "$orchp" >"$FLEET_STATE/orchestrator.pane"
# The guard's tmux sits in the state folder's orch-bin/, as install.sh puts it.
mkdir -p "$FLEET_STATE/orch-bin" "$FLEET_STATE/guard"
ln -s "$here/orch-tmux.sh" "$FLEET_STATE/orch-bin/tmux"
# The guard reads sessions and transcripts from lib.sh's own folders, whatever
# the caller's environment says; the tests' come from guard/test-env.
test_env() { printf 'KLEPSYDRA_DIR=%s\nFLEET_PROJECTS=%s\n' "$KLEPSYDRA_DIR" "$work/projects" >"$1/guard/test-env"; }
test_env "$FLEET_STATE"
mkdir -p "$KLEPSYDRA_DIR/fleet" "$work/projects/p"
# A Claude Code session in pane PANE runs COMMAND as its Bash tool does: a
# process named claude, with TMUX_PANE in its own environment, is the parent.
in_claude() { # PANE BIN COMMAND
  PATH="$2:$PATH" TMUX_PANE=$1 bash -c 'exec -a claude bash -c '"'"'bash -c "$0"; exit $?'"'"' "$1"' _ "$3"
}
# as_heph COMMAND: COMMAND run as the orchestrator's Bash runs it; prints ok
# or refused:<guard>, with the refusal's text in $(why).
# The guard reads its clock only from its own folder (FLEET_NOW in the
# environment moves nothing), so each call writes the test's time there.
as_heph() {
  local rc
  printf '%s\n' "$FLEET_NOW" >"$FLEET_STATE/guard/test-now"
  in_claude "$orchp" "$FLEET_STATE/orch-bin" "$1" >/dev/null 2>"$work/err"; rc=$?
  if grep -q '^orch-guard (' "$work/err"; then
    sed -n 's/^orch-guard (\([a-z-]*\)).*/refused:\1/p' "$work/err" | head -1
  elif (( rc == 0 )); then echo ok
  else echo "rc=$rc $(head -c 200 "$work/err")"; fi
}
why() { cat "$work/err"; }
# A transcript's entries as Claude Code writes them: the limit that stopped a
# turn (an assistant API-error entry, error rate_limit, model <synthetic>), or
# a reply that succeeded, at EPOCH.
tx_limit() { # FILE EPOCH
  jq -nc --arg t "$(date -u -d "@$2" +%Y-%m-%dT%H:%M:%S.000Z)" '{type: "assistant", timestamp: $t, isApiErrorMessage: true, error: "rate_limit", message: {model: "<synthetic>", content: [{type: "text", text: "You have hit your 5-hour limit"}]}}' >>"$1"
}
tx_reply() { # FILE EPOCH [EXTRA-JSON]: EXTRA merged in (isSidechain, an API error, a model)
  local x=${3:-}; [[ -n $x ]] || x='{}'
  jq -nc --arg t "$(date -u -d "@$2" +%Y-%m-%dT%H:%M:%S.000Z)" --argjson x "$x" '{type: "assistant", timestamp: $t, message: {model: "claude-opus-5-5", content: [{type: "text", text: "done"}]}} * $x' >>"$1"
}
T="tmux -L $FLEET_SOCK"

echo "sends, checked when made (orch-tmux.sh)"
cold=$(pane cold "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"]}")
warm=$(pane warm '{"above":["⏺ Done. done 10:00 AM","idle"]}')
young=$(pane young "{\"above\":[\"⏺ Done. done 10:20 AM\",\"$LIMIT\"]}")
typing=$(pane typing '{"above":["⏺ Done. done 10:20 AM"],"input":"AJ: also check the phone wall"}')
settle
# A session of its own for a pane, its transcript holding one good reply at EPOCH.
dated_by() { # PANE SID EPOCH
  jq -n --arg p "$1" '{session_id: "x", ended: null, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/$2.json"
  : >"$work/projects/p/$2.jsonl"; tx_reply "$work/projects/p/$2.jsonl" "$3"; tx_limit "$work/projects/p/$2.jsonl" "$(( $3 + 30 ))"
}
dated_by "$cold" aaaaaaaa-0000-4000-8000-0000000000c0 "$(( FLEET_NOW - 5340 ))"
t set-buffer -b x hi
check "a pane at a limit since 9:00 (now 10:30): refused" "$(as_heph "$T send-keys -t $cold continue Enter")" "refused:cold-limit"
check "the refusal names fresh-now.sh and the pane" "$(has "$(why)" "fresh-now.sh $cold")" "yes"
check "the refusal says how long" "$(has "$(why)" "89 min ago")" "yes"
check "and the pane took nothing" "$(got_keys cold)" "0"
check "it is logged with the pane" "$(jq -r 'select(.message | contains("refused a tmux call")) | "\(.guard) \(.pane)"' "$FLEET_LOG" | tail -1)" "cold-limit $cold"
check "round 7: a limit no transcript dates: refused as unknown, never read as minutes" \
  "$(as_heph "$T send-keys -t $young go Enter")" "refused:unknown"
check "round 7: the refusal says no reply dates the stop" "$(has "$(why)" "no transcript of its session holds a reply that succeeded")" "yes"
YS=aaaaaaaa-0000-4000-8000-0000000000e0
jq -n --arg p "$young" '{session_id: "x", ended: null, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/$YS.json"
: >"$work/projects/p/$YS.jsonl"; tx_reply "$work/projects/p/$YS.jsonl" "$(( FLEET_NOW - 660 ))"; tx_limit "$work/projects/p/$YS.jsonl" "$(( FLEET_NOW - 600 ))"
check "a limit 10 min old after a reply 11 min old: allowed" "$(as_heph "$T send-keys -t $young go Enter")" "ok"
check "and the keys arrive" "$(got_keys young)" "1"
rm -f -- "$KLEPSYDRA_DIR/fleet/$YS.json" "$work/projects/p/$YS.jsonl"
check "an idle pane at no limit: allowed" "$(as_heph "$T send-keys -t $warm 'next item' Enter")" "ok"
check "the send check is logged" "$(jq -r 'select(.message | contains("send checked")) | .pane' "$FLEET_LOG" | tail -1)" "$warm"
for shape in "send -t $cold go" "send-k -t $cold go" "send-keys -lt $cold go" "send-keys -Rt$cold go" "paste -t $cold" "pa -t $cold" \
  "pasteb -b x -t $cold" "send-prefix -t $cold"; do
  check "tmux $shape: refused" "$(as_heph "$T $shape")" "refused:cold-limit"
done
check "pipe-pane -I with a command: refused (the command could call tmux)" "$(as_heph "$T pipe-pane -I -t $cold 'printf go'")" "refused:hidden"
check "pipe-pane -O with a command: refused too" "$(as_heph "$T pipe-pane -O -t $warm 'cat >/dev/null'")" "refused:hidden"
t pipe-pane -t "$warm" 2>/dev/null
for wrap in "for p in $warm $cold; do $T send-keys -t \$p go; done" "echo $cold | xargs -I{} $T send-keys -t {} go" \
  "printf '%s\\n' $cold | while read -r p; do $T send-keys -t \"\$p\" go; done" "eval '$T send-keys -t $cold go'" \
  "x=\$($T send-keys -t $cold go)" "{ sleep 0.1; $T send-keys -t $cold go; }" "bash -c '$T send-keys -t $cold go'" \
  ". $here/lib.sh; FLEET_SOCK=$FLEET_SOCK; t send-keys -t $cold go" ". $here/lib.sh; FLEET_SOCK=$FLEET_SOCK; type_exactly $cold go"; do
  check "through the shell ($wrap): refused" "$(as_heph "$wrap")" "refused:cold-limit"
done
printf '#!/usr/bin/env bash\n%s send-keys -t %s go\n' "$T" "$cold" >"$work/nudge.sh"
check "from a script of its own: refused" "$(as_heph "bash $work/nudge.sh")" "refused:cold-limit"
# The check happens at the send, not when the command starts: a pane that
# reaches a long-past limit while the command sleeps is refused.
late=$(pane late '{"above":["⏺ Done. done 9:00 AM","idle"]}'); settle
dated_by "$late" aaaaaaaa-0000-4000-8000-0000000000c1 "$(( FLEET_NOW - 5340 ))"
( sleep 1; printf '%s' "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"]}" >"$work/late.json" ) & latew=$!
check "a limit that appears during a wait is seen at the send" "$(as_heph "sleep 2.5; $T send-keys -t $late continue Enter")" "refused:cold-limit"
wait "$latew"
check "a target no pane answers to: refused" "$(as_heph "$T send-keys -t %9999 hi")" "refused:unknown"
check "no -t is the orchestrator's own pane" "$(as_heph "$T send-keys -t $orchp hi")" "ok"
# Round 6: in a sequence, tmux resolves each target as it reaches it, so an
# earlier command can move what fleet: or {last} name; only a pane id holds.
cwin=$(t display -p -t "$cold" '#{window_id}')
check "round 6: select-window, then a send to fleet: (the cold pane by then): refused" \
  "$(as_heph "$T select-window -t $cwin \\; send-keys -t fleet: go Enter")" "refused:unknown"
check "round 7: the refusal asks for a send in a call of its own" "$(has "$(why)" "Send in a tmux call of its own")" "yes"
check "round 6: and the cold pane took nothing" "$(got_keys cold)" "0"
check "round 6: a sequence with no -t on its send: refused" "$(as_heph "$T select-window -t $cwin \\; send-keys hi")" "refused:unknown"
check "round 7: a sequence naming its send by its id: refused too, send alone" \
  "$(as_heph "$T select-window -t $cwin \\; send-keys -t $warm 'seq ok' Enter")" "refused:unknown"
check "two sends in one call: refused, the cold one never reached" "$(as_heph "$T send-keys -t $warm hi \\; send-keys -t $cold go")" "refused:unknown"
# Round 7: an earlier command can hold a send back past the check (wait-for, a
# load-buffer from a FIFO) while AJ types into the pane.
wk=$(got_keys warm)
( sleep 1.5; t wait-for -S orchtest ) & ww=$!
check "round 7: wait-for, then a send: refused before anything waits" "$(as_heph "$T wait-for orchtest \\; send-keys -t $warm 'report' Enter")" "refused:unknown"
wait "$ww"
mkfifo "$work/fifo"; ( sleep 1.5; printf 'x' >"$work/fifo" ) & fw=$!
check "round 7: a load-buffer from a FIFO, then a send: refused" "$(as_heph "$T load-buffer -b f $work/fifo \\; send-keys -t $warm 'report' Enter")" "refused:unknown"
timeout 5 cat "$work/fifo" >/dev/null 2>&1; wait "$fw" 2>/dev/null; rm -f -- "$work/fifo"
check "round 7: and the pane took none of them" "$(got_keys warm)" "$wk"
t select-window -t "$(t display -p -t "$orchp" '#{window_id}')"
# Round 6: E and T modifiers expand a value as a format again.
t set-buffer -b z 'plain text'
for f in '#{E:buffer_sample}' '#{T:pane_title}' '#{l;E:buffer_sample}' '#{=10;T:pane_title}' '#{s/#{l:x}/y/;E:buffer_sample}' '#{s/#{pane_id}/y/;E:buffer_sample}'; do
  check "round 6: the format $f: refused" "$(as_heph "$T list-buffers -F '$f'")" "refused:hidden"
done
check "round 6: plain formats with a colon between them: allowed" "$(as_heph "$T list-panes -F '#{pane_id}:#{pane_current_command}'")" "ok"
# Round 7: a differential against real tmux 3.4, its oracle the marker a #()
# in the buffer leaves. Every format that runs it on real tmux must be refused
# (and must not run through the guard).
# A client's #() jobs die with it, so the oracle's client waits on a channel
# the job signals (3 s at most: a format that runs nothing times out).
mods=('' 'l;' 'b;' 'd;' '=10;' 's/a/b/;' 's/:/x/;' 's/#{l:x}/y/;' 's/#{pane_id}/y/;' 's|:|x|;' 'm/r:a,b/;' '=/9/#{l:x}/;' 'l;s/a/b/;' 'q;')
ran=0 missed=""
for m in "${mods[@]}"; do
  for e in E T; do
    for name in buffer_sample 'l:#{buffer_sample}'; do
      f="#{${m}${e}:${name}}"
      rm -f -- "$work/fmt-ran"
      ch="fmt$ran-$RANDOM"
      t set-buffer -b z "#(touch $work/fmt-ran; tmux -L $FLEET_SOCK wait-for -S $ch)"
      timeout 3 tmux -L "$FLEET_SOCK" list-buffers -F "$f" \; wait-for "$ch" >/dev/null 2>&1
      [[ -e $work/fmt-ran ]] || continue
      ran=$((ran + 1)); rm -f -- "$work/fmt-ran"
      got=$(as_heph "$T list-buffers -F '$f'"); sleep 0.2
      [[ $got == refused:hidden && ! -e $work/fmt-ran ]] || missed+="$f=$got "
    done
  done
done
# On tmux 3.4 (this PC's) the same seed runs 30 of them; another version needs only some.
if [[ $(tmux -V) == "tmux 3.4" ]]; then oracle_want=30 oracle_got=$ran; else oracle_want=1 oracle_got=$(( ran > 0 )); fi
check "round 7: generated formats run the buffer's #() on real tmux (the oracle works: $ran)" "$oracle_got" "$oracle_want"
check "round 7: every one of them is refused, and none runs through the guard" "$missed" ""
rm -f -- "$work/fmt-ran"; t set-buffer -b z 'plain text'
# Round 6: "done 10:20 AM" has no date; the session's transcript dates the stop.
TS=aaaaaaaa-0000-4000-8000-0000000000e1
# A pane of its own: young took keys above, so its limit is gone.
dated=$(pane dated "{\"above\":[\"⏺ Done. done 10:20 AM\",\"$LIMIT\"]}"); settle
jq -n --arg p "$dated" '{session_id: "x", ended: null, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/$TS.json"
: >"$work/projects/p/$TS.jsonl"
tx_reply "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 86400 - 700 ))"; tx_limit "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 86400 - 600 ))"
check "round 6: done 10:20 AM, but its transcript's reply and limit are from yesterday: refused as cold" \
  "$(as_heph "$T send-keys -t $dated continue Enter")" "refused:cold-limit"
touch -d "@$(( FLEET_NOW - 300 ))" "$work/projects/p/$TS.jsonl"
check "round 8: a day-old limit entry in a file written 5 min ago is still cold (mtime is a later write)" \
  "$(as_heph "$T send-keys -t $dated continue Enter")" "refused:cold-limit"
: >"$work/projects/p/$TS.jsonl"; tx_reply "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 86400 ))"; tx_limit "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 600 ))"
check "round 10: a limit 10 min old after a day-old reply is cold: the cache ages from the last good reply" \
  "$(as_heph "$T send-keys -t $dated go Enter")" "refused:cold-limit"
: >"$work/projects/p/$TS.jsonl"; tx_limit "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 900 ))"; tx_limit "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 600 ))"
check "round 10: limits and no reply that succeeded: unknown (fail closed)" "$(as_heph "$T send-keys -t $dated go Enter")" "refused:unknown"
: >"$work/projects/p/$TS.jsonl"; tx_reply "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 86400 ))"
tx_reply "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 700 ))" '{"isSidechain": true}'
tx_reply "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 680 ))" '{"isApiErrorMessage": true}'
tx_reply "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 660 ))" '{"message": {"model": "<synthetic>"}}'
tx_limit "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 600 ))"
check "round 10: a sidechain reply, an API error and a <synthetic> entry are no good reply: dated by yesterday's" \
  "$(as_heph "$T send-keys -t $dated go Enter")" "refused:cold-limit"
: >"$work/projects/p/$TS.jsonl"; tx_reply "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 720 ))"; tx_limit "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 600 ))"
check "round 6: a reply 12 min old and its limit 10 min old: allowed" "$(as_heph "$T send-keys -t $dated go Enter")" "ok"
check "round 6: the check logs where the stop came from" \
  "$(jq -r 'select(.message | contains("send checked")) | .stop_from' "$FLEET_LOG" | tail -1)" "transcript"
dated2=$(pane dated2 "{\"above\":[\"⏺ Done. done 10:20 AM\",\"$LIMIT\"]}"); settle
jq -n --arg p "$dated2" '{session_id: "x", ended: null, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/$TS.json"
: >"$work/projects/p/$TS.jsonl"; tx_reply "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 86400 ))"
check "round 8: no limit entry: the last reply dates the stop (yesterday: cold)" "$(as_heph "$T send-keys -t $dated2 go Enter")" "refused:cold-limit"
printf '{"type":"user"}\nnot json\n' >"$work/projects/p/$TS.jsonl"
check "round 8: a transcript with no dated entry: unknown" "$(as_heph "$T send-keys -t $dated2 go Enter")" "refused:unknown"
# Round 10 review: the screen's day-less time no longer decides. A warm reply
# 30 min old under a stale "done 9:00 AM" is allowed; so is one with no done line.
stale=$(pane stale "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"]}")
nodone=$(pane nodone "{\"above\":[\"⏺ working\",\"$LIMIT\"]}"); settle
dated_by "$stale" aaaaaaaa-0000-4000-8000-0000000000c2 "$(( FLEET_NOW - 1800 ))"
dated_by "$nodone" aaaaaaaa-0000-4000-8000-0000000000c3 "$(( FLEET_NOW - 1800 ))"
check "round 10 review: a reply 30 min old under a stale done 9:00 AM: allowed (the cache is warm)" "$(as_heph "$T send-keys -t $stale go Enter")" "ok"
check "round 10 review: a reply 30 min old and no done line on screen: allowed" "$(as_heph "$T send-keys -t $nodone go Enter")" "ok"
# A NUL-padded line (a crash) hides nothing after it, and prints nothing.
nul=$(pane nul "{\"above\":[\"⏺ Done. done 10:20 AM\",\"$LIMIT\"]}"); settle
dated_by "$nul" aaaaaaaa-0000-4000-8000-0000000000c4 "$(( FLEET_NOW - 86400 ))"
printf '{"type":"assistant","x":"\0\0\0"}\n' >>"$work/projects/p/aaaaaaaa-0000-4000-8000-0000000000c4.jsonl"
tx_reply "$work/projects/p/aaaaaaaa-0000-4000-8000-0000000000c4.jsonl" "$(( FLEET_NOW - 720 ))"
check "round 10 review: a reply after a NUL-padded line still dates the stop, with nothing on stderr" \
  "$(as_heph "$T send-keys -t $nul go Enter") [$(cat "$work/err")]" "ok []"
# A bare value on a line (not an object) is skipped, not fatal.
bare=$(pane bare "{\"above\":[\"⏺ Done. done 10:20 AM\",\"$LIMIT\"]}"); settle
dated_by "$bare" aaaaaaaa-0000-4000-8000-0000000000c5 "$(( FLEET_NOW - 720 ))"
printf '5\n"x"\n[{"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z"}]\n' >>"$work/projects/p/aaaaaaaa-0000-4000-8000-0000000000c5.jsonl"
check "round 10 review: a bare number, string or array line is skipped" "$(as_heph "$T send-keys -t $bare go Enter")" "ok"
# Round 10 (Heph 11-03): a long session's transcript is never read whole.
# A reply 3 MB from the end (past the first 2 MB window) is found by widening;
# a 48 MB file whose reply is near its end costs one small window.
big=$(pane big "{\"above\":[\"⏺ Done. done 10:20 AM\",\"$LIMIT\"]}"); settle
jq -n --arg p "$big" '{session_id: "x", ended: null, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/$TS.json"
# Filler the prefilter keeps (assistant API errors), so only the tail window keeps the read cheap.
filler() { python3 -I -c 'import sys; line = "{\"type\":\"assistant\",\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"isApiErrorMessage\":true,\"message\":{\"model\":\"<synthetic>\",\"content\":\"" + "x" * 1000 + "\"}}\n"; sys.stdout.write(line * (int(sys.argv[1]) // len(line)))' "$1"; }
: >"$work/projects/p/$TS.jsonl"; tx_reply "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 720 ))"
filler 3000000 >>"$work/projects/p/$TS.jsonl"; tx_limit "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 600 ))"
check "round 10: a reply 3 MB from the end is found by widening the window" "$(as_heph "$T send-keys -t $big go Enter")" "ok"
# The same limit pane with a small transcript and with a 48 MB one: the big
# file costs next to nothing more, since only its tail is read (the old
# tac|jq of the whole file took 727 ms on it, on this PC).
TB=aaaaaaaa-0000-4000-8000-0000000000e4
small2=$(pane small2 "{\"above\":[\"⏺ Done. done 10:20 AM\",\"$LIMIT\"]}")
big2=$(pane big2 "{\"above\":[\"⏺ Done. done 10:20 AM\",\"$LIMIT\"]}"); settle
jq -n --arg p "$small2" '{session_id: "x", ended: null, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/$TS.json"
jq -n --arg p "$big2" '{session_id: "x", ended: null, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/$TB.json"
: >"$work/projects/p/$TS.jsonl"; tx_reply "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 720 ))"; tx_limit "$work/projects/p/$TS.jsonl" "$(( FLEET_NOW - 600 ))"
filler 48000000 >"$work/projects/p/$TB.jsonl"; tx_reply "$work/projects/p/$TB.jsonl" "$(( FLEET_NOW - 720 ))"; tx_limit "$work/projects/p/$TB.jsonl" "$(( FLEET_NOW - 600 ))"
send_ms() { # PANE: the median of 5 sends of nothing to PANE, in ms
  local ms=() a b
  for _ in 1 2 3 4 5; do a=$(date +%s%N); as_heph "$T send-keys -t $1 ''" >/dev/null; b=$(date +%s%N); ms+=($(( (b - a) / 1000000 ))); done
  printf '%s\n' "${ms[@]}" | sort -n | sed -n 3p
}
ms_small=$(send_ms "$small2") ms_big=$(send_ms "$big2")
echo "  (a send to a limit pane: ${ms_small} ms with a small transcript, ${ms_big} ms with a 48 MB one; medians of 5)"
check "round 10: a 48 MB transcript adds under $(( 200 * ${CI_SCALE:-1} )) ms to a send (read from its tail; a whole read takes ~700)" "$(( ms_big - ms_small < 200 * ${CI_SCALE:-1} ))" "1"
rm -f -- "$KLEPSYDRA_DIR/fleet/$TB.json" "$work/projects/p/$TB.jsonl"
rm -f -- "$KLEPSYDRA_DIR/fleet/$TS.json" "$work/projects/p/$TS.jsonl"
weekly=$(pane weekly '{"above":["⏺ Done. done 10:20 AM","  ⎿  You'"'"'ve hit your weekly limit · resets Nov 4, 1pm (America/New_York)","",""]}'); settle
check "round 6: a dated (weekly) reset and no transcript: refused as unknown" \
  "$(as_heph "$T send-keys -t $weekly continue Enter")" "refused:unknown"
check "round 6: the environment cannot point the guard at other folders" \
  "$(as_heph "KLEPSYDRA_DIR=/nonexistent FLEET_PROJECTS=/nonexistent $T send-keys -t $weekly continue Enter")" "refused:unknown"
# Only the orchestrator's PATH holds orch-bin (launch.sh, for heph): whatever
# reaches it is the orchestrator's, whatever its environment says.
for e in "FRESH_AFTER_S=999999" "FLEET_NOW=0" "FLEET_STATE=/nonexistent" "TMUX_PANE=$warm" "ORCH_GUARD_OWN_S=99999" "ORCH_TAIL_BYTES=0"; do
  check "the guard's own settings hold ($e in front): refused" "$(as_heph "$e timeout 20 $T send-keys -t $cold go")" "refused:cold-limit"
done
# Round 4: a job left running in the background loses its Claude Code parent,
# but keeps the orchestrator's TMUX_PANE, so it is still the orchestrator's.
check "with no Claude Code above (a background job): checked" \
  "$(PATH="$FLEET_STATE/orch-bin:$PATH" env -u TMUX_PANE bash -c "$T send-keys -t $cold go" 2>&1 | grep -o 'orch-guard (cold-limit)')" "orch-guard (cold-limit)"
for bg in "( sleep 0.3; $T send-keys -t $cold orphan Enter ) &" "nohup sh -c 'sleep 0.3; $T send-keys -t $cold orphan Enter' >/dev/null 2>&1 &" \
  "setsid -f sh -c 'sleep 0.3; $T send-keys -t $cold orphan Enter' >/dev/null 2>&1"; do
  as_heph "$bg" >/dev/null; sleep 1.2
  check "a send that outlives its Bash call ($bg): refused" "$(got_keys cold)" "0"
done
# shellcheck disable=SC2016 # the script's own $1 and $0
printf '#!/usr/bin/env bash\nif (( $1 > 0 )); then bash "$0" $(( $1 - 1 )); else %s send-keys -t %s deep; fi\n' "$T" "$cold" >"$work/nest.sh"
check "a send under 14 nested shells: refused" "$(as_heph "bash $work/nest.sh 14")" "refused:cold-limit"
check "the orchestrator setting TMUX_PANE does not make it another session" "$(as_heph "TMUX_PANE=$warm $T send-keys -t $cold go")" "refused:cold-limit"
check "nor does unsetting it" "$(as_heph "env -u TMUX_PANE $T send-keys -t $cold go")" "refused:cold-limit"
check "read-only tmux commands pass" "$(as_heph "$T capture-pane -p -t $cold >/dev/null && $T list-panes -a >/dev/null")" "ok"

echo "pending input"
check "a box holding AJ's text: refused" "$(as_heph "$T send-keys -t $typing 'report?' Enter")" "refused:pending-input"
check "the refusal quotes the text" "$(has "$(why)" "also check the phone wall")" "yes"
check "ORCH_GUARD_ALLOW=pending-input lets it through" "$(as_heph "ORCH_GUARD_ALLOW=pending-input $T send-keys -t $typing C-u")" "ok"
check "the override is logged" "$(jq -r 'select(.message | contains("allowed by ORCH_GUARD_ALLOW")) | .pane' "$FLEET_LOG" | tail -1)" "$typing"
two=$(pane two '{"above":["⏺ Done. done 10:20 AM"]}'); settle
check "typing into an empty box: allowed" "$(as_heph "$T send-keys -t $two -l 'your next item'")" "ok"
check "its own Enter after typing: allowed" "$(as_heph "$T send-keys -t $two Enter")" "ok"
printf '%s' '{"above":["⏺ Done. done 10:20 AM"],"input":"your next item"}' >"$work/two.json"; settle
check "the same box two minutes later is no longer its own" "$(FLEET_NOW=$((FLEET_NOW + 200)) as_heph "$T send-keys -t $two Enter")" "refused:pending-input"
# Own text is the exact text typed, not any text within two minutes (round 3:
# AJ's line arriving after the orchestrator's first send was then merged).
mix=$(pane mix '{"above":["⏺ Done. done 10:20 AM"]}'); settle
check "a first task into an empty box: allowed" "$(as_heph "$T send-keys -t $mix -l 'first task'")" "ok"
printf '%s' '{"above":["⏺ Done. done 10:20 AM"],"input":"AJ: wait, stop"}' >"$work/mix.json"; settle
check "AJ's line replacing it 90 s later is not the orchestrator's own" "$(FLEET_NOW=$((FLEET_NOW + 90)) as_heph "$T send-keys -t $mix 'second task' Enter")" "refused:pending-input"
check "and nothing merged into it" "$(got_keys mix)" "0"
# A paste is the orchestrator's own text: its own Enter after it is allowed,
# also when Claude Code shows the paste as a placeholder.
pst=$(pane pst '{"above":["⏺ Done. done 10:20 AM"]}'); settle
t set-buffer -b brief 'line one of the brief'
check "a paste into an empty box: allowed" "$(as_heph "$T paste-buffer -p -b brief -t $pst")" "ok"
printf '%s' '{"above":["⏺ Done. done 10:20 AM"],"input":"[Pasted text #1 +3 lines]"}' >"$work/pst.json"; settle
check "its own Enter on the paste's placeholder: allowed" "$(as_heph "$T send-keys -t $pst Enter")" "ok"
rep2=$(pane rep2 '{"above":["⏺ Done. done 10:20 AM"]}'); settle
as_heph "$T send-keys -N 3 -t $rep2 ab" >/dev/null
printf '%s' '{"above":["⏺ Done. done 10:20 AM"],"input":"ababab"}' >"$work/rep2.json"; settle
check "keys repeated with -N are its own: allowed" "$(as_heph "$T send-keys -t $rep2 Enter")" "ok"
# A pane only named in a message is not typed into, so it is not stamped own.
named=$(pane named '{"above":["⏺ Done. done 10:20 AM"]}'); settle
as_heph "$T send-keys -t $warm 'Hermes in $named is done' Enter" >/dev/null
printf '%s' '{"above":["⏺ Done. done 10:20 AM"],"input":"AJ is typing"}' >"$work/named.json"; settle
check "a pane named in a message is not the orchestrator's own" "$(as_heph "$T send-keys -t $named 'new task' Enter")" "refused:pending-input"
rm -f -- "$FLEET_STATE/guard/typed-${warm#%}"
check "a refused call stamps nothing as its own" \
  "$(as_heph "$T send-keys -t $warm hi \\; send-keys -t $cold hi" >/dev/null; [[ -e $FLEET_STATE/guard/typed-${warm#%} ]] && echo stamped || echo none)" "none"

echo "commands the guard cannot read"
printf 'send-keys -t %s go\n' "$cold" >"$work/x.conf"
for hidden in "source-file $work/x.conf" "source $work/x.conf" "run-shell '$T send-keys -t $cold go'" "if-shell true 'send-keys -t $cold go'" \
  "new-window -d '$T send-keys -t $cold go'" "-f $work/x.conf list-sessions" "pipe-pane -o -t $warm '$T send-keys -t $cold go'" \
  "display-message -p '#($T send-keys -t $cold go)'" "set-hook -g pane-focus-in 'send-keys -t $cold go'" \
  "set -s command-alias[90] zz=send-keys" "new-window -d 'sleep 1'" "kill-server"; do
  check "tmux $hidden: refused" "$(as_heph "$T $hidden")" "refused:hidden"
done
check "and nothing reached the pane" "$(got_keys cold)" "0"
check "pipe-pane with no command (it stops a pipe): allowed" "$(as_heph "$T pipe-pane -t $warm")" "ok"
nodone=$(pane nodone "{\"above\":[\"⏺ Working on it\",\"$LIMIT\"]}")
shell=$(t new-window -d -P -F '#{pane_id}' -t fleet: 'sleep 100000'); settle
check "a pane at a limit with no stop time on screen: refused" "$(as_heph "$T send-keys -t $nodone go")" "refused:unknown"
check "a pane with no input line: refused" "$(as_heph "$T send-keys -t $shell ls Enter")" "refused:unknown"
check "a pane with no input line, when AJ asked: allowed" "$(as_heph "ORCH_GUARD_ALLOW=pending-input $T send-keys -t $shell true Enter")" "ok"
check "#( in the keys send-keys types is text: allowed" "$(as_heph "$T send-keys -t $warm -l 'look #(here)'")" "ok"
t send-keys -t "$warm" C-u
t set -s 'command-alias[99]' 'zzz=run-shell' 2>/dev/null
check "a name the server aliases: refused" "$(as_heph "$T zzz true")" "refused:unknown"
t set -su 'command-alias[99]' 2>/dev/null
sock_path=$(t display -p '#{socket_path}')
for f in "send-keys -K -t $warm x" "send-keys -X cancel -t $warm" "send-keys -c /dev/pts/0 -t $warm x" "send-keys -M -t $warm" \
  "display-message -I -t $warm" "kill-pane -a -t $warm" "kill-window -a -t $warm"; do
  check "tmux $f: refused (the flag reaches what the guard does not check)" "$(as_heph "$T $f")" "refused:hidden"
done
check "split-pane (a default alias): refused as unknown" "$(as_heph "$T split-pane -d 'sleep 1'")" "refused:unknown"
check "-S to the real server and -L to none: checked where tmux sends" "$(as_heph "tmux -S $sock_path -L bogus-$$ send-keys -t $cold go")" "refused:cold-limit"

echo "fleet scripts send with their own checks"
mkdir -p "$work/fleetcopy" "$work/elsewhere" "$work/state2/orch-bin" "$work/state2/guard"
cp -- "$here/orch-tmux.sh" "$here/lib.sh" "$work/fleetcopy/"
ln -s "$work/fleetcopy/orch-tmux.sh" "$work/state2/orch-bin/tmux"
printf '%s\n' "$orchp" >"$work/state2/orchestrator.pane"; printf '%s\n' "$FLEET_NOW" >"$work/state2/guard/test-now"; test_env "$work/state2"
cold2=$(pane cold2 "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"]}"); settle
dated_by "$cold2" aaaaaaaa-0000-4000-8000-0000000000c6 "$(( FLEET_NOW - 5340 ))"
printf '#!/usr/bin/env bash\n%s send-keys -t %s /clear\n' "$T" "$cold2" | tee "$work/fleetcopy/fresh-now.sh" >"$work/elsewhere/fresh-now.sh"
check "the script outside the fleet folder is checked" "$(in_claude "$orchp" "$work/state2/orch-bin" "bash $work/elsewhere/fresh-now.sh" 2>&1 | grep -o 'orch-guard (cold-limit)')" "orch-guard (cold-limit)"
printf 'import subprocess\nsubprocess.run(["tmux", "-L", "%s", "send-keys", "-t", "%s", "x"], check=True)\n' "$FLEET_SOCK" "$cold2" >"$work/fleetcopy/note.py"
check "a python script in the fleet folder passes too" "$(in_claude "$orchp" "$work/state2/orch-bin" "python3 $work/fleetcopy/note.py" 2>&1 && echo ok)" "ok"
check "the same script in the fleet folder passes" "$(in_claude "$orchp" "$work/state2/orch-bin" "bash $work/fleetcopy/fresh-now.sh" 2>&1 && echo ok)" "ok"
cp -- "$here/heavy.sh" "$work/fleetcopy/"
ln -s "$work/fleetcopy/heavy.sh" "$work/fleetcopy/sender.sh"
check "#287 review 14: a link named like a sender to heavy.sh is heavy.sh: what it runs is checked" \
  "$(FLEET_HEAVY_LOCK="$work/heavy.lock" in_claude "$orchp" "$work/state2/orch-bin" "bash $work/fleetcopy/sender.sh bash $work/elsewhere/fresh-now.sh" 2>&1 | grep -o 'orch-guard (cold-limit)')" "orch-guard (cold-limit)"
check "#287 review 14: an option's value is no script: bash --rcfile <fleet script> -c is checked" \
  "$(in_claude "$orchp" "$work/state2/orch-bin" "bash --rcfile $work/fleetcopy/fresh-now.sh -c '$T send-keys -t $cold2 /clear'" 2>&1 | grep -o 'orch-guard (cold-limit)')" "orch-guard (cold-limit)"
check "heavy.sh in the fleet folder runs any command: what it runs is checked" \
  "$(FLEET_HEAVY_LOCK="$work/heavy.lock" in_claude "$orchp" "$work/state2/orch-bin" "bash $work/fleetcopy/heavy.sh bash $work/elsewhere/fresh-now.sh" 2>&1 | grep -o 'orch-guard (cold-limit)')" "orch-guard (cold-limit)"

echo "before the call (orch-guard.sh, PreToolUse)"
OSID=aaaaaaaa-0000-4000-8000-000000000001 WSID=bbbbbbbb-0000-4000-8000-000000000002
printf '%s\n' "$OSID" >"$FLEET_STATE/orchestrator.session"
GUARD=$here/orch-guard.sh
call() { # SESSION TOOL INPUT-JSON: allow, or deny:<guard>; $(reason) is the text
  local out
  out=$(jq -nc --arg s "$1" --arg t "$2" --argjson i "$3" \
    '{session_id: $s, transcript_path: "/home/x/.claude/projects/p/s.jsonl", cwd: "/home/x", permission_mode: "bypassPermissions", hook_event_name: "PreToolUse", tool_name: $t, tool_input: $i, tool_use_id: "toolu_1"}' |
    bash "$GUARD")
  jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<<"$out" >"$work/reason" 2>/dev/null
  if [[ -z $out ]]; then echo allow
  elif [[ $(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out") == deny ]]; then
    sed -E 's/^orch-guard \(([a-z-]+)\).*/deny:\1/' "$work/reason"
  else echo "other: $out"; fi
}
reason() { cat "$work/reason"; }
run() { call "$OSID" Bash "$(jq -nc --arg c "$1" '{command: $c}')"; } # COMMAND
edit() { call "$OSID" "$1" "$(jq -nc --arg f "$2" '{file_path: $f, content: "x"}')"; } # TOOL FILE

check "a worker's session is never guarded" "$(call "$WSID" Bash '{"command":"ANTHROPIC_API_KEY=sk claude"}')" "allow"
mv "$FLEET_STATE/orchestrator.session" "$work/osid"
check "no orchestrator on record: nothing is guarded" "$(run 'ANTHROPIC_API_KEY=sk claude')" "allow"
mv "$work/osid" "$FLEET_STATE/orchestrator.session"
check "another tool passes" "$(call "$OSID" Read '{"file_path":"/x/panes.tsv"}')" "allow"
: >"$FLEET_LOG"
check "an ordinary command passes" "$(run 'git status && ls -la')" "allow"
check "an ordinary command logs nothing" "$(wc -c <"$FLEET_LOG" | tr -d ' ')" "0"

check "tmux by its path skips the guard's tmux: refused" "$(run "/usr/bin/tmux send-keys -t $cold go")" "deny:bypass"
check "tmux with a new PATH: refused" "$(run "PATH=/usr/bin tmux send-keys -t $cold go")" "deny:bypass"
check "env -i tmux: refused" "$(run "env -i tmux send-keys -t $cold go")" "deny:bypass"
for b in "command -p tmux send-keys -t $cold go" "env -u PATH tmux send-keys -t $cold go" "cd /usr/bin && ./tmux send-keys -t $cold go" \
  "p=/usr/bin; \$p/tmux send-keys -t $cold go"; do
  check "a bypass ($b): refused" "$(run "$b")" "deny:bypass"
done
check "plain tmux passes here (orch-tmux.sh checks it)" "$(run "tmux send-keys -t $cold go")" "allow"

printf '%s' '{"apiKeyHelper":"op read op://Fleet/key/credential","env":{}}' >"$work/key-settings.json"
printf '%s' '{"env":{"KERYX_ENABLED":"false"}}' >"$work/plain-settings.json"
check "an interactive session on a key: refused" "$(run 'ANTHROPIC_API_KEY=sk-x claude --model opus')" "deny:api-key"
check "the refusal says keys are for headless jobs" "$(has "$(reason)" "only for headless jobs")" "yes"
check "a launch with key settings: refused" "$(run "bash fleet/launch.sh review $work/brief.src --settings $work/key-settings.json")" "deny:api-key"
check "an exported key reaches a later claude" "$(run 'export ANTHROPIC_API_KEY=sk-x; timeout 60 claude')" "deny:api-key"
check "mkdir -p is no headless claude" "$(run 'mkdir -p /tmp/w && ANTHROPIC_API_KEY=sk-x claude --model opus')" "deny:api-key"
check "a launch on plain settings passes" "$(run "bash fleet/launch.sh review $work/brief.src --settings $work/plain-settings.json")" "allow"
check "a headless job on the subscription passes" "$(run 'claude -p "summarise" --model haiku')" "allow"
check "a headless key job, no balance logged: refused" "$(run "claude -p hi --settings $work/key-settings.json")" "deny:api-key"
check "the refusal names fleet balance" "$(has "$(reason)" "fleet balance ORG AMOUNT")" "yes"
check "a settings file the command makes first counts as a key" "$(run "cp $work/key-settings.json /tmp/s-$$.json && claude --settings /tmp/s-$$.json")" "deny:api-key"
printf '%s org=lab balance=98.50 by=heph\n' "$(date -d "@$((FLEET_NOW - 86400))" '+%F %H:%M')" >"$FLEET_STATE/api-balance.log"
check "a check logged yesterday is not today's" "$(run "claude -p hi --settings $work/key-settings.json")" "deny:api-key"
check "fleet balance refuses a bad amount" "$(bash "$here/fleet" balance lab lots >/dev/null 2>&1; echo $?)" "2"
check "fleet balance logs a check" "$(bash "$here/fleet" balance lab 98.50 | grep -c "org=lab balance=98.50")" "1"
check "after today's check: allowed" "$(FLEET_NOW=$(date +%s) run "claude -p hi --settings $work/key-settings.json")" "allow"
cp -- "$work/key-settings.json" "$HOME/key.json"
# shellcheck disable=SC2016 # the literal $HOME is the case
check 'a --settings file under $HOME' "$(run 'claude --settings $HOME/key.json')" "deny:api-key"
# shellcheck disable=SC2016 # the literal $S is the case
check "a --settings path the guard cannot read: refused" "$(run 'claude --settings "$S/x.json"')" "deny:api-key"
mkdir -p "$work/keycfg"; cp -- "$work/key-settings.json" "$work/keycfg/settings.json"
check "a config folder whose settings use a key" "$(run "CLAUDE_CONFIG_DIR=$work/keycfg claude --model opus")" "deny:api-key"
check "launch.sh on such a folder" "$(run "FLEET_ACCOUNT=$work/keycfg bash fleet/launch.sh x $work/brief.src")" "deny:api-key"
check "launch.sh on the fleet's own folders passes" "$(run "bash fleet/launch.sh x $work/brief.src")" "allow"
cp -- "$work/key-settings.json" "$work/cfg-b/settings.json"
check "launch.sh where it may pick a folder that uses a key" "$(run "bash fleet/launch.sh x $work/brief.src")" "deny:api-key"
rm -f -- "$work/cfg-b/settings.json"
check "clearing the key is no key" "$(run 'ANTHROPIC_API_KEY= claude --model opus')" "allow"
printf '%s' '{"env":{"ANTHROPIC_API_KEY":"sk-x"}}' >"$work/envkey.json"
check "a settings file whose env holds a key" "$(run "claude --settings $work/envkey.json")" "deny:api-key"
cp -- "$work/envkey.json" "$work/cfg-a/settings.json"
check "a config folder whose env holds a key" "$(run "CLAUDE_CONFIG_DIR=$work/cfg-a claude")" "deny:api-key"
rm -f -- "$work/cfg-a/settings.json"
mkdir -p "$work/proj/.claude"; cp -- "$work/key-settings.json" "$work/proj/.claude/settings.local.json"
check "the project's settings.local.json in the call's folder holds a key" \
  "$(jq -nc --arg s "$OSID" --arg d "$work/proj" '{session_id: $s, cwd: $d, hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "claude --model opus"}}' | bash "$GUARD" | jq -r .hookSpecificOutput.permissionDecision)" "deny"
check "the npm package name is claude too" "$(run 'ANTHROPIC_API_KEY=sk npx @anthropic-ai/claude-code')" "deny:api-key"

reg=$FLEET_STATE/panes.tsv
check "an edit with no loop running: allowed" "$(run "sed -i '/old/d' $reg")" "allow"
mkdir -p "$FLEET_PROC/4242"
printf 'bash\0-c\0until ! tmux has -t %%9; do sleep 30; done; bash ~/.local/state/fleet-orchestrator/launch.sh card brief\0' >"$FLEET_PROC/4242/cmdline"
check "an edit while a chain launch waits: refused" "$(run "sed -i '/old/d' $reg")" "deny:registry"
check "the refusal names the loop's pid" "$(has "$(reason)" "4242 bash -c until")" "yes"
for w in "sed -ri '/x/d' $reg" "sed -Ei '/x/d' $reg" "sed -n '1w $reg' bak" "sort -ro $reg x" "cp src/panes.tsv $FLEET_STATE/" \
  "grep x $reg >&$reg" "grep -v old $reg > $reg" "mv /tmp/new $reg" "reg=$reg; grep -v x \"\$reg\" > p.new && cat p.new > \"\$reg\"" \
  "cp p.new \"\$REGISTRY\"" "awk -i inplace 1 $reg" "python3 - $reg" "tee -a $reg" "cp $reg $reg.bak"; do
  check "a write ($w): refused" "$(run "$w")" "deny:registry"
done
check "the Edit tool: refused" "$(edit Edit "$reg")" "deny:registry"
check "the Write tool: refused, saying to use Bash" "$(edit Write "$reg"; has "$(reason)" "make it in Bash")" "deny:registry
yes"
for r in "cat $reg | cut -f1" "grep x $reg >/dev/null 2>&1" "grep x < $reg" "cat \${REGISTRY}" "column -t $reg" "wc -l $reg"; do
  check "a read ($r): passes" "$(run "$r")" "allow"
done
check "editing another file passes" "$(edit Edit "$FLEET_STATE/HEPH.md")" "allow"
check "ORCH_GUARD_ALLOW=registry lets it through" "$(run "ORCH_GUARD_ALLOW=registry sed -i '/old/d' $reg")" "allow"
for c in 'shellcheck\0fleet/launch.sh' 'vim\0launch.sh' 'bash\0fleet/test_fleet.sh' 'less\0x-chain.sh'; do
  printf '%b\0' "$c" >"$FLEET_PROC/4242/cmdline"
  check "no loop: a process that only names a script ($(tr '\0' ' ' <"$FLEET_PROC/4242/cmdline"))" "$(run "sed -i '/old/d' $reg")" "allow"
done
for c in 'launch.sh\0card' 'bash\0/x/relaunch-fresh.sh\0%3' 'sh\0-c\0sleep 9; bash recover.sh' 'bash\0dependabot-chain.sh'; do
  printf '%b\0' "$c" >"$FLEET_PROC/4242/cmdline"
  check "a loop: $(tr '\0' ' ' <"$FLEET_PROC/4242/cmdline")" "$(run "sed -i '/old/d' $reg")" "deny:registry"
done

echo "cost"
# A median of single calls, and CI runners get twice the local budget (11-03:
# one run read 68 ms against 60 on a shared runner); the local budget stays strict.
median_ms() { # N COMMAND...: the median wall time of N runs, in ms
  local n=$1 a b; shift
  local ms=()
  for (( i = 0; i < n; i++ )); do a=$(date +%s%N); "$@" >/dev/null 2>&1; b=$(date +%s%N); ms+=($(( (b - a) / 1000000 ))); done
  printf '%s\n' "${ms[@]}" | sort -n | sed -n "$(( n / 2 + 1 ))p"
}
payload=$(jq -nc --arg s "$WSID" '{session_id: $s, transcript_path: "/home/x/.claude/p.jsonl", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "tmux send-keys -t %1 hi"}}')
hook_once() { bash "$GUARD" <<<"$payload"; }
per=$(median_ms 21 hook_once)
echo "  (the hook on another session's call: ${per} ms, median of 21)"
check "the hook costs another session under $(( 40 * ${CI_SCALE:-1} )) ms" "$(( per < 40 * ${CI_SCALE:-1} ))" "1"
tmux_once() { PATH="$FLEET_STATE/orch-bin:$PATH" tmux -L "$FLEET_SOCK" display -p '#{pid}'; }
per=$(median_ms 21 tmux_once)
echo "  (the orchestrator's tmux, a call that sends nothing: ${per} ms, median of 21)"
check "the guard's tmux keeps a call that sends nothing under $(( 60 * ${CI_SCALE:-1} )) ms" "$(( per < 60 * ${CI_SCALE:-1} ))" "1"

echo "differential against tmux and bash"
diff_out=$(timeout 900 python3 -I "$here/tests/orch_parse_differential.py" 200 264 2>&1)
echo "  ${diff_out##*$'\n'}"
check "no send tmux delivers and no registry write bash makes is missed" "$(grep -c MISSED <<<"$diff_out")" "0"

echo "sweep: every tmux command, alias and flag against the expected table"
# The expected table, written apart from orch-tmux.sh's: commands that run no
# other command, with the flags they may take.
declare -A want=(
  [capture-pane]=aCeJNpPqTbESt [clear-history]=Ht [delete-buffer]=b [display-message]=alNpvcdFt
  [has-session]=t [kill-pane]=t [kill-window]=t [last-pane]=deZt [last-window]=t
  [list-buffers]=Ff [list-clients]=Fft [list-commands]=F [list-keys]=1aNPT [list-panes]=asFft
  [list-sessions]=Ff [list-windows]=aFft [load-buffer]=bt [paste-buffer]=dprsbt [pipe-pane]=IOot
  [rename-window]=t [resize-pane]=DLMRTUZxyt [save-buffer]=ab [select-pane]=DdeLlMmRUZTt
  [select-window]=lnpTt [send-keys]=FHlRNt [send-prefix]=2t [set-buffer]=awbnt [show-buffer]=b
  [show-environment]=hgst [show-hooks]=gpwt [show-messages]=JTt [show-options]=AgHpqsvwt
  [show-window-options]=gvt [wait-for]=LSU
)
sweepp=$(pane sweep '{"above":["⏺ Done. done 10:20 AM"]}'); settle
listing=$(tmux -f /dev/null -L "sweep-$$" list-commands); tmux -L "sweep-$$" kill-server 2>/dev/null
rm -f -- "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/sweep-$$"
swept=0 sweep_bad=0
while read -r name rest; do
  alias_="" usage=$rest
  [[ $rest == \(* ]] && { alias_=${rest%%)*}; alias_=${alias_#(}; usage=${rest#*) }; }
  case $name in send-keys | send-prefix | paste-buffer) tgt="-t $sweepp" ;; *) tgt="-t %9999" ;; esac
  [[ $usage == *"[-t "* ]] || tgt=""
  for nm in "$name" $alias_; do
    swept=$((swept + 1))
    got=$(as_heph "$T $nm $tgt")
    # An allowed name is never refused as hidden (the pane's state may still refuse it).
    if [[ -n ${want[$name]+x} ]]; then [[ $got != refused:hidden ]] || ok=0
    else [[ $got == refused:hidden ]] || ok=0; fi
    if [[ ${ok:-1} == 0 ]]; then sweep_bad=$((sweep_bad + 1)); echo "  sweep: tmux $nm -> $got"; fi
    unset ok
  done
  [[ -n ${want[$name]+x} ]] || continue
  valued=$(grep -oE '\[-[A-Za-z] [^]]+\]' <<<"$usage" | cut -c3 | tr -d '\n')
  letters=$(grep -oE '\[-[A-Za-z0-9|-]+\]' <<<"$usage" | tr -d '[]|-' | tr -d '\n')$valued
  for (( k = 0; k < ${#letters}; k++ )); do
    c=${letters:k:1}
    [[ $c == t ]] && continue
    arg="-$c"; [[ $valued == *"$c"* ]] && arg="-$c 1"
    swept=$((swept + 1))
    got=$(as_heph "$T $name $arg $tgt")
    if [[ ${want[$name]} == *"$c"* ]]; then [[ $got != refused:hidden ]] || ok=0
    else [[ $got == refused:hidden ]] || ok=0; fi
    if [[ ${ok:-1} == 0 ]]; then sweep_bad=$((sweep_bad + 1)); echo "  sweep: tmux $name $arg -> $got"; fi
    unset ok
  done
done <<<"$listing"
echo "  ($swept names, aliases and flags swept)"
check "the sweep reached every command tmux lists" "$(( swept > 250 ))" "1"
check "every command, alias and flag matches the expected table" "$sweep_bad" "0"

echo "mutation checks"
mut=$work/mut
mkdir -p "$mut"
cp -- "$here/lib.sh" "$here/orch_guard_parse.py" "$here/orch-guard.sh" "$here/orch-tmux.sh" "$mut/"
mkdir -p "$work/state-mut/orch-bin" "$work/state-mut/guard"
ln -s "$mut/orch-tmux.sh" "$work/state-mut/orch-bin/tmux"
printf '%s\n' "$orchp" >"$work/state-mut/orchestrator.pane"; printf '%s\n' "$FLEET_NOW" >"$work/state-mut/guard/test-now"; test_env "$work/state-mut"
printf 'bash\0launch.sh\0x\0' >"$FLEET_PROC/4242/cmdline"
typing2=$(pane typing2 '{"above":["⏺ Done. done 10:20 AM"],"input":"AJ: one more thing"}')
cold3=$(pane cold3 "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"]}"); settle
# Its transcript dates the stop, so only the cold-limit refusal guards it.
C3=aaaaaaaa-0000-4000-8000-0000000000e3
jq -n --arg p "$cold3" '{session_id: "x", ended: null, tmux: {pane: $p}}' >"$KLEPSYDRA_DIR/fleet/$C3.json"
: >"$work/projects/p/$C3.jsonl"; tx_reply "$work/projects/p/$C3.jsonl" "$(( FLEET_NOW - 5500 ))"; tx_limit "$work/projects/p/$C3.jsonl" "$(( FLEET_NOW - 5400 ))"
for g in cold-limit pending-input hidden unknown; do
  sed "s/refuse $g /true $g /g" "$here/orch-tmux.sh" >"$mut/orch-tmux.sh"
  check "mutant $g: its refusals removed" "$(grep -c "refuse $g " "$mut/orch-tmux.sh")" "0"
  case $g in
    cold-limit) cmd="$T send-keys -t $cold3 go" ;;
    pending-input) cmd="$T send-keys -t $typing2 go" ;;
    hidden) cmd="$T source-file $work/x.conf" ;;
    unknown) cmd="$T send-keys -t %9999 go" ;;
  esac
  check "mutant $g: the case it guards now passes" "$(in_claude "$orchp" "$work/state-mut/orch-bin" "$cmd" 2>&1 | grep '^orch-guard (')" ""
  check "unmutated: the same case is refused" "$(as_heph "$cmd")" "refused:$g"
done
cp -- "$here/orch-tmux.sh" "$mut/orch-tmux.sh"
for g in bypass api-key registry; do
  sed "s/deny $g /true $g /g" "$here/orch-guard.sh" >"$mut/orch-guard.sh"
  check "mutant $g: its refusals removed" "$(grep -c "deny $g " "$mut/orch-guard.sh")" "0"
  case $g in
    bypass) cmd="/usr/bin/tmux send-keys -t $cold go" ;;
    api-key) cmd='ANTHROPIC_API_KEY=sk-x claude' ;;
    registry) cmd="sed -i '/old/d' $reg" ;;
  esac
  check "mutant $g: the case it guards now passes" "$(GUARD=$mut/orch-guard.sh run "$cmd")" "allow"
  check "unmutated: the same case is refused" "$(run "$cmd")" "deny:$g"
done
rm -rf -- "${FLEET_PROC:?}/4242"

echo
echo "orch guard: $pass passed, $fail failed"
(( fail == 0 ))

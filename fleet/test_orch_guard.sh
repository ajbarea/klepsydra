#!/usr/bin/env bash
# Tests for the orchestrator guard (#264): orch-tmux.sh, the tmux on the
# orchestrator's PATH that checks each send when it is made, and orch-guard.sh,
# the PreToolUse hook. Against a private tmux server, fake Claude Code panes
# (tests/fake_pane.py) and a fake /proc, with no real Claude. Each refusal has
# a case where it fires and a mutant without it that must fail that case.
# Run: bash fleet/test_orch_guard.sh
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
mkdir -p "$work/orch-bin"
ln -s "$here/orch-tmux.sh" "$work/orch-bin/tmux"
# A Claude Code session in pane PANE runs COMMAND as its Bash tool does: a
# process named claude, with TMUX_PANE in its own environment, is the parent.
in_claude() { # PANE BIN COMMAND
  PATH="$2:$PATH" TMUX_PANE=$1 bash -c 'exec -a claude bash -c '"'"'bash -c "$0"; exit $?'"'"' "$1"' _ "$3"
}
# as_heph COMMAND: COMMAND run as the orchestrator's Bash runs it; prints ok
# or refused:<guard>, with the refusal's text in $(why).
as_heph() {
  local rc
  in_claude "$orchp" "$work/orch-bin" "$1" >/dev/null 2>"$work/err"; rc=$?
  if grep -q '^orch-guard (' "$work/err"; then
    sed -n 's/^orch-guard (\([a-z-]*\)).*/refused:\1/p' "$work/err" | head -1
  elif (( rc == 0 )); then echo ok
  else echo "rc=$rc $(head -c 200 "$work/err")"; fi
}
why() { cat "$work/err"; }
T="tmux -L $FLEET_SOCK"

echo "sends, checked when made (orch-tmux.sh)"
cold=$(pane cold "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"]}")
warm=$(pane warm '{"above":["⏺ Done. done 10:00 AM","idle"]}')
young=$(pane young "{\"above\":[\"⏺ Done. done 10:20 AM\",\"$LIMIT\"]}")
typing=$(pane typing '{"above":["⏺ Done. done 10:20 AM"],"input":"AJ: also check the phone wall"}')
settle
t set-buffer -b x hi
check "a pane at a limit since 9:00 (now 10:30): refused" "$(as_heph "$T send-keys -t $cold continue Enter")" "refused:cold-limit"
check "the refusal names fresh-now.sh and the pane" "$(has "$(why)" "fresh-now.sh $cold")" "yes"
check "the refusal says how long" "$(has "$(why)" "89 min ago")" "yes"
check "and the pane took nothing" "$(got_keys cold)" "0"
check "it is logged with the pane" "$(jq -r 'select(.message | contains("refused a tmux call")) | "\(.guard) \(.pane)"' "$FLEET_LOG" | tail -1)" "cold-limit $cold"
check "a limit 10 min old: allowed" "$(as_heph "$T send-keys -t $young go Enter")" "ok"
check "and the keys arrive" "$(got_keys young)" "1"
check "an idle pane at no limit: allowed" "$(as_heph "$T send-keys -t $warm 'next item' Enter")" "ok"
check "the send check is logged" "$(jq -r 'select(.message | contains("send checked")) | .pane' "$FLEET_LOG" | tail -1)" "$warm"
for shape in "send -t $cold go" "send-k -t $cold go" "send-keys -lt $cold go" "send-keys -Rt$cold go" "paste -t $cold" "pa -t $cold" \
  "pasteb -b x -t $cold" "send-keys -t $warm hi \\; send-keys -t $cold go" "send-prefix -t $cold"; do
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
( sleep 1; printf '%s' "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"]}" >"$work/late.json" ) &
check "a limit that appears during a wait is seen at the send" "$(as_heph "sleep 2.5; $T send-keys -t $late continue Enter")" "refused:cold-limit"
wait
check "a target tmux does not know goes to tmux, which fails" "$(as_heph "$T send-keys -t %9999 hi" | cut -c1-4)" "rc=1"
check "no -t is the orchestrator's own pane" "$(as_heph "$T send-keys -t $orchp hi")" "ok"
check "another session's calls are never checked" "$(in_claude "$warm" "$work/orch-bin" "$T send-keys -t $cold x" 2>&1 && echo ok)" "ok"
t send-keys -t "$cold" C-u
check "no Claude Code session above: never checked" "$(PATH="$work/orch-bin:$PATH" TMUX_PANE=$orchp bash -c "$T display -p -t $cold '#{pane_id}'" 2>&1)" "$cold"
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

echo "fleet scripts send with their own checks"
mkdir -p "$work/fleetcopy" "$work/elsewhere"
cp -- "$here/orch-tmux.sh" "$here/lib.sh" "$work/fleetcopy/"
mkdir -p "$work/orch-bin2"
ln -s "$work/fleetcopy/orch-tmux.sh" "$work/orch-bin2/tmux"
cold2=$(pane cold2 "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"]}"); settle
printf '#!/usr/bin/env bash\n%s send-keys -t %s /clear\n' "$T" "$cold2" | tee "$work/fleetcopy/fresh-now.sh" >"$work/elsewhere/fresh-now.sh"
check "the script outside the fleet folder is checked" "$(in_claude "$orchp" "$work/orch-bin2" "bash $work/elsewhere/fresh-now.sh" 2>&1 | grep -o 'orch-guard (cold-limit)')" "orch-guard (cold-limit)"
check "the same script in the fleet folder passes" "$(in_claude "$orchp" "$work/orch-bin2" "bash $work/fleetcopy/fresh-now.sh" 2>&1 && echo ok)" "ok"

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
payload=$(jq -nc --arg s "$WSID" '{session_id: $s, transcript_path: "/home/x/.claude/p.jsonl", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "tmux send-keys -t %1 hi"}}')
start=$(date +%s%N)
for _ in {1..20}; do bash "$GUARD" <<<"$payload" >/dev/null; done
per=$(( ($(date +%s%N) - start) / 20000000 ))
echo "  (the hook on another session's call: ${per} ms each)"
check "the hook costs another session under 40 ms" "$(( per < 40 ))" "1"
start=$(date +%s%N)
for _ in {1..20}; do PATH="$work/orch-bin:$PATH" TMUX_PANE=$warm tmux -L "$FLEET_SOCK" display -p '#{pid}' >/dev/null; done
per=$(( ($(date +%s%N) - start) / 20000000 ))
echo "  (the orchestrator's tmux, another pane's call: ${per} ms each)"
check "the guard's tmux adds under 40 ms to another pane's call" "$(( per < 40 ))" "1"

echo "differential against tmux and bash"
diff_out=$(timeout 900 python3 -I "$here/tests/orch_parse_differential.py" 200 264 2>&1)
echo "  ${diff_out##*$'\n'}"
check "no send tmux delivers and no registry write bash makes is missed" "$(grep -c MISSED <<<"$diff_out")" "0"

echo "mutation checks"
mut=$work/mut
mkdir -p "$mut"
cp -- "$here/lib.sh" "$here/orch_guard_parse.py" "$here/orch-guard.sh" "$here/orch-tmux.sh" "$mut/"
mkdir -p "$work/orch-bin-mut"
ln -s "$mut/orch-tmux.sh" "$work/orch-bin-mut/tmux"
printf 'bash\0launch.sh\0x\0' >"$FLEET_PROC/4242/cmdline"
typing2=$(pane typing2 '{"above":["⏺ Done. done 10:20 AM"],"input":"AJ: one more thing"}')
cold3=$(pane cold3 "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"]}"); settle
for g in cold-limit pending-input hidden; do
  sed "s/refuse $g /true $g /g" "$here/orch-tmux.sh" >"$mut/orch-tmux.sh"
  check "mutant $g: its refusals removed" "$(grep -c "refuse $g " "$mut/orch-tmux.sh")" "0"
  case $g in
    cold-limit) cmd="$T send-keys -t $cold3 go" ;;
    pending-input) cmd="$T send-keys -t $typing2 go" ;;
    hidden) cmd="$T source-file $work/x.conf" ;;
  esac
  check "mutant $g: the case it guards now passes" "$(in_claude "$orchp" "$work/orch-bin-mut" "$cmd" 2>&1 | grep '^orch-guard (')" ""
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

#!/usr/bin/env bash
# Tests for orch-guard.sh (#264) against a private tmux server, fake Claude
# Code panes (tests/fake_pane.py) and a fake /proc, with no real Claude.
# Each guard has a case where it fires and a mutation check: the guard with
# its refusal removed must fail that case.
# Run: bash fleet/test_orch_guard.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
fake="$here/tests/fake_pane.py"
work=$(mktemp -d)
export TZ=America/New_York
export FLEET_SOCK="orch-guard-test-$$" FLEET_STATE="$work/state" FLEET_SESSION=fleet
export FLEET_LOG="$work/state/log/fleet.log" FLEET_PROC="$work/proc" KLEPSYDRA_DIR="$work/klepsydra"
unset TMUX CLAUDE_CONFIG_DIR
mkdir -p "$FLEET_STATE/log" "$FLEET_PROC"
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

OSID=aaaaaaaa-0000-4000-8000-000000000001 WSID=bbbbbbbb-0000-4000-8000-000000000002
printf '%s\n' "$OSID" >"$FLEET_STATE/orchestrator.session"
GUARD=$here/orch-guard.sh
# The decision on one call: allow, or deny:<guard>; $(reason) is the refusal text.
reason() { cat "$work/reason"; }
call() { # SESSION TOOL INPUT-JSON
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
run() { call "$OSID" Bash "$(jq -nc --arg c "$1" '{command: $c}')"; } # COMMAND
edit() { call "$OSID" "$1" "$(jq -nc --arg f "$2" '{file_path: $f, content: "x"}')"; } # TOOL FILE
logged() { jq -r --arg m "$1" 'select(.message | contains($m)) | [.guard // "", .pane // ""] | join(" ")' "$FLEET_LOG" 2>/dev/null | tail -1; }

LIMIT='  ⎿  You'"'"'ve hit your 5-hour limit · resets 1:10pm (America/New_York)'
at() { date -d "2026-11-02 $1" +%s; } # HH:MM AM|PM, the fixtures' day

echo "scope"
cold=$(pane cold "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\"]}"); settle
FLEET_NOW=$(at '10:30 AM')
export FLEET_NOW
check "a worker's session is never guarded" "$(call "$WSID" Bash "$(jq -nc --arg c "tmux -L $FLEET_SOCK send-keys -t $cold go Enter" '{command: $c}')")" "allow"
mv "$FLEET_STATE/orchestrator.session" "$work/osid"
check "no orchestrator on record: nothing is guarded" "$(run "tmux -L $FLEET_SOCK send-keys -t $cold go Enter")" "allow"
mv "$work/osid" "$FLEET_STATE/orchestrator.session"
check "another tool passes" "$(call "$OSID" Read '{"file_path":"/x/panes.tsv"}')" "allow"
: >"$FLEET_LOG"
check "an ordinary command passes" "$(run 'git status && ls -la')" "allow"
check "an ordinary command logs nothing" "$(wc -c <"$FLEET_LOG" | tr -d ' ')" "0"
check "text naming no tmux send passes" "$(run "gh pr comment 1 --body 'send the report to $cold'")" "allow"
# The parser over-approximates (it never models bash): a command that sends
# keys has every pane it names checked, quoted ones too.
check "a quoted send naming a cold pane is checked too" "$(run "gh pr comment 1 --body 'tmux send-keys -t $cold go'")" "deny:cold-limit"

echo "cold-limit"
check "a pane at a limit for 89 min (done 9:00, now 10:30): refused" "$(run "tmux -L $FLEET_SOCK send-keys -t $cold 'continue' Enter")" "deny:cold-limit"
check "the refusal names fresh-now.sh and the pane" "$(has "$(reason)" "fresh-now.sh $cold")" "yes"
check "the refusal says how long" "$(has "$(reason)" "89 min ago")" "yes"
check "it is logged with the pane" "$(logged "guard refused")" "cold-limit $cold"
check "a pane at a limit for 40 min: allowed" "$(FLEET_NOW=$(at '9:40 AM') run "tmux -L $FLEET_SOCK send-keys -t $cold 'continue' Enter")" "allow"
check "the send check is logged" "$(logged "send checked")" " $cold"
warm=$(pane warm '{"above":["⏺ Done. done 10:00 AM","idle"]}'); settle
check "an idle pane with no limit: allowed" "$(run "tmux -L $FLEET_SOCK send-keys -t $warm 'next item' Enter")" "allow"
check "a loop over panes reaches the cold one" "$(run "for p in $warm $cold; do tmux -L $FLEET_SOCK send-keys -t \$p go Enter; done")" "deny:cold-limit"
check "lib.sh's t reaches the fleet socket" "$(run ". fleet/lib.sh; t send-keys -t $cold go Enter")" "deny:cold-limit"
check "a pane id set earlier in the command" "$(run "p=$cold; tmux -L $FLEET_SOCK send-keys -t \"\$p\" go")" "deny:cold-limit"
check "a paste into the cold pane" "$(run "tmux -L $FLEET_SOCK paste-buffer -b b1 -t $cold")" "deny:cold-limit"
check "on a later line of the command" "$(run $'echo hi\ntmux -L '"$FLEET_SOCK send-keys -t $cold go")" "deny:cold-limit"
resumed=$(pane resumed "{\"above\":[\"⏺ Done. done 9:00 AM\",\"$LIMIT\",\"❯ The usage limit has reset. Continue\",\"⏺ On it.\"]}"); settle
check "a limit a prompt already followed is past" "$(run "tmux -L $FLEET_SOCK send-keys -t $resumed more Enter")" "allow"
printf '%s\n' "$cold" >"$FLEET_STATE/orchestrator.pane"
check "the orchestrator's own pane is left alone" "$(run "tmux -L $FLEET_SOCK send-keys -t $cold x")" "allow"
rm -f -- "$FLEET_STATE/orchestrator.pane"

echo "target"
# shellcheck disable=SC2016 # the literal $x is the case
check "a variable the command never sets: refused" "$(run 'tmux send-keys -t "$x" hi Enter')" "deny:target"
check "a command substitution: refused" "$(run "tmux send-keys -t \"\$(cat $FLEET_STATE/orchestrator.pane)\" hi")" "deny:target"
check "no -t is the session's own pane" "$(run 'tmux send-keys hi')" "allow"
check "a target tmux does not know passes" "$(run "tmux -L $FLEET_SOCK send-keys -t %9999 hi")" "allow"

echo "pending-input"
typing=$(pane typing '{"above":["⏺ Done. done 10:20 AM"],"input":"AJ: also check the phone wall"}'); settle
check "a box holding AJ's text: refused" "$(run "tmux -L $FLEET_SOCK send-keys -t $typing 'report?' Enter")" "deny:pending-input"
check "the refusal quotes the text" "$(has "$(reason)" "also check the phone wall")" "yes"
check "ORCH_GUARD_ALLOW=pending-input lets it through" "$(run "ORCH_GUARD_ALLOW=pending-input tmux -L $FLEET_SOCK send-keys -t $typing C-u")" "allow"
check "the override is logged" "$(logged "allowed by ORCH_GUARD_ALLOW")" "pending-input $typing"
two=$(pane two '{"above":["⏺ Done. done 10:20 AM"]}'); settle
check "typing into an empty box: allowed" "$(run "tmux -L $FLEET_SOCK send-keys -t $two -l 'your next item'")" "allow"
printf '%s' '{"above":["⏺ Done. done 10:20 AM"],"input":"your next item"}' >"$work/two.json"; settle
check "its own Enter after typing: allowed" "$(run "tmux -L $FLEET_SOCK send-keys -t $two Enter")" "allow"
check "the same box two minutes later is no longer its own" "$(FLEET_NOW=$((FLEET_NOW + 200)) run "tmux -L $FLEET_SOCK send-keys -t $two Enter")" "deny:pending-input"
rm -f -- "$FLEET_STATE/guard/typed-${warm#%}"
check "a refused command records nothing as its own" \
  "$(run "tmux -L $FLEET_SOCK send-keys -t $warm hi; tmux -L $FLEET_SOCK send-keys -t $cold hi" >/dev/null; [[ -e $FLEET_STATE/guard/typed-${warm#%} ]] && echo recorded || echo none)" "none"

echo "api-key"
printf '%s' '{"apiKeyHelper":"op read op://Fleet/key/credential","env":{}}' >"$work/key-settings.json"
printf '%s' '{"env":{"KERYX_ENABLED":"false"}}' >"$work/plain-settings.json"
check "an interactive session on a key: refused" "$(run 'ANTHROPIC_API_KEY=sk-x claude --model opus')" "deny:api-key"
check "the refusal says keys are for headless jobs" "$(has "$(reason)" "only for headless jobs")" "yes"
check "a launch with key settings: refused" "$(run "bash fleet/launch.sh review $work/brief.src --settings $work/key-settings.json")" "deny:api-key"
check "an exported key reaches a later claude" "$(run 'export ANTHROPIC_API_KEY=sk-x; timeout 60 claude')" "deny:api-key"
check "a launch on plain settings passes" "$(run "bash fleet/launch.sh review $work/brief.src --settings $work/plain-settings.json")" "allow"
check "a headless job on the subscription passes" "$(run 'claude -p "summarise" --model haiku')" "allow"
check "a headless key job, no balance logged: refused" "$(run "claude -p hi --settings $work/key-settings.json")" "deny:api-key"
check "the refusal names fleet balance" "$(has "$(reason)" "fleet balance ORG AMOUNT")" "yes"
printf '%s org=lab balance=98.50 by=heph\n' "$(date -d "@$((FLEET_NOW - 86400))" '+%F %H:%M')" >"$FLEET_STATE/api-balance.log"
check "a check logged yesterday is not today's" "$(run "claude -p hi --settings $work/key-settings.json")" "deny:api-key"
check "fleet balance refuses a bad amount" "$(bash "$here/fleet" balance lab lots >/dev/null 2>&1; echo $?)" "2"
check "fleet balance logs a check" "$(bash "$here/fleet" balance lab 98.50 | grep -c "org=lab balance=98.50")" "1"
check "after today's check: allowed" "$(FLEET_NOW=$(date +%s) run "claude -p hi --settings $work/key-settings.json")" "allow"

echo "registry"
reg=$FLEET_STATE/panes.tsv
check "an edit with no loop running: allowed" "$(run "sed -i '/old/d' $reg")" "allow"
mkdir -p "$FLEET_PROC/4242" "$FLEET_PROC/77" "$FLEET_PROC/78"
printf 'cargo\0build\0--target-dir\0toolchain\0' >"$FLEET_PROC/77/cmdline"
printf 'bash\0-c\0sleep 5\0' >"$FLEET_PROC/78/cmdline"
check "a toolchain build is no loop" "$(run "sed -i '/old/d' $reg")" "allow"
printf 'bash\0-c\0until ! tmux has -t %%9; do sleep 30; done; bash ~/.local/state/fleet-orchestrator/launch.sh card brief\0' >"$FLEET_PROC/4242/cmdline"
check "an edit while a chain launch waits: refused" "$(run "sed -i '/old/d' $reg")" "deny:registry"
check "the refusal names the loop's pid" "$(has "$(reason)" "4242 bash -c until")" "yes"
check "a rewrite by redirect: refused" "$(run "grep -v old $reg > $reg")" "deny:registry"
check "a move into place: refused" "$(run "mv /tmp/new $reg")" "deny:registry"
check "the Edit tool: refused" "$(edit Edit "$reg")" "deny:registry"
check "the Write tool: refused" "$(edit Write "$reg")" "deny:registry"
check "reading it passes" "$(run "cat $reg | cut -f1")" "allow"
check "a backup copy passes" "$(run "cp $reg $reg.bak-0655")" "allow"
check "editing another file passes" "$(edit Edit "$FLEET_STATE/HEPH.md")" "allow"
check "ORCH_GUARD_ALLOW=registry lets it through" "$(run "ORCH_GUARD_ALLOW=registry sed -i '/old/d' $reg")" "allow"
printf 'bash\0/home/x/.local/state/fleet-orchestrator/dependabot-chain.sh\0' >"$FLEET_PROC/4242/cmdline"
check "a *-chain.sh script is a loop" "$(run "sed -i '/old/d' $reg")" "deny:registry"
rm -rf -- "${FLEET_PROC:?}/4242"

echo "cost"
payload=$(jq -nc --arg s "$WSID" '{session_id: $s, transcript_path: "/home/x/.claude/p.jsonl", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "tmux send-keys -t %1 hi"}}')
start=$(date +%s%N)
for _ in {1..20}; do bash "$GUARD" <<<"$payload" >/dev/null; done
per=$(( ($(date +%s%N) - start) / 20000000 ))
echo "  (another session's call: ${per} ms each)"
check "another session's call costs under 40 ms" "$(( per < 40 ))" "1"

echo "differential against bash"
diff_out=$(timeout 600 python3 -I "$here/tests/orch_parse_differential.py" 300 264 2>&1)
echo "  ${diff_out##*$'\n'}"
check "no send or registry write bash makes is missed by the parser" "$(grep -c MISSED <<<"$diff_out")" "0"

echo "mutation checks"
# Each guard's refusal removed in turn: its firing case must then pass.
mut=$work/mut
mkdir -p "$mut"
cp -- "$here/lib.sh" "$here/orch_guard_parse.py" "$mut/"
mutate() { # GUARD: orch-guard.sh with GUARD's refusals removed, at $mut
  sed "s/^\([[:space:]]*\)deny $1 /\1true $1 /" "$here/orch-guard.sh" >"$mut/orch-guard.sh"
  grep -c "deny $1 " "$mut/orch-guard.sh"
}
mkdir -p "$FLEET_PROC/4242"
printf 'bash\0launch.sh\0x\0' >"$FLEET_PROC/4242/cmdline"
# shellcheck disable=SC2016 # the literal $x is the case
unset_var_send='tmux send-keys -t "$x" hi'
for g in cold-limit pending-input api-key registry target; do
  check "mutant $g: its refusals removed" "$(mutate "$g")" "0"
  case $g in
    cold-limit) cmd="tmux -L $FLEET_SOCK send-keys -t $cold go" ;;
    pending-input) cmd="tmux -L $FLEET_SOCK send-keys -t $typing go" ;;
    api-key) cmd='ANTHROPIC_API_KEY=sk-x claude' ;;
    registry) cmd="sed -i '/old/d' $reg" ;;
    target) cmd=$unset_var_send ;;
  esac
  check "mutant $g: the case it guards now passes, so the test catches its removal" "$(GUARD=$mut/orch-guard.sh run "$cmd")" "allow"
  check "unmutated: the same case is refused" "$(run "$cmd")" "deny:$g"
done

echo
echo "orch guard: $pass passed, $fail failed"
(( fail == 0 ))

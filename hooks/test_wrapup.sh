#!/usr/bin/env bash
# Tests for the wrap-up Stop hook and its reporter.
# Run: bash hooks/test_wrapup.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hook="$here/klepsydra-wrapup.sh"
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

export KLEPSYDRA_DIR="$work/kl" KLEPSYDRA_WRAPUP_SKILL="$here/klepsydra-wrapup.md"
mkdir -p "$KLEPSYDRA_DIR/wrapup"
S1=4ce1be96-f12f-4c66-87eb-4ab36e451dc5
S2=0b6f0f3e-1111-4c66-87eb-4ab36e451dc5
now=$(printf '%(%s)T' -1)
request() { printf '{"id":"%s","at":%s,"until":%s}\n' "$1" "$now" "$2" >"$KLEPSYDRA_DIR/wrapup/request.json"; }
stop() { printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":%s}' "$1" "${2:-false}" | bash "$hook"; }
state() { jq -c "${2:-.}" "$KLEPSYDRA_DIR/wrapup/$1.json" 2>/dev/null; }

echo "stop hook"
out=$(stop "$S1"); rc=$?
check "no request: silent" "$out" ""
check "no request: exit 0" "$rc" "0"
check "no request: records nothing" "$(state "$S1")" ""

request 1000 $((now + 600))
out=$(stop "$S1"); rc=$?
check "live request: exit 0" "$rc" "0"
check "live request: a Stop context" "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")" "Stop"
ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out")
check "the context is the skill without its frontmatter" "$(head -1 <<<"$ctx")" \
  "klepsydra is wrapping up every session, because AJ may restart the machine. In this turn:"
check "the context names this session" "$(grep -cF "klepsydra-wrapup.sh ready $S1"'`' <<<"$ctx")" "1"
check "no placeholder is left" "$(grep -c 'CLAUDE_SESSION_ID' <<<"$ctx")" "0"
check "no decision: the stop is never blocked" "$(jq -r 'has("decision")' <<<"$out")" "false"
check "asked is recorded" "$(state "$S1" '[.request, .state]')" '["1000","asked"]'
check "asked once: silent the second time" "$(stop "$S1" true)" ""
check "another session is asked too" "$(stop "$S2" | jq -r '.hookSpecificOutput.hookEventName')" "Stop"

request 1001 $((now + 600))
check "a new request asks again" "$(stop "$S1" | jq -r '.hookSpecificOutput.hookEventName')" "Stop"
check "the new request is recorded" "$(state "$S1" .request)" '"1001"'

request 1002 $((now - 1))
check "an expired request: silent" "$(stop "$S1")" ""
check "an expired request: the old state stays" "$(state "$S1" .request)" '"1001"'

request 1003 $((now + 600))
out=$(printf '{"session_id":"../../etc","hook_event_name":"Stop"}' | bash "$hook"); rc=$?
check "a bad session id: silent" "$out" ""
check "a bad session id: exit 0" "$rc" "0"
check "a bad session id: writes nothing" "$(find "$KLEPSYDRA_DIR" -name '*etc*' | wc -l)" "0"
check "garbage stdin: silent" "$(printf 'not json' | bash "$hook")" ""
printf '{"id":"x;rm","until":"soon"}' >"$KLEPSYDRA_DIR/wrapup/request.json"
check "a malformed request: silent" "$(stop "$S2")" ""
request 1004 $((now + 600))
check "a missing skill: silent" "$(KLEPSYDRA_WRAPUP_SKILL="$work/none.md" bash "$hook" <<<"{\"session_id\":\"$S2\"}")" ""
check "a missing skill: not marked asked" "$(state "$S2" .request)" '"1000"'
check "no data dir: silent" "$(KLEPSYDRA_DIR="" bash "$hook" <<<"{\"session_id\":\"$S2\"}")" ""
chmod a-w "$KLEPSYDRA_DIR/wrapup"
out=$(stop "$S2"); rc=$?
check "an unwritable folder: silent, so it is asked again later" "$out" ""
check "an unwritable folder: exit 0" "$rc" "0"
chmod u+w "$KLEPSYDRA_DIR/wrapup"

echo "reporter"
request 2000 $((now + 600))
out=$(bash "$hook" ready "$S1" 2>&1); rc=$?
check "ready: exit 0" "$rc" "0"
check "ready: says so" "$out" "Told klepsydra: ready."
check "ready: recorded for this request" "$(state "$S1" '[.request, .state, has("reason")]')" '["2000","ready",false]'
out=$(bash "$hook" blocked "$S2" $'TIGRIS job\n415235 dies; 2 h' 2>&1); rc=$?
check "blocked: exit 0" "$rc" "0"
check "blocked: the reason, one line" "$(state "$S2" '[.state, .reason]')" '["blocked","TIGRIS job 415235 dies; 2 h"]'
long=$(printf 'x%.0s' $(seq 400))
bash "$hook" blocked "$S2" "$long" >/dev/null 2>&1
check "blocked: the reason is capped" "$(state "$S2" '.reason | length')" "300"
out=$(bash "$hook" blocked "$S2" "  " 2>&1); rc=$?
check "blocked without a reason: exit 1" "$rc" "1"
out=$(bash "$hook" ready "../x" 2>&1); rc=$?
check "a bad session id: exit 1" "$rc" "1"
check "a bad session id: says so" "$out" "Not a session id: ../x"
request 2001 $((now - 5))
out=$(bash "$hook" ready "$S1" 2>&1); rc=$?
check "no live request: exit 1" "$rc" "1"
check "no live request: says so" "$out" "No wrap-up is waiting for an answer; nothing was recorded."
check "no live request: the old answer stays" "$(state "$S1" .request)" '"2000"'
out=$(bash "$hook" bogus 2>&1); rc=$?
check "unknown command: exit 1" "$rc" "1"

echo "install block"
settings=$(sed -n '/^<!-- wrapup-settings:start -->$/,/^<!-- wrapup-settings:end -->$/p' "$here/../README.md" |
  grep -v -e '^<!--' -e '^```')
check "settings: parses" "$(jq -r 'type' <<<"$settings" 2>/dev/null)" "object"
check "settings: Stop only" "$(jq -c '.hooks | keys' <<<"$settings")" '["Stop"]'
check "settings: not async, so its output is read" "$(jq '[.hooks.Stop[].hooks[] | has("async")] | any' <<<"$settings")" "false"
check "settings: the wrap-up script" "$(jq -r '.hooks.Stop[0].hooks[0].command | ltrimstr("~")' <<<"$settings")" "/.claude/klepsydra-wrapup.sh"
check "settings: a short timeout" "$(jq '.hooks.Stop[0].hooks[0].timeout <= 10' <<<"$settings")" "true"
check "README installs the skill where the script reads it" \
  "$(grep -c 'cp hooks/klepsydra-wrapup.md ~/.claude/skills/klepsydra-wrapup/SKILL.md' "$here/../README.md")" "1"
check "the script's default skill path is that one" \
  "$(grep -cF -- "/.claude/skills/klepsydra-wrapup/SKILL.md}" "$hook")" "1"

echo "shared blocks"
block() { sed -n '/^# --- klepsydra dir/,/^# --- end klepsydra dir ---$/p' "$1"; }
check "dir block identical in the fleet hook" "$(block "$hook")" "$(block "$here/klepsydra-fleet.sh")"

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))

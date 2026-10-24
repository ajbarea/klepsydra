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
S3=9a9a9a9a-2222-4c66-87eb-4ab36e451dc5 # never listed
now=$(printf '%(%s)T' -1)
request() { # id until [ids as JSON]
  printf '{"id":"%s","at":%s,"until":%s,"ids":%s}\n' "$1" "$now" "$2" "${3:-[\"$S1\",\"$S2\"]}" >"$KLEPSYDRA_DIR/wrapup/request.json"
}
stop() { printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":%s}' "$1" "${2:-false}" | bash "$hook"; }
stop_within() { printf '{"session_id":"%s","hook_event_name":"Stop"}' "$2" | timeout "$1" bash "$hook"; } # seconds session
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
check "another listed session is asked too" "$(stop "$S2" | jq -r '.hookSpecificOutput.hookEventName')" "Stop"
check "a session the wall did not list: silent" "$(stop "$S3")" ""
check "a session the wall did not list: records nothing" "$(state "$S3")" ""
check "an unlisted session cannot report" "$(bash "$hook" ready "$S3" 2>&1; echo "rc=$?")" \
  "No wrap-up is waiting for this session's answer; nothing was recorded.
rc=1"
printf '{"id":"999","at":%s,"until":%s}\n' "$now" $((now + 600)) >"$KLEPSYDRA_DIR/wrapup/request.json"
check "a request that lists nobody asks nobody" "$(stop "$S3")" ""

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
check "no live request: says so" "$out" "No wrap-up is waiting for this session's answer; nothing was recorded."
check "no live request: the old answer stays" "$(state "$S1" .request)" '"2000"'
out=$(bash "$hook" bogus 2>&1); rc=$?
check "unknown command: exit 1" "$rc" "1"

echo "late reports"
request 2100 $((now + 600))
stop "$S1" >/dev/null
stop "$S2" >/dev/null
bash "$hook" ready "$S2" >/dev/null 2>&1
request 2100 $((now - 30)) # Stop wrap-up, or the window ran out
out=$(bash "$hook" blocked "$S1" "a build" 2>&1); rc=$?
check "asked, then the window closed: the report is still taken" "$rc $out" "0 Told klepsydra: blocked."
check "asked, then the window closed: recorded" "$(state "$S1" '[.request, .state]')" '["2100","blocked"]'
out=$(bash "$hook" blocked "$S2" "changed my mind" 2>&1); rc=$?
check "answered, then the window closed: no second answer" "$rc" "1"
check "answered, then the window closed: the answer stays" "$(state "$S2" .state)" '"ready"'
request 2101 $((now + 600))
stop "$S1" >/dev/null
request 2101 $((now - 3601))
out=$(bash "$hook" ready "$S1" 2>&1); rc=$?
check "asked, but the wall no longer shows the request: refused" "$rc" "1"
check "asked, but the wall no longer shows the request: still asked" "$(state "$S1" .state)" '"asked"'

echo "a session clock that disagrees with the app's"
# The app stamps the request by its clock, the one that also stamps files in
# the folder; under WSL the session's clock drifts from it. KLEPSYDRA_NOW
# stands in for the session's clock.
n=0
for ahead in -300 0 120 700; do
  n=$((n + 1))
  t=$(printf '%(%s)T' -1)
  request "60$n" $((t + 60))
  out=$(printf '{"session_id":"%s"}' "$S1" | KLEPSYDRA_NOW=$((t + ahead)) bash "$hook")
  check "clock ${ahead} s: a live request is asked" "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out" 2>/dev/null)" "Stop"
  check "clock ${ahead} s: asked at the session's time, which the reader corrects" "$(state "$S1" '.at')" "$((t + ahead))"
  request "61$n" $((t - 5))
  check "clock ${ahead} s: an expired request asks nobody" "$(printf '{"session_id":"%s"}' "$S2" | KLEPSYDRA_NOW=$((t + ahead)) bash "$hook")" ""
  request "62$n" $((t + 60))
  check "clock ${ahead} s: a live request takes a report" "$(KLEPSYDRA_NOW=$((t + ahead)) bash "$hook" ready "$S2" 2>&1)" "Told klepsydra: ready."
  request "63$n" $((t - 5))
  check "clock ${ahead} s: an expired one, unasked, refuses it" "$(KLEPSYDRA_NOW=$((t + ahead)) bash "$hook" ready "$S2" >/dev/null 2>&1; echo $?)" "1"
done

echo "the skill's folder"
mkdir -p "$work/config/skills/klepsydra-wrapup"
cp "$here/klepsydra-wrapup.md" "$work/config/skills/klepsydra-wrapup/SKILL.md"
request 7000 $((now + 600))
out=$(printf '{"session_id":"%s"}' "$S1" | env -u KLEPSYDRA_WRAPUP_SKILL CLAUDE_CONFIG_DIR="$work/config" HOME="$work/nohome" bash "$hook")
check "read from CLAUDE_CONFIG_DIR, as Claude Code reads its skills" "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out" 2>/dev/null)" "Stop"
request 7001 $((now + 600))
out=$(printf '{"session_id":"%s"}' "$S1" | env -u KLEPSYDRA_WRAPUP_SKILL -u CLAUDE_CONFIG_DIR HOME="$work/nohome" bash "$hook")
check "no skill in ~/.claude without CLAUDE_CONFIG_DIR: silent" "$out" ""

echo "files that are not files"
request 3000 $((now + 600))
rm -f "$KLEPSYDRA_DIR/wrapup/$S1.json"; mkfifo "$KLEPSYDRA_DIR/wrapup/$S1.json"
out=$(stop_within 3 "$S1"); rc=$?
check "a FIFO answer file: no hang, exit 0" "$rc" "0"
check "a FIFO answer file: silent" "$out" ""
rm -f "$KLEPSYDRA_DIR/wrapup/$S1.json"
mv "$KLEPSYDRA_DIR/wrapup/request.json" "$work/request.json"; mkfifo "$KLEPSYDRA_DIR/wrapup/request.json"
out=$(stop_within 3 "$S1"); rc=$?
check "a FIFO request: no hang, exit 0" "$rc" "0"
check "a FIFO request: silent" "$out" ""
rm -f "$KLEPSYDRA_DIR/wrapup/request.json"; ln -s "$work/request.json" "$KLEPSYDRA_DIR/wrapup/request.json"
check "a symlinked request: silent" "$(stop "$S1")" ""
rm -f "$KLEPSYDRA_DIR/wrapup/request.json"

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
# shellcheck disable=SC2016 # the script's literal text, not an expansion
check "the script's default skill path is that one" \
  "$(grep -cF -- '${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/klepsydra-wrapup/SKILL.md}' "$hook")" "1"

echo "shared blocks"
block() { sed -n '/^# --- klepsydra dir/,/^# --- end klepsydra dir ---$/p' "$1"; }
check "dir block identical in the fleet hook" "$(block "$hook")" "$(block "$here/klepsydra-fleet.sh")"

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))

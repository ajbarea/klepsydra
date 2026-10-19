#!/usr/bin/env bash
# Fixture-driven tests for the fleet hook. Run: bash hooks/test_fleet.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hook="$here/klepsydra-fleet.sh"
fixtures="$here/fixtures"
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

# shellcheck source=hooks/klepsydra-fleet.sh
source "$hook"

echo "where"

# Repos laid out by git itself: a main checkout with a linked worktree, a
# superproject with a submodule, and a folder outside any repo.
g() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main \
  -c protocol.file.allow=always "$@"; }
repos="$work/repos"
mkdir -p "$repos/loose/notes"
for r in klepsydra ideas subsrc; do
  g init -q "$repos/$r" && g -C "$repos/$r" commit -q --allow-empty -m init
done
g -C "$repos/klepsydra" worktree add -q -b feat/fleet-visualizer "$repos/klepsydra/.claude/worktrees/fleet"
mkdir -p "$repos/klepsydra/src/deep" "$repos/klepsydra/.claude/worktrees/fleet/src"
g -C "$repos/ideas" submodule add -q "$repos/subsrc" vendor/subsrc >/dev/null 2>&1
g -C "$repos/subsrc" checkout -q --detach

where() { git_where "$1"; printf '%s|%s|%s' "$where_repo" "$where_worktree" "$where_branch"; }
# The branch as git reports it, or a detached commit's first 7 characters.
git_branch() { git -C "$1" symbolic-ref --short -q HEAD || git -C "$1" rev-parse --short=7 HEAD; }

check "plain repo" "$(where "$repos/klepsydra")" "klepsydra||main"
check "repo subdir" "$(where "$repos/klepsydra/src/deep")" "klepsydra||main"
check "linked worktree" "$(where "$repos/klepsydra/.claude/worktrees/fleet")" \
  "klepsydra|fleet|feat/fleet-visualizer"
check "worktree subdir" "$(where "$repos/klepsydra/.claude/worktrees/fleet/src")" \
  "klepsydra|fleet|feat/fleet-visualizer"
check "file not written yet" "$(where "$repos/klepsydra/.claude/worktrees/fleet/src/new.rs")" \
  "klepsydra|fleet|feat/fleet-visualizer"
check "submodule" "$(where "$repos/ideas/vendor/subsrc")" \
  "subsrc||$(git_branch "$repos/ideas/vendor/subsrc")"
check "detached HEAD" "$(where "$repos/subsrc")" "subsrc||$(git_branch "$repos/subsrc")"
check "outside any repo" "$(where "$repos/loose/notes")" "notes||"
check "filesystem root" "$(where /)" "||"

# keryx names the same repos; when its source is here, ask it directly.
keryx_src=${KERYX_SRC:-$HOME/ajsoftworks/keryx/src}
if [[ -f "$keryx_src/keryx/hook.py" ]]; then
  for p in klepsydra klepsydra/src/deep klepsydra/.claude/worktrees/fleet ideas/vendor/subsrc subsrc loose/notes; do
    got=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from keryx.hook import source_name; print(source_name(sys.argv[2]))' \
      "$keryx_src" "$repos/$p")
    git_where "$repos/$p"
    check "keryx agrees: $p" "$where_repo" "$got"
  done
else
  echo "  skip keryx parity: no keryx source at $keryx_src"
fi

echo "identity"

# A /proc tree: pid, parent, name, start time, state, then argv.
mkproc() {
  local d="$work/proc/$1"
  mkdir -p "$d"
  printf '%s (%s) %s %s 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 %s 1000 100\n' \
    "$1" "$3" "${5:-S}" "$2" "$4" >"$d/stat"
  printf '%s\n' "$3" >"$d/comm"
  if (( $# > 5 )); then printf '%s\0' "${@:6}" >"$d/cmdline"; else : >"$d/cmdline"; fi
}
mkproc 1 0 systemd 1
mkproc 500 1 claude 8717628 S claude
mkproc 550 500 'sh) (x' 8717700 S /bin/sh -c "$hook"
mkproc 600 550 klepsydra-fleet 8717701 S bash "$hook"
mkproc 700 1 node 9000000 S node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js
mkproc 710 700 bash 9000001 S bash "$hook"
mkproc 800 1 bash 9100000 S bash
mkproc 810 800 bash 9100001 S bash "$hook"
PROC_ROOT="$work/proc"

ancestor() { claude_ancestor "$1"; printf '%s:%s' "$found_pid" "$found_start"; }
check "nearest claude above the hook" "$(ancestor 600)" "500:8717628"
check "an npm install found by its argv" "$(ancestor 710)" "700:9000000"
check "no claude above" "$(ancestor 810)" ":"
check "a missing pid" "$(ancestor 999)" ":"

printf '{"homes":{"klepsydra":{"voice":"am_michael","seen":1}},"holders":{"500:8717628":{"voice":"am_michael","seen":1},"700:9000000":{"voice":"af_heart(0.5)+af_bella(0.5)","seen":1}}}\n' >"$work/voices.json"
VOICES="$work/voices.json"
check "the holder's voice" "$(holder_voice 500 8717628)" "am_michael"
check "a blend is a voice too" "$(holder_voice 700 9000000)" "af_heart(0.5)+af_bella(0.5)"
check "no hold, no voice" "$(holder_voice 500 1)" ""
VOICES="$work/missing.json"
check "no keryx, no voice" "$(holder_voice 500 8717628)" ""

# With HOME unset the default voices.json path has no home: no voice, no output, no abort.
# shellcheck disable=SC2016 # the script is for the child shell to expand
out=$(env -u HOME -u XDG_CACHE_HOME -u KERYX_VOICES KLEPSYDRA_PROC="$work/proc" \
  bash -uc 'source "$1"; v=$(holder_voice 500 8717628); claude_ancestor 600; printf "[%s][%s:%s]" "$v" "$found_pid" "$found_start"' _ "$hook" 2>&1); rc=$?
check "unset HOME: identity exit 0" "$rc" "0"
check "unset HOME: empty voice, no output" "$out" "[][500:8717628]"

echo "session file"

S=11111111-2222-4333-8444-555555555555
dir="$work/dev.ajsoftworks.klepsydra"
file="$dir/fleet/$S.json"
now=1792353000
wt="$repos/klepsydra/.claude/worktrees/fleet"

# Fire one fixture event at the hook, edited by an optional jq filter, as
# Claude Code would from the terminal held by pid 500.
fire() { # fixture [filter] [VAR=value...]
  local fixture=$1 filter=${2:-.}
  shift; (( $# )) && shift
  jq -c --arg cwd "$wt" "if .cwd then .cwd = \$cwd else . end | $filter" "$fixtures/$fixture" |
    env KLEPSYDRA_DIR="$dir" KLEPSYDRA_NOW="$now" KLEPSYDRA_PROC="$work/proc" KLEPSYDRA_PID=600 \
      KERYX_VOICES="$work/voices.json" XDG_RUNTIME_DIR="$work" "$@" bash "$hook"
}
field() { jq -c "$1" "$file"; }
mtime() { stat -c %Y "$file"; }

out=$(fire session-start.json); rc=$?
check "start: exit 0" "$rc" "0"
check "start: prints nothing" "$out" ""
check "start: not started" "$(field '[.v, .state, .reason, .state_at, .started_at]')" "[1,\"new\",null,$now,$now]"
check "start: launch dir" "$(field .launch_dir)" "\"$wt\""
check "start: claude" "$(field .claude)" '{"pid":500,"start":8717628}'
check "start: voice" "$(field .voice)" '"am_michael"'
check "start: where" "$(field '.where | [.repo, .worktree, .branch, .by, .at]')" \
  "[\"klepsydra\",\"fleet\",\"feat/fleet-visualizer\",\"cwd\",$now]"
check "start: nothing asked yet" "$(field '[.prompt, .reply, .needs, .error, .ended]')" "[null,null,null,null,null]"

touch -d @1 "$file"
now=1792353005 fire notification-permission.json
check "permission_prompt notification: no write" "$(mtime)" "1"
now=1792353005 fire post-tool-bash.json
check "a tool in the same place: no write" "$(mtime)" "1"

now=1792353010
fire user-prompt.json
check "prompt: working" "$(field '[.state, .state_at]')" "[\"working\",$now]"
check "prompt: stored" "$(field .prompt)" \
  "{\"text\":\"i just want to be able to VIZ them, one glance at the screen\",\"at\":$now}"

now=1792353020
fire task-notification.json
check "subagent report: still working" "$(field .state)" '"working"'
check "subagent report: keeps AJ's prompt" "$(field .prompt.at)" "1792353010"
fire pasted-content.json
check "pasted text quoting a report is AJ's prompt" "$(field '.prompt.text | startswith("why did this fire?")')" "true"

long=$(printf 'x%.0s' {1..290})$(printf '🙂%.0s' {1..20})
fire user-prompt.json ".prompt = \"$long\""
check "prompt: first 300 characters" "$(field '.prompt.text | length')" "300"
check "prompt: cut on a character, not a byte" "$(field '.prompt.text | endswith("🙂")')" "true"

now=1792353030
fire permission-request.json
check "permission request: needs you" "$(field '[.state, .reason, .state_at]')" "[\"needs_you\",\"approve Bash\",$now]"
check "permission request: prints nothing, so decides nothing" "$(fire permission-request.json)" ""
check "tool input never recorded" "$(grep -c SECRET "$file")" "0"

now=1792353040
fire post-tool-bash.json '.tool_name = "Read"'
check "another tool finishing leaves it waiting" "$(field .state)" '"needs_you"'
fire post-tool-bash.json '.agent_id = "agent-7" | .agent_type = "Explore"'
check "a subagent's tool finishing leaves it waiting" "$(field .state)" '"needs_you"'
fire post-tool-bash.json
check "its own tool finishing clears it" "$(field '[.state, .reason, .needs]')" '["working",null,null]'
check "tool output never recorded" "$(grep -c SECRET "$file")" "0"

fire pre-tool-question.json
check "question" "$(field '[.state, .reason]')" '["needs_you","question"]'
fire post-tool-bash.json '.tool_name = "AskUserQuestion"'
check "answered" "$(field .state)" '"working"'
fire pre-tool-plan.json
check "plan" "$(field '[.state, .reason]')" '["needs_you","approve plan"]'
plan_at=$(field .state_at)
now=$((now + 1)) fire permission-request.json '.tool_name = "ExitPlanMode"'
check "plan permission request keeps reason and state_at" "$(field '[.reason, .state_at]')" "[\"approve plan\",$plan_at]"
fire post-tool-bash.json '.tool_name = "ExitPlanMode"'
check "plan approved" "$(field .state)" '"working"'
fire notification-elicitation.json
check "MCP elicitation" "$(field '[.state, .reason]')" '["needs_you","question"]'
fire post-tool-bash.json '.tool_name = "mcp__memory__store"'
check "elicitation answered" "$(field .state)" '"working"'
fire permission-request.json '.agent_id = "agent-7"'
check "a subagent can need you" "$(field '[.state, .needs]')" '["needs_you",{"by":"agent-7","tool":"Bash"}]'
fire post-tool-bash.json
check "the main thread's tool does not clear a subagent's request" "$(field .state)" '"needs_you"'
fire post-tool-bash.json '.agent_id = "agent-7"'
check "the subagent's own tool does" "$(field .state)" '"working"'

now=1792353050
fire stop.json ".transcript_path = \"$fixtures/lagging-transcript.jsonl\""
check "stop: done" "$(field '[.state, .state_at]')" "[\"done\",$now]"
check "stop: the reply from last_assistant_message" "$(field .reply.text)" \
  '"That works with no model calls: the hook writes one file per session and the overlay reads them."'
check "stop: never the lagging transcript" "$(grep -c STALE "$file")" "0"
check "the hook never opens the transcript" "$(grep -c transcript_path "$hook")" "0"
now=$((now + 5)) fire stop.json '.last_assistant_message = ""'
check "stop with no text keeps the last reply" "$(field '[.reply.text, .reply.at]')" \
  '["That works with no model calls: the hook writes one file per session and the overlay reads them.",1792353050]'

now=1792353060
fire stop-failure.json
check "failure: error" "$(field '[.state, .reason, .error]')" '["error","rate limit","API Error: Rate limit reached"]'
fire user-prompt.json
check "the next prompt clears the error" "$(field '[.state, .error]')" '["working",null]'

echo "where moves, identity stays"
now=1792353100
fire post-tool-edit.json ".tool_input.file_path = \"$repos/ideas/README.md\""
check "an edit moves where" "$(field '.where | [.repo, .by, .at]')" "[\"ideas\",\"edit\",$now]"
check "the old place is touched" "$(field '.touched')" "[{\"repo\":\"klepsydra\",\"at\":$now}]"
now=1792353110
fire post-tool-notebook.json ".tool_input.notebook_path = \"$repos/loose/notes/nb.ipynb\""
check "a notebook edit moves where" "$(field '.where.repo')" '"notes"'
fire user-prompt.json ".cwd = \"$repos/subsrc\""
check "after an edit, cwd does not move where" "$(field '.where.repo')" '"notes"'
check "identity unchanged across three repos" "$(field '[.voice, .claude.pid]')" '["am_michael",500]'
check "touched, newest first" "$(field '[.touched[].repo]')" '["ideas","klepsydra"]'
for i in 1 2 3 4 5 6 7; do
  mkdir -p "$repos/r$i/.git"
  now=$((1792353200 + i)) fire post-tool-edit.json ".tool_input.file_path = \"$repos/r$i/f\""
done
check "touched keeps six" "$(field '[.touched[].repo]')" '["r6","r5","r4","r3","r2","r1"]'
# shellcheck disable=SC2016  # a jq variable
check "where is not touched" "$(field '.where.repo as $w | [.touched[].repo] | index($w)')" "null"

printf '{"holders":{"500:8717628":{"voice":"bf_emma","seen":2}}}\n' >"$work/voices.json"
fire post-tool-bash.json
check "a voice keryx changes is copied" "$(field .voice)" '"bf_emma"'
rm "$work/voices.json"
fire user-prompt.json
check "keryx gone keeps the voice" "$(field .voice)" '"bf_emma"'

echo "lifecycle"
now=1792353300
fire session-end.json
check "end" "$(field '[.state, .reason, .ended]')" "[\"ended\",\"exited\",{\"reason\":\"prompt_input_exit\",\"at\":$now}]"
touch -d @1 "$file"
fire stop.json
fire permission-request.json
fire user-prompt.json
check "a late stop, request or prompt cannot revive it" "$(mtime):$(field .state)" '1:"ended"'
now=1792353400 fire session-start.json '.source = "resume"'
check "resumed: done, since it has a prompt" "$(field '[.state, .ended]')" '["done",null]'
now=1792353405 fire session-start.json '.source = "resume"' KLEPSYDRA_PID=710
check "resumed in another terminal: the new claude" "$(field .claude)" '{"pid":700,"start":9000000}'
fire user-prompt.json
now=1792353410 fire session-start.json '.source = "compact"'
check "compaction keeps the state" "$(field .state)" '"working"'
check "compaction keeps the claude" "$(field .claude.pid)" "700"

rm -f "$file"
now=1792353500 fire user-prompt.json
check "installed mid-session: created from any event" "$(field '[.state, .started_at, .prompt.at]')" \
  '["working",1792353500,1792353500]'
rm -f "$file"
fire session-end.json
check "an end for an unknown session writes nothing" "$([[ -e $file ]] && echo written || echo none)" "none"

fire session-start.json '.session_title = "fleet-plan"'
check "a custom title names it" "$(field .name)" '"fleet-plan"'

echo "bad input"
out=$(KLEPSYDRA_DIR="$dir" XDG_RUNTIME_DIR="$work" bash "$hook" <"$fixtures/malformed.json"); rc=$?
check "malformed: exit 0" "$rc" "0"
check "malformed: silent" "$out" ""
fire user-prompt.json '.session_id = "../../evil"'
check "a session id that is not a uuid writes nothing" "$(find "$work" -name 'evil*' | wc -l)" "0"
out=$(fire user-prompt.json '.' KLEPSYDRA_DIR=/proc/nonexistent); rc=$?
check "unwritable dir: exit 0" "$rc" "0"
check "no tmp litter" "$(find "$dir" -name '*.tmp' | wc -l)" "0"
mkdir -p "$work/full"
# shellcheck disable=SC1090
( source "$hook"; trap '' XFSZ; ulimit -f 0; write_atomic "$work/full/x.json" '{}' ) 2>/dev/null
check "a failed write leaves no tmp file" "$(find "$work/full" -type f | wc -l)" "0"

echo "concurrency"
rm -f "$file"
now=1792354000 fire session-start.json
for i in $(seq 1 12); do mkdir -p "$repos/c$i/.git"; done
for i in $(seq 1 12); do
  now=$((1792354000 + i)) fire post-tool-edit.json ".tool_input.file_path = \"$repos/c$i/f\"" &
done
wait
check "parallel events: the file parses" "$(jq -e .v "$file" >/dev/null && echo ok)" "ok"
check "parallel events: no update lost" "$(field '.touched | length')" "6"
check "parallel events: where and touched are seven repos" \
  "$(field '[.where.repo] + [.touched[].repo] | unique | length')" "7"


echo "self-heal and heartbeat"
rm -f "$file"
now=1792355000
fire post-tool-bash.json
check "created from a tool event: working" "$(field '[.state, .state_at, .active_at]')" "[\"working\",$now,$now]"
check "tool output never recorded (created mid-turn)" "$(grep -c SECRET "$file")" "0"
touch -d @1 "$file"
now=1792355030
fire post-tool-bash.json
check "two events 30 s apart: one write" "$(mtime):$(field .active_at)" "1:1792355000"
now=1792355061
fire post-tool-bash.json
check "61 s apart: active_at moves" "$(field '[.active_at, .written_at, .state_at]')" "[1792355061,1792355061,1792355000]"
now=1792355070
fire notification-idle.json
check "idle prompt: working becomes done" "$(field '[.state, .reason, .state_at]')" "[\"done\",null,$now]"
fire permission-request.json
now=1792355080
fire notification-idle.json
check "idle prompt: needs_you becomes done" "$(field '[.state, .reason, .state_at]')" "[\"done\",null,$now]"
now=1792355090
fire stop-failure.json
now=1792355095
fire notification-idle.json
check "idle prompt leaves an error alone" "$(field .state)" '"error"'
fire session-end.json
now=1792355100
fire notification-idle.json
check "idle prompt leaves ended alone" "$(field .state)" '"ended"'

rm -f "$file"
now=1792355200
fire stop-failure.json '.last_assistant_message = ""'
check "failure with no text falls back to error_details" "$(field .error)" '"429 Too Many Requests"'
fire session-start.json '.source = "resume"'
check "resume clears the error" "$(field '[.state, .error]')" '["new",null]'

rm -f "$file"
fire post-tool-edit.json
check "edit input never recorded" "$(grep -c SECRET "$file")" "0"
rm -f "$file"
fire post-tool-notebook.json
check "notebook input never recorded" "$(grep -c SECRET "$file")" "0"

echo "partial voices.json"
printf '{"holders":{"500:8717628":{"voice":"am_' >"$work/voices.json"
rm -f "$file"
now=1792354100
out=$(fire session-start.json); rc=$?
check "truncated voices.json: exit 0" "$rc" "0"
check "truncated voices.json: silent" "$out" ""
check "truncated voices.json: no voice" "$(field .voice)" "null"
check "truncated voices.json: file still written" "$(field .state)" '"new"'

block() { sed -n '/^# --- klepsydra dir/,/^# --- end klepsydra dir ---$/p' "$1"; }
check "dir block present" "$([[ -n "$(block "$hook")" ]] && echo yes)" "yes"
check "sourceable from a set -e script" \
  "$(KLEPSYDRA_DIR=/x/dev.ajsoftworks.klepsydra bash -ec 'source "$1"; echo "$KLEPSYDRA_DIR"' _ "$hook")" \
  "/x/dev.ajsoftworks.klepsydra"
check "dir block identical in the statusline" "$(block "$hook")" "$(block "$here/../statusline/klepsydra-statusline.sh")"

# A hook must stay silent and exit 0 even when its environment is bare.
out=$(env -u USER -u HOME bash "$hook" </dev/null 2>&1); rc=$?
check "unset USER and HOME: exit 0" "$rc" "0"
check "unset USER and HOME: no output" "$out" ""

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]

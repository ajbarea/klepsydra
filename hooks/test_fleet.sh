#!/usr/bin/env bash
# Fixture-driven tests for the fleet hook. Run: bash hooks/test_fleet.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hook="$here/klepsydra-fleet.sh"
fixtures="$here/fixtures"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Every test runs with a tmux that only logs its calls, so no run can touch a real server.
stub="$work/stubbin"
mkdir -p "$stub"
# $work/tmux.mode: "fail" exits 1, "hang" sleeps past the hook's timeout; else it succeeds.
# shellcheck disable=SC2016 # the stub script expands its own variables
printf '#!/bin/sh\necho "$*" >>"%s/tmux.log"\ncase $(cat "%s/tmux.mode" 2>/dev/null) in fail) exit 1;; hang) exec sleep 30;; esac\n' "$work" "$work" >"$stub/tmux"
chmod +x "$stub/tmux"
export PATH="$stub:$PATH"
tlog="$work/tmux.log"

pass=0 fail=0

check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
  fi
}

cp "$here/../src/fleet/cast.json" "$work/test-cast.json"
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
# A .git file saved with CRLF still leads to its main checkout.
mkdir -p "$repos/crlf"
printf 'gitdir: %s\r\n' "$repos/klepsydra/.git/worktrees/fleet" >"$repos/crlf/.git"

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
check "a CRLF .git file" "$(where "$repos/crlf")" "klepsydra|crlf|feat/fleet-visualizer"

# keryx names the same repos; when its source is here, ask it directly.
keryx_src=${KERYX_SRC:-$HOME/ajsoftworks/keryx/src}
if [[ -f "$keryx_src/keryx/hook.py" ]]; then
  for p in klepsydra klepsydra/src/deep klepsydra/.claude/worktrees/fleet ideas/vendor/subsrc subsrc loose/notes crlf; do
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

# The boot and host the hook sees unless a test says otherwise, whatever runs it.
boot_file="$work/boot_id"
printf '%s\n' 0b6e1c5a-1111-4222-8333-444455556666 >"$boot_file"

# Fire one fixture event at the hook, edited by an optional jq filter, as
# Claude Code would from the terminal held by pid 500.
fire() { # fixture [filter] [VAR=value...]
  local fixture=$1 filter=${2:-.}
  shift; (( $# )) && shift
  jq -c --arg cwd "$wt" "if .cwd then .cwd = \$cwd else . end | $filter" "$fixtures/$fixture" |
    env KLEPSYDRA_DIR="$dir" KLEPSYDRA_NOW="$now" KLEPSYDRA_PROC="$work/proc" KLEPSYDRA_PID=600 \
      KERYX_VOICES="$work/voices.json" XDG_RUNTIME_DIR="$work" KLEPSYDRA_CAST="$work/test-cast.json" \
      KLEPSYDRA_BOOT_ID="$boot_file" TMUX= TMUX_PANE= WSL_DISTRO_NAME= "$@" bash "$hook"
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

fire permission-request.json
fire post-tool-bash.json '.hook_event_name = "PostToolUseFailure"'
check "a failed tool call ends the wait it was approved from" "$(field '[.state, .reason, .needs]')" '["working",null,null]'
fire permission-request.json
fire post-tool-bash.json '.hook_event_name = "PostToolUseFailure" | .tool_name = "Read"'
check "another tool failing leaves it waiting" "$(field .state)" '"needs_you"'
fire post-tool-bash.json '.hook_event_name = "PostToolUseFailure" | .agent_id = "agent-7"'
check "a subagent's failing tool leaves it waiting" "$(field .state)" '"needs_you"'
fire post-tool-bash.json '.hook_event_name = "PostToolUseFailure"'
check "its own failure clears it" "$(field .state)" '"working"'
fire post-tool-edit.json '.hook_event_name = "PostToolUseFailure" | .tool_input.file_path = "'"$repos"'/ideas/x"'
check "a failed edit moves nothing" "$(field '.where.repo')" '"klepsydra"'

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
fire notification-elicitation.json '.notification_type = "elicitation_url_dialog"'
check "MCP URL elicitation" "$(field '[.state, .reason]')" '["needs_you","question"]'
fire post-tool-bash.json '.tool_name = "mcp__memory__store"'
check "URL elicitation answered" "$(field .state)" '"working"'
fire permission-request.json '.agent_id = "agent-7"'
check "a subagent can need you" "$(field '[.state, .needs]')" '["needs_you",{"by":"agent-7","tool":"Bash"}]'
fire post-tool-bash.json
check "the main thread's tool does not clear a subagent's request" "$(field .state)" '"needs_you"'
fire post-tool-bash.json '.agent_id = "agent-7"'
check "the subagent's own tool does" "$(field .state)" '"working"'

now=1792353050
fire stop.json ".transcript_path = \"$fixtures/lagging-transcript.jsonl\""
check "stop: done" "$(field '[.state, .state_at]')" "[\"done\",$now]"
check "stop: the turn's end" "$(field .turn_end)" "$now"
check "stop: the reply from last_assistant_message" "$(field .reply.text)" \
  '"That works with no model calls: the hook writes one file per session and the overlay reads them."'
check "stop: never the lagging transcript" "$(grep -c STALE "$file")" "0"
check "the hook never opens the transcript" "$(grep -c transcript_path "$hook")" "0"
now=$((now + 5)) fire stop.json '.last_assistant_message = ""'
check "stop with no text keeps the last reply" "$(field '[.reply.text, .reply.at]')" \
  '["That works with no model calls: the hook writes one file per session and the overlay reads them.",1792353050]'
check "stop with no text still ends the turn" "$(field .turn_end)" "1792353055"

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
check "an edit outside any repo leaves where alone" "$(field '.where | [.repo, .at]')" "[\"ideas\",1792353100]"
fire post-tool-edit.json '.tool_input.file_path = "/tmp/x.rs"'
check "a file directly under /tmp leaves where alone" "$(field '.where.repo')" '"ideas"'
check "and touched" "$(field '[.touched[].repo]')" '["klepsydra"]'
fire post-tool-notebook.json ".tool_input.notebook_path = \"$repos/subsrc/nb.ipynb\""
check "a notebook edit in a repo moves where" "$(field '.where.repo')" '"subsrc"'
fire user-prompt.json ".cwd = \"$repos/klepsydra\""
check "after an edit, cwd does not move where" "$(field '.where.repo')" '"subsrc"'
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

echo "home voice"
# While keryx is muted no terminal is held, so a session takes the voice keryx
# remembers for its repo; a held voice always beats it.
H=22222222-3333-4444-8555-666666666666
hfile="$dir/fleet/$H.json"
hfield() { jq -c "$1" "$hfile"; }
day=$((24 * 3600))
printf '{"homes":{"klepsydra":{"voice":"bf_emma","seen":%s}}}\n' $((now - 60)) >"$work/voices.json"
fire session-start.json ".session_id = \"$H\""
check "muted keryx: the repo's home voice" "$(hfield '[.voice, .voice_from]')" '["bf_emma","home"]'
printf '{"homes":{"klepsydra":{"voice":"bf_emma","seen":%s}},"holders":{"500:8717628":{"voice":"am_adam","seen":1}}}\n' $((now - 60)) >"$work/voices.json"
fire user-prompt.json ".session_id = \"$H\""
check "a later hold replaces a home voice" "$(hfield '[.voice, .voice_from]')" '["am_adam","hold"]'
printf '{"homes":{"klepsydra":{"voice":"bf_emma","seen":%s}}}\n' $((now - 60)) >"$work/voices.json"
fire post-tool-bash.json ".session_id = \"$H\""
check "a home voice never replaces a hold" "$(hfield '[.voice, .voice_from]')" '["am_adam","hold"]'
rm -f "$hfile"
printf '{"homes":{"klepsydra":{"voice":"bf_emma","seen":%s}}}\n' $((now - 90 * day - 1)) >"$work/voices.json"
fire session-start.json ".session_id = \"$H\""
check "a home keryx has forgotten (90 days) is ignored" "$(hfield '[.voice, .voice_from]')" '[null,null]'
printf '{"homes":{"klepsydra":{"voice":"bf_emma","seen":%s}}}\n' $((now - 90 * day)) >"$work/voices.json"
fire user-prompt.json ".session_id = \"$H\""
check "90 days exactly still counts" "$(hfield '[.voice, .voice_from]')" '["bf_emma","home"]'
printf '{"homes":{"klepsydra":{"voice":"am_adam","seen":%s}}}\n' $((now - 60)) >"$work/voices.json"
fire post-tool-bash.json ".session_id = \"$H\""
check "a home voice never replaces a home voice" "$(hfield '[.voice, .voice_from]')" '["bf_emma","home"]'
rm -f "$hfile"
printf '{"homes":{"klepsydra":{"voice":"bf_emma","seen":%s}},"holders":{"500:8717628":{"voice":"am_adam","seen":1}}}\n' $((now - 60)) >"$work/voices.json"
fire session-start.json ".session_id = \"$H\""
check "a live hold beside a home: the hold" "$(hfield '[.voice, .voice_from]')" '["am_adam","hold"]'
rm -f "$hfile"
printf '{"homes":{"loose":{"voice":"bf_emma","seen":%s}}}\n' $((now - 60)) >"$work/voices.json"
fire session-start.json ".session_id = \"$H\""
check "another repo's home is not this one's" "$(hfield .voice)" "null"
printf '{"v":1,"session_id":"%s","started_at":%s,"voice":"am_michael","state":"new","state_at":%s,"written_at":%s}\n' "$H" "$now" "$now" "$now" >"$hfile"
printf '{"homes":{"klepsydra":{"voice":"bf_emma","seen":%s}}}\n' $((now - 60)) >"$work/voices.json"
fire user-prompt.json ".session_id = \"$H\""
check "a voice from before voice_from counts as held" "$(hfield '[.voice, .voice_from]')" '["am_michael","hold"]'
rm -f "$hfile" "$work/voices.json"

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
check "resumed: no turn ended" "$(field '.turn_end < 1792353400')" "true"
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
check "created from a tool event: working" "$(field '[.state, .state_at, .written_at]')" "[\"working\",$now,$now]"
check "tool output never recorded (created mid-turn)" "$(grep -c SECRET "$file")" "0"
touch -d @1 "$file"
now=1792355030
fire post-tool-bash.json
check "two events 30 s apart: one write" "$(mtime):$(field .written_at)" "1:1792355000"
now=1792355061
fire post-tool-bash.json
check "61 s apart: written_at moves" "$(field '[.written_at, .state_at]')" "[1792355061,1792355000]"
now=1792355062
fire user-prompt.json
now=1792355063
fire notification-idle.json
check "idle prompt right after a prompt: still working" "$(field .state)" '"working"'
now=1792355123
fire notification-idle.json
check "idle prompt: working becomes done" "$(field '[.state, .reason, .state_at]')" "[\"done\",null,$now]"
check "idle prompt: done, but no turn ended" "$(field '(.turn_end // 0) < '"$now")" "true"
fire permission-request.json
now=1792355130
fire notification-idle.json
check "idle prompt right after a request: still needs_you" "$(field .state)" '"needs_you"'
now=1792355200
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

echo "pruning"
# Sessions in a scratch data dir, each a pid:start, a last event, and a beat age.
pd="$work/prune/dev.ajsoftworks.klepsydra"
pnow=1792400000
day=86400
mksession() { # id pid start last-event [beat-mtime]
  printf '{"v":1,"session_id":"%s","claude":{"pid":%s,"start":%s},"started_at":%s,"state_at":%s}\n' \
    "$1" "$2" "$3" "$4" "$4" >"$pd/fleet/$1.json"
  if [[ -n ${5:-} ]]; then printf 'name\t1\n' >"$pd/fleet/$1.beat"; touch -d "@$5" "$pd/fleet/$1.beat"; fi
}
id() { printf '%08d-0000-4000-8000-000000000000' "$1"; }
reset_prune() {
  rm -rf "$work/prune"
  mkdir -p "$pd/fleet"
  mksession "$(id 1)" 999 1 $((pnow - 2 * day))                  # gone, old: deleted
  mksession "$(id 2)" 500 8717628 $((pnow - 3 * day))            # live claude: kept
  mksession "$(id 3)" 500 1234 $((pnow - 3 * day))               # pid reused: deleted
  mksession "$(id 4)" 999 1 $((pnow - 3600))                     # gone, recent: kept
  mksession "$(id 5)" 999 1 $((pnow - 2 * day)) $((pnow - 60))   # beat still fresh: kept
  mksession "$(id 6)" 999 1 $((pnow - 2 * day)) $((pnow - 2 * day))  # gone, old, old beat: both deleted
  printf 'n\t1\n' >"$pd/fleet/$(id 7).beat"; touch -d "@$((pnow - 2 * day))" "$pd/fleet/$(id 7).beat"  # orphan, old
  printf 'n\t1\n' >"$pd/fleet/$(id 8).beat"                       # orphan, fresh
  touch -d "@$pnow" "$pd/fleet/$(id 8).beat"
  printf '{"v":1}' >"$pd/fleet/notes.json"; touch -d @1 "$pd/fleet/notes.json"  # not a session
  printf 'x' >"$pd/fleet/abc.beat"; touch -d @1 "$pd/fleet/abc.beat"
  printf 'not json' >"$pd/fleet/$(id 9).json"; touch -d @1 "$pd/fleet/$(id 9).json"  # unreadable
  ln -s "$pd/fleet/$(id 2).json" "$pd/fleet/$(id 10).json"           # a link
}
names() { find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' '; }
listing() { names "$pd/fleet"; }
mkproc 501 1 claude 4321 Z claude
reset_prune
before=$(listing)

# Refusals first: none of these may delete anything.
prune_fleet "" "$pnow"; rc=$?
check "unset dir: refused" "$rc|$(listing)" "1|$before"
prune_fleet "prune/dev.ajsoftworks.klepsydra" "$pnow"; rc=$?
check "relative dir: refused" "$rc|$(listing)" "1|$before"
mkdir -p "$work/other/fleet" && cp "$pd/fleet/$(id 1).json" "$work/other/fleet/"
prune_fleet "$work/other" "$pnow"; rc=$?
check "wrong name: refused" "$rc|$(names "$work/other/fleet")" "1|$(id 1).json "
mv "$pd/fleet" "$work/real-fleet" && ln -s "$work/real-fleet" "$pd/fleet"
prune_fleet "$pd" "$pnow"; rc=$?
check "linked fleet dir: refused" "$rc|$(names "$work/real-fleet")" "1|$before"
rm "$pd/fleet" && mv "$work/real-fleet" "$pd/fleet"
prune_fleet "$pd" "not-a-time"; rc=$?
check "no clock: refused" "$rc|$(listing)" "1|$before"

prune_fleet "$pd/" "$pnow"; rc=$?
check "prune ran" "$rc" "0"
check "kept: live, recent, fresh beat, non-sessions, unreadable, link" "$(listing)" \
  "$(id 2).json $(id 4).json $(id 5).beat $(id 5).json $(id 8).beat $(id 9).json $(id 10).json abc.beat notes.json "
check "the linked file's target survives" "$(jq -r .session_id "$pd/fleet/$(id 2).json")" "$(id 2)"

reset_prune
mksession "$(id 11)" 501 4321 $((pnow - 2 * day))
prune_fleet "$pd" "$pnow"
check "a zombie is gone" "$([[ -e $pd/fleet/$(id 11).json ]] && echo kept || echo deleted)" "deleted"

# A link to a dead, old session is neither followed nor deleted.
reset_prune
printf '{"v":1,"claude":{"pid":999,"start":1},"started_at":1,"state_at":1}\n' >"$work/outside.json"
ln -s "$work/outside.json" "$pd/fleet/$(id 14).json"
printf x >"$work/outside.beat"; touch -d @1 "$work/outside.beat"
ln -s "$work/outside.beat" "$pd/fleet/$(id 15).beat"
prune_fleet "$pd" "$pnow"
check "linked session and beat files stay, targets untouched" \
  "$([[ -L $pd/fleet/$(id 14).json && -L $pd/fleet/$(id 15).beat && -e $work/outside.json && -e $work/outside.beat ]] && echo kept || echo gone)" "kept"

# written_at is last activity too.
reset_prune
printf '{"v":1,"claude":{"pid":999,"start":1},"started_at":%s,"state_at":%s,"written_at":%s}\n' \
  $((pnow - 3 * day)) $((pnow - 3 * day)) $((pnow - 60)) >"$pd/fleet/$(id 13).json"
prune_fleet "$pd" "$pnow"
check "a recent written_at keeps a dead session" "$([[ -e $pd/fleet/$(id 13).json ]] && echo kept || echo deleted)" "kept"

# Write litter: <uuid>.json.<digits>.tmp older than a day.
reset_prune
old=$((pnow - 2 * day))
printf x >"$pd/fleet/$(id 20).json.123.tmp"; touch -d "@$old" "$pd/fleet/$(id 20).json.123.tmp"
printf x >"$pd/fleet/$(id 21).json.123.tmp"; touch -d "@$((pnow - 60))" "$pd/fleet/$(id 21).json.123.tmp"
for n in notes.tmp "$(id 22).json.tmp" "$(id 22).json.12.tmp.bak" "$(id 22).json.1x.tmp" "x$(id 22).json.12.tmp"; do
  printf x >"$pd/fleet/$n"; touch -d "@$old" "$pd/fleet/$n"
done
ln -s "$pd/fleet/$(id 2).json" "$pd/fleet/$(id 23).json.9.tmp"
touch -h -d "@$old" "$pd/fleet/$(id 23).json.9.tmp"
prune_fleet "$pd" "$pnow"
check "old tmp removed" "$([[ -e $pd/fleet/$(id 20).json.123.tmp ]] && echo kept || echo deleted)" "deleted"
check "fresh tmp, other names and a linked tmp stay" "$(names "$pd/fleet" | tr ' ' '\n' | grep -c 'tmp')" "7"
check "the linked tmp's target survives" "$(jq -r .session_id "$pd/fleet/$(id 2).json")" "$(id 2)"

# More refusals and skips.
reset_prune
before=$(listing)
for bad in / // "$pd/../dev.ajsoftworks.klepsydra" "$pd/.." "$work/prune/x/../dev.ajsoftworks.klepsydra"; do
  prune_fleet "$bad" "$pnow"; rc=$?
  check "refused dir $bad" "$rc|$(listing)" "1|$before"
done
mkdir -p "$work/linked" && ln -s "$pd" "$work/linked/dev.ajsoftworks.klepsydra"
prune_fleet "$work/linked/dev.ajsoftworks.klepsydra" "$pnow"; rc=$?
check "a linked data dir: refused" "$rc|$(listing)" "1|$before"
prune_fleet "$pd//" "$pnow"; rc=$?
check "trailing slashes on the real name: pruned" "$rc|$([[ -e $pd/fleet/$(id 1).json ]] && echo kept || echo deleted)" "0|deleted"
rm -rf "$work/empty" && mkdir -p "$work/empty/dev.ajsoftworks.klepsydra/fleet"
prune_fleet "$work/empty/dev.ajsoftworks.klepsydra" "$pnow"; rc=$?
check "an empty fleet dir: nothing to do" "$rc" "0"
rm -rf "$work/empty/dev.ajsoftworks.klepsydra/fleet" && printf x >"$work/empty/dev.ajsoftworks.klepsydra/fleet"
prune_fleet "$work/empty/dev.ajsoftworks.klepsydra" "$pnow"; rc=$?
check "fleet as a regular file: left alone" "$rc|$(cat "$work/empty/dev.ajsoftworks.klepsydra/fleet")" "0|x"

reset_prune
printf '{"v":2,"claude":{"pid":999,"start":1},"started_at":1,"state_at":1}\n' >"$pd/fleet/$(id 16).json"
printf '{"v":1,"claude":{"pid":999,"start":1}}\n' >"$pd/fleet/$(id 17).json"
printf '{"v":1,"claude":{"pid":999,"start":1},"started_at":1}' >"$pd/fleet/$(id 18).json"  # no final newline
printf '{"v":1,"claude":{"pid":999,"start":1},"started_at":1}\n' >"$pd/fleet/$(id 19).json"
prune_fleet "$pd" "$pnow"
check "unknown v and no timestamps kept; a missing final newline does not hide the next file" \
  "$(for n in 16 17 18 19; do [[ -e $pd/fleet/$(id $n).json ]] && printf kept || printf gone; done)" "keptkeptgonegone"

# A process that is not Claude Code is not Claude Code, whatever its pid and start.
mkproc 502 1 vim 7777 S vim
reset_prune
mksession "$(id 24)" 502 7777 $((pnow - 2 * day))
prune_fleet "$pd" "$pnow"
check "a reused pid running another program is gone" "$([[ -e $pd/fleet/$(id 24).json ]] && echo kept || echo deleted)" "deleted"

# Heartbeat write litter.
reset_prune
printf x >"$pd/fleet/$(id 25).beat.55.tmp"; touch -d "@$((pnow - 2 * day))" "$pd/fleet/$(id 25).beat.55.tmp"
prune_fleet "$pd" "$pnow"
check "old beat tmp removed" "$([[ -e $pd/fleet/$(id 25).beat.55.tmp ]] && echo kept || echo deleted)" "deleted"

# A forged session file cannot name what gets deleted.
reset_prune
mkdir -p "$work/outside" && printf v >"$work/outside/victim" && printf v >"$work/outside/victim.beat"
jq -nc --arg p "0
$work/outside/victim	999	1	5
" '{v:1,claude:{pid:$p,start:1},started_at:1}' >"$pd/fleet/$(id 27).json"
jq -nc --arg p "0
$pd/fleet/$(id 2).json	999	1	5
" '{v:1,claude:{pid:$p,start:1},started_at:1}' >"$pd/fleet/$(id 28).json"
jq -nc --arg p "0
$(id 2).json	999	1	5
" '{v:1,claude:{pid:$p,start:"x"},started_at:1}' >"$pd/fleet/$(id 29).json"
out=$(prune_fleet "$pd" "$pnow" 2>&1); rc=$?
check "forged pid text: rc 0, no output" "$rc|$out" "0|"
check "forged paths delete nothing outside the glob" \
  "$(names "$work/outside")|$([[ -e $pd/fleet/$(id 2).json ]] && echo kept)" "victim victim.beat |kept"

# A file named like a stat line cannot turn a FIFO into a regular file, which
# the prune would then block on with the lock held.
reset_prune
mkfifo "$pd/fleet/$(id 40).json"
: >"$pd/fleet/zz.json"$'\n'"regular file|1|$(id 40).json"
# shellcheck disable=SC2016  # expanded by the inner shell
timeout 10 bash -c 'source "$1"; prune_fleet "$2" "$3"' _ "$hook" "$pd" "$pnow"; rc=$?
check "a stat line planted in a file name does not hang the prune" "$rc" "0"
check "the FIFO is left alone" "$([[ -p $pd/fleet/$(id 40).json ]] && echo kept)" "kept"

# Zero-byte beats and litter are files too.
reset_prune
: >"$pd/fleet/$(id 1).beat"; touch -d "@$((pnow - 2 * day))" "$pd/fleet/$(id 1).beat"
: >"$pd/fleet/$(id 30).beat"; touch -d "@$((pnow - 2 * day))" "$pd/fleet/$(id 30).beat"
: >"$pd/fleet/$(id 31).json.7.tmp"; touch -d "@$((pnow - 2 * day))" "$pd/fleet/$(id 31).json.7.tmp"
prune_fleet "$pd" "$pnow"
check "empty beat of a dead old session, empty orphan beat and empty tmp are pruned" \
  "$(for n in $(id 1).json $(id 1).beat $(id 30).beat $(id 31).json.7.tmp; do [[ -e $pd/fleet/$n ]] && printf kept || printf gone; done)" "gonegonegonegone"

stamp="$work/klepsydra-fleet-$UID.pruned"
reset_prune; rm -f "$stamp"
out=$(fire session-start.json ".session_id = \"$(id 12)\"" KLEPSYDRA_DIR="$pd" KLEPSYDRA_NOW="$pnow"); rc=$?
check "session start prunes" "$([[ -e $pd/fleet/$(id 1).json ]] && echo kept || echo deleted)" "deleted"
check "the prune path prints nothing and exits 0" "$rc|$out" "0|"
check "session start writes its own file" "$(jq -r .state "$pd/fleet/$(id 12).json")" "new"
reset_prune
fire session-start.json ".session_id = \"$(id 12)\"" KLEPSYDRA_DIR="$pd" KLEPSYDRA_NOW="$((pnow + 60))"
check "no second prune within the hour" "$([[ -e $pd/fleet/$(id 1).json ]] && echo kept || echo deleted)" "kept"
fire session-start.json ".session_id = \"$(id 12)\"" KLEPSYDRA_DIR="$pd" KLEPSYDRA_NOW="$((pnow + 3600))"
check "prunes again after an hour" "$([[ -e $pd/fleet/$(id 1).json ]] && echo kept || echo deleted)" "deleted"
reset_prune; rm -f "$stamp"
fire user-prompt.json ".session_id = \"$(id 12)\"" KLEPSYDRA_DIR="$pd" KLEPSYDRA_NOW="$pnow"
check "other events do not prune" "$([[ -e $pd/fleet/$(id 1).json ]] && echo kept || echo deleted)" "kept"

# A resumed session (dead, over a day idle) is written before the prune looks.
reset_prune; rm -f "$stamp"
printf '{"v":1,"session_id":"%s","claude":{"pid":999,"start":1},"started_at":%s,"state_at":%s,"state":"done"}\n' \
  "$(id 26)" $((pnow - 5 * day)) $((pnow - 5 * day)) >"$pd/fleet/$(id 26).json"
fire session-start.json ".session_id = \"$(id 26)\"" KLEPSYDRA_DIR="$pd" KLEPSYDRA_NOW="$pnow"
check "a resumed old session keeps its history" "$(jq -r .started_at "$pd/fleet/$(id 26).json" 2>&1)" "$((pnow - 5 * day))"

echo "background work"
A=abd38d40cac785715 B=biwpk3ab6
bg() { field '[(.background // [])[] | "\(.kind):\(.id)"] | join(",")'; }
rm -f "$file"
now=1792356000
fire session-start.json
fire user-prompt.json
check "no background work: no field" "$(field 'has("background")')" "false"
now=1792356001 fire post-tool-bash-background.json
check "a background shell is added by its task id" "$(bg)" "\"shell:$B\""
check "added at its time" "$(field '.background[0].at')" "1792356001"
now=1792356002 fire subagent-start.json
check "a subagent start adds the agent" "$(bg)" "\"shell:$B,agent:$A\""
now=1792356003 fire post-tool-agent-background.json
check "the async launch of a known agent adds nothing" "$(bg)" "\"shell:$B,agent:$A\""
now=1792356004 fire post-tool-bash.json
check "a foreground shell adds nothing" "$(bg)" "\"shell:$B,agent:$A\""
check "working during the turn, no reason" "$(field '[.state, .reason]')" '["working",null]'
now=1792356005 fire stop.json '.background_tasks = null'
check "stop with work out: working in background" "$(field '[.state, .reason, .state_at]')" '["working","background",1792356005]'
check "stop with work out: the reply is kept" "$(field .reply.at)" "1792356005"
now=1792356010 fire notification-idle.json
now=1792356100 fire notification-idle.json
check "idle prompt with work out: still working" "$(field '[.state, .reason]')" '["working","background"]'
now=1792356200 fire post-tool-bash.json ".agent_id = \"$A\""
check "the subagent's own event refreshes its time" "$(field "[.background[] | select(.id == \"$A\") | .at][0]")" "1792356200"
check "a shell's time never moves" "$(field "[.background[] | select(.id == \"$B\") | .at][0]")" "1792356001"
now=1792356230 fire post-tool-bash.json ".agent_id = \"$A\""
check "refreshed at most once a minute" "$(field "[.background[] | select(.id == \"$A\") | .at][0]")" "1792356200"
now=1792356300 fire subagent-stop.json
check "a subagent stop removes it" "$(bg)" "\"shell:$B\""
check "a subagent's reply is not the session's" "$(grep -c SUBAGENT-REPLY "$file")" "0"
check "still working in background" "$(field '[.state, .reason]')" '["working","background"]'
now=1792356310 fire task-notification-background.json
check "its notification starts a turn" "$(field '[.state, .reason]')" '["working",null]'
check "and keeps AJ's prompt" "$(field .prompt.text | grep -c task-notification)" "0"
now=1792356320 fire stop.json '.background_tasks = null'
check "the shell still out keeps it working" "$(field '[.state, .reason]')" '["working","background"]'
now=1792356330 fire user-prompt.json ".prompt = \"<task-notification>\n<task-id>$B</task-id>\n<status>completed</status>\n</task-notification>\""
check "a shell's notification removes it" "$(field 'has("background")')" "false"
now=1792356340 fire stop.json '.background_tasks = null'
check "stop with nothing out: done" "$(field '[.state, .reason]')" '["done",null]'

# Every removal path, one entry at a time.
now=1792356400 fire user-prompt.json
fire post-tool-bash-background.json
now=1792356401 fire post-tool-task-stop.json
check "TaskStop removes the shell" "$(bg)" '""'
fire post-tool-bash-background.json
fire post-tool-task-stop.json '.tool_name = "KillShell" | .tool_input = {shell_id: "biwpk3ab6"} | .tool_response = "Killed"'
check "KillShell removes it by shell_id" "$(bg)" '""'
fire post-tool-bash-background.json '.tool_response.backgroundTaskId = null'
check "no task id: the tool use id stands in" "$(bg)" '"shell:toolu_01G3isFBmhUydH4YMNewPyaP"'
fire user-prompt.json '.prompt = "<task-notification>\n<tool-use-id>toolu_01G3isFBmhUydH4YMNewPyaP</tool-use-id>\n<status>completed</status>\n</task-notification>"'
check "and its notification's tool use id removes it" "$(bg)" '""'
fire post-tool-bash-background.json
fire subagent-start.json
fire user-prompt.json ".prompt = \"<task-notification><task-id>$A</task-id></task-notification>\n<task-notification><task-id>$B</task-id></task-notification>\""
check "several notifications in one prompt remove each" "$(bg)" '""'
fire post-tool-bash-background.json
fire user-prompt.json ".prompt = \"why did <task-id>$B</task-id> fire?\""
check "a task id outside a notification removes nothing" "$(bg)" "\"shell:$B\""
fire subagent-start.json
now=1792356410 fire session-start.json '.source = "compact"'
check "compaction keeps the work out" "$(bg)" "\"shell:$B,agent:$A\""
now=1792356420 fire session-end.json
check "session end clears it" "$(field '[has("background"), .state]')" '[false,"ended"]'
now=1792356430 fire session-start.json '.source = "resume"'
fire user-prompt.json
fire post-tool-bash-background.json
now=1792356440 fire session-start.json '.source = "resume"'
check "a new process starts with none" "$(field 'has("background")')" "false"

# Stop's own list of running tasks is the truth.
fire user-prompt.json
now=1792356450 fire subagent-start.json
now=1792356500 fire stop-background.json
check "stop's list adds a shell the hook missed" "$(bg)" "\"shell:$B,agent:$A\""
check "and keeps a known entry's time" "$(field "[.background[] | select(.id == \"$A\") | .at][0]")" "1792356450"
check "a missed one is added at the stop" "$(field "[.background[] | select(.id == \"$B\") | .at][0]")" "1792356500"
check "stop's list: working in background" "$(field '[.state, .reason]')" '["working","background"]'
fire user-prompt.json
now=1792356510 fire stop.json
check "an empty list clears a missed stop: done" "$(field '[has("background"), .state]')" '[false,"done"]'
fire user-prompt.json
fire stop-background.json '.background_tasks[0].status = "completed" | .background_tasks[1].status = "killed"'
check "finished tasks in the list do not count" "$(field '[has("background"), .state]')" '[false,"done"]'

# Malformed and absent fields change nothing and never abort.
fire user-prompt.json
fire subagent-start.json '.agent_id = null'
fire subagent-start.json '.agent_id = 42'
fire subagent-start.json 'del(.agent_id)'
fire post-tool-bash-background.json '.tool_response = "text" | .tool_use_id = null'
fire post-tool-bash-background.json '.tool_input.run_in_background = "true" | .tool_response.backgroundTaskId = "x1"'
fire post-tool-agent-background.json '.tool_response.agentId = ["x"]'
fire stop-background.json '.background_tasks = [42, null, {"status": "running"}, {"id": 7, "status": "running"}]'
check "malformed adds: nothing added, done" "$(field '[has("background"), .state]')" '[false,"done"]'
fire user-prompt.json
fire subagent-start.json
fire subagent-stop.json '.agent_id = null'
fire post-tool-task-stop.json '.tool_input = "x" | .tool_response = null'
fire user-prompt.json '.prompt = 42'
fire stop.json '.background_tasks = "none"'
check "malformed removes: the agent stays" "$(field '[.background[].id, .state, .reason]')" "[\"$A\",\"working\",\"background\"]"
jq -c '.background = [{"id":"k","kind":"agent","at":1}, "junk", {"id":"x","kind":"cron","at":1}, {"id":"y","kind":"shell","at":"soon"}]' "$file" >"$file.new" && mv "$file.new" "$file"
fire user-prompt.json
check "a hand-broken set keeps only well-formed entries" "$(bg)" '"agent:k"'
for i in $(seq 1 70); do printf '{"id":"s%s","kind":"shell","at":1}\n' "$i"; done | jq -s '.' >"$work/many.json"
jq -c --slurpfile m "$work/many.json" '.background = $m[0]' "$file" >"$file.new" && mv "$file.new" "$file"
fire user-prompt.json
check "the set keeps at most 64, newest last" "$(field '[(.background | length), .background[0].id, .background[-1].id]')" '[64,"s7","s70"]'

# needs_you outranks everything.
fire user-prompt.json
jq -c 'del(.background)' "$file" >"$file.new" && mv "$file.new" "$file"
fire subagent-start.json
fire permission-request.json ".agent_id = \"$A\""
now=1792356600 fire stop.json '.background_tasks = null'
check "stop leaves a subagent's open request" "$(field '[.state, .reason]')" '["needs_you","approve Bash"]'
fire permission-request.json
now=1792356610 fire stop.json '.background_tasks = null'
check "the main thread's request ends with its turn, as before" "$(field '[.state, .reason]')" '["working","background"]'
fire permission-request.json
check "a request outranks background work" "$(field .state)" '"needs_you"'

# Review fixes: each pins a path the first version got wrong.
rm -f "$file"
now=1792357000 fire session-start.json
now=1792357001 fire user-prompt.json
now=1792357002 fire subagent-start.json
now=1792357002 fire post-tool-agent-background.json
now=1792357003 fire permission-request.json ".agent_id = \"$A\""
now=1792357100 fire notification-idle.json
check "idle prompt leaves a subagent's open request, as Stop does" "$(field '[.state, .reason]')" '["needs_you","approve Bash"]'
rm -f "$file"
now=1792357104 fire session-start.json
now=1792357105 fire user-prompt.json
now=1792357106 fire subagent-start.json
now=1792357107 fire permission-request.json ".agent_id = \"$A\""
now=1792357110 fire stop.json '.background_tasks = null'
check "the held stop keeps needs you" "$(field '[.state, .reason]')" '["needs_you","approve Bash"]'
now=1792357120 fire post-tool-bash.json ".agent_id = \"$A\""
check "answering it after the turn ended restores prompt free" "$(field '[.state, .reason]')" '["working","background"]'
fire subagent-stop.json
fire user-prompt.json
now=1792357200 fire permission-request.json
now=1792357210 fire post-tool-bash.json
check "answering the main thread mid-turn stays an open turn" "$(field '[.state, .reason]')" '["working",null]'

# Esc during a foreground subagent: no Stop, no SubagentStop; the idle prompt ends it.
rm -f "$file"
now=1792357300 fire session-start.json
now=1792357301 fire user-prompt.json
now=1792357302 fire subagent-start.json
now=1792357400 fire notification-idle.json
check "an interrupted foreground subagent: idle prompt gives done" "$(field '[.state, .reason, has("background")]')" '["done",null,false]'
now=1792357401 fire user-prompt.json
now=1792357402 fire subagent-start.json
now=1792357402 fire post-tool-agent-background.json
now=1792357403 fire post-tool-bash-background.json
now=1792357500 fire notification-idle.json
check "a launched background agent and a shell survive the idle prompt" "$(bg)" "\"agent:$A,shell:$B\""
check "and keep it working" "$(field '[.state, .reason]')" '["working","background"]'
now=1792357501 fire user-prompt.json
now=1792357502 fire post-tool-agent-background.json
now=1792357502 fire subagent-start.json
now=1792357600 fire notification-idle.json
check "the launch confirmed before its start still counts" "$(field "[.background[] | select(.id == \"$A\") | .kind][0]")" '"agent"'

# Other task types count as tasks; only a finished status drops one.
rm -f "$file"
now=1792357700 fire session-start.json
now=1792357701 fire user-prompt.json
now=1792357702 fire stop-background.json '.background_tasks += [{"id": "m1", "type": "monitor", "status": "running"}, {"id": "w1", "type": "workflow", "status": "backgrounded"}, {"id": "n1", "type": "shell"}, {"id": "f1", "type": "shell", "status": "finished"}, {"id": "x1", "type": "shell", "status": "failed"}, {"id": "k1", "type": "shell", "status": "killed"}]'
check "monitor and workflow are tasks; backgrounded and no status stay" "$(bg)" "\"shell:$B,agent:$A,task:m1,task:w1,shell:n1\""

# A SubagentStop handled before its SubagentStart leaves no phantom.
rm -f "$file"
now=1792357800 fire session-start.json
now=1792357801 fire user-prompt.json
now=1792357802 fire subagent-stop.json
now=1792357802 fire subagent-start.json
now=1792357802 fire post-tool-agent-background.json
check "a start after its own stop adds nothing" "$(field 'has("background")')" "false"
now=$((1792357802 + 61)) fire subagent-start.json
check "past the tombstone's minute, a start counts again" "$(bg)" "\"agent:$A\""
check "the tombstone is gone once expired" "$(field 'has("background_stopped")')" "false"

# An old file, written before the field existed, reads and updates.
rm -f "$file"
printf '{"v":1,"session_id":"%s","name":null,"started_at":1792356000,"launch_dir":null,"claude":null,"tmux":null,"host":null,"voice":null,"voice_from":null,"state":"working","reason":null,"needs":null,"state_at":1792356000,"where":null,"touched":[],"prompt":null,"reply":null,"error":null,"ended":null,"written_at":1792356000}\n' "$S" >"$file"
now=1792356700 fire stop.json
check "an old file: stop gives done" "$(field '[.state, has("background")]')" '["done",false]'

echo "install block"
# README.md's settings block is what users paste; it must register every
# event the hook handles, each async, with the statusline's 30 s heartbeat.
settings=$(sed -n '/^<!-- fleet-settings:start -->$/,/^<!-- fleet-settings:end -->$/p' "$here/../README.md" |
  grep -v -e '^<!--' -e '^```')
check "settings: parses" "$(jq -r 'type' <<<"$settings" 2>/dev/null)" "object"
check "settings: heartbeat every 30 s" "$(jq '.statusLine.refreshInterval' <<<"$settings")" "30"
check "settings: statusline command kept" "$(jq -r '.statusLine.command | ltrimstr("~")' <<<"$settings")" "/.claude/klepsydra-statusline.sh"
check "settings: the events" "$(jq -c '.hooks | keys' <<<"$settings")" \
  '["Notification","PermissionRequest","PostToolUse","PostToolUseFailure","PreToolUse","SessionEnd","SessionStart","Stop","StopFailure","SubagentStart","SubagentStop","UserPromptSubmit"]'
check "settings: every fleet hook is async" \
  "$(jq '[.hooks[][].hooks[]] | length > 0 and all(.async == true and (.command | endswith("/klepsydra-fleet.sh")))' <<<"$settings")" "true"
check "settings: questions and plans only" "$(jq -r '.hooks.PreToolUse[0].matcher' <<<"$settings")" "AskUserQuestion|ExitPlanMode"
check "settings: input requests and the idle self-heal" "$(jq -r '.hooks.Notification[0].matcher' <<<"$settings")" "elicitation_dialog|elicitation_url_dialog|idle_prompt"
check "settings: every tool after use" "$(jq -r '.hooks.PostToolUse[0].matcher // "*"' <<<"$settings")" "*"
check "settings: every tool after failure" "$(jq -r '.hooks.PostToolUseFailure[0].matcher // "*"' <<<"$settings")" "*"
check "the hook handles exactly the events registered" \
  "$(tr ' ' '\n' <<<"$EVENTS" | LC_ALL=C sort | paste -sd, -)" "$(jq -r '.hooks | keys | join(",")' <<<"$settings")"

block() { sed -n '/^# --- klepsydra dir/,/^# --- end klepsydra dir ---$/p' "$1"; }
check "dir block present" "$([[ -n "$(block "$hook")" ]] && echo yes)" "yes"
check "sourceable from a set -e script" \
  "$(KLEPSYDRA_DIR=/x/dev.ajsoftworks.klepsydra bash -ec 'source "$1"; echo "$KLEPSYDRA_DIR"' _ "$hook")" \
  "/x/dev.ajsoftworks.klepsydra"
check "dir block identical in the statusline" "$(block "$hook")" "$(block "$here/../statusline/klepsydra-statusline.sh")"
pblock() { sed -n '/^# --- proc stat/,/^# --- end proc stat ---$/p' "$1"; }
check "proc stat block present" "$([[ -n "$(pblock "$hook")" ]] && echo yes)" "yes"
check "proc stat block identical in the launcher" "$(pblock "$hook")" "$(pblock "$here/klepsydra-launch.sh")"
# shellcheck disable=SC2016 # a literal $PROC_ROOT, as the scripts spell it
check "the launcher parses /proc only in the block" \
  "$(sed '/^# --- proc stat/,/^# --- end proc stat ---$/d' "$here/klepsydra-launch.sh" | grep -cE 'read -r -a stat|<"?(/proc|\$PROC_ROOT)/')" "0"

# A hook must stay silent and exit 0 even when its environment is bare.
out=$(env -u USER -u HOME bash "$hook" </dev/null 2>&1); rc=$?
check "unset USER and HOME: exit 0" "$rc" "0"
check "unset USER and HOME: no output" "$out" ""

echo "tmux and host"
rm -f "$file"
fire session-start.json . "TMUX=$work/sock/klepsydra,4242,0" TMUX_PANE=%3 \
  WSL_DISTRO_NAME=Ubuntu KLEPSYDRA_BOOT_ID="$boot_file" >/dev/null
check "tmux recorded" "$(field .tmux)" "{\"socket\":\"$work/sock/klepsydra\",\"pane\":\"%3\"}"
check "host recorded" "$(field .host)" '{"boot":"0b6e1c5a-1111-4222-8333-444455556666","distro":"Ubuntu"}'
rm -f "$file"
fire session-start.json . TMUX= TMUX_PANE= WSL_DISTRO_NAME= KLEPSYDRA_BOOT_ID="$boot_file" >/dev/null
check "outside tmux: no tmux" "$(field .tmux)" "null"
check "no distro: null distro" "$(field .host.distro)" "null"
rm -f "$file"
fire session-start.json . 'TMUX=/tmp/x,1,0' 'TMUX_PANE=%3;rm -rf' KLEPSYDRA_BOOT_ID="$boot_file" >/dev/null
check "a malformed pane is not recorded" "$(field .tmux)" "null"
rm -f "$file"
fire session-start.json . 'TMUX=rel/sock,1,0' TMUX_PANE=%3 KLEPSYDRA_BOOT_ID="$boot_file" >/dev/null
check "a relative socket is not recorded" "$(field .tmux)" "null"
rm -f "$file"
fire session-start.json . KLEPSYDRA_BOOT_ID="$work/no-such-file" >/dev/null
check "no boot id: no host" "$(field .host)" "null"

echo "gone"
put() { # id state boot distro pid start
  jq -nc --arg id "$1" --arg st "$2" --arg b "$3" --arg d "$4" --argjson p "$5" --argjson s "$6" --argjson now "$now" \
    '{v:1, session_id:$id, state:$st, state_at:($now-100), written_at:($now-100),
      claude:{pid:$p, start:$s}, host:{boot:$b, distro:(if $d == "" then null else $d end)}}' \
    >"$dir/fleet/$1.json"
}
state_of() { jq -r '[.state, (.reason // "-")] | join("/")' "$dir/fleet/$1.json"; }
B=0b6e1c5a-1111-4222-8333-444455556666; OLD=99999999-1111-4222-8333-444455556666
A1=aaaaaaaa-0000-4000-8000-000000000001 # an earlier boot
A2=aaaaaaaa-0000-4000-8000-000000000002 # this boot and distro, pid dead
A3=aaaaaaaa-0000-4000-8000-000000000003 # this boot and distro, alive (pid 500)
A4=aaaaaaaa-0000-4000-8000-000000000004 # this boot, another distro, pid dead here
A5=aaaaaaaa-0000-4000-8000-000000000005 # this boot and distro, pid reused by a later process
A6=aaaaaaaa-0000-4000-8000-000000000006 # already ended, an earlier boot
A7=aaaaaaaa-0000-4000-8000-000000000007 # no distro, an earlier boot
A8=aaaaaaaa-0000-4000-8000-000000000008 # no distro, this boot, pid dead
A9=aaaaaaaa-0000-4000-8000-000000000009 # this boot and distro, claude unknown
A10=aaaaaaaa-0000-4000-8000-000000000010 # an earlier boot, claude unknown
A11=aaaaaaaa-0000-4000-8000-000000000011 # an earlier boot, idle over a day: left to the prune
put $A1 working $OLD Ubuntu 500 8717628
put $A2 'done' $B Ubuntu 4999 1
put $A3 working $B Ubuntu 500 8717628
put $A4 working $B Debian 4999 1
put $A5 working $B Ubuntu 500 1
put $A6 ended $OLD Ubuntu 500 8717628
put $A7 working $OLD "" 4999 1
put $A8 working $B "" 4999 1
put $A9 working $B Ubuntu 4999 1
put $A10 working $OLD Ubuntu 4999 1
put $A11 working $OLD Ubuntu 4999 1
jq -c --argjson t $((now - 2 * 86400)) '.state_at = $t | .written_at = $t' "$dir/fleet/$A11.json" >"$work/n" && mv "$work/n" "$dir/fleet/$A11.json"
jq -c '.needs = {by: "", tool: "Bash"}' "$dir/fleet/$A1.json" >"$work/n" && mv "$work/n" "$dir/fleet/$A1.json"
for n in $A9 $A10; do jq -c '.claude = null' "$dir/fleet/$n.json" >"$work/n" && mv "$work/n" "$dir/fleet/$n.json"; done
jq -c '.reason = "exited"' "$dir/fleet/$A6.json" >"$work/a6" && mv "$work/a6" "$dir/fleet/$A6.json"
rm -f "$file"
printf '%s\n' "$now" >"$stamp" # no prune in this section
fire session-start.json . WSL_DISTRO_NAME=Ubuntu >/dev/null
check "an earlier boot is gone" "$(state_of $A1)" "ended/gone"
check "same distro, pid dead: gone" "$(state_of $A2)" "ended/gone"
check "same distro, alive: unchanged" "$(state_of $A3)" "working/-"
check "another distro: unchanged" "$(state_of $A4)" "working/-"
check "same distro, pid reused: gone" "$(state_of $A5)" "ended/gone"
check "already ended: unchanged" "$(state_of $A6)" "ended/exited"
check "no distro, earlier boot: gone" "$(state_of $A7)" "ended/gone"
check "no distro, this boot: unchanged" "$(state_of $A8)" "working/-"
check "this boot, claude unknown: unchanged" "$(state_of $A9)" "working/-"
check "earlier boot, claude unknown: gone" "$(state_of $A10)" "ended/gone"
check "idle over a day: left to the prune" "$(state_of $A11)|$(jq -c .written_at "$dir/fleet/$A11.json")" "working/-|$((now - 2 * 86400))"
check "gone clears needs" "$(jq -c .needs "$dir/fleet/$A1.json")" "null"
check "gone stamps when" "$(jq -c '[.ended.at, .state_at]' "$dir/fleet/$A1.json")" "[$now,$now]"
rm -f "$dir"/fleet/aaaaaaaa-*.json
# The firing session's own file is never marked, even with a dead pid on record
# and no Claude process found above the hook.
put $S working $B Ubuntu 4999 1
fire session-start.json '.source = "compact"' WSL_DISTRO_NAME=Ubuntu >/dev/null
check "the firing session is not marked gone" "$(field '[.state, .claude.pid]')" '["working",4999]'

# A resumed session whose Claude process is not found loses its stale pid, so
# another session's start does not mark it gone.
put $S working $B Ubuntu 4999 1
jq -c '.tmux = {socket: "/tmp/old", pane: "%9"}' "$file" >"$work/n" && mv "$work/n" "$file"
fire session-start.json . KLEPSYDRA_PID=999 WSL_DISTRO_NAME=Ubuntu >/dev/null
check "resumed, no claude found: pid, pane cleared" "$(field '[.claude, .tmux, .host.boot]')" '[null,null,"0b6e1c5a-1111-4222-8333-444455556666"]'
fire session-start.json ".session_id = \"$A1\"" WSL_DISTRO_NAME=Ubuntu >/dev/null
check "resumed, no claude found: not marked gone" "$(field .state)" '"new"'
rm -f "$dir/fleet/$A1.json"

# Native Linux: no distro on either side, so the pid decides.
put $A1 working $B "" 4999 1
put $A2 working $B "" 500 8717628
put $A3 working $B Ubuntu 4999 1
rm -f "$file"
fire session-start.json . >/dev/null
check "no distro either side, pid dead: gone" "$(state_of $A1)" "ended/gone"
check "no distro either side, alive: unchanged" "$(state_of $A2)" "working/-"
check "a distro the host lacks: unchanged" "$(state_of $A3)" "working/-"
rm -f "$dir"/fleet/aaaaaaaa-*.json

# The listing reads every file with one jq, however many there are; only a
# session it marks costs another.
gd="$work/many/dev.ajsoftworks.klepsydra"
mkdir -p "$gd/fleet" "$work/jqshim"
# shellcheck disable=SC2016 # the shim expands these when it runs
printf '#!/usr/bin/env bash\nprintf x >>"$JQ_CALLS"\nexec %q "$@"\n' "$(command -v jq)" >"$work/jqshim/jq"
chmod +x "$work/jqshim/jq"
for i in $(seq 10 29); do
  jq -nc --arg id "aaaaaaaa-0000-4000-8000-0000000000$i" --arg b "$B" --argjson now "$now" \
    '{v:1, session_id:$id, state:"working", state_at:($now-100), written_at:($now-100),
      claude:{pid:500, start:8717628}, host:{boot:$b, distro:"Ubuntu"}}' >"$gd/fleet/aaaaaaaa-0000-4000-8000-0000000000$i.json"
done
for i in 30 31; do
  jq -nc --arg id "aaaaaaaa-0000-4000-8000-0000000000$i" --arg b "$OLD" --argjson now "$now" \
    '{v:1, session_id:$id, state:"working", state_at:($now-100), written_at:($now-100),
      claude:{pid:500, start:8717628}, host:{boot:$b, distro:"Ubuntu"}}' >"$gd/fleet/aaaaaaaa-0000-4000-8000-0000000000$i.json"
done
: >"$work/jq_calls"
( host_boot=$B host_distro=Ubuntu JQ_CALLS="$work/jq_calls" PATH="$work/jqshim:$PATH" mark_gone "$gd" "$now" "$S" )
check "mark_gone: one jq lists 22 files, one more per gone session" "$(wc -c <"$work/jq_calls")" "3"
check "mark_gone: the two of an earlier boot are gone, the 20 alive are not" \
  "$(cat "$gd"/fleet/*.json | jq -r .state | sort | uniq -c | awk '{printf "%s:%s ", $2, $1}')" "ended:2 working:20 "

# What mark_gone must leave alone. Each case holds a session of an earlier boot
# that would otherwise be marked gone.
old_session() { # file id: a v1 file on an earlier boot with a dead pid
  jq -nc --arg id "$2" --arg b "$OLD" --argjson now "$now" \
    '{v:1, session_id:$id, state:"working", state_at:($now-100), written_at:($now-100),
      claude:{pid:4999, start:1}, host:{boot:$b, distro:"Ubuntu"}}' >"$1"
}
untouched() { # name dir-with-fleet [fire args...]: fire a start, compare the fleet folder's files
  local name=$1 d=$2 before after; shift 2
  before=$(cd -- "$d/fleet" && for f in *; do [[ $f == "$S.json" ]] || printf '%s:%s\n' "$(stat -c %F "$f")" "$(md5sum <"$f")"; done)
  fire session-start.json . KLEPSYDRA_DIR="$d" WSL_DISTRO_NAME=Ubuntu "$@" >/dev/null
  after=$(cd -- "$d/fleet" && for f in *; do [[ $f == "$S.json" ]] || printf '%s:%s\n' "$(stat -c %F "$f")" "$(md5sum <"$f")"; done)
  check "$name" "$([[ -n $before && $before == "$after" ]] && echo untouched || printf 'changed\n%s\n--\n%s' "$before" "$after")" "untouched"
}
g1="$work/guard/dev.ajsoftworks.klepsydra"
mkdir -p "$g1/fleet" "$work/guard/target"
old_session "$work/guard/target/t.json" $A1
ln -s "$work/guard/target/t.json" "$g1/fleet/$A1.json"
untouched "a symlinked session file is left alone" "$g1"
check "the symlink's target is unchanged" "$(jq -r .state "$work/guard/target/t.json")" "working"

g2="$work/guard2/dev.ajsoftworks.klepsydra"
mkdir -p "$g2" "$work/guard2/real"
old_session "$work/guard2/real/$A1.json" $A1
ln -s "$work/guard2/real" "$g2/fleet"
before=$(md5sum <"$work/guard2/real/$A1.json")
fire session-start.json . KLEPSYDRA_DIR="$g2" WSL_DISTRO_NAME=Ubuntu >/dev/null
check "a symlinked fleet folder is left alone" "$(md5sum <"$work/guard2/real/$A1.json")" "$before"

g3="$work/guard3/not-the-overlay"
mkdir -p "$g3/fleet"
old_session "$g3/fleet/$A1.json" $A1
untouched "a data dir that is not the overlay's is left alone" "$g3"

g4="$work/guard4/dev.ajsoftworks.klepsydra"
mkdir -p "$g4/fleet"
old_session "$g4/fleet/$A1.json" $A1
: >"$work/empty_boot"
untouched "an empty boot id marks nothing" "$g4" KLEPSYDRA_BOOT_ID="$work/empty_boot"
untouched "a missing boot id marks nothing" "$g4" KLEPSYDRA_BOOT_ID="$work/no-such-file"
printf 'not-a-boot-id\n' >"$work/bad_boot"
untouched "a malformed boot id marks nothing" "$g4" KLEPSYDRA_BOOT_ID="$work/bad_boot"

g5="$work/guard5/dev.ajsoftworks.klepsydra"
mkdir -p "$g5/fleet"
printf 'not json\n' >"$g5/fleet/$A1.json"
old_session "$g5/fleet/${A1%1}2.json" ${A1%1}2
jq -c '.v = 2' "$g5/fleet/${A1%1}2.json" >"$work/n" && mv "$work/n" "$g5/fleet/${A1%1}2.json"
old_session "$g5/fleet/notes.json" notes
untouched "malformed, non-v1 and non-uuid files are left alone" "$g5"
check "all three kept their bytes" "$(cat "$g5/fleet/$A1.json"; jq -c .v "$g5/fleet/${A1%1}2.json"; jq -r .state "$g5/fleet/notes.json")" $'not json\n2\nworking'

echo "window colours"

printf '{"holders":{"500:8717628":{"voice":"am_michael","seen":1},"700:9000000":{"voice":"af_heart(0.5)+af_bella(0.5)","seen":1}}}\n' >"$work/win-voices.json"
cast_src="$here/../src/fleet/cast.json"
fsock=$work/sock/klepsydra
C1=aaaaaaaa-2222-4333-8444-555555555551
C2=aaaaaaaa-2222-4333-8444-555555555552
C3=aaaaaaaa-2222-4333-8444-555555555553
C4=aaaaaaaa-2222-4333-8444-555555555554
cfire() { # fixture session [VAR=value...]; a pane on the fleet socket unless TMUX is overridden
  local fx=$1 id=$2
  shift 2
  : >"$tlog"
  fire "$fx" ".session_id = \"$id\"" KLEPSYDRA_CAST="$cast_src" KERYX_VOICES="$work/win-voices.json" TMUX="$fsock,1,0" TMUX_PANE=%3 "$@"
}

cfire session-start.json $C1
check "a kourai voice sets both options" "$(cat "$tlog")" \
  "-S $fsock set-option -w -t %3 window-status-style fg=#DA8C20
-S $fsock set-option -w -t %3 window-status-current-style bg=#DA8C20,fg=#000000,bold"

cfire user-prompt.json $C1
check "an unchanged voice on a later event: no tmux call" "$(cat "$tlog")" ""

cfire session-start.json $C2 TMUX=/tmp/tmux-1000/default,1,0
check "a foreign socket: no tmux call" "$(cat "$tlog")" ""

cfire session-start.json $C3 KLEPSYDRA_PID=710
check "a blend unsets both options" "$(cat "$tlog")" \
  "-S $fsock set-option -w -u -t %3 window-status-style
-S $fsock set-option -w -u -t %3 window-status-current-style"

# The voice recorded in the file changes mid-session: the window follows.
cfire user-prompt.json $C1 KLEPSYDRA_PID=710
check "a changed voice recolours" "$(cat "$tlog")" \
  "-S $fsock set-option -w -u -t %3 window-status-style
-S $fsock set-option -w -u -t %3 window-status-current-style"

for bad in "#DA8C20; run-shell x" $'#DA8C20\n' "red" "#DA8C2" 5; do
  jq --arg a "$bad" '.characters.am_michael.accent = $a' "$cast_src" >"$work/bad-cast.json"
  cfire session-start.json $C4 KLEPSYDRA_CAST="$work/bad-cast.json"
  check "a bad accent ($(printf %q "$bad")): no tmux call" "$(cat "$tlog")" ""
done
cfire session-start.json $C4 KLEPSYDRA_CAST="$work/no-such-cast.json"
check "no cast: no tmux call" "$(cat "$tlog")" ""

# A tmux that fails changes nothing the hook says or does.
echo fail >"$work/tmux.mode"
out=$(cfire session-start.json $C4); rc=$?
check "a failing tmux: exit 0" "$rc" "0"
check "a failing tmux: prints nothing" "$out" ""
check "a failing tmux: the session file is written" "$(jq -r .session_id "$dir/fleet/$C4.json")" "$C4"

# A tmux that hangs holds neither the hook for long nor the fleet lock: another
# session's start still writes its file while the first is stuck in tmux.
echo hang >"$work/tmux.mode"
C5=aaaaaaaa-2222-4333-8444-555555555555
C6=aaaaaaaa-2222-4333-8444-555555555556
( cfire session-start.json $C5 >/dev/null ) &
hung=$!
until [[ -s $tlog ]]; do read -r -t 0.05 <> <(:) || true; done # the first hook is inside tmux
t0=$SECONDS
fire session-start.json ".session_id = \"$C6\"" >/dev/null
check "a hung tmux does not hold the lock: another session is written at once" \
  "$(jq -r .session_id "$dir/fleet/$C6.json" 2>/dev/null) $(( SECONDS - t0 < 2 ))" "$C6 1"
wait "$hung"; rc=$?
check "a hung tmux: the hook still exits 0" "$rc" "0"
check "a hung tmux: its own file is written" "$(jq -r .session_id "$dir/fleet/$C5.json")" "$C5"
rm -f "$work/tmux.mode"

# The hook's ink is contrast.js's, for every character and for two colours
# either side of the black/white switch (relative luminance about 0.179).
jq '.characters += {zz_dark: {name: "Dark", face: "x", accent: "#747474", gender: "f"},
                    zz_light: {name: "Light", face: "x", accent: "#777777", gender: "f"}}' "$cast_src" >"$work/parity-cast.json"
# shellcheck disable=SC2016 # the script is for node, not the shell
want=$(node --input-type=module -e '
import { inkOn } from "./src/fleet/contrast.js";
import { readFileSync } from "node:fs";
const cast = JSON.parse(readFileSync(process.argv[1], "utf8"));
for (const [v, c] of Object.entries(cast.characters)) console.log(`${v} ${c.accent} ${inkOn(c.accent)}`);' "$work/parity-cast.json" 2>/dev/null || true)
got=""
while read -r v acc ink; do
  : >"$tlog"
  printf '{"holders":{"500:8717628":{"voice":"%s","seen":1}}}\n' "$v" >"$work/ink-voices.json"
  fire session-start.json ".session_id = \"$C4\"" KLEPSYDRA_CAST="$work/parity-cast.json" TMUX="$fsock,1,0" TMUX_PANE=%3 KERYX_VOICES="$work/ink-voices.json" >/dev/null
  got+="$v $acc $(sed -n 's/.*current-style bg=#[0-9A-Fa-f]*,fg=\(#[0-9a-f]*\),bold/\1/p' "$tlog")"$'\n'
done <<<"$want"
check "the hook's ink matches contrast.js for all seventeen" "$got" "$want"$'\n'
check "all seventeen were compared" "$(wc -l <<<"$want")" "17"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]

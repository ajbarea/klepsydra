#!/usr/bin/env bash
# Claude Code hook for the klepsydra fleet strip. Keeps one JSON file per
# session in <KLEPSYDRA_DIR>/fleet: its state, where it works, and what it was
# last asked and last said. Registered with "async": true on the events listed
# in README.md, so Claude Code never waits for it. It prints nothing and always
# exits 0.

set -uo pipefail

# --- klepsydra dir: identical in hooks/klepsydra-fleet.sh and statusline/klepsydra-statusline.sh ---
# The overlay's app-local-data dir, named for the bundle identifier in
# src-tauri/tauri.conf.json. Not the install dir: the uninstaller's "delete app
# data" reaches only this one, and a per-machine install cannot be written to.
# Under WSL the overlay is a Windows app, so the hook writes across to it. On
# Linux, Tauri honours XDG_DATA_HOME only when it is absolute, and so must we,
# or the readings land under whatever directory Claude Code is running in.
if [[ -z "${KLEPSYDRA_DIR:-}" ]]; then
  osrelease=""
  { read -r osrelease </proc/sys/kernel/osrelease; } 2>/dev/null  # builtin: no process per run
  if [[ "$osrelease" == *[Mm]icrosoft* ]]; then
    if [[ -n "${USER:-}" ]]; then
      KLEPSYDRA_DIR="/mnt/c/Users/$USER/AppData/Local/dev.ajsoftworks.klepsydra"
    fi
  else
    data_home="${HOME:-}/.local/share"
    [[ "${XDG_DATA_HOME:-}" == /* ]] && data_home="$XDG_DATA_HOME"
    [[ "$data_home" == /* ]] && KLEPSYDRA_DIR="$data_home/dev.ajsoftworks.klepsydra"
  fi
fi
# --- end klepsydra dir ---

UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
PROC_ROOT=${KLEPSYDRA_PROC:-/proc} # tests point these at a fake /proc and voices.json
VOICES=${KERYX_VOICES:-}
if [[ -z $VOICES ]]; then
  if [[ -n ${XDG_CACHE_HOME:-} ]]; then VOICES=$XDG_CACHE_HOME/keryx/voices.json
  elif [[ -n ${HOME:-} ]]; then VOICES=$HOME/.cache/keryx/voices.json; fi
fi
# Every session's hooks run as separate processes, so writes take one lock.
LOCK=${XDG_RUNTIME_DIR:-/tmp}/klepsydra-fleet-$UID.lock
PROMPT_CHARS=300
# The events README.md registers this hook on; any other is ignored.
EVENTS="SessionStart UserPromptSubmit PermissionRequest PreToolUse Notification PostToolUse Stop StopFailure SessionEnd"

# Sets where_repo, where_worktree and where_branch for `path` (empty when
# none), reading .git directly as keryx's source_name does, so no git process
# runs. A worktree is named by its main checkout, a submodule by its own folder,
# and a path outside any repo by its own name.
git_where() { # path
  local here=${1%/} folder dotgit link gitdir common main
  where_repo="" where_worktree="" where_branch=""
  [[ -n $here ]] || here=/
  if [[ $here != /* ]]; then where_repo=${here##*/}; return; fi
  folder=$here
  while :; do
    dotgit=$folder/.git
    if [[ -d $dotgit ]]; then
      where_repo=${folder##*/}
      branch_of "$dotgit"
      return
    elif [[ -f $dotgit ]]; then
      link=""
      { IFS= read -r link <"$dotgit"; } 2>/dev/null
      where_repo=${folder##*/}
      [[ $link == gitdir:* ]] || return
      gitdir=${link#gitdir:}
      gitdir=${gitdir#"${gitdir%%[![:space:]]*}"}
      [[ $gitdir == /* ]] || gitdir=$folder/$gitdir
      if [[ -f $gitdir/commondir ]]; then
        common=""
        { IFS= read -r common <"$gitdir/commondir"; } 2>/dev/null
        [[ $common == /* ]] || common=$gitdir/$common
        if main=$(cd "$common" 2>/dev/null && pwd -P); then
          main=${main%/*}
          where_repo=${main##*/}
          where_worktree=${folder##*/}
        fi
      fi
      branch_of "$gitdir"
      return
    fi
    [[ $folder == / ]] && break
    folder=${folder%/*}
    [[ -n $folder ]] || folder=/
  done
  where_repo=${here##*/}
}

# Sets where_branch from a git dir's HEAD: the branch, else a detached commit's
# first 7 characters.
branch_of() { # gitdir
  local head=""
  { IFS= read -r head <"$1/HEAD"; } 2>/dev/null
  case $head in
    "ref: refs/heads/"*) where_branch=${head#ref: refs/heads/} ;;
    "ref: "*) where_branch=${head#ref: } ;;
    *) where_branch=${head:0:7} ;;
  esac
}

# Fields of /proc/<pid>/stat after the command name, into `stat`: [0] is the
# state, [1] the parent pid, [19] the start time. The name sits in parentheses
# and may itself contain spaces or ")".
proc_stat() { # pid
  local raw=""
  { IFS= read -r raw <"$PROC_ROOT/$1/stat"; } 2>/dev/null
  [[ $raw == *") "* ]] || return 1
  read -r -a stat <<<"${raw##*") "}"
  (( ${#stat[@]} > 19 ))
}

# Whether `pid` is Claude Code: by name, or an npm install's
# `node .../@anthropic-ai/claude-code/cli.js`, as keryx decides.
is_claude() { # pid
  local comm="" arg part
  local -a argv=() parts=()
  { IFS= read -r comm <"$PROC_ROOT/$1/comm"; } 2>/dev/null
  [[ $comm == claude || $comm == claude-code ]] && return 0
  { mapfile -d '' -t -n 2 argv <"$PROC_ROOT/$1/cmdline"; } 2>/dev/null || return 1
  for arg in "${argv[@]}"; do
    IFS=/ read -r -a parts <<<"$arg"
    for part in "${parts[@]}"; do
      [[ $part == claude || $part == claude-code ]] && return 0
    done
  done
  return 1
}

# Sets found_pid and found_start to the nearest Claude Code process at or
# above `pid`: keryx's key for a terminal (pid:starttime in voices.json).
claude_ancestor() { # pid
  local pid=$1 i
  local -a stat=()
  found_pid="" found_start=""
  for ((i = 0; i < 32; i++)); do
    proc_stat "$pid" || return 1
    if is_claude "$pid"; then
      found_pid=$pid found_start=${stat[19]}
      return 0
    fi
    pid=${stat[1]}
    (( pid >= 1 )) || return 1
  done
  return 1
}

# The voice keryx holds for a terminal, or nothing without keryx or a hold.
holder_voice() { # pid start
  [[ -n $VOICES && -r $VOICES ]] || return 0
  jq -r --arg h "$1:$2" '.holders[$h].voice // empty | strings' "$VOICES" 2>/dev/null
}

# Whether the Claude Code process recorded as `pid start` still runs. A zombie
# has exited, and a pid with another start time or another program is someone
# else's.
claude_alive() { # pid start
  local -a stat=()
  [[ $1 =~ ^[0-9]+$ && $2 =~ ^[0-9]+$ ]] || return 1
  proc_stat "$1" || return 1
  [[ ${stat[0]} != Z && ${stat[19]} == "$2" ]] && is_claude "$1"
}

# Delete the files of sessions whose Claude Code process is gone and whose
# last activity is more than a day old, heartbeats a day old with no session
# file, and write litter a day old. Only <uuid>.json, <uuid>.beat and
# <uuid>.{json,beat}.<digits>.tmp directly inside <dir>/fleet, never a
# symlink, and only when `dir` is the overlay's own absolute data dir. Runs
# under the fleet lock in a few processes however many files there are.
PRUNE_AFTER=86400
PRUNE_EVERY=3600
PRUNE_STAMP=${LOCK%.lock}.pruned
prune_fleet() { # dir now
  local dir=$1 now=$2
  while [[ $dir == */ ]]; do dir=${dir%/}; done
  [[ -n $dir ]] || return 1
  [[ $dir == /* ]] || return 1
  [[ $dir == */../* || $dir == */.. ]] && return 1
  [[ ${dir##*/} == dev.ajsoftworks.klepsydra ]] || return 1
  [[ $now =~ ^[0-9]+$ ]] || return 1
  [[ -L $dir ]] && return 1
  [[ -L $dir/fleet ]] && return 1
  [[ -d $dir/fleet ]] || return 0
  # From inside the folder every name is short, which matters on /mnt/c.
  ( cd -- "$dir/fleet" 2>/dev/null && prune_here "$now" )
}

# prune_fleet's work, in the fleet folder. Types and mtimes of every candidate
# come from one stat (which does not follow links); the session files are read
# here and parsed by one jq.
prune_here() { # now
  local now=$1 f name id pid start last line
  local -A type=() mt=()
  local -a sessions=()
  while IFS= read -r line; do
    [[ $line =~ ^([^|]+)\|([0-9]+)\|(.+)$ ]] || continue
    type[${BASH_REMATCH[3]}]=${BASH_REMATCH[1]}
    mt[${BASH_REMATCH[3]}]=${BASH_REMATCH[2]}
  done < <(stat -c '%F|%Y|%n' -- *.json *.beat *.tmp 2>/dev/null)
  plain() { [[ ${type[$1]:-} == "regular file" ]]; } # name
  old() { plain "$1" && (( now - mt[$1] > PRUNE_AFTER )); } # name

  for name in *.json; do
    [[ ${name%.json} =~ $UUID_RE ]] && plain "$name" && sessions+=("$name")
  done
  if (( ${#sessions[@]} )); then
    # A file without a final newline cannot run into the next one this way; a
    # line that does not parse as a v1 object yields nothing.
    while IFS=$'\t' read -r f pid start last; do
      id=${f%.json}
      [[ $last =~ ^[1-9][0-9]*$ ]] || continue
      (( now - last > PRUNE_AFTER )) || continue
      if [[ -n ${type[$id.beat]:-} ]]; then
        old "$id.beat" || continue
      fi
      claude_alive "$pid" "$start" && continue
      rm -f -- "$f"
      [[ ${type[$id.beat]:-} == "symbolic link" ]] || rm -f -- "$id.beat"
    done < <(
      for f in "${sessions[@]}"; do
        line=""
        { IFS= read -r line <"$f"; } 2>/dev/null
        printf '%s\t%s\n' "$f" "$line"
      done | jq -Rr '(index("\t")) as $i | .[:$i] as $f
        | (try (.[$i + 1:] | fromjson) catch empty) | select(type == "object" and .v == 1)
        | try [$f, (.claude.pid // 0), (.claude.start // 0),
            ([.started_at, .state_at, .where.at, .prompt.at, .reply.at, .ended.at, .written_at]
              | map(numbers) | max // 0)]
          catch empty
        | map(if type == "number" then floor | tostring else . end) | join("\t")' 2>/dev/null)
  fi

  for name in *.beat; do
    id=${name%.beat}
    [[ $id =~ $UUID_RE && -z ${type[$id.json]:-} ]] || continue
    old "$name" && rm -f -- "$name"
  done
  for name in *.tmp; do
    [[ $name =~ ^(.{36})\.(json|beat)\.[0-9]+\.tmp$ ]] || continue
    [[ ${BASH_REMATCH[1]} =~ $UUID_RE ]] || continue
    old "$name" && rm -f -- "$name"
  done
  return 0
}

# prune_fleet at most once an hour, stamped next to the lock (the stamp holds
# the time of the last run).
prune_hourly() { # dir now
  local last=""
  { IFS= read -r last <"$PRUNE_STAMP"; } 2>/dev/null
  [[ $last =~ ^[0-9]+$ ]] && (( $2 - last < PRUNE_EVERY && $2 >= last )) && return 0
  prune_fleet "$1" "$2" && { printf '%s\n' "$2" >"$PRUNE_STAMP"; } 2>/dev/null
  return 0
}

# The session file after one event, as compact JSON, or nothing when no field
# changed. `$old` is the current file's text (empty for none).
read -r -d '' APPLY <<'JQ' || true  # read returns 1 at the end of input
def clip: if type == "string" and length > 0 then .[0:$chars] else null end;
def text: if type == "string" and length > 0 then . else null end;
def need_reason($tool): if $tool == "AskUserQuestion" then "question"
  elif $tool == "ExitPlanMode" then "approve plan" else "approve \($tool // "a tool")" end;
def ended_as: {clear: "cleared", resume: "resumed elsewhere", logout: "logged out",
               prompt_input_exit: "exited", other: "stopped"}[.] // gsub("_"; " ");

. as $ev
| $ev.hook_event_name as $event
| ($ev.agent_id // "") as $agent
| ($old | try fromjson catch null
   | if type == "object" and .v == 1 and .session_id == $ev.session_id then . else null end) as $was
| if $was == null and $event == "SessionEnd" then empty
  elif $was.state == "ended" and $event != "SessionStart" then empty
  else
  ($was // {v: 1, session_id: $ev.session_id, name: null, started_at: $now,
            launch_dir: ($ev.cwd | text), claude: null, voice: null,
            state: (if $event == "PreToolUse" or $event == "PostToolUse" then "working" else "new" end),
            reason: null, needs: null, state_at: $now,
            where: null, touched: [], prompt: null, reply: null, error: null,
            ended: null, written_at: $now}) as $s
  | $s
  | .name = (($ev.session_title | text) // .name)
  | (if $pid != "" then {pid: ($pid | tonumber), start: ($start | tonumber)} else null end) as $me
  | .claude = (if $me != null and $event == "SessionStart" and $ev.source != "compact" then $me else (.claude // $me) end)
  | .voice = (($voice | text) // .voice)

  # Where: the last edit's repo, or the cwd's until something is edited.
  | (if $repo != "" and ($by == "edit" or .where == null or .where.by == "cwd")
     then {repo: $repo, worktree: ($worktree | text), branch: ($branch | text)}
     else null end) as $w
  | if $w == null then .
    elif .where != null and (.where | {repo, worktree, branch}) == $w then .where.by = (if $by == "edit" then "edit" else .where.by end)
    else
      (if .where != null and .where.repo != $w.repo
       then .touched = ([{repo: .where.repo, at: $now}]
                        + (.touched | map(select(.repo != $s.where.repo and .repo != $w.repo))))[0:6]
       else . end)
      | .where = $w + {by: $by, at: $now}
    end

  # State, with what it needs from AJ and who asked.
  | (if $event == "SessionStart" then
       if $was == null then {state: "new", reason: null}
       elif $ev.source == "compact" then {state: .state, reason: .reason}
       else {state: (if .prompt then "done" else "new" end), reason: null} end
     elif $event == "UserPromptSubmit" then {state: "working", reason: null}
     elif $event == "PermissionRequest" then
       {state: "needs_you", reason: need_reason($ev.tool_name), needs: {by: $agent, tool: $ev.tool_name}}
     elif $event == "PreToolUse" and ($ev.tool_name | IN("AskUserQuestion", "ExitPlanMode")) then
       {state: "needs_you", reason: need_reason($ev.tool_name), needs: {by: $agent, tool: $ev.tool_name}}
     elif $event == "Notification" and $ev.notification_type == "elicitation_dialog" then
       {state: "needs_you", reason: "question", needs: {by: $agent, tool: null}}
     elif $event == "PostToolUse" and .state == "needs_you" and (.needs.by // "") == $agent
          and (.needs.tool == null or .needs.tool == $ev.tool_name) then
       {state: "working", reason: null}
     elif $event == "Notification" and $ev.notification_type == "idle_prompt"
          and (.state == "working" or .state == "needs_you") and $now - .state_at >= 30 then
       {state: "done", reason: null}
     elif $event == "Stop" then {state: "done", reason: null}
     elif $event == "StopFailure" then {state: "error", reason: (($ev.error // "unknown") | gsub("_"; " "))}
     elif $event == "SessionEnd" then {state: "ended", reason: (($ev.reason // "other") | ended_as)}
     else {state: .state, reason: .reason} end) as $t
  | (if $t.state != .state or $t.reason != .reason or $event == "UserPromptSubmit" then .state_at = $now else . end)
  | .needs = (if $t.state != "needs_you" then null else ($t.needs // .needs) end)
  | .state = $t.state
  | .reason = $t.reason

  # What AJ asked and what came back. A background subagent's report arrives
  # as a prompt starting <task-notification>; it is not AJ's.
  | if $event == "UserPromptSubmit" then
      .error = null
      | if ($ev.prompt // "" | test("^\\s*<task-notification>")) then .
        else .prompt = (($ev.prompt | clip) as $p | if $p then {text: $p, at: $now} else .prompt end) end
    elif $event == "Stop" then
      (($ev.last_assistant_message | clip) as $r | if $r then .reply = {text: $r, at: $now} else . end)
    elif $event == "StopFailure" then
      .error = ([$ev.last_assistant_message, $ev.error_details, $ev.error] | map(clip | select(. != null)) | .[0])
    elif $event == "SessionEnd" then .ended = {reason: ($ev.reason // "other"), at: $now}
    elif $event == "SessionStart" and $ev.source != "compact" then .ended = null | .error = null
    else . end

  # An event that changes nothing still refreshes written_at, once a minute.
  | if $was != null and (del(.written_at) == ($was | del(.written_at))) and $now - $was.written_at < 60 then empty
    else .written_at = $now end
  end
JQ

# Replace the file with `text` through a temp file in the same directory, so a
# reader never sees half of it.
write_atomic() { # file text
  local tmp="$1.$$.tmp"
  if printf '%s\n' "$2" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$1" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

main() {
  local input fields session event cwd edited now file old new lock voice="" by=cwd
  input=$(cat)
  fields=$(printf '%s' "$input" | jq -r '
    def s: if type == "string" then gsub("[\u001f\n]"; " ") else "" end;
    [ (.session_id | s), (.hook_event_name | s), (.cwd | s),
      (if .hook_event_name == "PostToolUse" and (.tool_name | IN("Edit", "Write", "NotebookEdit"))
       then ((.tool_input.file_path // .tool_input.notebook_path) | s) else "" end)
    ] | join("\u001f")' 2>/dev/null) || return 0
  IFS=$'\x1f' read -r session event cwd edited <<<"$fields"
  [[ $session =~ $UUID_RE && " $EVENTS " == *" $event "* ]] || return 0

  now=${KLEPSYDRA_NOW:-}
  [[ $now =~ ^[0-9]+$ ]] || printf -v now '%(%s)T' -1
  if [[ -n $edited ]]; then
    by=edit
    git_where "${edited%/*}"
  else
    git_where "$cwd"
  fi
  if claude_ancestor "${KLEPSYDRA_PID:-$$}"; then
    voice=$(holder_voice "$found_pid" "$found_start") || voice=""
  fi

  [[ -n ${KLEPSYDRA_DIR:-} ]] || return 0
  local fleet=$KLEPSYDRA_DIR/fleet
  mkdir -p "$fleet" 2>/dev/null || return 0
  { exec {lock}>>"$LOCK"; } 2>/dev/null || return 0
  flock -w 5 "$lock" || return 0

  file=$fleet/$session.json
  old=""
  [[ -f $file ]] && { old=$(<"$file"); } 2>/dev/null
  new=$(printf '%s' "$input" | jq -c --arg old "$old" --argjson now "$now" --argjson chars "$PROMPT_CHARS" \
    --arg repo "$where_repo" --arg worktree "$where_worktree" --arg branch "$where_branch" \
    --arg by "$by" \
    --arg voice "$voice" --arg pid "$found_pid" --arg start "$found_start" \
    "$APPLY" 2>/dev/null) || new=""
  [[ -n $new ]] && write_atomic "$file" "$new"
  [[ $event == SessionStart ]] && prune_hourly "$KLEPSYDRA_DIR" "$now"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  (main) >/dev/null 2>&1 # a subshell, so no failure inside can end this shell non-zero
  exit 0
fi

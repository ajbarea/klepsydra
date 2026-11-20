#!/usr/bin/env bash
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
fleet=${KLEPSYDRA_FLEET_HOOK:-"$here/klepsydra-fleet.sh"}

fail() { printf 'klepsydra: %s\n' "$1" >&2; exit 0; }

engine=${1:-}
source_event=${2:-}
case "$engine:$source_event" in
  agy:SessionStart) target_event=SessionStart ;;
  agy:PreInvocation) target_event=UserPromptSubmit ;;
  agy:PreToolUse) target_event=PreToolUse ;;
  agy:PostToolUse) target_event=PostToolUse ;;
  agy:Stop) target_event=Stop ;;
  copilot:sessionStart) target_event=SessionStart ;;
  copilot:userPromptSubmitted) target_event=UserPromptSubmit ;;
  copilot:preToolUse) target_event=PreToolUse ;;
  copilot:postToolUse) target_event=PostToolUse ;;
  copilot:agentStop) target_event=Stop ;;
  copilot:sessionEnd) target_event=SessionEnd ;;
  *) fail "unknown engine event" ;;
esac

command -v jq >/dev/null 2>&1 || fail "jq is not installed"
[[ -f "$fleet" ]] || fail "fleet hook is missing"

input=$(cat)

last_msg=""
if [[ "$engine" == "agy" && ( "$target_event" == "Stop" || "$target_event" == "PostToolUse" ) ]]; then
  t_path=$(printf '%s' "$input" | jq -r '. as $root | ($root.lastAssistantMessage // $root.last_assistant_message // $root.response // "") | if type == "string" and . != "" then "" else (($root.transcriptPath // $root.transcript_path // "") | if type == "string" then . else "" end) end' 2>/dev/null || true)
  if [[ -n "$t_path" ]]; then
    target_t="$t_path"
    [[ -f "${t_path%/*}/transcript_full.jsonl" ]] && target_t="${t_path%/*}/transcript_full.jsonl"
    if [[ -f "$target_t" ]]; then
      # The transcript grows all session: its last MiB, newest line first, up to the
      # first reply or the turn boundary. The echo keeps a line still being written apart
      # from the one before.
      last_msg=$({ tail -c 1048576 -- "$target_t"; echo; } 2>/dev/null | tac | jq -nrR 'label $done | first(foreach (inputs | fromjson? | objects) as $x (null; if $x.type == "USER_INPUT" then break $done elif $x.type == "PLANNER_RESPONSE" and ($x.content | type == "string") and ($x.content != "") then $x.content else null end; select(. != null))) // empty' 2>/dev/null || true)
    fi
  fi
fi

printf '%s' "$input" | jq -c \
  --arg engine "$engine" \
  --arg event "$target_event" \
  --arg last_msg "$last_msg" '
  def text: if type == "string" then . else "" end;
  {
    session_id: ((.conversationId // .sessionId // .session_id) | text),
    hook_event_name: $event,
    cwd: ((.cwd // .workingDirectory // (.workspacePaths[0])) | text),
    transcript_path: ((.transcriptPath // .transcript_path) | text),
    prompt: ((.lastUserInput // .prompt) | text),
    last_assistant_message:
      (if $last_msg != "" then $last_msg else ((.lastAssistantMessage // .last_assistant_message // .response) | text) end),
    tool_name: (
      ((.toolName // .tool_name // .toolCall.name) | text) as $raw
      | if $engine == "agy" then
          if $raw == "run_command" then "Bash"
          elif $raw == "edit_file" then "Edit"
          elif $raw == "write_file" then "Write"
          elif $raw == "read_file" then "View"
          elif $raw == "invoke_subagent" then "Agent"
          elif $raw == "ask_question" then "AskUserQuestion"
          elif $raw == "manage_task" and ((.toolInput // .tool_input // .toolCall.args // {}).Action == "kill") then "TaskStop"
          else $raw end
        else $raw end
    ),
    tool_input: (
      ((.toolInput // .tool_input // .toolCall.args // {}) | if type == "object" then . else {} end) as $in
      | if $engine == "agy" then
          $in
          | if .CommandLine != null and .command == null then .command = .CommandLine else . end
          | if .Path != null and .file_path == null then .file_path = .Path else . end
          | if .Prompt != null and .prompt == null then .prompt = .Prompt else . end
          | if .TypeName != null and .subagent_type == null then .subagent_type = .TypeName else . end
          | if .TaskId != null and .task_id == null then .task_id = .TaskId else . end
        else $in end
    ),
    tool_response: (.toolResponse // .tool_response // null),
    agent_id: ((.agentId // .agent_id) | text),
    engine: $engine,
    source: ((.source // .reason) | text),
    session_title: ((.sessionTitle // .session_title // .title) | text)
  }
  | if .hook_event_name == "UserPromptSubmit" and .prompt == ""
    then del(.prompt)
    else .
    end
  | if .hook_event_name == "SessionEnd" and .source == ""
    then del(.source)
    else .
    end
  | if .session_title == ""
    then del(.session_title)
    else .
    end
' | exec bash "$fleet"

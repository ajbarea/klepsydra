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

jq -c \
  --arg engine "$engine" \
  --arg event "$target_event" '
  def text: if type == "string" then . else "" end;
  {
    session_id: ((.conversationId // .sessionId // .session_id) | text),
    hook_event_name: $event,
    cwd: ((.cwd // .workingDirectory // (.workspacePaths[0])) | text),
    transcript_path: ((.transcriptPath // .transcript_path) | text),
    prompt: ((.lastUserInput // .prompt) | text),
    last_assistant_message:
      ((.lastAssistantMessage // .last_assistant_message // .response) | text),
    tool_name: ((.toolName // .tool_name // .toolCall.name) | text),
    tool_input: (.toolInput // .tool_input // .toolCall.args // {}),
    tool_response: (.toolResponse // .tool_response // null),
    agent_id: ((.agentId // .agent_id) | text),
    engine: $engine,
    source: ((.source // .reason) | text)
  }
  | if .hook_event_name == "UserPromptSubmit" and .prompt == ""
    then del(.prompt)
    else .
    end
  | if .hook_event_name == "SessionEnd" and .source == ""
    then del(.source)
    else .
    end
' | exec bash "$fleet"

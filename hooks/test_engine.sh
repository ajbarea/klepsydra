#!/usr/bin/env bash
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat >"$work/fleet.sh" <<'EOF'
#!/usr/bin/env bash
jq -c .
EOF
chmod +x "$work/fleet.sh"

run() {
  printf '%s\n' "$2" |
    KLEPSYDRA_FLEET_HOOK="$work/fleet.sh" \
    bash "$here/klepsydra-engine.sh" "$1" "$3"
}

check() {
  [[ "$1" == "$2" ]] || {
    printf 'FAIL\nwant: %s\ngot:  %s\n' "$2" "$1"
    exit 1
  }
}

check "$(run agy '{"conversationId":"11111111-2222-4333-8444-555555555555","workspacePaths":["/repo"],"lastUserInput":"hello"}' PreInvocation)" \
  '{"session_id":"11111111-2222-4333-8444-555555555555","hook_event_name":"UserPromptSubmit","cwd":"/repo","transcript_path":"","prompt":"hello","last_assistant_message":"","tool_name":"","tool_input":{},"tool_response":null,"agent_id":"","engine":"agy","source":""}'

# AGY tool mapping & input normalization
check "$(run agy '{"conversationId":"11111111-2222-4333-8444-555555555555","toolCall":{"name":"run_command","args":{"CommandLine":"make test"}}}' PreToolUse)" \
  '{"session_id":"11111111-2222-4333-8444-555555555555","hook_event_name":"PreToolUse","cwd":"","transcript_path":"","prompt":"","last_assistant_message":"","tool_name":"Bash","tool_input":{"CommandLine":"make test","command":"make test"},"tool_response":null,"agent_id":"","engine":"agy","source":""}'

check "$(run agy '{"conversationId":"11111111-2222-4333-8444-555555555555","toolCall":{"name":"edit_file","args":{"Path":"/repo/file.txt"}}}' PostToolUse)" \
  '{"session_id":"11111111-2222-4333-8444-555555555555","hook_event_name":"PostToolUse","cwd":"","transcript_path":"","prompt":"","last_assistant_message":"","tool_name":"Edit","tool_input":{"Path":"/repo/file.txt","file_path":"/repo/file.txt"},"tool_response":null,"agent_id":"","engine":"agy","source":""}'

check "$(run agy '{"conversationId":"11111111-2222-4333-8444-555555555555","toolCall":{"name":"write_file","args":{"Path":"/repo/file.txt"}}}' PostToolUse)" \
  '{"session_id":"11111111-2222-4333-8444-555555555555","hook_event_name":"PostToolUse","cwd":"","transcript_path":"","prompt":"","last_assistant_message":"","tool_name":"Write","tool_input":{"Path":"/repo/file.txt","file_path":"/repo/file.txt"},"tool_response":null,"agent_id":"","engine":"agy","source":""}'

check "$(run agy '{"conversationId":"11111111-2222-4333-8444-555555555555","toolCall":{"name":"invoke_subagent","args":{"Prompt":"do task","TypeName":"general"}}}' PreToolUse)" \
  '{"session_id":"11111111-2222-4333-8444-555555555555","hook_event_name":"PreToolUse","cwd":"","transcript_path":"","prompt":"","last_assistant_message":"","tool_name":"Agent","tool_input":{"Prompt":"do task","TypeName":"general","prompt":"do task","subagent_type":"general"},"tool_response":null,"agent_id":"","engine":"agy","source":""}'

check "$(run agy '{"conversationId":"11111111-2222-4333-8444-555555555555","toolCall":{"name":"ask_question","args":{"questions":[{"question":"choice?"}]}}}' PreToolUse)" \
  '{"session_id":"11111111-2222-4333-8444-555555555555","hook_event_name":"PreToolUse","cwd":"","transcript_path":"","prompt":"","last_assistant_message":"","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"choice?"}]},"tool_response":null,"agent_id":"","engine":"agy","source":""}'

check "$(run agy '{"conversationId":"11111111-2222-4333-8444-555555555555","toolCall":{"name":"manage_task","args":{"Action":"kill","TaskId":"task-1"}}}' PostToolUse)" \
  '{"session_id":"11111111-2222-4333-8444-555555555555","hook_event_name":"PostToolUse","cwd":"","transcript_path":"","prompt":"","last_assistant_message":"","tool_name":"TaskStop","tool_input":{"Action":"kill","TaskId":"task-1","task_id":"task-1"},"tool_response":null,"agent_id":"","engine":"agy","source":""}'

# AGY Stop and PostToolUse harvest assistant reply from transcript
mkdir -p "$work/logs"
cat >"$work/logs/transcript.jsonl" <<'EOF'
{"type":"USER_INPUT","content":"hello"}
{"type":"PLANNER_RESPONSE","content":"Hello! I can help you with that."}
EOF
check "$(run agy "{\"conversationId\":\"11111111-2222-4333-8444-555555555555\",\"transcriptPath\":\"$work/logs/transcript.jsonl\",\"toolCall\":{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"ls\"}}}" PostToolUse)" \
  "{\"session_id\":\"11111111-2222-4333-8444-555555555555\",\"hook_event_name\":\"PostToolUse\",\"cwd\":\"\",\"transcript_path\":\"$work/logs/transcript.jsonl\",\"prompt\":\"\",\"last_assistant_message\":\"Hello! I can help you with that.\",\"tool_name\":\"Bash\",\"tool_input\":{\"CommandLine\":\"ls\",\"command\":\"ls\"},\"tool_response\":null,\"agent_id\":\"\",\"engine\":\"agy\",\"source\":\"\"}"

check "$(run agy "{\"conversationId\":\"11111111-2222-4333-8444-555555555555\",\"transcriptPath\":\"$work/logs/transcript.jsonl\"}" Stop)" \
  "{\"session_id\":\"11111111-2222-4333-8444-555555555555\",\"hook_event_name\":\"Stop\",\"cwd\":\"\",\"transcript_path\":\"$work/logs/transcript.jsonl\",\"prompt\":\"\",\"last_assistant_message\":\"Hello! I can help you with that.\",\"tool_name\":\"\",\"tool_input\":{},\"tool_response\":null,\"agent_id\":\"\",\"engine\":\"agy\",\"source\":\"\"}"

# The newest reply wins, past an empty one and a line still being written.
mkdir -p "$work/logs2"
printf '%s\n' '{"type":"PLANNER_RESPONSE","content":"older"}' '{"type":"PLANNER_RESPONSE","content":""}' \
  '{"type":"PLANNER_RESPONSE","content":"newest"}' >"$work/logs2/transcript.jsonl"
printf '{"type":"PLANNER_RESP' >>"$work/logs2/transcript.jsonl"
check "$(run agy "{\"conversationId\":\"11111111-2222-4333-8444-555555555555\",\"transcriptPath\":\"$work/logs2/transcript.jsonl\"}" Stop | jq -r .last_assistant_message)" "newest"
# Only the last MiB is read: a reply further back is not looked for.
{ printf '%s\n' '{"type":"PLANNER_RESPONSE","content":"far back"}'; head -c 1100000 /dev/zero | tr '\0' x; echo; } >"$work/logs2/transcript.jsonl"
check "$(run agy "{\"conversationId\":\"11111111-2222-4333-8444-555555555555\",\"transcriptPath\":\"$work/logs2/transcript.jsonl\"}" Stop | jq -r .last_assistant_message)" ""

# Turn boundary stops the search: turn one reply does not leak into turn two narration
mkdir -p "$work/logs3"
cat >"$work/logs3/transcript.jsonl" <<'EOF'
{"type":"USER_INPUT","content":"turn one"}
{"type":"PLANNER_RESPONSE","content":"Turn one is finished: all green."}
{"type":"USER_INPUT","content":"turn two"}
{"type":"PLANNER_RESPONSE","content":null,"tool_calls":[{"name":"run_command"}]}
EOF
check "$(run agy "{\"conversationId\":\"11111111-2222-4333-8444-555555555555\",\"transcriptPath\":\"$work/logs3/transcript.jsonl\",\"toolCall\":{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"ls\"}}}" PostToolUse | jq -r .last_assistant_message)" ""

check "$(run copilot '{"sessionId":"11111111-2222-4333-8444-555555555555","cwd":"/repo","toolName":"Read","toolInput":{"path":"x"}}' preToolUse)" \
  '{"session_id":"11111111-2222-4333-8444-555555555555","hook_event_name":"PreToolUse","cwd":"/repo","transcript_path":"","prompt":"","last_assistant_message":"","tool_name":"Read","tool_input":{"path":"x"},"tool_response":null,"agent_id":"","engine":"copilot","source":""}'

check "$(run agy '{}' Nope)" ""
check "$(run nope '{}' SessionStart)" ""

printf 'engine adapter tests passed\n'

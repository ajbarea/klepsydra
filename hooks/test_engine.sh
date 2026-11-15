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

check "$(run copilot '{"sessionId":"11111111-2222-4333-8444-555555555555","cwd":"/repo","toolName":"Read","toolInput":{"path":"x"}}' preToolUse)" \
  '{"session_id":"11111111-2222-4333-8444-555555555555","hook_event_name":"PreToolUse","cwd":"/repo","transcript_path":"","prompt":"","last_assistant_message":"","tool_name":"Read","tool_input":{"path":"x"},"tool_response":null,"agent_id":"","engine":"copilot","source":""}'

check "$(run agy '{}' Nope)" ""
check "$(run nope '{}' SessionStart)" ""

printf 'engine adapter tests passed\n'

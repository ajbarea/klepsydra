# IMPL

Current slice: background work keeps a session working (#45), branch
feat/background-work. A turn that ends with subagents or background shells
still running stays **working**, with the count on the pill and "prompt free"
on the card, and the portrait ring now shows that crew, one segment per piece
of work. The water-clock arc is retired.

## Done
- Probe (throwaway haiku sessions, `--setting-sources local`): SubagentStart and
  SubagentStop fire in the parent's session_id with `agent_id`; a background
  Bash's PostToolUse carries `tool_response.backgroundTaskId`; Stop fires before
  the notifications and lists `background_tasks` [{id, type: shell|subagent,
  status}]; each notification is a UserPromptSubmit whose prompt holds
  `<task-id>` and `<tool-use-id>`; TaskStop has `tool_input.task_id` and sends
  no notification.
- Hook: `background` [{id, kind, at}] in the session file (absent when empty).
  Adds: SubagentStart, background Bash, async Agent launch. Removes:
  SubagentStop, notification ids, TaskStop/KillShell, SessionEnd, a fresh
  SessionStart. Stop reconciles to its own `background_tasks`, then gives
  working + reason "background", or done. idle_prompt with work out stays
  working. A subagent's open request survives the main Stop. Capped at 64.
- Reader: lenient `background` (bad entries cost themselves), `Crew {agents,
  shells}` on every view, `BACKGROUND_STALE_AFTER = 3600`; working-after-turn
  is never quiet and falls back to done once every entry is stale.
- Wall: segmented ring (gap 18 deg; agent 6 solid, shell 3.5 dashed 3 3;
  accent or Okabe-Ito yellow), "+N" past 8, fades off under reduced motion,
  crew line, header lets a long pill wrap under the name. Demo fixture: 0, 1,
  3, 10 and a medallion with one shell.
- Gates: the whole audit list, build-windows --check.

## Next
- Review (independent) and merge; then copy the hook and the new
  SubagentStart/SubagentStop entries into ~/.claude for the live wall check.

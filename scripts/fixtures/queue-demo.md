<!-- budget: 600 words -->
# Claude queue

One list for the agent fleet and for you. Claude keeps it current: it reads this file before launching each agent, marks items done, and adds new asks here. Last rewritten 2026-10-24 09:30.

**How it runs:** at most two agents at once, each a fresh session with its own brief and a shared lock, so only one heavy job runs at a time. Briefs live in `~/.local/state/orchestrator/`.

## Needs you (short, today)

1. **Telemetry setting (PR #12).** Paste in a normal terminal. It backs up the settings file, then adds one env line.
   ```bash
   cp ~/.claude/settings.json ~/.claude/settings.json.bak &&
   jq '.env.EXAMPLE_FLAG = "on"' ~/.claude/settings.json.bak > ~/.claude/settings.json
   ```
   Undo: `mv ~/.claude/settings.json.bak ~/.claude/settings.json`.
2. **Ollama memory, then voice back on.** Restarting unloads every model, so do it while no agent runs one.
   ```bash
   sudo systemctl edit ollama
   # add these two lines, save, close:
   [Service]
   Environment="OLLAMA_FLASH_ATTENTION=1"
   ```
3. **Calendar export:** Settings, Import and export, Export. See the [help page](https://support.example.com/calendar/export "Export help") or write to [the desk](mailto:desk@example.com).
4. ✅ **Reply to the lab** about Tuesday at 1 pm. Sent 10-23.
5. **Review the draft** at [the tracker](https://tracker.example.com/items/42) before Friday.

## Running now

Relaunched 10-23 22:05 after the early-morning shutdown:
- **tools:** rerun the lost review round on #201, then merge.
  - ✅ #201 option rule merged: every option is on only for exactly `true`.
  - 📋 #197 → PR #204: second review running.
- **gauge #86, Queue panel:** this file rendered live inside the wall.
  - 📋 Being built on `feat/queue-panel`.

## Queued

1. Theme tokens for the wall (#90).
2. A [bad link](javascript:alert(1)) and an [image link](data:text/html;base64,PHNjcmlwdD4=) stay text.

<script>alert("an HTML block shows as text")</script>

## Answers

| Question | Answer |
|:--|--:|
| Where do briefs live? | `~/.local/state/orchestrator/` |
| How many agents at once? | 2 |

> Asked 10-22: does the receiver ever listen beyond loopback? No.

---

Older answers are in the git log.

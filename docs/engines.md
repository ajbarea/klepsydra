# Engine adapters: running agy and Copilot from the fleet

`fleet delegate` hands read-only work (research, drafts, a first-pass PR
review, CI triage) to another vendor's agent CLI, so the orchestrator's Claude
quota goes to orchestration, final review and anything that enters a paper or a
team repo. Code: `fleet/delegate.sh` (the command), `fleet/engines.sh` (one
adapter per engine behind one interface), `hooks/klepsydra-agy-locked.json` and
`hooks/klepsydra-engine-rules.md` (the policy and rules the launcher shares).
Tests: `make test-delegate` (stubs), `fleet/attack_live.sh` (the real engines).

Everything an engine writes is an unverified lead. Claude checks what it uses.

## Two modes, one interface

| | Print mode (default) | Interactive lane (`--interactive`) |
|---|---|---|
| Use | a one-shot: research, draft, review, triage | longer work the orchestrator follows up on |
| Engines | agy, Copilot | agy, Copilot |
| Start | `fleet delegate [opts] TASK-FILE` | same, plus `--interactive` |
| Turn end | the process exits | the watcher sees the prompt idle after a busy spell |
| Answer | stdout, saved to `answer.md` | the pane's last turn, saved to `answer-N.md` and `answer.md` |
| Follow-up | none (start another call) | `fleet delegate msg ID TEXT` |
| Stop | timeout, or it ends | `fleet delegate stop ID` |

State lives in `$FLEET_STATE/delegate/<id>/` (`meta.json`, `answer.md`, the
engine's stderr, the lane's settings and last screen). Each call writes one
`delegate call` line to the fleet log (`fleet log`).

## The return path: the model never needs write or shell access

A locked engine cannot write a report file or run `fleet send`, so it never
reports back itself. The adapter, outside the model, does:

1. **Detect the turn end.** (A turn is over only when the pane is idle and there is a reply under the echo of the prompt that was sent, so the gap before a late busy footer is not a turn; a lane's pane is trusted only while its id, window name and process still match what was launched, so a pane the pane-died hook revived is not the lane.) Print mode: the process exits (or the timeout
   kills it). Interactive: the watcher polls the pane every 2 s; a turn ends
   when the footer goes from `esc to cancel` to `? for shortcuts`. A quota or
   login message near the box, a turn over `FLEET_DELEGATE_TURN_TIMEOUT`, or
   the window closing ends the watch with that status.
2. **Capture the answer** to a file in the state folder, stamped as an
   unverified lead with engine, model and time.
3. **Notify** the orchestrator (or the pane that launched the call) through
   `fleet send`, which pastes into the pane only when its input box is empty
   and prints `sent`, `held` or `mixed` otherwise (the result is recorded in
   `meta.json` and the log; the file is always there). The line carries engine,
   status and the answer's path.

| Engine | Turn end | Answer | Limit signal | Notes |
|---|---|---|---|---|
| agy print | process exit | stdout | exit text or stderr matching a quota/auth phrase | `--print-timeout` unused: `timeout -k` outside is the limit |
| agy interactive | footer `esc to cancel` to `? for shortcuts` | text after the last non-empty `> ` echo up to the next rule, minus tool, token and tip lines | phrase near the box | agy also has a Stop hook and a status line with `agent_state` and quota buckets; the pane watcher needs neither, so it is the one signal used (later stage) |
| copilot print | process exit | stdout (`-s`) | exit text or stderr | no quota command exists; limits are read from failure text |
| copilot interactive | footer `Working ctrl+c interrupt` to `open sidebar ... Manual Approval` | text after the last `❯ text` echo up to the cwd line, bullet stripped, model-choice notice dropped | phrase near the box | a new folder shows a trust dialog (footer `enter to select`); the adapter answers Enter once. It stays in scrollback, so only the last lines are read |

Limit and auth phrases (`ENG_LIMIT_RE`, `ENG_AUTH_RE` in `engines.sh`) are the
vendors' wording and can change. A failure that matches neither is reported as
`error` and does not fall back. A failure is read for those phrases with its stderr; an exit-0 answer only when its stdout is under 200
bytes (an interactive pane: only an idle one whose last reply, under the echo of the prompt sent, is under 400 bytes), so a long answer that mentions quotas is kept; a short one that reads as a limit is also saved to `answer.md` and the notice says so.
No real limit message has been seen live yet; add the exact text here when one is.

A narrow, single-purpose report tool over MCP (the engine calls `report(text)`
and nothing else) is a possible later option. It is not built: it would give
the engine a tool that writes, which the lock removes today.

## The lock

Every non-Claude session the fleet starts, `+ New session` included, is locked,
and a lock that cannot be built starts nothing. The two entry points differ: a
`fleet delegate` lane runs in a read-only snapshot with a scope and a timeout; a
`+ New session` agy window is a person's own session in a live folder, so it has the
deny rules and `--sandbox` only, and the lock policy names no trusted workspace, so
agy's interactive window asks before trusting a folder, and its hooks do not run before that answer (a headless `agy -p` runs a folder's `.agents/hooks.json` with no
trust question, outside the deny rules, as tested). Because trust is the only gate, the launcher also refuses a folder that ships `.agents/hooks.json`, `plugins.json` or `skills.json`, the Windows side (`/mnt`), the home folder and any folder holding it. The delegate snapshot strips `.agents`.

| Engine | Lock |
|---|---|
| agy | `--settings FILE` (the policy overrides the user's `~/.gemini/antigravity-cli/settings.json` key by key; keys it does not set, such as `model`, still come from there, and nothing is rewritten), `--sandbox`, `toolPermission: request-review` (headless, anything not allowed is auto-denied; a denial ends the print run), `allowNonWorkspaceAccess: false`, deny `write_file(*)`, `command(*)`, `execute_url(*)`, `mcp(*)` and `read_url(*)` (a research task alone gets URL reads back, so `+ New session` has no outbound channel); a `fleet delegate` lane's settings add its snapshot as the one trusted workspace; the launcher refuses the whole home folder and `/` as a workspace |
| Copilot | `--available-tools view,grep,glob`, `--deny-tool=write`, `--deny-tool=shell`, `--disable-builtin-mcps`, `--disallow-temp-dir` (else it reads every session's scratch files in /tmp), `--no-ask-user`; `--allow-all-tools` only lets a headless run start, the tool list and denies do the locking |
| both | the engine's folder is a read-only snapshot (see below); a memory- and task-capped systemd scope, for the interactive window too; a timeout; the fleet's memory floor |

Facts found by attack (agy 1.5.3, Copilot 1.0.105; re-check on a CLI upgrade):

- agy's deny rules win over `toolPermission: always-proceed`; with no deny rules the same ask succeeded.
- agy plan mode is not a read-only boundary. `allowNonWorkspaceAccess: false` alone did not stop a read of `/etc/hostname` once reads were allowed everywhere.
- `toolPermission: strict` blocks even in-workspace reads, and an `allow` rule `read_file(<dir>)` did not match files below that dir (`read_file(/)` did). `request-review` with no allow list reads inside the workspace and auto-denies outside it.
- agy fetches URLs with no allow rule; only `read_url(*)` in `deny` stops it.
- Copilot: `--deny-tool` beats `--allow-all-tools`. Its docs call the lists defense in depth, not containment, so the read-only snapshot and the scope sit under them.

## What the engine sees

`fleet delegate` copies the repo's committed files (`git archive HEAD`) into a
read-only folder, removes anything secret-looking (`.env*` except `.env.example`
and `.env.sample`, `.envrc`, keys, `id_*`, `.netrc`, `credentials*`, `secrets*`, `*.tfvars`, service-account files; a matching directory goes whole, and the filter fails closed if anything matching is left), removes every symlink (a read tool would follow one out), drops binary files (NUL bytes: UTF-16, compiled; no text engine reads them) and any text file whose content looks like a credential (the same patterns that refuse a task file: AWS, GitHub, GitLab, Slack, Google, Hugging Face, npm, JWT, private-key blocks), matches names without regard to case, removes the repo's own engine configuration (`.github/hooks`, skills, agents, MCP files, `.copilot`, `.gemini`, `.agents`: Copilot's folder trust loads hooks, which run commands outside the tool lock), and adds
`TASK.md` (the task) and `AGENTS.md` (the repo's own, then the helper rules).
The prompt is one fixed line pointing at `TASK.md`, so the task is not in `ps`.
Uncommitted work is not visible: put a diff in the task file when the engine
should review it. A task file or follow-up that looks like it holds a secret is refused.
The rules file is short (under agy's 24,000-byte limit, tested) and names no
person, course or account.

## Learning a new harness

Per engine, find and record: how it runs one prompt headless and what it
prints; its permission model and what denies (attack it); its prompt, busy and
idle screens (capture a pane at each); its limit and login wording; whether it
reads `AGENTS.md`. Then add the functions to `engines.sh` (`eng_model`,
`eng_order`, `eng_can`, `eng_argv`, `eng_settings` if it needs a file) and a
stub case to `test_delegate.sh`.

agy still loads the user's own plugin hooks and starts the MCP servers set in the user's own agy settings (its log shows them connecting); their tools are denied by `mcp(*)`. A task worded as a question about web access once sent agy into a loop of generations until the timeout: the timeout path reports it.

agy quirks seen: the first screen can show a banner above the prompt; each
prompt is preceded by a rule line (so a rule alone does not end an answer);
a folder not in `trustedWorkspaces` asks for trust once, so the lane's settings
trust its own folder; a headless run that hits an un-allowed tool prints
`jetski: no output produced` and stops.

## Live attack results

`fleet/attack_live.sh`, run 2026-11-09 against agy 1.5.3 and 1.5.4 and Copilot 1.0.105. Each lane is asked to create a file, run `git commit --allow-empty` and `touch`, in a writable throwaway git folder, so only the lock stands in the way. The control runs the same ask with the lock off.

| Lane | Locked | Control (lock off) |
|---|---|---|
| agy print | clean | file, touch, commit |
| Copilot print | clean | file, touch, commit |
| agy interactive | clean | file, touch, commit |
| Copilot interactive | clean | file, touch, commit |

Guard mutants, first sweep (`test_delegate.sh`, 16 hand mutants: each Copilot flag, agy `--sandbox` in both modes, each policy deny, the snapshot's read-only mode and secret filter, the non-research URL deny, the memory floor, both secret refusals, the quota and both-out handling, the answer's rule handling, the idle-only send): 15 killed. The survivor, an explicit `--engine` falling through the fallback branch, is equivalent: an explicit engine has a one-engine list.

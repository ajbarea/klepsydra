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
| Engines | agy, Copilot | agy |
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

1. **Detect the turn end.** Print mode: the process exits (or the timeout
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
| copilot interactive | not built | | | its prompt and idle signals are not yet learned |

Limit and auth phrases (`ENG_LIMIT_RE`, `ENG_AUTH_RE` in `engines.sh`) are the
vendors' wording and can change. A failure that matches neither is reported as
`error` and does not fall back. Only a failure, or an exit-0 answer under 1000
bytes, is read for those phrases, so a long answer that mentions quotas is kept.
No real limit message has been seen live yet; add the exact text here when one is.

A narrow, single-purpose report tool over MCP (the engine calls `report(text)`
and nothing else) is a possible later option. It is not built: it would give
the engine a tool that writes, which the lock removes today.

## The lock

Every non-Claude session the fleet starts, `+ New session` included, is locked,
and a lock that cannot be built starts nothing.

| Engine | Lock |
|---|---|
| agy | `--settings FILE` (a file of its own, so `~/.gemini/antigravity-cli/settings.json` is never read for these or rewritten), `--sandbox`, `toolPermission: request-review` (headless, anything not allowed is auto-denied; a denial ends the print run), `allowNonWorkspaceAccess: false`, deny `write_file(*)`, `command(*)`, `unsandboxed(*)`, `execute_url(*)`, `mcp(*)`; `read_url(*)` is denied unless the task is research; the folder is its one trusted workspace |
| Copilot | `--available-tools view,grep,glob`, `--deny-tool=write`, `--deny-tool=shell`, `--disable-builtin-mcps`, `--no-ask-user`; `--allow-all-tools` only lets a headless run start, the tool list and denies do the locking |
| both | the engine's folder is a read-only snapshot (see below); a memory- and task-capped systemd scope; a timeout; the fleet's memory floor |

Facts found by attack (agy 1.5.3, Copilot 1.0.105; re-check on a CLI upgrade):

- agy's deny rules win over `toolPermission: always-proceed`; with no deny rules the same ask succeeded.
- agy plan mode is not a read-only boundary. `allowNonWorkspaceAccess: false` alone did not stop a read of `/etc/hostname` once reads were allowed everywhere.
- `toolPermission: strict` blocks even in-workspace reads, and an `allow` rule `read_file(<dir>)` did not match files below that dir (`read_file(/)` did). `request-review` with no allow list reads inside the workspace and auto-denies outside it.
- agy fetches URLs with no allow rule; only `read_url(*)` in `deny` stops it.
- Copilot: `--deny-tool` beats `--allow-all-tools`. Its docs call the lists defense in depth, not containment, so the read-only snapshot and the scope sit under them.

## What the engine sees

`fleet delegate` copies the repo's committed files (`git archive HEAD`) into a
read-only folder, removes anything secret-looking (`.env*` except `.env.example`
and `.env.sample`, keys, `.netrc`, `credentials*`, `secrets*`), and adds
`TASK.md` (the task) and `AGENTS.md` (the repo's own, then the helper rules).
The prompt is one fixed line pointing at `TASK.md`, so the task is not in `ps`.
Uncommitted work is not visible: put a diff in the task file when the engine
should review it. A task file that looks like it holds a secret is refused.
The rules file is short (under agy's 24,000-byte limit, tested) and names no
person, course or account.

## Learning a new harness

Per engine, find and record: how it runs one prompt headless and what it
prints; its permission model and what denies (attack it); its prompt, busy and
idle screens (capture a pane at each); its limit and login wording; whether it
reads `AGENTS.md`. Then add the functions to `engines.sh` (`eng_model`,
`eng_order`, `eng_can`, `eng_argv`, `eng_settings` if it needs a file) and a
stub case to `test_delegate.sh`.

agy quirks seen: the first screen can show a banner above the prompt; each
prompt is preceded by a rule line (so a rule alone does not end an answer);
a folder not in `trustedWorkspaces` asks for trust once, so the lane's settings
trust its own folder; a headless run that hits an un-allowed tool prints
`jetski: no output produced` and stops.

## Live attack results

Recorded by `fleet/attack_live.sh` (see the end of this file).

# Engine adapters: running agy and Copilot from the fleet

`fleet delegate` hands read-only work (research, drafts, a first-pass PR
review, CI triage) to another vendor's agent CLI, so the orchestrator's Claude
quota goes to orchestration, final review and anything that enters a paper or a
team repo. Code: `fleet/delegate.sh` (the command), `fleet/engines.sh` (one
adapter per engine behind one interface), `hooks/klepsydra-agy-locked.json` and
`hooks/klepsydra-engine-rules.md` (the policy and rules the launcher shares).
Tests: `make test-delegate` (stubs), `fleet/attack_live.sh` (the real engines).

Everything an engine writes is an unverified lead. Claude checks what it uses.

## Playbook: using agy and Copilot as agents

<!-- budget: 1200 words for this section -->

Evidence is from 2026-11-09 to 11-11. Run ids (`1110-...`, `1111-...`) are
folders under `$FLEET_STATE/delegate/`; "friction" and "HEPH" are the dated
lines in `friction.md` and `HEPH.md` there. The per-engine scorecard stays in
klepsydra#346 and grows as runs accrue. Both engines run read-only in a snapshot
of committed files, so uncommitted work reaches them only inside the task file.

### Which engine for what

| Job | Engine | Evidence |
|---|---|---|
| Web research with sources | agy | Cover-flow practice: high quality, cited (1110-194814-0588). LinkedIn research: all 6 projects real (1111-063103-4c91). |
| Qualifier sweep over long rule text | agy | Found 2 real qualifiers an Opus reader missed in a paper explainer (HEPH 11-10 21:5x, friction 11-10 p4-sheet); 4 real gaps in the sphragis code, 2 wrong (HEPH 11-11 08:09); more real issues than Copilot on the QML paper (friction 11-11 qml-paper). |
| Consistency check of a deck against a paper | Copilot | Line-cited stale slides in the big FA deck (1110-195107-d35b). |
| Second reader on a code PR | Copilot | 1 real finding per PR on sphragis (HEPH 11-11 08:09), 5 real leads across the next three PRs (HEPH 11-11 11:49); nothing new on a talks diff already reviewed (HEPH 11-10 22:4x) or on klepsydra#350 (HEPH 11-11 15:07). |
| Word counts and time grades | neither | agy said 870 words, the script said 947; Copilot said 1,200 (friction 11-11 c810). Run the gate. |

Both engines state a wrong claim in the same confident voice as a true one.
Known misses: agy's "token-pooled" estimand, where the code averages over
examples (HEPH 11-10 21:5x, friction 11-10 p4-sheet); agy's two wrong lexicon
claims about VADER (friction 11-11 act7); "goldfish about 2 weeks old", repeated
though the repo was created 09-13, and agy's claim that techne lacks
anti-rationalization tables, which it has (both HEPH 11-11 06:37). Copilot
called "past the crossover every seed was ambiguous" false by reading a
4-column outcome row as the wrong column (friction 11-11 qml-paper). Check each
claim against the code, the lexicon or the row before you edit anything.

### Briefing a lane

- **Prompt shape.** Put the answer first in the task and ask for `path:line`
  citations; `hooks/klepsydra-engine-rules.md` already tells the engine to do
  both, so the task only has to say what to check and against what. Name the
  columns of every table next to the table: Copilot misread a row whose column
  order the brief did not give (friction 11-11 qml-paper).
- **File set.** The engine sees committed text files only. Binary files (PDF,
  PNG) are withheld and the lane still runs: a review of a slide bundle
  returned "Waiting for the research subagent..." with status `ok`
  (1111-060904-b67e). For a visual review, hand it text: `pdftotext` per slide
  or a shape and position dump.
- **Task size.** A task file over 65,536 bytes is refused at the start, before
  any snapshot (friction 11-11 coverflow; `delegate.sh` checks the size
  while parsing arguments). Point the engine at the snapshot's files
  and inline only small diffs.
- **Large repos.** A snapshot over 300 MB is refused; sphragis was 966 MB
  (friction 11-11 s253). Build a slim git repo of code, tests and docs with
  `git archive HEAD <paths>` and pass it as `--dir`.
- **Timeouts.** Print mode stops at 600 s (`FLEET_DELEGATE_TIMEOUT`) and an
  agy timeout returns no partial answer. A 51 KB agy review timed out at 619 s
  (1111-083732-5125, friction 11-11 s253b). Pass `--timeout 1500` to an agy
  review over about 30 KB, or split the input into one lane per section.
- **Read the answer, not the status.** `status=ok` held for a one-line
  non-answer (1111-060904-b67e). A denied `read_file` gave `status=empty` in
  78 s (1111-061256-71ed); inlining the material in the task file (under
  64 KB) fixed the retry (1111-061432-6004). Treat an answer of a few lines as a
  failed run.
- **Cost.** A Copilot call bills AI Credits: 0.54 for a one-line test, because
  its built-in prompt is about 37k tokens (HEPH 11-10 20:0x). Batch questions
  into one task rather than many small calls.

### Quirks and workarounds

| Quirk | Workaround | Source |
|---|---|---|
| Copilot refuses every explicit `--model` on this plan (gpt-5.6-sol, gpt-5.6, gpt-5, gpt-6-luna, gpt-5.3-codex): "Model ... is not available" | Use `auto`, the default in `engines.sh`; its session log shows gpt-5.6-luna | 1110-194855-9122, HEPH 11-10 20:0x |
| agy has no partial answer on a print-mode timeout | `--timeout`, or split the input | 1111-083732-5125 |
| agy once auto-denied `read_file` on a `--dir` bundle snapshot and returned empty | Inline the material in the task file; it worked on the retry (1111-061432-6004, a 220 s `ok` with a full answer) | 1111-061256-71ed, friction 11-11 aware-mid |
| agy permission rules are not what the docs imply: `strict` blocks even in-workspace reads, an allow on a directory matches nothing below it, `allowNonWorkspaceAccess:false` did not stop `/etc/hostname` | Test each permission claim with a real attempt; the lock section below holds the tested form | friction 11-09 agy-copilot |
| Both engines fold a long paste into a placeholder | A follow-up is one short tagged line; long text goes in a task file | the return-path section |
| agy's plan mode is not a read-only boundary | The deny rules, the sandbox and the snapshot do the locking | HEPH 11-09 17:1x |

### What never goes to an engine

- **Registered-report text.** Never sent to an engine (AJ's 11-11 scope,
  klepsydra#346). Registered-report review stays with Opus (HEPH 11-11 06:24
  budget rule). The sphragis runs cited above predate this scope (set 11-11 13:48 on
  klepsydra#346).
- **Team repos.** Never snapshotted for an engine, and nothing an engine
  writes is posted to a teammate or a team repo (AJ's 11-11 scope,
  klepsydra#346; HEPH overnight rules 11-09). Engines are a second reader on
  our own repos.
- **Merges, pushes, comments, email.** Locked lanes cannot write, and an
  engine's answer is never the approval for any of these.
- **Secrets.** The snapshot filter withholds secret-looking files and the task
  scan refuses a task holding one; a refusal means remove the secret, not rerun.
- **Final verification.** A lane's answer feeds the next worker's brief and
  that worker checks it; the verify pass before a merge stays with Opus
  (HEPH 11-11 06:24 budget rule).

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

1. **Detect the turn end.** (A follow-up is one short line (newlines folded, at most 700 bytes) led by a tag unique to its send, `[fleet:N]` (N counts sends, not answered turns), because both engines fold a long or multi-line paste into a placeholder and two follow-ups that open alike could not otherwise be told apart. A turn is over only when the pane is idle and there is a reply under the echo of the prompt that was sent (matched ignoring leading spaces and whitespace; the lines an engine wraps the echo onto are skipped using the sent text; no echo matched means no answer, never another turn's, and a turn that times out saves the last reply on screen to `answer-unverified.md`, labeled), so the gap before a late busy footer is not a turn; a lane's pane is trusted only while its id, window name and process still match what was launched, so a pane the pane-died hook revived is not the lane.) Print mode: the process exits (or the timeout
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
| agy interactive | footer `esc to cancel` to `? for shortcuts`, with a reply under the echo of the prompt sent | text after the echo of that prompt (`> [fleet:N] ...`) up to the next rule, minus tool, token and tip lines | phrase near the box | agy also has a Stop hook and a status line with `agent_state` and quota buckets; the pane watcher needs neither, so it is the one signal used (later stage) |
| copilot print | process exit | stdout (`-s`) | exit text or stderr | no quota command exists; limits are read from failure text |
| copilot interactive | footer `Working ctrl+c interrupt` to `open sidebar ... Manual Approval`, with a reply under the echo of the prompt sent | text after the echo of that prompt (`❯ [fleet:N] ...`) up to the cwd line, bullet stripped, model-choice notice dropped | phrase near the box | a new folder shows a trust dialog (footer `enter to select`); the adapter answers Enter once. It stays in scrollback, so only the last lines are read |

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
trust question, outside the deny rules, as tested). Because trust is the only gate, the launcher also refuses a folder that ships agy workspace configuration (`.agents`, `.agent`, `_agents` or `_agent` in it or any folder above it up to the repo root; a bare `hooks.json` elsewhere in the tree is loaded by nothing, tested), the Windows side (`/mnt`), the home folder and any folder holding it. The delegate snapshot strips `.agents`.

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
and `.env.sample`, `.envrc`, keys, `id_*`, `.netrc`, `credentials*`, `secrets*`, `*.tfvars`, service-account files; a matching directory goes whole, and the filter fails closed if anything matching is left), removes every symlink (a read tool would follow one out), drops files over 25 MB (`FLEET_DELEGATE_FILE_MB`, before any scan reads them whole) and files with a NUL byte anywhere (UTF-16, compiled; no text engine reads them) and any text file whose content looks like a credential (the same patterns that refuse a task file: AWS, GitHub, GitLab, Slack, Google, Hugging Face, npm, JWT, private-key blocks), matches names without regard to case, removes the repo's own engine configuration (`.github/hooks`, skills, agents, MCP files, `.copilot`, `.gemini`, and agy's `.agents`, `.agent`, `_agents`, `_agent`, plus any `hooks.json`, `plugins.json`, `skills.json` or `mcp_config.json` anywhere: Copilot's folder trust loads hooks, which run commands outside the tool lock), and adds
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

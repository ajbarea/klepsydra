# Headless jobs: fleet work on the API credit

<!-- budget: 1200 words -->

`fleet headless` runs one fleet job as a one-shot `claude -p` on an API
credential, so queue items can spend free API credit before the Claude
subscription's weekly limit (#260). Interactive sessions stay on the
subscription. Code: `fleet/headless.sh`; tests: `make test-headless`.

## The rule

| Session | Runs on |
|---|---|
| Heph, workers, anything in a tmux pane (`fleet/launch.sh`) | the claude.ai subscription only |
| `fleet headless` jobs | the API credit, through an `apiKeyHelper` |

Promotional API credit does not cover interactive Claude Code: on 11-01 an
interactive session on a lab key failed with "Credit balance too low", while
`claude -p` on the same key worked (#241). A session started with a key also
loses the claude.ai login, its connectors and Remote Control. So `launch.sh`
and the tray's launcher drop `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and
`ANTHROPIC_PROFILE` from every session they start. `launch.sh` also refuses to
start when a settings file the session would read (user, project, local,
managed, the worker settings or `--settings`) sets an `apiKeyHelper` or a key,
and `fleet doctor` fails on it. Claude Code ranks each of those above the
subscription login ([Authentication
precedence](https://code.claude.com/docs/en/authentication#authentication-precedence)).

## Setup, once

1. Log in to the credit's workspace with the `ant` CLI:
   `ant --profile ldqis auth login`. The token lasts about 8 hours and the CLI
   renews it.
2. Make the config folder the jobs use, `~/.claude-api`, with a
   `settings.json` that prints that token:

   ```json
   {
     "apiKeyHelper": "ant --profile ldqis auth print-credentials --access-token",
     "env": { "CLAUDE_CODE_API_KEY_HELPER_TTL_MS": "900000" }
   }
   ```

   Put your `CLAUDE.md` there too. A helper renews the token during a long
   job, which a fixed `ANTHROPIC_AUTH_TOKEN` would not.
3. `fleet doctor` then reports `auth mode: subscription + headless credit`.

`FLEET_HEADLESS_CONFIG` and `FLEET_HEADLESS_PROFILE` change the folder and the
profile.

## Running a job

```bash
fleet headless fix-123 brief.md --repo ~/ajsoftworks/klepsydra --budget 5
fleet headless --status
```

- **NAME** is used once. The job gets the worktree
  `<repo>/.claude/worktrees/headless-NAME` on a new branch `headless-NAME`,
  made from the repo's default branch.
- **BRIEF** is a file, or `-` for stdin. Its text is the whole prompt, so
  write it as a full brief (`fleet brief` adds the shared rules).
- **`--budget`** is the hard cap in dollars: default 10, at most 50
  (`FLEET_HEADLESS_MAX_USD`). Claude Code stops the run when it is reached.
- **`--model`** defaults to `claude-opus-5-5`.
- **`--wait`** runs in the foreground and exits with the job's status.
  Without it the command returns once the job has started.

The job runs with `--permission-mode bypassPermissions` and
`--permission-prompts none`, since nobody can answer a prompt. It runs in the
workers' memory- and task-capped scope, and it stops after 6 hours
(`FLEET_HEADLESS_TIMEOUT`). It refuses to start without an `ant` login and
prints the command that fixes it.

## Seeing a job to its end

A `claude -p` job ends when its turn ends, and nothing wakes it when
something finishes later. On 11-13 three jobs stopped half done this way: one
started its browser suite in the background and wrote "I'll continue once it
finishes", and two lost a call that Claude Code moved to the background when it
reached the 10-minute tool limit while waiting on the heavy lock. One of them
had wrapped the lock around a `sleep`, which outlived it and held the lock for
30 minutes. The runner guards each of these:

| Guard | Does |
|---|---|
| Rules (`fleet/headless-rules.md`) | put before every brief: foreground only, no background jobs, watchers or monitors, each command under 8 minutes and each lock wait under 7, the heavy lock per command (`flock -o -E 75 -w 420 /tmp/fleet-heavy.lock timeout 480 <command>`, issued again on exit 75), and a final message that starts with `FINAL REPORT:` |
| Environment and tools | `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`, so a command at its tool timeout stops instead of moving to the background, and `CLAUDE_CODE_DISABLE_AGENT_VIEW=1`; `BASH_DEFAULT_TIMEOUT_MS` and `BASH_MAX_TIMEOUT_MS` at 16 minutes, so a 7-minute lock wait and an 8-minute run fit in one call; `--disallowedTools Monitor,ScheduleWakeup,CronCreate`, since Monitor still runs in the background |
| Resume loop | a run whose last message does not start with `FINAL REPORT:` (bold, a heading or any case counts) is resumed (`claude -p --resume <session>`) with a fixed "continue to the end, foreground only" message, up to 4 times (`FLEET_HEADLESS_RESUMES`); a report whose last lines say "I'll continue" or "I'm waiting" is resumed once |
| Stall | past the resumes, with under a cent of budget left, with no cost or session in the result, or on a claude older than 2.1.277, the job reads `stalled` in `--status`, the ledger and the fleet log, and `--wait` exits 1 |
| Reaper | after every run, and when the runner is stopped, it stops what the job started since it began: every other process in the job's scope, every process carrying the job's `KLEPSYDRA_AGENT` (Claude Code runs each Bash command in a session of its own), and claude's session; TERM, then KILL; the record counts them as `reaped` |
| `fleet doctor` | `heavy lock:` names each holder (pid, command, age, scope, job) and the runs queued; it warns when a holder is a bare `sleep` or its headless job has ended, with the pid to stop |

A resumed run reports the session's whole spend (from Claude Code 2.1.277), so
the record's cost is the largest `total_cost_usd` seen (a crash may report 0),
and each resume gets the budget less that spend as its `--max-budget-usd`, which
counts only its own run
([cost tracking](https://code.claude.com/docs/en/agent-sdk/cost-tracking)). A
resume that ends with no result leaves the cost a floor: `--status` shows it as
`$1.2+`. The reaper acts on a cgroup only when it is the unit `fleet headless`
made for the job, never its caller's. A runner killed outright (KILL, OOM) cannot reap; `fleet
doctor` then names what it left holding the lock.

## Where the spend shows

| Place | What |
|---|---|
| `fleet headless --status` | running jobs, then each finished job's cost, budget, time, exit, result, resumes and stopped leftovers, and the total |
| `$FLEET_STATE/headless/ledger.jsonl` | one line per finished job |
| `fleet log` | `headless job ended` with name, model, `cost_usd`, seconds and exit |
| `$FLEET_STATE/headless/NAME/` | `job.json`, `brief.md`, `stream.jsonl` (the run), `stderr.log` |
| klepsydra's Ledger | the job's tokens, when the default config folder sets the telemetry `env` block, which the job copies |

The cost is the `total_cost_usd` of the run's final `result` message: Claude
Code's estimate from token counts, not the bill
([headless docs](https://code.claude.com/docs/en/headless)). The Console's usage
page is the billing record. A job stopped at its cap reads
`error_max_budget_usd`; one with no result message reads `no result`, a
timed-out one `timeout`, one that never wrote its report `stalled`, and one
whose runner was stopped `stopped`.

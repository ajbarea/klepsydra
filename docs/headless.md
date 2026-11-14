# Headless jobs: fleet work on the API credit

<!-- budget: 600 words -->

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

## Where the spend shows

| Place | What |
|---|---|
| `fleet headless --status` | running jobs, then each finished job's cost, budget, time, exit and result, and the total |
| `$FLEET_STATE/headless/ledger.jsonl` | one line per finished job |
| `fleet log` | `headless job ended` with name, model, `cost_usd`, seconds and exit |
| `$FLEET_STATE/headless/NAME/` | `job.json`, `brief.md`, `stream.jsonl` (the run), `stderr.log` |
| klepsydra's Ledger | the job's tokens, when the default config folder sets the telemetry `env` block, which the job copies |

The cost is the `total_cost_usd` of the run's final `result` message: Claude
Code's estimate from token counts, not the bill
([headless docs](https://code.claude.com/docs/en/headless)). The Console's usage
page is the billing record. A job stopped at its cap reads
`error_max_budget_usd`; one with no result message reads `no result`, and a
timed-out one `timeout`.

<!-- budget: 1500 words -->
# Resume method experiment: design (#272)

## Question

When a worker stops at a usage limit, which way of picking the work up again costs the least plan usage without losing quality? The fleet's rule today is: after 55 minutes idle (`FRESH_AFTER_S=3300` in `fleet/resume-at-reset.sh`), replace the pane with a fresh session from its brief and IMPL.md; before that, type a continue into it. No run has measured either branch.

## What the docs settle before any run

Read 11-03 against Claude Code 2.1.316, the version installed here.

| Fact | Consequence for the design | Source |
|---|---|---|
| On a subscription within plan usage, the main conversation already gets the one-hour cache TTL; subagents and compaction get five minutes. | The issue's "warm under 5 min" arm only exists for API-key or usage-credit sessions (Heph's #241 fallback). Workers on RIT or Personal are always on the hour. | [prompt caching: which TTL each request gets](https://code.claude.com/docs/en/prompt-caching#which-ttl-each-request-gets) |
| A resumed or continued session re-sends the whole transcript; the part still inside the TTL is read at the cached rate, the rest is written again. | A 5-hour limit always leaves a cold cache, so a typed continue after it re-writes the full context. This matches 11-02 12:48: five continues re-cached about 1.7M tokens and took 38% of the RIT window in 4 minutes (`token-costs.md`). | [prompt caching: resuming a session](https://code.claude.com/docs/en/prompt-caching#resuming-a-session) |
| `/compact` sends a summarization request that repeats the history being summarized; on a cold cache that whole history is uncached input. | Compact-then-continue after a long limit pays the cold re-read once to summarize, then a short rebuild. It can only win against a typed continue if the summary is much shorter and the later turns are many. | [prompt caching: compacting the conversation](https://code.claude.com/docs/en/prompt-caching#compacting-the-conversation) |
| Idle compaction runs about an hour after the last request, on the one-hour TTL, once context passes 200,000 tokens, before the cache expires. On by default. | A limited worker may already be compacted while warm by the time the service reaches it. Unknown: whether that request runs while the account is at its limit. Step 0 checks it. | [settings reference: idleCompaction](https://code.claude.com/docs/en/settings-reference#idlecompaction) |
| Claude Code waits at a usage limit and continues the task by itself at the reset (`autoContinueAtUsageLimit`, default on), except in Remote Control sessions, where it only offers `/rate-limit-options`. | Every fleet worker runs Remote Control, so the built-in continue never fires for them and the resume service does that job. AJ's idea of Remote Control on Heph only would hand resets back to Claude Code. That is arm E. | [interactive mode: wait for a usage limit to reset](https://code.claude.com/docs/en/interactive-mode#wait-for-a-usage-limit-to-reset) |
| Cache scope is one machine and one directory; a session in another directory builds a different prefix. | Replays in separate worktrees cannot read each other's cache, so arms stay independent. A replay also cannot read the original pane's warm cache; step 0 measures whether a forked resume in another directory hits any cache at all. | [prompt caching: cache scope](https://code.claude.com/docs/en/prompt-caching#cache-scope) |

## Arms

| Arm | What happens at the reset | Applies when |
|---|---|---|
| A. Fresh | New session from the brief + IMPL.md (today's rule past 55 min) | any gap |
| B. Continue | `--resume` the transcript, type the service's continue line | any gap; cold past 1 h |
| C. Compact, then continue | `/compact` on the resumed transcript, then the continue line | any gap; cold past 1 h |
| D. Warm continue | as B, within the hour of the last request | a limit that resets within 1 h of the stop |
| E. Built-in continue | Remote Control off; Claude Code's own wait and continue | any gap |

E sends the same requests as B or D. It is measured for whether Claude Code's own continue prompt resumes as well as the service's line, against what the fleet loses without Remote Control (phone access, account moves). D is only reachable when the reset is near; today's `MOVE_MIN_S=900` already waits for those.

## Step 0: pilot (one snapshot, no arms compared)

1. Does idle compaction run while the account is limited? Leave one large worker (over 200k context) at a limit for 70 minutes and read its transcript for a compact boundary and its usage line.
2. Does a forked resume (`claude --resume <id> --fork-session`) in a copy of the worktree read any cache? Read `cache_read_input_tokens` on its first request.
3. Check that the measurement script below reads every request of a run, subagents included (their own transcripts under the session's folder).

If (2) shows a fork in another directory hits no cache, D is measured live only, on the next real near reset, not by replay.

## Method: replay from snapshots

A real resume happens once, so arms are compared on copies of the same moment.

1. **Snapshot.** When a worker hits a limit, `fleet` copies its transcript JSONL, its brief, and its worktree at that moment (HEAD plus a patch of uncommitted changes) into `~/.local/state/fleet-orchestrator/experiments/272/<snap>/`. Five snapshots from different workers and context sizes (under 150k, 150k to 300k, over 300k).
2. **Arms.** After the cache is cold (over an hour past the stop), each arm runs in its own throwaway worktree built from the snapshot: A starts fresh; B and C use `--resume --fork-session` on the copied transcript. Arms run one at a time, never two at once, so the usage reading for each run is its own.
3. **Sandbox.** Each replay gets a `gh` stub on PATH that refuses every write, a push URL pointing at a missing path, its own `FLEET_STATE`, and no Remote Control. It never touches AJ's panes, inbox, or the remote. It runs on the worker settings (`fleet/worker-settings.json`).
4. **Stop rule.** A replay ends at its first useful action (defined below) plus 10 more turns, or after 30 minutes, whichever comes first.
5. **Account.** Replays run on whichever account has the most weekly room after #227's worker reserve, in the overnight window, and stop if that account's five-hour reading passes 60%.

Five snapshots by three cold arms is 15 replays. Each result is reported as median and range over the five snapshots, never one draw.

## Measures

**Cost, from the transcripts (primary).** For every request from the resume to the stop rule, sum the four token counts each response reports: input, cache writes (split by `ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens`), cache reads, output. Combine them as list-price-weighted tokens: base input 1, 5-minute write 1.25, one-hour write 2, read at the model's cached rate, output at the model's output multiple, from the [pricing page](https://platform.claude.com/docs/en/about-claude/pricing) read on the day of the run and recorded with the results. Report each part as well as the sum. Plan-limit weights are not published, so the weighted sum is labelled as list-price weighting.

**Cost, from the gauge (cross-check).** The account's five-hour utilization before and after each replay, from klepsydra's usage reading. Valid only because arms never overlap; any other agent's activity on that account in the window voids the reading, and the run log says so.

**Time to first useful action.** Requests and seconds from the resume to the first tool call that changes the work: an edit, a commit, a test run of the item in IMPL.md's Next, or a reviewer dispatch.

**Quality (fixed rubric).** An opus judge that is not told the arm scores each replay from its transcript and diff, 0 to 2 per line:

| Line | 2 | 0 |
|---|---|---|
| Right item | picks up IMPL.md's first open item, or the one the transcript was mid-way through | starts something else |
| No repeated work | redoes nothing already committed or reported done | repeats a finished step |
| No lost state | carries over uncommitted changes, running reviews, and pending CI notes | drops one |
| First deliverable | its first change passes the touched tests or a review round | breaks a test |
| Rules kept | heavy lock, guarded rm, no public asks | breaks one |

Two arms that differ by one point or less on the median are treated as equal in quality.

## Decision rule

Take the arm with the lowest median weighted cost whose median quality is within one point of arm A. Ties go to A, which needs no transcript. The result sets `FRESH_AFTER_S`, whether the service ever types a continue after a cold gap, and whether workers keep Remote Control (E). Each replay's row goes in the Ledger (#157) with its arm, snapshot, and both cost readings, and the decision cites the run log.

## Out of scope

- Heph's own resumes: one session, and a missed reset there costs AJ, not tokens.
- Changing the TTL: workers already get the hour; `FORCE_PROMPT_CACHING_5M` exists for a later comparison on API-key sessions only.
- Message threads: they do not change pricing (checked on #272, 11-03).

# Fleet shell: processes per run, 2026-11-19 (klepsydra#492)

<!-- budget: 600 words -->

How many processes each recurring fleet shell path starts, measured on the live fleet.
The slices of #492 report their AFTER against the BEFORE column.

## Method

- **What is counted:** processes created (`clone`, `clone3`, `fork`, `vfork`) and programs run
  (`execve`). Only calls that succeeded count (`strace -f -z`). A `$(...)` subshell is a fork with
  no exec; a pipeline of three programs is three of each. The counts come out the same on every
  run with the same panes and files, so they can be compared run against run. Wall time is not
  (one resume pass took 0.8 s to 6.0 s over 10 runs on a loaded PC).
- **Harness:** `scripts/perf/forks/run.sh OUT PANE...` runs each path from one checkout against
  the live tmux panes, through `sandbox.sh`. The sandbox uses copies of the fleet state and the
  klepsydra data folder, and a read-only `tmux` (`tmux-ro`: reads pass through, writes are refused
  and logged). It makes no launches and calls no `systemctl` and no `recover`.
  `SANDBOX_SEED` gives two checkouts the same copies.
- **Run:** `flock -o /tmp/fleet-heavy.lock timeout 1200 bash ba.sh %59 %60 %63`. BEFORE is
  origin/main 958dbb2 in a detached worktree, AFTER is this branch, both seeded from one copy
  (74 session files, 4 fleet panes, 3 of them watched). strace 6.8, bash 5.2.21, gawk 5.2.1;
  Ryzen 5 3600X, WSL2 6.18.
- **Cost of one process here** (hyperfine, 30 runs of 100 each): a fork plus exec of `/bin/true`
  takes 0.95 ms; a bare `$(:)` subshell takes 0.56 ms. A large shell such as the resume service
  forks slower than the small one measured.

## Results

| Path (how often) | BEFORE forks | BEFORE execs | AFTER slice 4 forks | AFTER slice 4 execs |
|---|---:|---:|---:|---:|
| fleet hook, PostToolUse (every tool call of every agent) | 24 | 9 | 24 | 9 |
| resume pass, 4 panes (every 60 s) | 772 | 418 | 472 | 242 |
| watch-panes, per tick, 3 panes (every 30 s per watcher) | 152 | | 39 | |
| watch-panes, start | 285 | | 100 | |
| `fleet doctor` (every 5 min) | 1645 | 941 | 1479 | 845 |
| tmux-watch (every minute) | 36 | 18 | 36 | 18 |
| `. fleet/lib.sh`, which every fleet command runs | 16 to 19 | | 16 to 19 | |

The exec count names `tmux` twice per call, because `tmux-ro` is a script that runs the real
`tmux`. The fork counts are not affected.

**Where BEFORE went:**
- **Doctor:** 456 `jq` runs. 292 of them read one session file per pane, 73 the voice of each
  file, and 23 the live session of a pane.
- **Resume pass:** 111 `awk` and 58 `sed` re-parse the same capture for each question asked
  of it, and 58 `jq` read session files one at a time.
- **Watch tick:** 245 `grep` and 164 `awk` in the BEFORE watch run; one `tmux list-panes` per
  watched pane per tick.

## Slices (#492)

| Slice | Change | Rows it moves |
|---|---|---|
| 1 | one `jq` reads every session file (the fleet hook's `fleet_rows`, shared) | doctor, resume pass |
| 2 | `tmux list-panes` once per pass | doctor, watch tick |
| 3 | `lib.sh` load and `flog` with bash builtins | every command; tmux-watch |
| 4 | one `awk` per screen capture (`screen_parse`) | resume pass, watch tick, doctor |
| 5 | `basename`/`dirname` replaced by parameter expansion, plus a lint | every command |

The hook's 9 programs each do needed work. `input=$(cat)` stays as it is: bash's `read` takes
a pipe one byte per system call, and a tool's output can be large.

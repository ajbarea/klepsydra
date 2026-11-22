# IMPL: klepsydra#503: make shellcheck memory guard for large test suite

Branch fix/shellcheck-memory-503 (worktree .claude/worktrees/shellcheck-503), cut from origin/main 7ed5e88.
Never push to main.

## Slice
- Guard `make shellcheck` against OOM termination under the fleet's 3.6 GB worker slice cap.
- Check core files (hooks, statusline, scripts, fleet scripts) cleanly and check the heavy monolithic test suite (`fleet/test_fleet.sh`) when memory headroom permits or in CI (`CI=true` / `FLEET_SHELLCHECK_ALL=1`).
- Provide dedicated `make shellcheck-suite` target to run shellcheck directly on `fleet/test_fleet.sh` under the heavy lock.

## Done
- `scripts/shellcheck.sh`:
  - Created wrapper with memory headroom guard.
  - Partitions arguments into core files and heavy test suite (`fleet/test_fleet.sh`).
  - Checks core files unconditionally.
  - Evaluates cgroup v2 `memory.max` (via `/sys/fs/cgroup`) and `/proc/meminfo` `MemAvailable`.
  - When memory headroom is under 4500 MiB (such as inside `fleet-workers.slice` capped at 3628 MiB), skips `test_fleet.sh` with an informative note unless `FLEET_SHELLCHECK_ALL=1` or `CI=true`.
  - Allows full execution in CI where unconstrained runner memory is available.
- `Makefile`:
  - Updated `shellcheck` target to route through `scripts/shellcheck.sh $(SHELL_FILES)`.
  - Added `shellcheck-suite` target for running directly on `fleet/test_fleet.sh`.
  - Added `test-shellcheck` target to run unit tests.
- `scripts/test_shellcheck.sh`:
  - Added unit tests covering core file execution, cgroup memory constraint skip, MemAvailable constraint skip, `FLEET_SHELLCHECK_ALL=1` override, and `CI=true` override.

## Next
- Verify `git diff` and commit with conventional commit.
- Push branch `fix/shellcheck-memory-503`.
- Open PR with team ceremony.
- Post Elenchus bug-class self-review.

## Verify
- `make -C /home/ajbar/ajsoftworks/klepsydra/.claude/worktrees/shellcheck-503 test-shellcheck`: 5 passed, 0 failed.
- `make -C /home/ajbar/ajsoftworks/klepsydra/.claude/worktrees/shellcheck-503 shellcheck`: clean exit 0.
- `uvx --from shellcheck-py shellcheck scripts/shellcheck.sh scripts/test_shellcheck.sh`: clean exit 0.

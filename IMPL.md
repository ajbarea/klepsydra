# IMPL: #503 make shellcheck finishes inside a worker's memory (PR #521)

Branch fix/shellcheck-memory-503 (agy's, reworked by Opus agy-review-k 11-23).
Push: `git push origin fix/shellcheck-memory-503:fix/shellcheck-memory-503`. Never push to main.

## Done
- agy: skip fleet/test_fleet.sh when the process's own cgroup or MemAvailable is under 4500 MiB.
- Opus r1 rework (agy's version would still OOM here: it read only its own scope, 5 GiB, while
  fleet-workers.slice above it caps 3.6 GiB; and a skip let lint go unrun with exit 0):
  - Measured: `--extended-analysis=false` on test_fleet.sh peaks at 236 MB in 5.6 s (3.4 GB with
    dataflow). A file over 3000 lines is now checked that way when the least room over every
    cgroup up to the root (max - current) and MemAvailable is under 4000 MiB, with a note; never
    skipped. CI, or FLEET_SHELLCHECK_ALL=1, runs the full check. Exit = shellcheck's.
  - test_fleet.sh:1141 `return "$rc"`: the one finding reduced mode raised on main.
  - shellcheck-suite target dropped (FLEET_SHELLCHECK_ALL=1 make shellcheck does it); the runner's
    tests run in CI (Shell lint runner tests), 10 cases with a fake cgroup tree.
- Live: `make shellcheck` here exits 0 at 1.4 GB peak (note: 1145 MiB of room).

## Next
- CI green, fresh-reader verify, merge (restore main's IMPL.md first).

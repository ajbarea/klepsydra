# IMPL: #416 agy cards read silent (PR #563, branch agy/silent-416-r2)

Issue: https://github.com/ajbarea/klepsydra/issues/416. Supersedes #508.

## Slice
Harness-neutral heartbeat from screen changes, and agy task state from the
pane's live child processes (Heph's rules, 11-24): a live child means working,
done only at an idle prompt with no live child, a listed task with no process
is stale.

## Done
- agy (rebuild of #508 r2): beat from screen diffs with spinners and timers
  stripped, numeric names refused, live-child working / done / stale rules in
  the resume service and `view.rs`.
- Opus takeover at the free-engine cap (11-25): CI run 45577068501 failed the
  live-child case because its fixture wrote to the real /proc. Pass 8 now
  builds a private fake proc root passed only to its own pass, with a setup
  check naming the path.
- That fixture hid a real bug: `fleet/lib.sh` `proc_stat` read with
  `read -d ''`, which returns 1 at EOF on every real stat file, so a zombie
  child counted as a live task and the ancestor walk stopped at once. It now
  reads like the hook's `proc_stat` (one line, at least 20 fields). A zombie
  case goes red on the old reader and green on the new.

## Verify
- The #416 block alone (prelude + section, under the heavy lock): 11/11;
  old `proc_stat`: the zombie case fails.
- CI runs the whole fleet suite.

## Next
1. 📋 Fresh Opus review of the whole PR against main, then merge.
2. Follow-up: `live_shells` now lives in both `fleet/lib.sh` and
   `hooks/klepsydra-fleet.sh`; one shared copy (as the session-rows block is
   shared) belongs with the hooks-common work.

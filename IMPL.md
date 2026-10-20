# IMPL

Current slice: prune the readings the overlay can never draw again (265 files
on the WSL station, 128 over a week old, all read on every refresh).

## Done
- ✅ A reading whose every window has ended is never published, so a pruned
  idle session cannot republish its last response as new.
- ✅ Hourly prune, detached under a `flock` (the docs: a slow status line
  blocks updates, and a new update cancels it). It follows `toRows` and
  `reconcilable`: a reading whose windows all ended over a day ago goes
  unless it is its account's newest, and that once the account is dropped
  (30 days); an account whose times the gauge does not trust keeps all until
  dropped. Unparseable, unstamped, unseen or just-rewritten (new inode)
  files stay. The parent forks only for the overlay's own dir.
- ✅ `src/gauge.js`: an account's label comes from its newest reading.
- ✅ "prune helpers" (data-dir guard, hourly runner) is one block in both
  hooks, checked identical, so the fleet's guard tests cover this prune.

## Verified, not inferred
- ✅ statusline 129 (47 new, on a fixed clock now), node 120, fleet 186,
  shellcheck clean.
- ✅ `toRows` agrees before and after, in the suite (old-hook and mixed
  accounts too) and on a copy of the station's readings (265 to 74 files).
- ✅ Dropping any guard fails the suite; the folder-name check also keeps a
  folder named `-rf` from reaching jq as an option. Only the "jq printed a
  globbed name" check is unreachable, as defence in depth.
- ✅ A render returns in about 20 ms while a prune runs (1.6 s first, 0.35 s
  after, on /mnt/c).
- ✅ Live: a real render ran the first prune (23:59:57 to 23:59:59, 265 to
  74 files) and the gauge drew the same rows. Readings backed up first.
- ✅ Review round 1: no data loss; fixed a delete racing a writer, untrusted
  accounts, unseen files counting as newest, a fork per render for a
  foreign dir, an octal stamp, six surviving mutants.
- ✅ Review round 2 (final): no data loss for files the hook writes; a
  1500-case fuzz of toRows found no change. Fixed ext4 handing a rewrite the
  old inode (now inode and mtime to the nanosecond), an empty team name
  (now "Team", as for a missing one), and jq reading floats, NaN, far-future
  stamps or non-string ids unlike the overlay (account left alone).
- 📋 Known edges, both needing readings the hook never writes: a misfiled
  reading with a later reset can surface once a newer one goes, and an old
  hook still writing the pre-move legacy folder is not mirrored.

## Open
- The tray icon still draws a bar in either layout.
- The default display name (`my-app-3f`) reaches no hook (`session_title`
  carries only a set name), so such a session is named by its folder.
- Some turns end with no hook (Esc on a need, an interrupt): the card keeps
  its state until the next prompt, or "working?" at 10 minutes. Probe
  2026-10-19 (2.1.301); the transcript's internal records are not parsed.

## Verify
    node --test src/*.test.js
    bash statusline/test_statusline.sh && bash hooks/test_fleet.sh
    bash scripts/test_measure_memory.sh
    (cd src-tauri && cargo test -p klepsydra-fleet && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings)
    bash scripts/build-windows.sh --check
    bash scripts/visual-check.sh

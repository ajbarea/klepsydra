# IMPL: tray Voices tick follows what keryx does (#337), branch fix/voices-337

Resume from this file, `git log`, the PR and its comments. Brief: issue #337 and its 11-13 comment.

## Slice
The tray's Voices tick shows keryx's real state, not the saved mode. `fleet voices` (every run but `--check`) keeps `keryx-paths.json` in the data folder: keryx's config as Windows opens it (`wslpath -w`) and the orchestrator's session file. When the pointer enters the tray icon or presses it, the app reads that file and keryx's `config.json` on a thread it waits on for at most 250 ms (`voices::Reader`), ticks the mode the config matches (Off / Everyone / Heph only) or none, and sets a status line above the modes (`keryx now: Off; saved: Heph only`). A late read shows itself when it lands; nothing is cached between opens. A click still saves through `fleet voices`.

## Done
- Pure logic + tests in `src-tauri/fleet/src/voices.rs` (keryx's parsing rules, tick/status, Reader with timeout and late answer); app glue in `src-tauri/src/voices.rs` and `main.rs` (`on_tray_icon_event`); `publish_paths` in `fleet/voices.sh` + `test_fleet.sh` #337 cases; README Voices section and `fleet voices` row.
- Mutation-checked: a cached tick, an ignored timeout, a dropped late answer, no busy guard are each caught.
- Opus review: round 1 (4 S) and round 2 (1 B: late answer ticking off the main thread could hang the tray; 2 S) fixed; round 3 clean, its panic nit fixed (035eeba). Late answers post to the main thread and apply only if newest (`Reader.stamp`).
- PR #376 open (bug, ajbarea), not merged.

## Next
1. Confirm the full suites on HEAD (test-fleet, launch, delegate, heavy-lock, slice, shellcheck, build-windows --check, browser suites) and CI; PR stays open for AJ's merge.
2. After merge: `make install-fleet` so the installed `fleet voices` writes `keryx-paths.json`; until it runs once the tray says "unknown (fleet voices has not run yet)".

## Verify
`cargo test -p klepsydra-fleet voices`, `make test-fleet`, `bash scripts/build-windows.sh --check` (KLEPSYDRA_STAGE=klepsydra-build-voices_337), `node --test src/*.test.js`.

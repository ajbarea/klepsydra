# IMPL: klepsydra#501, perf class (b): read only the files that changed

Branch perf/readers (worktree .claude/worktrees/perf-readers), PR #510 (Closes #501). Base origin/main 5dfdff5.
Push only: `git push -u origin perf/readers:perf/readers`. Never push to main. Do not merge (Athena merges).

## State (11-20, stopped for a Windows restart)
- Merged-ready history up to 43fd34d (CI green, my verify passes clean). Athena's independent round 1 on 43fd34d:
  NOT CLEAN, 2 Should-fix + nits: ~/.local/state/fleet-orchestrator/reports/readers-510-r1.md.
- HEAD = WIP commit answering round 1. UNTESTED: it compiles on Linux (`cargo check --tests`), nothing else ran.
  - SF1: `memo::Stamp` is now {len, modified, changed, id}; `Change` is gone. Unix: ctime + inode. Windows:
    `memo::win::list` lists with GetFileInformationByHandleEx(FileIdBothDirectoryInfo) (ChangeTime + FileId per
    entry, no call per file; falls back to std read_dir, unstamped, on ERROR_INVALID_PARAMETER), and
    `Stamp::of_file` reads the handle (GetFileInformationByHandle + FileBasicInfo). `memo::list` returns
    `Listed {name, kind, modified, stamp}`; scan.rs and usage.rs use it; bounded.rs uses `Stamp::of_file`.
    The still test is max(mtime, ctime) (`Stamp::last`).
  - Test clock: `memo::now()` runs RACY + 1 s ahead in tests (a just-written file has ctime = now); a test of
    the racy rule on real files sets `memo::REAL_CLOCK` on its thread (scan's a_file_written_just_now test).
  - Tests: in-place rewrite, recreate-without-pass and rename-replace are now cross-platform; new memo tests
    (change time keeps it racy, each stamp part compared, listing kinds + listed == handle stamp).
  - Nit: `UsageReader::read` in main.rs (lock/poison/read in one place); phone.rs uses it.
  - mutate.py anchors updated (15 mutations, every anchor occurs once); not yet run.

## Next (fresh session: rerun everything below; nothing after the WIP commit has passed)
1. `cd src-tauri/fleet && cargo fmt --check && flock -o /tmp/fleet-heavy.lock timeout 1500 cargo test -q --lib`; fix failures.
2. Windows type check: `CARGO_TARGET_DIR=<scratch>/wincheck flock -o /tmp/fleet-heavy.lock timeout 900 cargo clippy --target x86_64-pc-windows-msvc --lib --tests -- -D warnings`
   (target installed), then real Windows tests: `KLEPSYDRA_STAGE=klepsydra-build-perf_readers flock -o /tmp/fleet-heavy.lock timeout 2400 bash scripts/build-windows.sh --check`.
   Settle empirically there: the in-place test proves NTFS ChangeTime moves on write + set_modified.
3. `flock -o /tmp/fleet-heavy.lock timeout 3000 python3 docs/perf/2026-11-19-readers/mutate.py` (expect 15 of 15 killed); clippy on Linux.
4. SF2: app-level before/after on one copy of live data: build main (stage klepsydra-build-perf-before) and this
   branch (klepsydra-build-perf_readers), run each exe 60 s with its own KLEPSYDRA_DIR = a fresh copy of the data,
   `scripts/perf/io.ps1`; back up/restore %APPDATA% .window-state.json; stop only your own PID. If not done, say
   plainly in the PR body what was measured (old installed app live; readers per call on Windows) and what was not.
   Fix the PR body "Checked live" line either way; README "Not measured here" stays honest.
5. Rerun readcost (examples/readcost.rs) on Windows: the listing changed, so the after counts in the README change.
6. Update PR body (SF1 design + sources: MS FILE_ID_BOTH_DIR_INFO, MS-FSCC EaSize = reparse tag, Go os/dir_windows.go
   uses the same query), fresh Opus self-review, CI green, then report to Athena; a fresh reviewer runs round 2.

## Verify
- see Next 1-3. Data copy: C:\Users\ajbar\klepsydra-perf\data-1119 (delete when the PR merges).

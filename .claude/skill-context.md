# skill-context — klepsydra

Repo-specific facts the techne skills read. Logic lives in the skills; only facts
belong here.

## repo

- name: klepsydra
- kind: desktop application (always-on-top usage gauge). Public.
- default_branch: main
- description: a thin always-on-top bar showing how much of the Claude Code
  rate-limit window has been used, fed by the `statusLine` hook rather than by
  any API call
- language: JavaScript (frontend, `src/`), Rust (shell, `src-tauri/`), Bash
  (the two hooks and the build scripts)
- toolchain: Tauri 2 + Cargo for the shell, Node's built-in test runner for the
  gauge logic, shellcheck for the scripts. No bundler, no framework, no
  `package.json` dependency beyond `@tauri-apps/cli`.
- package_root: `src/` (frontend), `src-tauri/src/` (the Tauri shell),
  `src-tauri/fleet/` (the fleet reader, a workspace crate free of Tauri),
  `hooks/` (the fleet hook)
- platform: Windows and Linux (X11). The win32 calls behind the drag handle
  and the topmost re-assert compile only for Windows; the X11 button query
  (`x11rb`) only for Linux. Windows development happens in WSL; `scripts/build-windows.sh` stages to native NTFS
  because Cargo on a `\\wsl$` UNC path is slow and prone to link failures.
  Jump to terminal (UI Automation) also compiles only for Windows, and WSL
  has no WebKitGTK headers, so the app crate is checked with
  `bash scripts/build-windows.sh --check`; the fleet crate tests anywhere.
- runner: none. There is no `make`, no task runner, and no `logs/dev-<ts>-*.log`
  archive convention, so the audit's log-reconciliation phase is N/A.
- data flow: Claude Code pipes a JSON blob to the `statusLine` command on every
  render; `statusline/klepsydra-statusline.sh` prints the compact readout and
  publishes the figures to a small JSON file that the overlay polls. There is no
  second background process and no credential anywhere in the repository.

## audit

### Phase 1 — Setup

- `npm install` (only `@tauri-apps/cli`; the app itself has no JS dependencies)

### Phase 2 — Fix (one-way door)

- `cargo fmt` in `src-tauri/`

### Phase 3 — Lint

- `shellcheck hooks/*.sh statusline/*.sh scripts/*.sh` (in WSL:
  `uvx --from shellcheck-py shellcheck ...`)
- `cd src-tauri && cargo fmt --all --check`
- `cd src-tauri && cargo clippy --workspace --all-targets -- -D warnings`
  (in WSL: `-p klepsydra-fleet`, and `bash scripts/build-windows.sh --check`)

### Phase 4 — Test

Every change runs the whole Phase 3 and Phase 4 list, not only the suites its
files belong to: the JS guards scan hooks and scripts too.


- `node --test src/*.test.js` — ramp, countdown, reading age, reconciliation
  (newest reading wins), multi-account rows
- `bash statusline/test_statusline.sh` — the hook is the only path that publishes
  usage, so the cases cover what would otherwise fail silently: account
  identity, two accounts not overwriting each other, two sessions of one account
  keeping separate files (a shared file let an idle terminal overwrite an active
  one with a stale reading), a re-render publishing nothing (it would file
  the last reading under whichever login is current), gateway spend limit,
  malformed stdin, and an unwritable destination. `statusline/fixtures/*.json` supply the input blobs;
  the multi-account and unwritable cases are built in the script itself.
- `bash hooks/test_fleet.sh`: the fleet hook's states, where, identity,
  pruning (every refusal first) and the README settings block.
- `bash scripts/test_measure_memory.sh`: the release memory rule.
- `bash hooks/test_wrapup.sh`: the wrap-up Stop hook (silent unless a live
  request is unasked, never blocks a stop, fails open) and its reporter.
- `bash hooks/test_launch.sh`: the tmux launcher against a private tmux server
  and a stub `wt.exe` (one tab per fleet, a failed launch starts nothing).
- `bash scripts/test_build_windows.sh`: the Windows build's stage-name check.
- `cd src-tauri && cargo test -p klepsydra-fleet`: the fleet reader, the OTLP
  receiver (spawned on a free loopback port), the ledger, and `ledger-verify`
  on its recorded transcript fixture.
- `uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py`:
  the wall in a real browser: 16 demo cards at 1920x1000 and 8 at 945x1000
  fit in Auto (compact, no scrollbar, ring key in view); Auto re-checks when
  a card grows, never leaves a comfortable wall scrolling (a pixel at a time
  through the boundary, and where the comfortable bar is taller), and a
  compact note covers no text; the empty state (no sessions, or only ended
  ones) fits both sizes, a long launch folder fits 420 px, and its buttons
  send only launch_session and clear_session, each into its own note. Takes a few minutes. Needs
  Playwright's Chromium, or a Chrome at `$KLEPSYDRA_CHROME`; local only, not
  in CI.

### do_not_run (interactive / long-running / platform-bound)

- `scripts/cut-portraits.py`: recuts the committed kourai portraits; needs
  kourai-khryseai and Pillow through `uv`.
- `scripts/measure-memory.sh run`: takes 8 hours.
- `scripts/build-windows.sh` — rsyncs to `C:\Users\<user>\klepsydra-build` and
  drives `powershell.exe`; produces an NSIS installer and takes minutes.
  `KLEPSYDRA_STAGE=klepsydra-build-<name>` stages a branch in its own folder.
- `scripts/build-linux.sh` — full release build plus a `.deb`; takes minutes.
- `scripts/visual-check.sh` — spawns headless `chrome.exe` against a local
  server and writes screenshots to the Windows temp directory.
- `npm run tauri dev` — opens the overlay window and does not return.

## ci_audit

- workflows: `.github/workflows/ci.yml` (two jobs), and
  `.github/workflows/dependabot-auto-merge.yml`.
- `Gauge logic + statusLine hook` runs on `ubuntu-latest` with Node 24: unit
  tests, both hooks' tests, the release memory check's tests, shellcheck, and
  the install-directory guard.
- `Rust (fmt + clippy, <os>)` is a matrix over `windows-latest` and
  `ubuntu-latest`, for the reason in `## repo`; the Linux leg installs the
  WebKitGTK and tray headers first. Clippy is `-D warnings`, so a warning is a
  failure.
- required checks on `main`: `Gauge logic + statusLine hook` and both matrix
  legs of the Rust job.
- The install-directory guard greps the shell, JS and Rust sources for a path
  under `AppData\Local\Klepsydra` and fails if one appears; prose may name it. Readings belong in the app
  data dir and harness output in temp; the install directory is writable only by
  accident of the installer's mode, and a per-machine build would put it under
  Program Files where the write fails at runtime rather than in CI.
- `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` is set repo-wide in `env:`.

## slop_ground_truth

- The comments in `.github/workflows/ci.yml` beside the Windows runner choice
  and the install-directory guard record *why* each constraint exists, not what
  the step does. They are the reason the constraint survives a refactor.
- The header comment in `scripts/build-windows.sh` explains the NTFS staging
  copy and the explicit PATH rebuild. Both encode a failure that already
  happened; neither is restating the code.
- `statusline/fixtures/*.json` are regression fixtures, each standing for a
  real input shape the hook must survive. Adding a shape means adding a fixture.
- `src-tauri/fleet/tests/fixtures/transcripts/` holds transcript lines cut down to ids, times,
  model and usage (session and message ids replaced by placeholders; two lines of
  session 3 retimed to straddle New York's midnight) with matching ledger days.
- `src-tauri/fleet/tests/fixtures/otel/{delta,cumulative}/*.json` are OTLP/HTTP
  JSON exports recorded from live `claude -p` sessions (Claude Code 2.1.301),
  with `user.email`, `user.account_uuid`, `user.account_id`, `user.id` and
  `organization.id` replaced by fixed placeholders. Re-record rather than
  hand-edit when Claude Code's export shape changes.

## scan_scope

- include: `src/`, `src-tauri/src/`, `src-tauri/fleet/src/`, `hooks/`,
  `statusline/`, `scripts/`
- exclude: `node_modules/`, `src-tauri/target/`, `src-tauri/icons/`, `assets/`,
  `src/fleet/faces/` (kourai portraits cut by `scripts/cut-portraits.py`)
- `src/dev-fixture.json` and `src/dev-fleet.json` are harness input for
  `visual-check.sh`, excluded from both builds on purpose. `src/dev-fleet.json`
  is generated by that script and gitignored. The wall's `?demo` sample,
  `scripts/fixtures/fleet-demo.json`, sits outside `src/` so no build bundles
  it; serve the repo root and open `/src/wall.html?demo`.

## docs_site

- none. Documentation is `README.md`, `ROADMAP.md`, and `IMPL.md` at the root;
  there is no Zensical site, no `docs/` tree, and no Pages deploy. The docs-site
  dimension of any audit is N/A here.

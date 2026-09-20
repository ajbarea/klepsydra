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
  (the hook and the build scripts)
- toolchain: Tauri 2 + Cargo for the shell, Node's built-in test runner for the
  gauge logic, shellcheck for the scripts. No bundler, no framework, no
  `package.json` dependency beyond `@tauri-apps/cli`.
- package_root: `src/` (frontend), `src-tauri/src/main.rs` (single Rust file)
- platform: Windows only. The overlay is a Windows app, and the win32 calls
  behind the drag handle and the topmost re-assert compile for no other target.
  Development happens in WSL; `scripts/build-windows.sh` stages to native NTFS
  because Cargo on a `\\wsl$` UNC path is slow and prone to link failures.
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

- `shellcheck statusline/*.sh scripts/*.sh`
- `cd src-tauri && cargo fmt --check`
- `cd src-tauri && cargo clippy --all-targets -- -D warnings`

### Phase 4 — Test

- `node --test src/*.test.js` — ramp, countdown, staleness, multi-account rows
- `bash statusline/test_statusline.sh` — the hook is the only path that publishes
  usage, so the cases cover what would otherwise fail silently: account
  identity, two accounts not overwriting each other, two sessions of one account
  keeping separate files (a shared file let an idle terminal overwrite an active
  one with a stale reading), gateway spend limit, malformed stdin, and an
  unwritable destination. `statusline/fixtures/*.json` supply the input blobs;
  the multi-account and unwritable cases are built in the script itself.

### do_not_run (interactive / long-running / Windows-only)

- `scripts/build-windows.sh` — rsyncs to `C:\Users\<user>\klepsydra-build` and
  drives `powershell.exe`; produces an NSIS installer and takes minutes.
- `scripts/visual-check.sh` — spawns headless `chrome.exe` against a local
  server and writes screenshots to the Windows temp directory.
- `npm run tauri dev` — opens the overlay window and does not return.

## ci_audit

- workflows: `.github/workflows/ci.yml` (two jobs), and
  `.github/workflows/dependabot-auto-merge.yml`.
- `Gauge logic + statusLine hook` runs on `ubuntu-latest` with Node 22: unit
  tests, hook tests, shellcheck, and the install-directory guard.
- `Rust (fmt + clippy)` runs on `windows-latest`, for the reason in `## repo`.
  Clippy is `-D warnings`, so a warning is a failure.
- required checks on `main`: both job names above.
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

## scan_scope

- include: `src/`, `src-tauri/src/`, `statusline/`, `scripts/`
- exclude: `node_modules/`, `src-tauri/target/`, `src-tauri/icons/`, `assets/`
- `src/dev-fixture.json` is harness input for `visual-check.sh`, excluded from
  the Windows build on purpose.

## docs_site

- none. Documentation is `README.md`, `ROADMAP.md`, and `IMPL.md` at the root;
  there is no Zensical site, no `docs/` tree, and no Pages deploy. The docs-site
  dimension of any audit is N/A here.

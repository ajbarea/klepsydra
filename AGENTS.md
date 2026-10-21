# klepsydra

klepsydra is an always-on-top desktop gauge (Tauri 2 shell, plain JavaScript frontend, Bash hooks) that shows how much of the Claude Code usage limit is used, fed by the `statusLine` hook. Humans start with [README.md](README.md).

## Commands

`.claude/skill-context.md` (`## audit`) lists every suite, and every change runs all of them. Before a PR:

- `node --test src/*.test.js`
- `bash statusline/test_statusline.sh`, `bash hooks/test_fleet.sh`, `bash hooks/test_launch.sh` (needs tmux), `bash scripts/test_measure_memory.sh`, `bash scripts/test_build_windows.sh`
- `shellcheck hooks/*.sh statusline/*.sh scripts/*.sh` (under WSL: `uvx --from shellcheck-py shellcheck ...`)
- `(cd src-tauri && cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings)`
- `(cd src-tauri && cargo test -p klepsydra-fleet)`
- `uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py` (a few minutes; needs Playwright's Chromium; local only)

Under WSL the app crate cannot compile (no WebKitGTK headers): use `-p klepsydra-fleet` for clippy and `bash scripts/build-windows.sh --check` for the rest. From a worktree, set `KLEPSYDRA_STAGE=klepsydra-build-<name>` so it mirrors into a stage of its own; `<name>` takes only letters, digits, `.` and `_` (`scripts/build-windows.sh` refuses `-`), so write `agents-md` as `agents_md`.

## Rules

- Work in a git worktree and open a pull request; `main` is protected.
- Never commit `COMMITS.md` (a local scratchpad).
- The gauge never shows a confident wrong number: a stale reading says its age, an ended window says when it reset (ROADMAP, Design constraint).
- Usage readings come only from the `statusLine` hook. Add no API calls, credentials or second background process.
- Readings belong in the app data dir and harness output in temp. Never write an install-directory path (`AppData\Local\Klepsydra`, or `LOCALAPPDATA` / `local_data_dir` joined to klepsydra) in shell, JS or Rust sources; CI greps for it.
- The OTLP receiver listens only on `127.0.0.1:4318` and refuses requests carrying an `Origin` header. The ledger never stores the account email or organization ID the exports carry, and the fixtures in `src-tauri/fleet/tests/fixtures/otel/` hold placeholder identities: re-record them from a live session rather than hand-editing.
- Adding an input shape to the statusLine hook means adding a fixture in `statusline/fixtures/`.
- Do not run `scripts/measure-memory.sh run` (8 hours), `scripts/build-windows.sh` without `--check`, `scripts/build-linux.sh`, `scripts/visual-check.sh`, `scripts/cut-portraits.py` or `npm run tauri dev`; they are long, interactive or platform-bound.

## State

`IMPL.md` holds the current slice and next step; `ROADMAP.md` the long view.
`.claude/skill-context.md` holds the facts the techne skills read for this repo.

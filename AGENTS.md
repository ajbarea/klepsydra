# klepsydra

klepsydra is an always-on-top desktop gauge (Tauri 2 shell, plain JavaScript frontend, Bash hooks) that shows how much of the Claude Code usage limit is used, fed by the `statusLine` hook. Humans start with [README.md](README.md).

## Commands

There is no Makefile; the README's Tests section lists every suite. Run these before a PR:

- `node --test src/*.test.js`
- `bash statusline/test_statusline.sh`, `bash hooks/test_fleet.sh`, `bash scripts/test_measure_memory.sh`
- `shellcheck hooks/*.sh statusline/*.sh scripts/*.sh`
- `cd src-tauri && cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings`
- `cd src-tauri && cargo test -p klepsydra-fleet`

Under WSL the app crate cannot compile (no WebKitGTK headers): use `-p klepsydra-fleet` for clippy and `bash scripts/build-windows.sh --check` for the rest.

## Rules

- Work in a git worktree and open a pull request; `main` is protected.
- Never commit `COMMITS.md` (a local scratchpad).
- The gauge never shows a confident wrong number: a stale reading says its age, an ended window says when it reset (ROADMAP, Design constraint).
- Usage readings come only from the `statusLine` hook. Add no API calls, credentials or second background process.
- Readings belong in the app data dir and harness output in temp. Never write a path under `AppData\Local\Klepsydra` in shell, JS or Rust sources; CI greps for it.
- Prompt and response text stays redacted, and the OTLP fixtures in `src-tauri/fleet/tests/fixtures/otel/` hold placeholder identities. Re-record them from a live session rather than hand-editing.
- Adding an input shape to the statusLine hook means adding a fixture in `statusline/fixtures/`.
- Do not run `scripts/measure-memory.sh run` (8 hours), `scripts/build-windows.sh`, `scripts/build-linux.sh`, `scripts/visual-check.sh`, `scripts/cut-portraits.py` or `npm run tauri dev`; they are long, interactive or platform-bound.

## State

`IMPL.md` holds the current slice and next step; `ROADMAP.md` the long view.
`.claude/skill-context.md` holds the facts the techne skills read for this repo.

# IMPL: klepsydra#513: doctor: report when agy or Copilot model lists change (Gemini 4 Neon watch)

Branch feat/model-watch-513 (worktree .claude/worktrees/model-watch-513), cut from origin/main 7ed5e88.
Never push to main.

## Slice
- Record agy and Copilot available models in `$FLEET_STATE/models-<engine>.txt`.
- When vendor model lists change, emit a warning from `fleet doctor` indicating additions/removals and prompting routing review in `docs/engines.md`.

## Done
- `fleet/engines.sh`:
  - Added `eng_models` interface function to query model lists for `agy` (`agy models 2>/dev/null`) and `copilot` (`https://api.githubcopilot.com/models` API with fallback to `~/.copilot/data.db`).
  - Added mock environment variable support (`FLEET_AGY_MODELS`, `FLEET_AGY_MODELS_FILE`, `FLEET_COPILOT_MODELS`, `FLEET_COPILOT_MODELS_FILE`) for deterministic testing.
- `fleet/doctor.sh`:
  - Added model list monitoring loop over available engines.
  - Snapshot persistence in `$FLEET_MODELS_DIR/models-$e.txt` (default `$FLEET_STATE/models-$e.txt`).
  - Compares previous snapshot via `comm -13` / `comm -23`.
  - Reports `ok` on baseline capture and unchanged states (`N models (unchanged)`).
  - Reports `warn` on changes with `+added -removed` and advice to review routing in `docs/engines.md`.
- `docs/engines.md`:
  - Added `### Model discovery and routing review` section detailing empirical validation steps before workload rerouting when new models (such as Gemini 4 Neon) appear.
- `fleet/test_fleet.sh`:
  - Added test cases covering baseline model recording, unchanged status, model additions (+gemini-4-neon), and model removals.

## Next
- Verify with `make shellcheck` and tests.
- Commit conventional commit and push branch `feat/model-watch-513`.
- Open PR with team ceremony (under 150 words visible top, small plain table, `<details>` folded depth, `ajbarea` assignee, label, closing keyword).
- Post Elenchus bug-class self-review.

## Verify
- `make -C /home/ajbar/ajsoftworks/klepsydra/.claude/worktrees/model-watch-513 shellcheck`
- `make -C /home/ajbar/ajsoftworks/klepsydra/.claude/worktrees/model-watch-513 test-engine`
- Target doctor test execution in `test_fleet.sh`

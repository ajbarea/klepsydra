# IMPL: klepsydra#484 - Theme save reports success on corrupt prefs.json when default is picked

Branch `fix/theme-save-corrupt-prefs-484` (worktree `.claude/worktrees/theme-save-484`), cut from `origin/main` 7ed5e88.
Push only: `git push -u origin fix/theme-save-corrupt-prefs-484`. Never push to main.

## Slice
Prevent theme and preference setters from reporting false success when `prefs.json` is corrupt or unwritable.
`write_pref` and `write_pref_at` return `bool` indicating whether persistence succeeded; `theme::confirm` verifies `saved_ok` alongside value equality.

## Done
- `src-tauri/src/main.rs`:
  - `write_pref` and `write_pref_at` return `bool` (`true` when written and renamed successfully; `false` on unreadable JSON or IO error).
  - Added unit test `a_corrupt_prefs_file_is_refused_and_left_intact` verifying `{` in `prefs.json` returns `false` and leaves file untouched.
- `src-tauri/fleet/src/theme.rs`:
  - Updated `confirm(asked, saved, saved_ok) -> Result<(), String>`: requires `saved_ok && asked == saved`, so selecting the default theme on a corrupt/unwritten file returns an error instead of false success.
  - Updated unit test `a_choice_not_saved_says_so` verifying unwritten default theme returns error.
- `src-tauri/src/theme.rs`:
  - `set_theme`: passes `write_pref` return value `saved_ok` to `theme::confirm`.
- `src-tauri/src/opacity.rs`:
  - `set_gauge_opacity`: checks `saved_ok` from `write_pref`.
- `src-tauri/src/fleet.rs`:
  - `set_wall_density`: checks `write_pref` return value.
- `src-tauri/src/voices.rs`:
  - `on_menu`: checks `saved_ok` from `write_pref` before acknowledging mode change.

## Next
- Push branch `fix/theme-save-corrupt-prefs-484` and open PR with label `bug` and assignee `ajbarea`.
- Post Elenchus bug-class self-review on PR.
- Update desktop log and continue full auto.

## Verify
- `cargo fmt --all --check`: clean.
- `cargo check -p klepsydra-fleet --all-targets`: clean.
- `cargo test -p klepsydra-fleet`: 439 passed, 0 failed.
- `npm run lint`: 76 files clean.

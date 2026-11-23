# IMPL: #484 a prefs.json that cannot take a save says so (PR #522)

Branch fix/theme-save-corrupt-prefs-484 (agy's, reviewed and fixed by Opus agy-review-k 11-23).
Push: `git push origin fix/theme-save-corrupt-prefs-484:fix/theme-save-corrupt-prefs-484`. Never push to main.

## Done
- agy: write_pref/write_pref_at return whether the save took; set_theme, set_wall_density and
  the Voices menu check it.
- Opus r1:
  - set_new_session_default (same class) returned Ok on a refused save: now an error the
    wall's + New session note already shows.
  - set_wall_density's error was swallowed by the wall (`.catch(() => {})`): a density-note
    in the bar now says "Not saved: ..." and clears on the next save that takes.
  - theme::confirm: a refused save of the default read "still kourai, not kourai"; it now says
    the choice is not kept.
  - opacity: agy's extra branch repeated what opacity::confirm already reports; removed.
- Tests: theme confirm, saved_or_say, browser case refused_saves_say_so.

## Next
- CI (cargo test), wall browser suite locally, fresh-reader verify, merge.

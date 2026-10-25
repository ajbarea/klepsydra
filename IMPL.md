# IMPL

Slice: #58 Wrap up. Branch feat/wrap-up, worktree `.claude/worktrees/wrap-up`,
PR #82. Design: the 10-21 comment on #58.

## Done
- `hooks/klepsydra-wrapup.sh`: sync Stop hook (asks once per request through
  `additionalContext`, silent otherwise, fails open) and the reporter
  (`ready SESSION`, `blocked SESSION REASON`). `hooks/klepsydra-wrapup.md` is
  the skill, read from `${CLAUDE_CONFIG_DIR:-~/.claude}/skills/klepsydra-wrapup/`.
- Launcher `wrapup` verb: Ctrl+C, types `/klepsydra-wrapup`, Enter only when
  the line reads exactly that; refuses mid-turn; takes #22's pane lock, with
  its own refusal texts.
- Fleet crate `wrapup.rs` (request, answers, `route()`, start/cancel,
  create-only marks, `ask()`); app `start_wrapup` / `cancel_wrapup`.
- Wall: Wrap up… confirm grouped by route (`src/fleet/wrapup.js` mirrors
  `route()`, a guard parses both), card line, "N of M ready", Stop wrap-up,
  Safe to restart, End all ready sessions…. README "Wrapping up".
- Review round 2 fixed: answer times get the session files' clock
  correction and the script judges the request by the folder's clock; late
  reports; idle with background work routes Type; marks first, parallel
  typing; End all ready re-checks readiness; restart warning; wrapup/ watched.
- Review round 3 fixed: a ready answer counts once the Stop hook settles it
  (the turn that gave it ended) and until the next turn (`turn_at`, which the
  fleet hook stamps on every prompt, notifications too), never while working
  or waiting; the launcher judges mid-turn by the line above the input box
  (2.1.302 spinner fixtures); Start over keeps a running ask; each session is
  re-read just before typing; the reader makes `wrapup/` and drops a request
  past its hour; prune never follows a symlinked folder.
- Round 3 closing check fixed: mid-turn reads the first column-0 line above
  the box (tips under a spinner are indented; wrapped lines joined) and the
  footer's esc hint; Stop then Start over keeps an ask written within
  `WINDOW` (file time); "Working again" now says to ask again once idle.

## Next (resume state, 2026-10-25)
- 8694912 CI was red on two lint nits, fixed in the next commit:
  clippy `needless_borrows_for_generic_args` at `src-tauri/src/launch.rs`
  `.map_err(failed)` (CI clippy is Rust 1.99, newer than the local one), and
  shellcheck SC2015 in `klepsydra-wrapup.sh` (report's late-answer check).
  Wait for CI green on that commit; re-read PR #82 comments; squash-merge;
  remove this worktree, its branch and `C:\Users\ajbar\klepsydra-build-wrap_up`.
- Review is closed: rounds 1-3 done plus a round-3 closing check; no open
  Blocking or Should-fix. `/code-review high` is banned by AJ (medium + one
  reader, 3 rounds).
- One flake seen locally once (fleet crate, 1 of 297, under load; 8 clean
  reruns): the known receiver flake #75.
- Deploy waits for AJ's yes (see below). AJ decided nothing yet on: a
  working/background session never counts ready (my call, in the PR).

## Queue after #82 (each branch's IMPL.md holds its own state)
1. PR #83 (#46 empty state, `.claude/worktrees/empty-state`): review done
   (3 rounds), gate green at 7fd8d24. After #82 merges: rebase onto main
   (conflicts in src/fleet/wall.js, wall.html, wall.css, feed.js), rerun the
   gate, CI green, merge.
2. PR #88 (#86 Queue panel, `.claude/worktrees/queue-panel`): round-1
   fixes pushed at a1d039f. Next: a closing check of round 1 (one reader,
   not /code-review high), rebase after #82/#83, merge. Body says "Refs #86";
   close #86 after the live check on the installed build.
3. PR #89 (#32 split mode, `.claude/worktrees/split-mode`): round-1 fixes
   were in progress (red ubuntu clippy dead code, z-order behind the wall,
   select the fleet tab, SetWindowPlacement instead of SW_RESTORE, a
   Windows-only throwaway-window test). Read that worktree's git log and
   IMPL.md to see how far it got; finish, CI green, closing check, merge.
4. #52 phone wall (`feat/phone-wall`, built, not a PR yet): rebase after the
   above (it binds through receiver::bind, already pub(crate)), open the PR,
   review, merge. iPhone check is AJ's (Tailscale not installed).
- Every merge: delete the worktree, branch and its Windows staging folder
  `C:\Users\ajbar\klepsydra-build-<name>` (keep `klepsydra-build`).
- Deploy needs AJ's ok: copy `klepsydra-wrapup.sh` and the updated
  `klepsydra-fleet.sh` (it now stamps `turn_at`) to `~/.claude/`, the skill
  to `skills/klepsydra-wrapup/SKILL.md` in each config folder, the Stop hook
  block into both `settings.json`, and install the app build.

## Verify
- Full gate list in `.claude/skill-context.md`, plus `bash hooks/test_wrapup.sh`.
- `KLEPSYDRA_STAGE=klepsydra-build-wrap_up bash scripts/build-windows.sh --check`
- All heavy commands under `flock /tmp/fleet-heavy.lock`.

# IMPL: feat/fleet-module (PR #161), paused 10-28 23:5x

AJ re-prioritized: #159 ships, then techne#227, then klepsydra#162, then back here.
Stacked WIP: feat/two-accounts (1218281, untested): accounts-sync.sh, best_account,
move-at-a-limit, fleet accounts, doctor account checks.

## Review round 1 of #161 (fresh Opus reviewer) — all open, fix before merge
Blocking
- B1 install.sh/fleet cutover: live fleet units are TRANSIENT; `systemctl enable` of a
  same-named file fails ("transient or generated") and install.sh hides the error. Cutover
  must stop the transient units first, then daemon-reload + enable --now; test with a
  systemctl stub that refuses enable while transient. Also memfrag timer + wsl-mem-watch.
- B2 registry keyed by bare pane id: after a tmux restart %N is reused, so fresh() can
  /exit + kill another agent (or Heph). Check col 4 session id against klepsydra's fleet
  file for that pane (or stamp the tmux server pid) before /exit or kill-pane.
Should-fix
- S1 limit-menu check greps the whole screen: match only with no input box and the menu
  strings below the last rule.
- S2 "already sent" = grep -F first line anywhere above: match "❯ <line>" only.
- S3 retype replays the rendering ("[Pasted text #1 +2 lines]", wrap newlines): remember
  only what is reliable; for a paste marker, do not retype, log WARN instead.
- S4 typed text still changing at due time: wait one more pass.
- S5 holds_input only checks non-empty: compare input_text to what the script typed
  (/remote-control, /exit, MSG) before Enter; else back out its own chars.
- S6 fresh(): kill-pane before launch; launch failure loses the agent. Launch first? or
  keep pane until launch succeeds; log launch stderr; ERROR on new_pane=none.
- S7 launch.sh: pane found by diffing lists; registry rewrite unlocked. flock both.
- S8 doctor: gone registry rows FAIL forever (prune or warn for rows whose pane is gone
  and session ended); BEAT_MAX_S 180 < a pass with a fresh launch.
- S9 lost-input test injects the assumed cause; PR body states it as fact: reword; model
  a phone-sent note while limited.
Nits: reset time from $limit not whole screen; cutover greps old start line; install from
a worktree leaves dangling links (refuse unless main checkout); MSG left in box later read
as "AJ typed"; cutover starts with empty state.
Repro script: scratchpad repro/repro.sh (session-local).

# IMPL: fleet close refuses at-rest panes, the /exit menu wraps (#483)

Brief: fleet worker close-menu (task-close-menu.src). Branch fix/close-slash-menu, worktree
.claude/worktrees/close-menu. Push only `git push -u origin HEAD:refs/heads/fix/close-slash-menu`.
Do not merge: Heph reviews and merges. PR #496.

## Cause (found 11-19)
- Typing /exit opens Claude Code 2.1.316's command menu over the transcript's last rows. At 84
  columns two descriptions wrap, and close's filter dropped nothing, so it refused every close.
  At 160 nothing wraps, which is why close-454 closed at 00:02.

## Design now (11-20, after independent round 3)
- Round 3 (reports/close-496-r3.md): skipping the menu block plus a `menu_gap` refusal left every
  gap-layout pane refused forever, and its error said to type a bare /exit.
- Live probe 11-20 (2.1.316, private socket, haiku): `/exit ` with a trailing space opens no menu,
  and Enter on it exits (the pane went). Round 4 confirmed from the bundle: submit trims its input.
  Esc also shuts the menu but would interrupt a turn that started, so not used.
- close types `/exit `; the screen above the box must equal the one read before the quiet window
  byte for byte. screen_lines, same_transcript, menu_gap are gone. If the menu opens anyway: check
  `menu` ("fleet close needs updating"). Back-out (back_out) erases leftover /exit prefixes.
- Fixtures fleet/tests/close-screens/space-{gap,short,full}-{84,160}-* read same; 16 old menu
  captures read differs. fake_pane: menu shuts on a space; `slash_menu_space` keeps it open.

## Done 11-20
- 585ec37 (redesign + shellcheck SC2329/SC2034 fix): suite 1016/0; CI green (all jobs).
- Mutants (suite through the close section): no trailing space -> 8 close tests fail; no screen
  check -> 7 fail (later checks still refuse, nothing submitted). Both caught.
- Round 4 (fresh Opus, reports/close-496-r4.md): 0 Blocking, 1 Should-fix (live proof), 2 nits.
  Nits fixed in cb4b443 (check `menu` with its own message; back_out). Suite on cb4b443: 1017/0.

## Stopped here (PC restart 11-20)
- cb4b443 pushed; CI on it not yet seen.
- Live proof with the new code was stopped at its start: rerun it.

## Next (fresh session reruns these)
1. 📋 CI on cb4b443 green (`gh pr checks 496`).
2. 📋 Live proof (round-4 S1): `flock -o /tmp/fleet-heavy.lock timeout 1200 bash
   /tmp/claude-1001/close-menu-handoff/proof-v2.sh $PWD/fleet/close.sh 84 rest full busy bg wrapup`,
   then 160 (if /tmp was wiped: copy /tmp/claude-1001/close-menu-handoff/proof.sh, set SP to your
   scratchpad, `export FLEET_SESSION=t`, add a `full` scenario: rest after a 60-line reply).
   Want: rest and full closed; busy, bg, wrapup refused with their check.
3. 📋 Round 5: a fresh Opus reviewer verifies cb4b443 (diff 585ec37..cb4b443 + r4 report; write
   reports/close-496-r5.md). Stop at the first clean round.
4. 📋 PR body rewrite (short top: trailing-space design, live table, one results table).
5. 📋 Report to Heph (fleet send, else inbox/close-menu.md); note HEPH.md lines 14 and 19 still
   describe the pre-fix close (kill-pane advice): update after merge. Then `fleet done`.

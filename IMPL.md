# IMPL

Current slice: Ping (#48), branch feat/ping. A tray checkbox, off by default,
that plays a short chime when a session needs you or finishes its turn, and
stays silent under Windows Do Not Disturb, Focus and full-screen apps.

## Done
- Hook: every file carries `turns` (0 at creation, +1 at each Stop, the only
  event that ends a turn). `SessionFile.turns` is None only from an older
  hook (lenient parse); `View.marks` carries `turns` and the raw `state_at`
  (serde skip), since the skew correction moves between writes.
- `fleet/src/cue.rs`: the first snapshot asks for nothing. Needs-you or error
  cues when the raw `state_at` changed or the status just became needs-you
  (an unseen session: when its time is past the app's start). Done cues when
  `turns` changed on a session already seen; an older hook falls back to
  working -> done at a new state time. A session first seen silent is
  recorded so its turn's end still cues. Within `GAP` (2 s) only a higher
  rank plays. Absent sessions are forgotten a day after their last read.
- Known: a Stop that another Stop hook blocks chimes; the continuation's Stop
  chimes again. Nothing can know at Stop time that it will be blocked.
- `src/ping.rs` (Windows only): plays the embedded WAV with `PlaySoundW`
  (`SND_MEMORY | SND_ASYNC`). Quiet check: WNF quiet-hours profile (DND and
  Focus) and `SHQueryUserNotificationState` busy, D3D full screen,
  presentation (not `QUNS_APP`, which is any Store app). Ticking the box previews needs-you, past the check.
  Linux has no Ping: playing there means starting `pw-play`, and only the
  launcher may start a process (guard). A Linux chime needs an audio crate (#6).
- `fleet.rs`: on Windows the reader loop runs every snapshot through `Cues`, Ping on or off.
- `scripts/make-sounds.mjs` + `src/sounds.test.js`: the WAVs match the script;
  under 0.5 s; peak -3 dBFS (AJ picked the level by ear); a 10 ms release, so no click.
- README Ping section.

## Measured
- `SHQueryUserNotificationState` reads 5 with DND off, DND on and Focus on;
  the WNF profile reads 0, 1 and 1.
- Live on Windows, keryx off: done heard; silent with DND on; needs-you heard
  with DND off.

## Next
- Fourth review (of 5e6848a) found, to fix before merge:
  1. An older hook writing a file the new hook already counted keeps `turns` unchanged, so done never
     chimes again for that session. Fix: the hook writes `turns_at = written_at`; the reader trusts
     `turns` only when they match, else the fallback. Not "fallback when unchanged" (that brings back
     the chime on resume).
  2. README:239 note: the older rule also chimes on an Esc-interrupted turn; rewrap that sentence.
  3. cue.rs tests mostly hit the (None, Some) fallback: start them at Some(0) and step by 1; keep one
     deliberate None -> Some test.
- Live check with AJ, keryx off. Run the test copy as `C:\Users\ajbar\pingcheck\pingcheck.exe` with
  `KLEPSYDRA_DIR=C:\Users\ajbar\klepsydra-ping-test` (Ping off in prefs). Run a throwaway claude with
  `--setting-sources project --settings <branch-hook settings>`, built from the README block with each
  command set to this worktree's hook. Then: tick Ping in the tray (the preview plays and survives a
  restart), one done, one needs-you.
- Then merge; clean up the stage `klepsydra-build-ping`, `pingcheck`, `klepsydra-ping-test`.

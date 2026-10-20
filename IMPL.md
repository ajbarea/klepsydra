# IMPL

Current slice: Ping (#48), branch feat/ping. A tray checkbox, off by default,
that plays a short chime when a session needs you or finishes its turn, and
stays silent under Windows Do Not Disturb, Focus and full-screen apps.

## Done
- Hook: Stop stamps `turn_end = $now` (writer's clock); nothing else does.
  `SessionFile.turn_end`; `View.marks` carries the raw `state_at` and
  `turn_end` (serde skip), since the skew correction moves between writes.
- `fleet/src/cue.rs`: the first snapshot asks for nothing. Needs-you or error
  cues when the raw `state_at` changed or the status just became needs-you
  (an unseen session: when its time is past the app's start). Done cues only
  when `turn_end` changed on a session already seen. Silent views are
  skipped. Within `GAP` (2 s) only a higher rank plays. Absent sessions are
  forgotten a day after their last read, by the reader's clock.
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
- Review and merge.

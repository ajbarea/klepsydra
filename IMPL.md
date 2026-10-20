# IMPL

Current slice: Ping (#48), branch feat/ping. A tray checkbox, off by default,
that plays a short chime when a session needs you or finishes its turn, and
stays silent under Windows Do Not Disturb, Focus and full-screen apps.

## Done
- `fleet/src/cue.rs`: a cue answers a hook event. Only a status time past the
  last seen for that session (and past the app's start) can cue; silent views
  are skipped, so silence, a stale crew and a missed read never cue. Entering
  needs-you or error cues needs-you; done after working or done cues done.
  Within `GAP` (2 s) only a higher rank plays.
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

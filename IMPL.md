# IMPL

Current slice: Ping (#48), branch feat/ping. A tray checkbox, off by default,
that plays a short chime when a session needs you or finishes its turn, and
stays silent under Windows Do Not Disturb, Focus and full-screen apps.

## Done
- `fleet/src/cue.rs`: which cue a snapshot asks for. First snapshot is the
  baseline; entering needs-you or error asks for needs-you; working or silent
  to done asks for done; needs-you outranks done; one cue per `GAP` (2 s).
- `src/ping.rs` (Windows only): plays the embedded WAV with `PlaySoundW`
  (`SND_MEMORY | SND_ASYNC`). Quiet check: WNF quiet-hours profile (DND and
  Focus) and `SHQueryUserNotificationState` busy, D3D full screen,
  presentation, app. Ticking the box previews needs-you, past the check.
  Linux has no Ping: playing there means starting `pw-play`, and only the
  launcher may start a process (guard). A Linux chime needs an audio crate (#6).
- `fleet.rs`: on Windows the reader loop runs every snapshot through `Cues`, Ping on or off.
- `scripts/make-sounds.mjs` + `src/sounds.test.js`: the WAVs match the script;
  under 0.5 s; peak -3 dBFS. AJ picked the level by ear.
- README Ping section.

## Measured
- `SHQueryUserNotificationState` reads 5 with DND off, DND on and Focus on;
  the WNF profile reads 0, 1 and 1.
- Live on Windows, keryx off: done heard; silent with DND on; needs-you heard
  with DND off.

## Next
- Review and merge.
